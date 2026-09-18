// Detection rules: group per-process CPU samples by executable name and alert
// when a group stays above the configured CPU budget for long enough.
//
// Everything here is pure: the clock arrives as a monotonic timestamp and no
// I/O happens, so the daemon loop owns scanning, logging, and notification.

package activity_monitor

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

// One process measured for the current scan.
Process_Cpu :: struct {
	pid:          i32,
	name:         string,
	cpu_fraction: f64, // fraction of one core; exceeds 1.0 for multithreaded work
}

// All processes sharing one executable name; the unit the rules alert on.
Group_Cpu :: struct {
	name:        string,
	count:       int,
	cpu_percent: f64,
	pids:        [dynamic]i32,
}

Policy :: struct {
	cpu_percent: f64, // group budget in percent of one core
	sustained:   time.Duration,
	cooldown:    time.Duration,
	safelist:    []string, // substring match against the executable name
}

Alert :: struct {
	name:        string,
	count:       int,
	cpu_percent: f64,
	sustained:   time.Duration,
	pids:        [dynamic]i32,
}

// group_cpu aggregates samples by executable name, highest CPU first. The
// result and the names inside it live in temporary storage: use them before the
// next free_all(context.temp_allocator).
group_cpu :: proc(samples: []Process_Cpu) -> []Group_Cpu {
	groups := make([dynamic]Group_Cpu, 0, len(samples), context.temp_allocator)
	if len(samples) == 0 {
		return groups[:]
	}

	by_name := make(map[string]int, len(samples), context.temp_allocator)
	defer delete(by_name)

	for sample in samples {
		assert(sample.cpu_fraction >= 0, "CPU fraction is never negative")
		index, found := by_name[sample.name]
		if !found {
			index = len(groups)
			by_name[sample.name] = index
			append(&groups, Group_Cpu{name = sample.name, pids = make([dynamic]i32, 0, 2, context.temp_allocator)})
		}
		group := &groups[index]
		group.count += 1
		group.cpu_percent += sample.cpu_fraction * 100
		append(&group.pids, sample.pid)
	}

	slice.sort_by(groups[:], proc(a, b: Group_Cpu) -> bool {
		return a.cpu_percent > b.cpu_percent
	})
	return groups[:]
}

// policy_safelisted reports whether a process name is deliberately exempt. The
// entry is a case-sensitive substring, so "odin" also covers wrapper names.
policy_safelisted :: proc(name: string, safelist: []string) -> bool {
	for entry in safelist {
		if entry == "" {
			continue
		}
		if strings.contains(name, entry) {
			return true
		}
	}
	return false
}

// Episode tracks one executable name from the moment its group crosses the
// budget until the group drops below it again.
Episode :: struct {
	above_since: time.Tick,
	alerted_at:  time.Tick,
	alerted:     bool,
}

Tracker :: struct {
	episodes: map[string]Episode, // keys are cloned and owned by the tracker
}

tracker_destroy :: proc(tracker: ^Tracker) {
	for name in tracker.episodes {
		delete(name)
	}
	delete(tracker.episodes)
}

// tracker_evaluate records the current state and returns the alerts due now:
// above budget, sustained long enough, and past the cooldown. A group that
// drops below the budget starts over from scratch. Alerts live in temporary
// storage; the tracker itself owns only its episode keys.
tracker_evaluate :: proc(
	tracker: ^Tracker,
	groups: []Group_Cpu,
	now: time.Tick,
	policy: Policy,
) -> []Alert {
	assert(tracker != nil, "tracker required")
	assert(policy.cpu_percent > 0, "budget must be positive")

	alerts := make([dynamic]Alert, 0, 8, context.temp_allocator)
	above := make(map[string]struct{}, context.temp_allocator)
	defer delete(above)

	for group in groups {
		if group.cpu_percent < policy.cpu_percent {
			continue
		}
		if policy_safelisted(group.name, policy.safelist) {
			continue
		}
		above[group.name] = {}

		state, found := tracker.episodes[group.name]
		if !found {
			tracker.episodes[strings.clone(group.name, context.allocator)] = Episode{above_since = now}
			continue
		}
		elapsed := time.tick_diff(state.above_since, now)
		if elapsed < policy.sustained {
			continue
		}
		if state.alerted && time.tick_diff(state.alerted_at, now) < policy.cooldown {
			continue
		}

		state.alerted = true
		state.alerted_at = now
		tracker.episodes[group.name] = state
		append(&alerts, Alert{
			name        = group.name,
			count       = group.count,
			cpu_percent = group.cpu_percent,
			sustained   = elapsed,
			pids        = group.pids,
		})
	}

	to_forget := make([dynamic]string, 0, len(tracker.episodes), context.temp_allocator)
	for name in tracker.episodes {
		if name not_in above {
			append(&to_forget, name)
		}
	}
	for name in to_forget {
		delete_key(&tracker.episodes, name)
		delete(name)
	}
	delete(to_forget)

	return alerts[:]
}

// alert_description renders the notification body for an alert.
alert_description :: proc(alert: Alert) -> string {
	pid_list := strings.builder_make(context.temp_allocator)
	for pid, index in alert.pids {
		if index > 0 {
			strings.write_string(&pid_list, ", ")
		}
		fmt.sbprintf(&pid_list, "%d", pid)
	}
	return fmt.tprintf(
		"%s — %d process%s at %.0f%% CPU for %.0f min (pids %s)",
		alert.name,
		alert.count,
		alert.count == 1 ? "" : "es",
		alert.cpu_percent,
		time.duration_minutes(alert.sustained),
		strings.to_string(pid_list),
	)
}
