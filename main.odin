// hw_activity_monitor — a small launchd daemon that notices runaway processes.
//
// It samples per-process CPU through libproc every few seconds, groups the
// samples by executable name, and posts a Notification Center banner when a
// group stays above the configured CPU budget for long enough. Notify only: it
// never kills anything.

package activity_monitor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

main :: proc() {
	once := false
	config_path_override := ""
	for argument in os.args[1:] {
		switch {
		case argument == "--once":
			once = true
		case strings.has_prefix(argument, "--config="):
			config_path_override = argument[len("--config="):]
		case:
			fmt.eprintln("usage: hw_activity_monitor [--once] [--config=PATH]")
			os.exit(2)
		}
	}

	config := config_defaults()
	path := config_path_override
	if path == "" {
		path = config_path()
	}
	config_load(&config, path)
	config_validate(&config)

	if once {
		run_once(config)
		return
	}
	run_loop(config)
}

// run_once samples twice and prints the busiest groups; a manual sanity check
// without starting a notification loop.
run_once :: proc(config: Config) {
	sampler: Sampler
	defer sampler_destroy(&sampler)
	sampler_scan(&sampler) // prime the counters
	time.sleep(1 * time.Second)

	samples := sampler_scan(&sampler)
	groups := group_cpu(samples)
	fmt.printf("%d processes, %d names (budget %.0f%%):\n", len(samples), len(groups), config.cpu_percent)
	for group, index in groups {
		if index >= 15 {
			break
		}
		fmt.printf("  %s\t%d proc\t%.1f%%\n", group.name, group.count, group.cpu_percent)
	}
	free_all(context.temp_allocator)
}

run_loop :: proc(config: Config) {
	log := log_open()
	defer log_close(log)
	backend := notify_init(log)

	policy := Policy{
		cpu_percent = config.cpu_percent,
		sustained   = time.Duration(config.sustained_seconds * f64(time.Second)),
		cooldown    = time.Duration(config.cooldown_seconds * f64(time.Second)),
		safelist    = config.safelist,
	}

	sampler: Sampler
	defer sampler_destroy(&sampler)
	tracker: Tracker
	defer tracker_destroy(&tracker)

	log_event(log, "started", fmt.tprintf(
		"\"pid\":%d,\"interval_seconds\":%.0f,\"cpu_percent\":%.0f,\"sustained_seconds\":%.0f,\"cooldown_seconds\":%.0f,\"notifications\":%s",
		os.get_pid(),
		config.interval_seconds,
		config.cpu_percent,
		config.sustained_seconds,
		config.cooldown_seconds,
		log_string(fmt.tprintf("%v", backend)),
	))

	for {
		samples := sampler_scan(&sampler)
		groups := group_cpu(samples)
		alerts := tracker_evaluate(&tracker, groups, time.tick_now(), policy)
		for alert in alerts {
			body := alert_description(alert)
			notified := notify("Runaway process", body)
			log_event(log, "alert", fmt.tprintf(
				"\"name\":%s,\"processes\":%d,\"cpu_percent\":%.1f,\"sustained_seconds\":%.0f,\"pids\":[%s],\"notified\":%v",
				log_string(alert.name),
				alert.count,
				alert.cpu_percent,
				time.duration_seconds(alert.sustained),
				alert_pid_list(alert),
				notified,
			))
		}
		free_all(context.temp_allocator)
		wait_with_run_loop(config.interval_seconds)
	}
}
