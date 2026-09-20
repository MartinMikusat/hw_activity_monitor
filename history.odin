// Rolling per-name history for the panel's trend columns. The daemon appends
// one sample per tick and drops samples that fall out of the configured window,
// so a window change, a missed tick, or a restart cannot corrupt the summary.
//
// Everything here is pure: the clock arrives as the tick passed in.

package activity_monitor

import "core:strings"
import "core:time"

// One tick's measurement for an executable name.
History_Sample :: struct {
	at:           time.Tick,
	cpu_percent:  f64,
	memory_bytes: u64,
}

// Group_Trend summarizes one name's window, oldest sample first. The samples
// slice borrows the history's storage: use it before the next history_append.
Group_Trend :: struct {
	name:          string,
	samples:       []History_Sample,
	cpu_avg:       f64,
	cpu_peak:      f64,
	memory_last:   u64,
	memory_growth: i64, // last minus first; negative when memory shrank
	memory_peak:   u64,
}

History_Entry :: struct {
	name:    string,
	samples: [dynamic]History_Sample,
}

History :: struct {
	window:  time.Duration,
	entries: map[string]^History_Entry, // keys are cloned and owned
}

history_destroy :: proc(history: ^History) {
	assert(history != nil, "history required")
	for _, entry in history.entries {
		delete(entry.samples)
		delete(entry.name, context.allocator)
		free(entry)
	}
	delete(history.entries)
}

// history_append records this tick's groups and drops samples that fell out of
// the window. Entries for names that stopped appearing are pruned once their
// newest sample ages out, so a group missing for one tick keeps its trend.
history_append :: proc(history: ^History, groups: []Group_Sample, now: time.Tick) {
	assert(history != nil, "history required")
	assert(history.window > 0, "history window must be positive")

	for group in groups {
		entry, found := history.entries[group.name]
		if !found {
			entry = new(History_Entry, context.allocator)
			entry.name = strings.clone(group.name, context.allocator)
			history.entries[entry.name] = entry
		}
		append(&entry.samples, History_Sample{
			at           = now,
			cpu_percent  = group.cpu_percent,
			memory_bytes = group.memory_bytes,
		})
		for len(entry.samples) > 0 && time.tick_diff(entry.samples[0].at, now) > history.window {
			ordered_remove(&entry.samples, 0)
		}
	}

	stale := make([dynamic]string, 0, len(history.entries), context.temp_allocator)
	for name, entry in history.entries {
		if len(entry.samples) == 0 || time.tick_diff(entry.samples[len(entry.samples)-1].at, now) > history.window {
			append(&stale, name)
		}
	}
	for name in stale {
		entry := history.entries[name]
		delete_key(&history.entries, name)
		delete(entry.samples)
		delete(entry.name, context.allocator)
		free(entry)
	}
	delete(stale)
}

// history_trends summarizes the window for each current group, in group order.
// Trends borrow the history's storage; use them before the next append.
history_trends :: proc(history: ^History, groups: []Group_Sample) -> []Group_Trend {
	assert(history != nil, "history required")
	trends := make([dynamic]Group_Trend, 0, len(groups), context.temp_allocator)
	for group in groups {
		entry, found := history.entries[group.name]
		if !found || len(entry.samples) == 0 {
			continue
		}
		trend := Group_Trend{
			name        = entry.name,
			samples     = entry.samples[:],
			memory_last = entry.samples[len(entry.samples)-1].memory_bytes,
		}
		trend.memory_growth = i64(trend.memory_last) - i64(entry.samples[0].memory_bytes)
		total: f64
		for sample in entry.samples {
			total += sample.cpu_percent
			trend.cpu_peak = max(trend.cpu_peak, sample.cpu_percent)
			trend.memory_peak = max(trend.memory_peak, sample.memory_bytes)
		}
		trend.cpu_avg = total / f64(len(entry.samples))
		append(&trends, trend)
	}
	return trends[:]
}
