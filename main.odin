// hw_activity_monitor — a menu bar watchdog for runaway processes.
//
// On a timer the app samples per-process CPU and memory through libproc, groups
// the samples by executable name, posts a Notification Center banner when a
// group stays above either budget, and appends JSONL events. A status item shows
// total CPU percent; clicking it opens a popover with the top groups and their
// processes. Notify only: it never kills anything.

package activity_monitor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

Monitor_State :: struct {
	config:  Config,
	policy:  Policy,
	log:     Log,
	sampler: Sampler,
	tracker: Tracker,
	history: History,
}

monitor: Monitor_State

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
	run_app(config)
}

// run_once samples twice and prints the busiest groups; a manual sanity check
// without a menu bar item or notification loop.
run_once :: proc(config: Config) {
	sampler: Sampler
	defer sampler_destroy(&sampler)
	sampler_scan(&sampler) // prime the counters
	time.sleep(1 * time.Second)

	samples := sampler_scan(&sampler)
	groups := group_samples(samples)
	fmt.printf(
		"%d processes, %d names (CPU budget %.0f%%, memory budget %.0f MB):\n",
		len(samples),
		len(groups),
		config.cpu_percent,
		config.memory_mb,
	)
	for group, index in groups {
		if index >= 15 {
			break
		}
		fmt.printf(
			"  %s\t%d proc\t%.1f%%\t%s\n",
			group.name,
			group.count,
			group.cpu_percent,
			format_bytes(group.memory_bytes),
		)
	}
	free_all(context.temp_allocator)
}

run_app :: proc(config: Config) {
	monitor.config = config
	monitor.policy = Policy{
		cpu_percent  = config.cpu_percent,
		memory_bytes = u64(config.memory_mb * f64(1 << 20)),
		sustained    = time.Duration(config.sustained_seconds * f64(time.Second)),
		cooldown     = time.Duration(config.cooldown_seconds * f64(time.Second)),
		safelist     = config.safelist,
	}
	monitor.history.window = time.Duration(config.window_seconds * f64(time.Second))
	monitor.log = log_open()
	backend := notify_init(monitor.log)

	log_event(monitor.log, "started", fmt.tprintf(
		"\"pid\":%d,\"interval_seconds\":%.0f,\"cpu_percent\":%.0f,\"memory_mb\":%.0f,\"sustained_seconds\":%.0f,\"cooldown_seconds\":%.0f,\"notifications\":%s",
		os.get_pid(),
		config.interval_seconds,
		config.cpu_percent,
		config.memory_mb,
		config.sustained_seconds,
		config.cooldown_seconds,
		log_string(fmt.tprintf("%v", backend)),
	))

	if !ui_start() {
		// No window server or AppKit: keep alerting without the status item.
		log_event(monitor.log, "ui_unavailable", "\"fallback\":\"headless\"")
		run_headless()
		return
	}
	if worker := thread.create(monitor_worker); worker != nil {
		thread.start(worker)
	}
	ui_run()
}

// monitor_worker samples and evaluates alerts off the main thread; the UI only
// receives finished snapshots, so its animations never wait on a scan.
monitor_worker :: proc(_: ^thread.Thread) {
	context = runtime.default_context()
	for {
		monitor_tick()
		time.sleep(time.Duration(monitor.config.interval_seconds * f64(time.Second)))
	}
}

// run_headless keeps alerting without a status item; used only when the UI
// cannot start.
run_headless :: proc() {
	for {
		monitor_tick()
		time.sleep(time.Duration(monitor.config.interval_seconds * f64(time.Second)))
	}
}

// monitor_tick is one sampling pass: scan, evaluate alerts, log and notify,
// then hand a snapshot to the menu bar UI. Called by the worker thread, or by
// the headless loop.
monitor_tick :: proc() {
	samples := sampler_scan(&monitor.sampler)
	groups := group_samples(samples)
	now := time.tick_now()
	history_append(&monitor.history, groups, now)
	trends := history_trends(&monitor.history, groups)
	alerts := tracker_evaluate(&monitor.tracker, groups, now, monitor.policy)
	for alert in alerts {
		body := alert_description(alert)
		notified := notify(alert_title(alert), body)
		log_event(monitor.log, "alert", fmt.tprintf(
			"\"kind\":%s,\"name\":%s,\"processes\":%d,\"cpu_percent\":%.1f,\"memory_bytes\":%d,\"sustained_seconds\":%.0f,\"pids\":[%s],\"notified\":%v",
			log_string(alert_kind_text(alert.kind)),
			log_string(alert.name),
			alert.count,
			alert.cpu_percent,
			alert.memory_bytes,
			time.duration_seconds(alert.sustained),
			alert_pid_list(alert),
			notified,
		))
	}
	ui_post_snapshot(
		groups,
		samples,
		trends,
		Ui_Build_Options{
			total_percent = ui_total_percent(samples, ui_active_cpu_count()),
			process_count = len(samples),
			stats = config_stat_selection(monitor.config),
		},
	)
	free_all(context.temp_allocator)
}
