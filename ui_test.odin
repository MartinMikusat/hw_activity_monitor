// Popover model tests: row building is pure apart from its allocator.

package activity_monitor

import "core:testing"
import "core:time"
import draw "ui_framework:draw"
import coretext "ui_framework:coretext"
import hw_clay "hw_clay:."
import hw_clay_ui "hw_clay:ui_framework"

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
	testing.expect_value(t, rows[1].key, "hw_clay")
	testing.expect_value(t, rows[1].rank, 1)
	testing.expect_value(t, rows[1].cpu, "240%")
	testing.expect_value(t, rows[1].memory, "1.50 GB")
	testing.expect_value(t, rows[2].kind, Ui_Row_Kind.Process)
	testing.expect_value(t, rows[2].name, "  hw_clay · 11")
	testing.expect_value(t, rows[2].pid, i32(11))
	testing.expect_value(t, rows[2].rank, 1)
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
	// The name column is wide enough for this one now.
	testing.expect_value(t, rows[1].name, "com.apple.Virtualization.VirtualMachine ×1")
	testing.expect_value(t, rows[2].name, "  com.apple.Virtualization.VirtualMachine · 5765")

	// A name past the budget is elided with an ellipsis.
	longer := "com.apple.Virtualization.VirtualMachine.Helper.Renderer.Extension"
	long_samples := []Process_Sample{{pid = 7, name = longer, cpu_fraction = 0.2}}
	long_groups := group_samples(long_samples)
	long_rows := ui_build_rows(long_groups, long_samples, nil, test_options(5, 1), context.temp_allocator)
	testing.expect_value(t, long_rows[1].name, "com.apple.Virtualization.VirtualMachine.Helper.Renderer… ×1")
	testing.expect_value(t, long_rows[2].name, "  com.apple.Virtualization.VirtualMachine.Helper.Rende… · 7")
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

	// Combined urgency ranks the 8 GB group above the busy one.
	testing.expect_value(t, len(rows), 5)
	testing.expect_value(t, rows[1].kind, Ui_Row_Kind.Group)
	testing.expect_value(t, rows[1].name, "leak ×1")
	testing.expect_value(t, rows[1].rank, 1)
	testing.expect_value(t, rows[1].cpu, "0.1%")
	testing.expect_value(t, rows[1].memory, "8.00 GB")
	testing.expect_value(t, rows[2].kind, Ui_Row_Kind.Process)
	testing.expect_value(t, rows[2].name, "  leak · 2")
	testing.expect_value(t, rows[2].rank, 1)
	testing.expect_value(t, rows[3].kind, Ui_Row_Kind.Group)
	testing.expect_value(t, rows[3].name, "busy ×1")
	testing.expect_value(t, rows[3].rank, 2)
	testing.expect_value(t, rows[4].name, "  busy · 1")
}

@(test)
test_ui_rows_rank_by_cumulative_urgency :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	history: History
	defer history_destroy(&history)
	history.window = 600 * time.Second
	history_append(&history, []Group_Sample{{name = "leak", cpu_percent = 1, memory_bytes = 8 << 30}}, tick_at(0))
	history_append(&history, []Group_Sample{{name = "hog", cpu_percent = 50, memory_bytes = 100 << 20}}, tick_at(0))

	samples := []Process_Sample{
		{pid = 1, name = "leak", cpu_fraction = 0.01, memory_bytes = 8 << 30},
		{pid = 2, name = "hog", cpu_fraction = 0.5, memory_bytes = 100 << 20},
	}
	groups := group_samples(samples)
	trends := history_trends(&history, groups)
	rows := ui_build_rows(groups, samples, trends, test_options(60, 2), context.temp_allocator)

	// The leak's footprint is twice its budget; the hog uses 50 of 60 CPU.
	testing.expect_value(t, rows[1].key, "leak")
	testing.expect_value(t, rows[1].rank, 1)
	testing.expect_value(t, rows[2].key, "leak")
	testing.expect_value(t, rows[2].rank, 1)
	testing.expect_value(t, rows[3].key, "hog")
	testing.expect_value(t, rows[3].rank, 2)
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
	testing.expect_value(t, rows[2 + UI_PROCESS_LIMIT_PER_GROUP].name, "  … and 2 more")
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
test_ui_order_keeps_rows_in_place :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	order: Panel_Order
	defer ui_order_destroy(&order)

	first := []Ui_Row{
		{kind = .Header, name = "header"},
		{kind = .Group, key = "A", rank = 1, name = "A"},
		{kind = .Process, key = "A", pid = 1, rank = 1, name = "a1"},
		{kind = .Group, key = "B", rank = 2, name = "B"},
		{kind = .Process, key = "B", pid = 2, rank = 1, name = "b1"},
	}
	ordered := ui_order_rows(&order, first, tick_at(0), 600*time.Second, context.temp_allocator)
	testing.expect_value(t, len(ordered), 5)
	testing.expect_value(t, ordered[1].key, "A")
	testing.expect_value(t, ordered[3].key, "B")

	// B now ranks first, but the rows stay where they are: only the rank and
	// the values change.
	second := []Ui_Row{
		{kind = .Header, name = "header"},
		{kind = .Group, key = "B", rank = 1, name = "B"},
		{kind = .Process, key = "B", pid = 2, rank = 1, name = "b1"},
		{kind = .Group, key = "A", rank = 2, name = "A"},
		{kind = .Process, key = "A", pid = 1, rank = 1, name = "a1"},
	}
	ordered = ui_order_rows(&order, second, tick_at(5), 600*time.Second, context.temp_allocator)
	testing.expect_value(t, ordered[1].key, "A")
	testing.expect_value(t, ordered[1].rank, 2)
	testing.expect_value(t, ordered[3].key, "B")
	testing.expect_value(t, ordered[3].rank, 1)
}

