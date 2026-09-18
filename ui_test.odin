// Popover model tests: row building is pure apart from its allocator.

package activity_monitor

import "core:testing"

@(test)
test_ui_rows_group_then_processes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	samples := []Process_Cpu{
		{pid = 11, name = "hw_clay", cpu_fraction = 0.9},
		{pid = 10, name = "hw_clay", cpu_fraction = 0.8},
		{pid = 12, name = "hw_clay", cpu_fraction = 0.7},
		{pid = 20, name = "Brave Browser", cpu_fraction = 0.3},
		{pid = 30, name = "mds", cpu_fraction = 0.001},
	}
	groups := group_cpu(samples)
	rows := ui_build_rows(groups, samples, 27, 498, context.temp_allocator)

	testing.expect_value(t, rows[0].kind, Ui_Row_Kind.Header)
	testing.expect_value(t, rows[0].name, "27% of all cores · 498 processes")
	testing.expect_value(t, rows[1].kind, Ui_Row_Kind.Group)
	testing.expect_value(t, rows[1].name, "hw_clay ×3")
	testing.expect_value(t, rows[1].value, "240%")
	testing.expect_value(t, rows[2].kind, Ui_Row_Kind.Process)
	testing.expect_value(t, rows[2].name, "    hw_clay · 11")
	testing.expect_value(t, rows[2].value, "90%")
	testing.expect_value(t, rows[3].value, "80%")
	testing.expect_value(t, rows[4].value, "70%")
	testing.expect_value(t, rows[5].name, "Brave Browser ×1")
	testing.expect_value(t, rows[6].value, "30%")
}

@(test)
test_ui_rows_limit_and_quiet_state :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	quiet := ui_build_rows(nil, nil, 0, 12, context.temp_allocator)
	testing.expect_value(t, len(quiet), 2)
	testing.expect_value(t, quiet[1].kind, Ui_Row_Kind.Note)
	testing.expect_value(t, quiet[1].name, "All quiet")

	samples := make([]Process_Cpu, UI_PROCESS_LIMIT_PER_GROUP + 2, context.temp_allocator)
	for _, index in samples {
		samples[index] = {pid = i32(100 + index), name = "hog", cpu_fraction = 0.5}
	}
	groups := group_cpu(samples)
	rows := ui_build_rows(groups, samples, 50, len(samples), context.temp_allocator)
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
	samples := []Process_Cpu{
		{cpu_fraction = 0.5},
		{cpu_fraction = 1.0},
		{cpu_fraction = 0.25},
	}
	testing.expect(t, abs(ui_total_percent(samples, 10) - 17.5) < 0.001)
	testing.expect_value(t, ui_total_percent(samples, 0), f64(0))
}
