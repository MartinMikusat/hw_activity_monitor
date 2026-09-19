// Detection rules: group per-process CPU and memory samples by executable name
// and alert when a group stays above either budget for long enough. CPU and
// memory are independent dimensions: one group can alert for either or both.
//
// Everything here is pure: the clock arrives as a monotonic timestamp and no
// I/O happens, so the daemon loop owns scanning, logging, and notification.

package activity_monitor

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:time"

// One process measured for the current scan.
Process_Sample :: struct {
	pid:          i32,
	name:         string,
	cpu_fraction: f64, // fraction of one core; exceeds 1.0 for multithreaded work
	memory_bytes: u64, // physical footprint, the number Activity Monitor calls "Memory"
}

// All processes sharing one executable name; the unit the rules alert on.
Group_Sample :: struct {
	name:         string,
	count:        int,
	cpu_percent:  f64,
	memory_bytes: u64,
	pids:         [dynamic]i32,
}

Policy :: struct {
	cpu_percent:  f64, // group CPU budget in percent of one core
	memory_bytes: u64, // group footprint budget in bytes; 0 disables memory alerts
	sustained:    time.Duration,
	cooldown:     time.Duration,
	safelist:     []string, // substring match against the executable name
}

Alert_Kind :: enum {
	CPU,
	Memory,
}

Alert :: struct {
	kind:         Alert_Kind,
	name:         string,
	count:        int,
	cpu_percent:  f64,
	memory_bytes: u64,
	sustained:    time.Duration,
	pids:         [dynamic]i32,
}

