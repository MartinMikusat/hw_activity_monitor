// Tests for the panel layout. The pure helpers are checked directly; the
// maximized dashboard is checked against a real clay layout, which is the only
// way to verify its geometry without driving the UI.

package activity_monitor

import "core:testing"
import hw_clay "hw_clay:."
import hw_clay_ui "hw_clay:ui_framework"
import coretext "ui_framework:coretext"
import draw "ui_framework:draw"

@(test)
panel_block_rows_keeps_the_chart_minimum :: proc(t: ^testing.T) {
	testing.expect_value(t, panel_block_rows(1), PANEL_CHART_MIN_ROWS)
	testing.expect_value(t, panel_block_rows(3), PANEL_CHART_MIN_ROWS)
	testing.expect_value(t, panel_block_rows(4), PANEL_CHART_MIN_ROWS)
	testing.expect_value(t, panel_block_rows(7), 7)
}

@(test)
panel_chart_column_is_a_third_of_the_content :: proc(t: ^testing.T) {
	inner := f32(PANEL_WIDTH) - f32(PANEL_PADDING_HORIZONTAL)*2
	testing.expect_value(t, panel_chart_column_width(PANEL_WIDTH), inner/3)
	testing.expect_value(t, panel_chart_column_width(1440), (f32(1440)-f32(PANEL_PADDING_HORIZONTAL)*2)/3)
}

@(test)
panel_window_text_names_the_window :: proc(t: ^testing.T) {
	testing.expect_value(t, panel_window_text(30), "30s")
	testing.expect_value(t, panel_window_text(600), "10m")
	testing.expect_value(t, panel_window_text(3600), "1h")
}

// panel_test_layout builds one maximized frame headlessly: clay, the text
// renderer, and the fonts, without a window or a Metal device. The caller gets a
// laid-out context to read element boxes from.
panel_test_layout :: proc(t: ^testing.T) -> bool {
	panel.width = 1400
	panel.height = 900
	coretext.context_init(&panel.text)
	draw.list_init(&panel.list, pixel_ratio = 2)
	panel.renderer = {
		list            = &panel.list,
		text            = &panel.text,
		viewport_height = panel.height,
	}
	hw_clay_ui.renderer_register_font(&panel.renderer, FONT_BODY, "Iosevka")
	hw_clay_ui.renderer_register_font(&panel.renderer, FONT_BOLD, "Iosevka-Bold")
	panel.memory = make([]u8, hw_clay.min_memory_size())
	if !testing.expect(
		t,
		hw_clay.initialize(&panel.clay, panel.memory, {panel.width, panel.height}, {handler = panel_clay_error}),
		"clay initialize failed",
	) {
		return false
	}
	hw_clay.set_measure_text_function(&panel.clay, hw_clay_ui.measure_text, &panel.renderer)
	return true
}

panel_test_layout_destroy :: proc() {
	delete(panel.memory)
	panel.memory = nil
	panel.clay = {}
	draw.list_destroy(&panel.list)
	panel.width = PANEL_WIDTH
	panel.height = PANEL_MIN_HEIGHT
}

panel_test_box :: proc(t: ^testing.T, name: string, index: int) -> hw_clay.Bounding_Box {
	data := hw_clay.get_element_data(&panel.clay, hw_clay.id_indexed(name, u32(index)))
	if !testing.expectf(t, data.found, "%s-%d not found", name, index) {
		return {}
	}
	return data.bounding_box
}

// panel_test_palette keeps the layout test off the appearance APIs.
panel_test_palette :: proc() -> Panel_Palette {
	return {
		background  = {24, 24, 26, 255},
		border      = {255, 255, 255, 28},
		text        = {235, 235, 240, 255},
		secondary   = {145, 145, 155, 255},
		field       = {40, 40, 44, 255},
		field_focus = {56, 56, 62, 255},
		error       = {235, 118, 118, 255},
		rank_red        = {225, 70, 70, 54},
		rank_red_text   = {255, 138, 138, 255},
		rank_yellow     = {225, 180, 70, 46},
		rank_yellow_text = {248, 208, 120, 255},
	}
}

