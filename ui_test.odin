// Popover model tests: row building is pure apart from its allocator.

package activity_monitor

import "core:testing"
import "core:time"

test_stats :: proc() -> Stat_Selection {
	return {cpu = true, memory = true, window_cpu = true, window_memory = true}
}

test_options :: proc(total_percent: f64, process_count: int) -> Ui_Build_Options {
	return {total_percent = total_percent, process_count = process_count, config = config_defaults()}
}

@(test)
test_ui_rows_group_then_processes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	samples := []Process_Sample{
		{pid = 11, name = "hw_clay", cpu_fraction = 0.9, memory_bytes = 512 << 20},
		{pid = 10, name = "hw_clay", cpu_fraction = 0.8, memory_bytes = 512 << 20},
		{pid = 12, name = "hw_clay", cpu_fraction = 0.7, memory_bytes = 512 << 20},
		{pid = 13, name = "hw_clay", cpu_fraction = 0.004, memory_bytes = 1 << 20},
		{pid = 20, name = "Brave Browser", cpu_fraction = 0.3, memory_bytes = 256 << 20},
		{pid = 30, name = "mds", cpu_fraction = 0.001, memory_bytes = 1 << 20},
	}
	groups := group_samples(samples)
	rows := ui_build_rows(groups, samples, nil, test_options(27, 498), context.temp_allocator)

	testing.expect_value(t, rows[0].kind, Ui_Row_Kind.Header)
	testing.expect_value(t, rows[0].name, "27% of all cores · 498 processes")
	testing.expect_value(t, rows[1].kind, Ui_Row_Kind.Group)
	testing.expect_value(t, rows[1].name, "hw_clay ×4")
	testing.expect_value(t, rows[1].cpu, "240%")
	testing.expect_value(t, rows[1].memory, "1.50 GB")
	testing.expect_value(t, rows[2].kind, Ui_Row_Kind.Process)
	testing.expect_value(t, rows[2].name, "    hw_clay · 11")
	testing.expect_value(t, rows[2].cpu, "90%")
	testing.expect_value(t, rows[2].memory, "512.0 MB")
	testing.expect_value(t, rows[3].cpu, "80%")
	testing.expect_value(t, rows[3].memory, "512.0 MB")
	testing.expect_value(t, rows[4].cpu, "70%")
	testing.expect_value(t, rows[4].memory, "512.0 MB")
	testing.expect_value(t, rows[5].name, "Brave Browser ×1") // no note: the 0.4% member is not "hidden"
	testing.expect_value(t, rows[6].cpu, "30%")
	testing.expect_value(t, rows[6].memory, "256.0 MB")
}

@(test)
test_ui_rows_carry_windowed_stats_and_sparkline :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 600 * time.Second
	history_append(&history, []Group_Sample{{name = "leak", cpu_percent = 10, memory_bytes = 1 << 30}}, tick_at(0))
	history_append(&history, []Group_Sample{{name = "leak", cpu_percent = 30, memory_bytes = 3 << 30}}, tick_at(30))

	samples := []Process_Sample{{pid = 7, name = "leak", cpu_fraction = 0.3, memory_bytes = 3 << 30}}
	groups := group_samples(samples)
	trends := history_trends(&history, groups)
	rows := ui_build_rows(groups, samples, trends, test_options(5, 1), context.temp_allocator)

	testing.expect_value(t, rows[1].kind, Ui_Row_Kind.Group)
	testing.expect_value(t, rows[1].window_cpu, "avg 20%")
	testing.expect_value(t, rows[1].window_memory, "+2.00 GB")
	testing.expect_value(t, len(rows[1].spark), 2)
	testing.expect_value(t, rows[1].spark[0], f32(10))
	testing.expect_value(t, rows[1].spark[1], f32(30))
	// Process rows carry no window data.
	testing.expect_value(t, rows[2].window_cpu, "")
	testing.expect_value(t, len(rows[2].spark), 0)
}

@(test)
test_ui_rows_honor_the_stat_selection :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	samples := []Process_Sample{{pid = 1, name = "busy", cpu_fraction = 0.5, memory_bytes = 1 << 30}}
	groups := group_samples(samples)

	options := test_options(10, 1)
	options.config.show_cpu = false
	options.config.show_memory = false
	options.config.show_window_memory = false
	rows := ui_build_rows(groups, samples, nil, options, context.temp_allocator)
	testing.expect_value(t, rows[1].cpu, "")
	testing.expect_value(t, rows[1].memory, "")
	testing.expect_value(t, rows[2].cpu, "")
	testing.expect_value(t, rows[2].memory, "")
}

@(test)
test_ui_rows_elide_long_names :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	long := "com.apple.Virtualization.VirtualMachine"
	samples := []Process_Sample{{pid = 5765, name = long, cpu_fraction = 0.2, memory_bytes = 4 << 30}}
	groups := group_samples(samples)
	rows := ui_build_rows(groups, samples, nil, test_options(5, 1), context.temp_allocator)
	testing.expect_value(t, rows[1].name, "com.apple.Virtualizatio… ×1")
	testing.expect_value(t, rows[2].name, "    com.apple.Virtu… · 5765")
}