// group_samples aggregates samples by executable name, highest CPU first. The
// result and the names inside it live in temporary storage: use them before the
// next free_all(context.temp_allocator).
group_samples :: proc(samples: []Process_Sample) -> []Group_Sample {
	groups := make([dynamic]Group_Sample, 0, len(samples), context.temp_allocator)
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
			append(&groups, Group_Sample{name = sample.name, pids = make([dynamic]i32, 0, 2, context.temp_allocator)})
		}
		group := &groups[index]
		group.count += 1
		group.cpu_percent += sample.cpu_fraction * 100
		group.memory_bytes += sample.memory_bytes
		append(&group.pids, sample.pid)
	}

	slice.sort_by(groups[:], proc(a, b: Group_Sample) -> bool {
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

// Episode tracks one executable name in one dimension from the moment its group
// crosses that budget until the group drops below it again.
Episode :: struct {
	above_since: time.Tick,
	alerted_at:  time.Tick,
	alerted:     bool,
}

Tracker :: struct {
	episodes_cpu:    map[string]Episode, // keys are cloned and owned by the tracker
	episodes_memory: map[string]Episode,
}

tracker_destroy :: proc(tracker: ^Tracker) {
	for name in tracker.episodes_cpu {
		delete(name)
	}
	delete(tracker.episodes_cpu)
	for name in tracker.episodes_memory {
		delete(name)
	}
	delete(tracker.episodes_memory)
}

// episode_advance updates one dimension's episode for a name and reports the
// elapsed time and whether an alert is due now. A group that drops below the
// budget is forgotten by tracker_evaluate, so its next rise starts over.
episode_advance :: proc(
	episodes: ^map[string]Episode,
	name: string,
	now: time.Tick,
	policy: Policy,
) -> (elapsed: time.Duration, due: bool) {
	assert(episodes != nil, "episodes required")
	state, found := episodes[name]
	if !found {
		episodes[strings.clone(name, context.allocator)] = Episode{above_since = now}
		return 0, false
	}
	elapsed = time.tick_diff(state.above_since, now)
	if elapsed < policy.sustained {
		return elapsed, false
	}
	if state.alerted && time.tick_diff(state.alerted_at, now) < policy.cooldown {
		return elapsed, false
	}
	state.alerted = true
	state.alerted_at = now
	episodes[name] = state
	return elapsed, true
}

// tracker_forget_stale drops the names that are no longer above the matching
// budget and frees their cloned keys, so the next rise starts a fresh episode.
// A dimension that drops below its own budget resets even if the other one
// stays hot.
tracker_forget_stale :: proc(tracker: ^Tracker, above_cpu, above_memory: map[string]struct{}) {
	assert(tracker != nil, "tracker required")
	forget_stale_episodes(&tracker.episodes_cpu, above_cpu)
	forget_stale_episodes(&tracker.episodes_memory, above_memory)
}

forget_stale_episodes :: proc(episodes: ^map[string]Episode, above: map[string]struct{}) {
	to_forget := make([dynamic]string, 0, len(episodes), context.temp_allocator)
	for name in episodes {
		if name not_in above {
			append(&to_forget, name)
		}
	}
	for name in to_forget {
		delete_key(episodes, name)
		delete(name)
	}
	delete(to_forget)
}

// tracker_evaluate records the current state and returns the alerts due now:
// above a budget, sustained long enough, and past the cooldown. CPU and memory
// keep separate episodes, so a group alerts once per dimension. A group that
// drops below a budget starts over from scratch. Alerts live in temporary
// storage; the tracker itself owns only its episode keys.
tracker_evaluate :: proc(
	tracker: ^Tracker,
	groups: []Group_Sample,
	now: time.Tick,
	policy: Policy,
) -> []Alert {
	assert(tracker != nil, "tracker required")
	assert(policy.cpu_percent > 0, "budget must be positive")

	alerts := make([dynamic]Alert, 0, 8, context.temp_allocator)
	above_cpu := make(map[string]struct{}, context.temp_allocator)
	above_memory := make(map[string]struct{}, context.temp_allocator)
	defer delete(above_cpu)
	defer delete(above_memory)

	for group in groups {
		if policy_safelisted(group.name, policy.safelist) {
			continue
		}
		cpu_above := group.cpu_percent >= policy.cpu_percent
		memory_above := policy.memory_bytes > 0 && group.memory_bytes >= policy.memory_bytes
		if !cpu_above && !memory_above {
			continue
		}

		if cpu_above {
			above_cpu[group.name] = {}
			if elapsed, due := episode_advance(&tracker.episodes_cpu, group.name, now, policy); due {
				append(&alerts, Alert{
					kind         = .CPU,
					name         = group.name,
					count        = group.count,
					cpu_percent  = group.cpu_percent,
					memory_bytes = group.memory_bytes,
					sustained    = elapsed,
					pids         = group.pids,
				})
			}
		}
		if memory_above {
			above_memory[group.name] = {}
			if elapsed, due := episode_advance(&tracker.episodes_memory, group.name, now, policy); due {
				append(&alerts, Alert{
					kind         = .Memory,
					name         = group.name,
					count        = group.count,
					cpu_percent  = group.cpu_percent,
					memory_bytes = group.memory_bytes,
					sustained    = elapsed,
					pids         = group.pids,
				})
			}
		}
	}

	tracker_forget_stale(tracker, above_cpu, above_memory)
	return alerts[:]
}

// alert_pid_list renders the alert's pids for messages and JSONL events.
alert_pid_list :: proc(alert: Alert) -> string {
	pid_list := strings.builder_make(context.temp_allocator)
	for pid, index in alert.pids {
		if index > 0 {
			strings.write_string(&pid_list, ", ")
		}
		fmt.sbprintf(&pid_list, "%d", pid)
	}
	return strings.to_string(pid_list)
}

// alert_title names the condition for the notification banner.
alert_title :: proc(alert: Alert) -> string {
	switch alert.kind {
	case .CPU:
		return "Runaway process"
	case .Memory:
		return "Runaway memory"
	}
	return "Runaway process"
}

// alert_kind_text names the condition for JSONL events.
alert_kind_text :: proc(kind: Alert_Kind) -> string {
	switch kind {
	case .CPU:
		return "cpu"
	case .Memory:
		return "memory"
	}
	return "cpu"
}

// alert_description renders the notification body for an alert. The CPU alert
// carries the footprint as context; the memory alert is about the footprint.
alert_description :: proc(alert: Alert) -> string {
	switch alert.kind {
	case .CPU:
		return fmt.tprintf(
			"%s — %d process%s at %.0f%% CPU and %s memory for %.0f min (pids %s)",
			alert.name,
			alert.count,
			alert.count == 1 ? "" : "es",
			alert.cpu_percent,
			format_bytes(alert.memory_bytes),
			time.duration_minutes(alert.sustained),
			alert_pid_list(alert),
		)
	case .Memory:
		return fmt.tprintf(
			"%s — %d process%s at %s memory for %.0f min (pids %s)",
			alert.name,
			alert.count,
			alert.count == 1 ? "" : "es",
			format_bytes(alert.memory_bytes),
			time.duration_minutes(alert.sustained),
			alert_pid_list(alert),
		)
	}
	return ""
}
