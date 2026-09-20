// Rolling history tests with a synthetic clock: no sampling, no I/O.

package activity_monitor

import "core:testing"
import "core:time"

@(test)
test_history_summarizes_the_window :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 60 * time.Second

	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 10, memory_bytes = 1 << 30}}, tick_at(0))
	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 30, memory_bytes = 2 << 30}}, tick_at(30))
	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 20, memory_bytes = 3 << 30}}, tick_at(60))

	trends := history_trends(&history, []Group_Sample{{name = "hog"}})
	testing.expect_value(t, len(trends), 1)
	testing.expect_value(t, len(trends[0].samples), 3)
	testing.expect(t, abs(trends[0].cpu_avg - 20) < 0.001, "average spans the window")
	testing.expect_value(t, trends[0].cpu_peak, f64(30))
	testing.expect_value(t, trends[0].memory_last, u64(3 << 30))
	testing.expect_value(t, trends[0].memory_growth, i64(2 << 30))
	testing.expect_value(t, trends[0].memory_peak, u64(3 << 30))
}

@(test)
test_history_drops_samples_outside_the_window :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 60 * time.Second

	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 10, memory_bytes = 1 << 30}}, tick_at(0))
	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 90, memory_bytes = 4 << 30}}, tick_at(120))

	trends := history_trends(&history, []Group_Sample{{name = "hog"}})
	testing.expect_value(t, len(trends[0].samples), 1)
	testing.expect(t, abs(trends[0].cpu_avg - 90) < 0.001, "the stale sample is gone")
	testing.expect_value(t, trends[0].memory_growth, i64(0))
}

@(test)
test_history_shrinking_window_prunes_older_samples :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 600 * time.Second

	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 10, memory_bytes = 1 << 30}}, tick_at(0))
	history.window = 60 * time.Second
	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 20, memory_bytes = 2 << 30}}, tick_at(120))

	trends := history_trends(&history, []Group_Sample{{name = "hog"}})
	testing.expect_value(t, len(trends[0].samples), 1)
	testing.expect(t, abs(trends[0].cpu_avg - 20) < 0.001)
}

@(test)
test_history_prunes_names_that_stopped_appearing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 60 * time.Second

	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 10}}, tick_at(0))
	testing.expect_value(t, len(history.entries), 1)

	// The name is missing for one tick: the trend survives inside the window.
	history_append(&history, []Group_Sample{{name = "other", cpu_percent = 5}}, tick_at(30))
	testing.expect_value(t, len(history.entries), 2)

	// Past the window, the vanished name is pruned and its key freed.
	history_append(&history, []Group_Sample{{name = "other", cpu_percent = 5}}, tick_at(90))
	testing.expect_value(t, len(history.entries), 1)
	testing.expect(t, "hog" not_in history.entries)
}

@(test)
test_history_growth_can_be_negative :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 60 * time.Second

	history_append(&history, []Group_Sample{{name = "hog", memory_bytes = 4 << 30}}, tick_at(0))
	history_append(&history, []Group_Sample{{name = "hog", memory_bytes = 1 << 30}}, tick_at(30))

	trends := history_trends(&history, []Group_Sample{{name = "hog"}})
	testing.expect_value(t, trends[0].memory_growth, -i64(3 << 30))
}

@(test)
test_history_trends_skip_unknown_names :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 60 * time.Second

	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 10}}, tick_at(0))
	trends := history_trends(&history, []Group_Sample{{name = "hog"}, {name = "unseen"}})
	testing.expect_value(t, len(trends), 1)
	testing.expect_value(t, trends[0].name, "hog")
}