@(test)
test_ui_rows_include_memory_heavy_idle_group :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	samples := []Process_Sample{
		{pid = 1, name = "busy", cpu_fraction = 0.5},
		{pid = 2, name = "leak", cpu_fraction = 0.001, memory_bytes = 8 << 30},
	}
	groups := group_samples(samples)
	rows := ui_build_rows(groups, samples, nil, test_options(10, 2), context.temp_allocator)

	testing.expect_value(t, len(rows), 5)
	testing.expect_value(t, rows[1].name, "busy ×1")
	testing.expect_value(t, rows[3].kind, Ui_Row_Kind.Group)
	testing.expect_value(t, rows[3].name, "leak ×1")
	testing.expect_value(t, rows[3].cpu, "0.1%")
	testing.expect_value(t, rows[3].memory, "8.00 GB")
	testing.expect_value(t, rows[4].kind, Ui_Row_Kind.Process)
	testing.expect_value(t, rows[4].name, "    leak · 2")
	testing.expect_value(t, rows[4].cpu, "0.1%")
	testing.expect_value(t, rows[4].memory, "8.00 GB")
}

@(test)
test_ui_rows_limit_and_quiet_state :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	quiet := ui_build_rows(nil, nil, nil, test_options(0, 12), context.temp_allocator)
	testing.expect_value(t, len(quiet), 2)
	testing.expect_value(t, quiet[1].kind, Ui_Row_Kind.Note)
	testing.expect_value(t, quiet[1].name, "All quiet")

	samples := make([]Process_Sample, UI_PROCESS_LIMIT_PER_GROUP + 2, context.temp_allocator)
	for _, index in samples {
		samples[index] = {pid = i32(100 + index), name = "hog", cpu_fraction = 0.5}
	}
	groups := group_samples(samples)
	rows := ui_build_rows(groups, samples, nil, test_options(50, len(samples)), context.temp_allocator)
	testing.expect_value(t, rows[0].kind, Ui_Row_Kind.Header)
	testing.expect_value(t, rows[1].kind, Ui_Row_Kind.Group)
	testing.expect_value(t, rows[1].name, "hog ×6")
	for index in 2 ..< 2 + UI_PROCESS_LIMIT_PER_GROUP {
		testing.expect_value(t, rows[index].kind, Ui_Row_Kind.Process)
	}
	testing.expect_value(t, rows[2 + UI_PROCESS_LIMIT_PER_GROUP].kind, Ui_Row_Kind.Note)
	testing.expect_value(t, rows[2 + UI_PROCESS_LIMIT_PER_GROUP].name, "    … and 2 more")
}

@(test)
test_ui_total_percent :: proc(t: ^testing.T) {
	samples := []Process_Sample{
		{cpu_fraction = 0.5},
		{cpu_fraction = 1.0},
		{cpu_fraction = 0.25},
	}
	testing.expect(t, abs(ui_total_percent(samples, 10) - 17.5) < 0.001)
	testing.expect_value(t, ui_total_percent(samples, 0), f64(0))
}

@(test)
test_format_bytes_units :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, format_bytes(0), "0 KB")
	testing.expect_value(t, format_bytes(512 * 1024), "512 KB")
	testing.expect_value(t, format_bytes(512 << 20), "512.0 MB")
	testing.expect_value(t, format_bytes(2 << 30), "2.00 GB")
	testing.expect_value(t, format_bytes(12 << 30), "12.0 GB")
	testing.expect_value(t, format_bytes_delta(0), "0")
	testing.expect_value(t, format_bytes_delta(2 << 30), "+2.00 GB")
	testing.expect_value(t, format_bytes_delta(-(2 << 30)), "-2.00 GB")
}

@(test)
test_snapshot_round_trip_frees_cleanly :: proc(t: ^testing.T) {
	samples := []Process_Sample{
		{pid = 10, name = "hw_clay", cpu_fraction = 0.8, memory_bytes = 512 << 20},
		{pid = 20, name = "Brave Browser", cpu_fraction = 0.3, memory_bytes = 256 << 20},
	}
	groups := group_samples(samples)
	options := test_options(42, len(samples))
	rows := ui_build_rows(groups, samples, nil, options, context.allocator)
	snapshot := new(Ui_Snapshot, context.allocator)
	snapshot^ = {
		allocator     = context.allocator,
		total_percent = options.total_percent,
		process_count = options.process_count,
		config        = options.config,
		rows          = rows,
	}
	ui_snapshot_destroy(snapshot)
}

@(test)
test_snapshot_round_trip_quiet_state :: proc(t: ^testing.T) {
	rows := ui_build_rows(nil, nil, nil, test_options(0, 12), context.allocator)
	snapshot := new(Ui_Snapshot, context.allocator)
	snapshot^ = {allocator = context.allocator, rows = rows}
	ui_snapshot_destroy(snapshot)
}