@(test)
test_ui_order_adopt_sorts_to_the_ranks :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	order: Panel_Order
	defer ui_order_destroy(&order)

	rows := []Ui_Row{
		{kind = .Group, key = "B", rank = 1, name = "B"},
		{kind = .Process, key = "B", pid = 2, rank = 1, name = "b1"},
		{kind = .Group, key = "A", rank = 2, name = "A"},
		{kind = .Process, key = "A", pid = 1, rank = 1, name = "a1"},
	}
	_ = ui_order_rows(&order, rows, tick_at(0), 600*time.Second, context.temp_allocator)
	ui_order_adopt(&order, rows)
	testing.expect_value(t, order.groups[0].name, "B")
	testing.expect_value(t, order.groups[1].name, "A")
	testing.expect_value(t, order.groups[0].pids[0], i32(2))
}

@(test)
test_ui_order_appends_new_groups_and_prunes_stale :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	order: Panel_Order
	defer ui_order_destroy(&order)

	base := []Ui_Row{
		{kind = .Group, key = "A", rank = 1, name = "A"},
		{kind = .Group, key = "B", rank = 2, name = "B"},
	}
	_ = ui_order_rows(&order, base, tick_at(0), 600*time.Second, context.temp_allocator)

	// A new group C appears: it is appended, so the existing rows do not move.
	with_new := []Ui_Row{
		{kind = .Group, key = "C", rank = 1, name = "C"},
		{kind = .Group, key = "A", rank = 2, name = "A"},
	}
	ordered := ui_order_rows(&order, with_new, tick_at(10), 600*time.Second, context.temp_allocator)
	testing.expect_value(t, ordered[0].key, "A")
	testing.expect_value(t, ordered[1].key, "C")

	// B stays missing past the grace period and is dropped.
	_ = ui_order_rows(&order, with_new, tick_at(1200), 600*time.Second, context.temp_allocator)
	testing.expect_value(t, ui_order_find(&order, "B"), -1)
	testing.expect_value(t, len(order.groups), 2)
}

@(test)
test_ui_order_keeps_standalone_notes :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	order: Panel_Order
	defer ui_order_destroy(&order)
	rows := []Ui_Row{
		{kind = .Header, name = "header"},
		{kind = .Note, name = "All quiet"},
	}
	ordered := ui_order_rows(&order, rows, tick_at(0), 600*time.Second, context.temp_allocator)
	testing.expect_value(t, len(ordered), 2)
	testing.expect_value(t, ordered[1].name, "All quiet")
}

// The settings modal must stay flat: the panel root is the only element that
// paints a rectangle. This pins the bug where the root's between-children
// border drew separator lines across the settings rows.
@(test)
test_panel_settings_paints_only_the_root :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	coretext.context_init(&panel.text)
	defer coretext.context_destroy(&panel.text)
	draw.list_init(&panel.list, pixel_ratio = 2)
	defer draw.list_destroy(&panel.list)
	panel.renderer = {list = &panel.list, text = &panel.text, viewport_height = 192}
	hw_clay_ui.renderer_register_font(&panel.renderer, FONT_BODY, "Iosevka")
	hw_clay_ui.renderer_register_font(&panel.renderer, FONT_BOLD, "Iosevka-Bold")
	panel.memory = make([]u8, hw_clay.min_memory_size())
	defer delete(panel.memory)
	testing.expect(t, hw_clay.initialize(&panel.clay, panel.memory, {PANEL_WIDTH, 192}))
	hw_clay.set_measure_text_function(&panel.clay, hw_clay_ui.measure_text, &panel.renderer)

	palette := Panel_Palette{
		background  = {24, 24, 26, 255},
		border      = {255, 255, 255, 28},
		text        = {235, 235, 240, 255},
		secondary   = {145, 145, 155, 255},
		field       = {40, 40, 44, 255},
		field_focus = {56, 56, 62, 255},
		error       = {235, 118, 118, 255},
	}

	settings.open = true
	settings.texts[.Window] = "10"
	settings.texts[.Interval] = "5"
	defer {
		settings.open = false
		settings.texts[.Window] = ""
		settings.texts[.Interval] = ""
	}

	commands := panel_build_layout(&panel.clay, nil, palette)
	painted := 0
	for command in commands {
		switch data in command.render_data {
		case hw_clay.Rectangle_Render_Data:
			if data.background_color.a > 0 {
				painted += 1
			}
		case hw_clay.Text_Render_Data, hw_clay.Image_Render_Data, hw_clay.Custom_Render_Data, hw_clay.Border_Render_Data, hw_clay.Clip_Render_Data, hw_clay.Overlay_Color_Render_Data:
		}
	}
	testing.expect_value(t, painted, 1)
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