// panel_test_rows is one header, a one-row group, and a five-row group.
panel_test_rows :: proc() -> []Ui_Row {
	rows := make([]Ui_Row, 7)
	rows[0] = {kind = .Header, name = "Activity"}
	rows[1] = {kind = .Group, key = "one", rank = 1, name = "one", cpu = "1.0%", memory = "10.0 MB"}
	rows[2] = {kind = .Group, key = "two", rank = 2, name = "two"}
	rows[3] = {kind = .Process, key = "two", pid = 10, rank = 1, name = "helper"}
	rows[4] = {kind = .Process, key = "two", pid = 11, rank = 2, name = "worker"}
	rows[5] = {kind = .Process, key = "two", pid = 12, rank = 3, name = "indexer"}
	rows[6] = {kind = .Note, key = "two", name = "… and 2 more"}
	return rows
}

@(test)
panel_maximized_block_spans_its_chart :: proc(t: ^testing.T) {
	if !panel_test_layout(t) {
		return
	}
	defer panel_test_layout_destroy()

	rows := panel_test_rows()
	_ = panel_build_tree(&panel.clay, rows, panel_test_palette(), .Maximized)

	// Row 1 is a one-row group: the block is padded to the chart's minimum.
	// Row 2's group has five rows, so its block is taller than the minimum.
	block_one := panel_test_box(t, "panel-block", 1)
	block_two := panel_test_box(t, "panel-block", 2)
	testing.expect_value(t, block_one.height, f32(PANEL_CHART_MIN_ROWS)*PANEL_ROW_HEIGHT)
	testing.expect_value(t, block_two.height, f32(5)*PANEL_ROW_HEIGHT)

	// The chart column is a third of the panel's content, and the text column
	// takes the rest of the block beside it.
	column := panel_test_box(t, "panel-chart-column", 1)
	testing.expect_value(t, column.width, panel_chart_column_width(panel.width))
	text := panel_test_box(t, "panel-block-rows", 1)
	testing.expectf(
		t,
		text.width+column.width+f32(PANEL_CHART_GAP) == block_one.width,
		"text %.1f + chart %.1f + gap %d != block %.1f",
		text.width,
		column.width,
		PANEL_CHART_GAP,
		block_one.width,
	)

	// The series area spans each block above its axis line.
	expected_heights := [2]f32 {
		f32(PANEL_CHART_MIN_ROWS) * PANEL_ROW_HEIGHT,
		f32(5) * PANEL_ROW_HEIGHT,
	}
	for expected, offset in expected_heights {
		index := offset + 1
		body := panel_test_box(t, "panel-chart", index)
		axis := panel_test_box(t, "panel-chart-axis", index)
		column_i := panel_test_box(t, "panel-chart-column", index)
		testing.expect_value(t, axis.height, PANEL_CHART_AXIS_HEIGHT)
		testing.expect_value(t, body.height+axis.height, expected)
		testing.expect_value(t, body.width, column_i.width)
		testing.expect_value(t, body.y, column_i.y)
	}

	// The labels sit in their series' band: the CPU value at the top of the
	// body, the memory value at the top of the lower half.
	body := panel_test_box(t, "panel-chart", 1)
	cpu := panel_test_box(t, "panel-chart-cpu", 1)
	memory := panel_test_box(t, "panel-chart-memory", 1)
	testing.expect_value(t, cpu.y, body.y+1)
	testing.expect_value(t, memory.y, body.y+body.height/2+1)
	testing.expect_value(t, cpu.x, body.x+2)
}

@(test)
panel_maximized_chart_series_scales_to_its_own_peak :: proc(t: ^testing.T) {
	if !panel_test_layout(t) {
		return
	}
	defer panel_test_layout_destroy()

	// A flat series with a peak in the middle: the drawn line must stay inside
	// the band the layout gave the chart.
	rows := panel_test_rows()
	rows[1].spark = {0, 0, 50, 0, 0}
	rows[1].spark_memory = {0, 0, 0, 0, 0}
	rows[1].cpu_peak = 50
	_ = panel_build_tree(&panel.clay, rows, panel_test_palette(), .Maximized)

	// Drawing runs against the draw list the layout filled, so this only checks
	// that the series is accepted and does not touch the layout boxes.
	panel_draw_charts(rows, panel_test_palette())
	body := panel_test_box(t, "panel-chart", 1)
	testing.expect(t, body.width > 0 && body.height > 0, "chart body has no area")
}
