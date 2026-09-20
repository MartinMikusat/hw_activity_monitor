// The panel surface: clay layout over the current snapshot, rendered through
// the ui_framework draw list into the panel's Metal layer.
//
// panel_window.odin owns the window, view, layer, input, and animation clock;
// this file owns the renderer, the layout, and the draw call. Every frame is
// laid out from scratch, so content changes and scrolling never touch AppKit
// views.

package activity_monitor

import "core:fmt"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import hw_clay "hw_clay:."
import hw_clay_ui "hw_clay:ui_framework"
import coretext "ui_framework:coretext"
import draw "ui_framework:draw"
import ui "ui_framework:core"
import metal "ui_framework:metal"
import QC "vendor:darwin/QuartzCore"
import MTL "vendor:darwin/Metal"

PANEL_WIDTH :: 540
PANEL_MIN_HEIGHT :: 160
PANEL_MAX_HEIGHT :: 560
PANEL_ROW_HEIGHT :: f32(20)
PANEL_FONT_SIZE :: u16(12)
// Stats columns are fixed width so the CPU and memory values line up
// vertically across rows. The widths cover the widest realistic text at
// PANEL_FONT_SIZE (Iosevka at 12 px advances 6 px per character): "2400%",
// "1023.9 MB", "avg 2400%", and "+1023.9 MB".
PANEL_STAT_CPU_WIDTH :: f32(46)
PANEL_STAT_MEMORY_WIDTH :: f32(66)
PANEL_STAT_WINDOW_CPU_WIDTH :: f32(58)
PANEL_STAT_WINDOW_MEMORY_WIDTH :: f32(78)
PANEL_SPARK_WIDTH :: f32(72)
PANEL_PADDING_HORIZONTAL :: u16(6)
PANEL_PADDING_VERTICAL :: u16(6)
PANEL_CORNER_RADIUS :: f32(10)
PANEL_FRAME_SECONDS :: f32(1.0 / 60.0)
UI_GROUP_LIMIT :: 10
UI_GROUP_MIN_PERCENT :: 0.5
UI_GROUP_MEMORY_MIN_MB :: 1024
UI_PROCESS_LIMIT_PER_GROUP :: 4
UI_PROCESS_MIN_PERCENT :: 1.0
UI_PROCESS_MEMORY_MIN_MB :: 512
SETTINGS_ROW_COUNT :: 9
SETTINGS_FIELD_WIDTH :: f32(90)
SETTINGS_CHECK_SIZE :: f32(16)
SETTINGS_BUTTON_WIDTH :: f32(64)
FONT_BODY :: ui.Font_Handle(1)
FONT_BOLD :: ui.Font_Handle(2)

Panel_Palette :: struct {
	background:  hw_clay.Color,
	border:      hw_clay.Color,
	text:        hw_clay.Color,
	secondary:   hw_clay.Color,
	field:       hw_clay.Color,
	field_focus: hw_clay.Color,
	error:       hw_clay.Color,
}

Panel :: struct {
	// Surface, created by panel_window.odin.
	window: ^NS.Panel,
	view:   ^NS.View,
	layer:  ^QC.MetalLayer,
	device: ^MTL.Device,
	queue:  ^MTL.CommandQueue,
	// Rendering stack.
	gpu:      metal.Renderer,
	text:     coretext.Context,
	list:     draw.List,
	renderer: hw_clay_ui.Renderer,
	clay:     hw_clay.Context,
	memory:   []u8,
	// Geometry.
	width:  f32,
	height: f32,
	// Animation progress (0 hidden, 1 settled) with its pivot and start offset,
	// set by panel_window.odin.
	progress: f32,
	anchor:   [2]f32,
	from:     [2]f32,
	// Pending wheel delta for the next frame, and a dirty flag for redraws that
	// happen outside the animation clock.
	scroll_delta: [2]f32,
	draw_dirty:   bool,
	// True while panel_draw runs: state changes made by a click handler must
	// not start a nested draw, and resizes must happen before the drawable is
	// acquired.
	drawing:      bool,
}

panel: Panel

panel_clay_error :: proc(data: hw_clay.Error_Data) {
	fmt.eprintf("[panel] clay error: %v: %s\n", data.error_type, data.error_text)
}

// panel_setup_renderer wires clay and the ui_framework renderer to the layer's
// device. The layer must already exist.
panel_setup_renderer :: proc(layer: ^QC.MetalLayer, device: ^MTL.Device, queue: ^MTL.CommandQueue) -> bool {
	if layer == nil || device == nil || queue == nil {
		return false
	}
	panel.layer = layer
	panel.device = device
	panel.queue = queue
	panel.width = PANEL_WIDTH
	panel.height = PANEL_MIN_HEIGHT
	panel.progress = 1
	panel.anchor = {PANEL_WIDTH, PANEL_MIN_HEIGHT}
	panel.from = {0, PANEL_TRANSLATE_START}

	if !metal.renderer_init(&panel.gpu, rawptr(device), "", uint(MTL.PixelFormat.BGRA8Unorm), true) {
		return false
	}
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
	if !hw_clay.initialize(&panel.clay, panel.memory, {panel.width, panel.height}, {handler = panel_clay_error}) {
		fmt.eprintln("[panel] clay initialize failed")
		return false
	}
	hw_clay.set_measure_text_function(&panel.clay, hw_clay_ui.measure_text, &panel.renderer)
	return true
}

panel_rows :: proc() -> []Ui_Row {
	if ui_state.snapshot == nil {
		return nil
	}
	return ui_state.snapshot.rows
}

// panel_stats reports which stat columns the current snapshot asks for; before
// the first snapshot, show everything.
panel_stats :: proc() -> Stat_Selection {
	if ui_state.snapshot == nil {
		return {cpu = true, memory = true, window_cpu = true, window_memory = true}
	}
	return config_stat_selection(ui_state.snapshot.config)
}

// panel_name_chars reports how many characters fit in the name column for a
// stat selection; row labels are elided to it so long names never collide with
// the stats. Iosevka advances half the font size per character, and one
// character is reserved as a margin so a label that exactly fills the column is
// never cut by the clip.
panel_name_chars :: proc(stats: Stat_Selection) -> int {
	fixed: f32
	columns := 0
	if stats.cpu {
		fixed += PANEL_STAT_CPU_WIDTH
		columns += 1
	}
	if stats.memory {
		fixed += PANEL_STAT_MEMORY_WIDTH
		columns += 1
	}
	if stats.window_cpu {
		fixed += PANEL_STAT_WINDOW_CPU_WIDTH + PANEL_SPARK_WIDTH
		columns += 2
	}
	if stats.window_memory {
		fixed += PANEL_STAT_WINDOW_MEMORY_WIDTH
		columns += 1
	}
	width := f32(PANEL_WIDTH-PANEL_PADDING_HORIZONTAL*2) - fixed - f32(columns*8)
	return int(width / (f32(PANEL_FONT_SIZE) * 0.5)) - 1
}

// panel_draw_sparklines draws each group's windowed CPU series as a polyline
// inside the element reserved for it. It runs after the clay commands, inside
// the same opacity and transform, so the line animates with the panel; the
// element box comes from clay's layout.
panel_draw_sparklines :: proc(rows: []Ui_Row, palette: Panel_Palette) {
	color := hw_clay_ui.color_to_draw(palette.secondary)
	for row, index in rows {
		if len(row.spark) < 2 {
			continue
		}
		data := hw_clay.get_element_data(&panel.clay, hw_clay.id_indexed("panel-spark", u32(index)))
		if !data.found {
			continue
		}
		box := hw_clay_ui.rect_to_draw(&panel.renderer, data.bounding_box)
		if box.w <= 1 || box.h <= 1 {
			continue
		}
		peak: f32
		for value in row.spark {
			peak = max(peak, value)
		}
		if peak <= 0 {
			continue
		}
		scale := box.h / peak
		draw.path_begin(&panel.list)
		draw.path_move_to(&panel.list, box.x, box.y+row.spark[0]*scale)
		for value, sample_index in row.spark {
			if sample_index == 0 {
				continue
			}
			x := box.x + box.w*f32(sample_index)/f32(len(row.spark)-1)
			draw.path_line_to(&panel.list, x, box.y+value*scale)
		}
		draw.path_stroke(&panel.list, color, 1, label = "spark")
	}
}

// panel_content_changed recomputes the panel height for the current content,
// resizes the window, and redraws if nothing else is driving the clock.
panel_content_changed :: proc() {
	if settings.open {
		panel_settings_resized()
		return
	}
	rows := panel_rows()
	height := clamp(
		f32(PANEL_PADDING_VERTICAL * 2) + f32(len(rows)) * PANEL_ROW_HEIGHT,
		PANEL_MIN_HEIGHT,
		PANEL_MAX_HEIGHT,
	)
	panel_set_size(panel.width, height)
	panel_mark_dirty()
}

panel_set_size :: proc(width, height: f32) {
	assert(width > 0 && height > 0)
	if panel.width == width && panel.height == height {
		return
	}
	panel.width = width
	panel.height = height
	panel.renderer.viewport_height = height
	panel.anchor = {panel.anchor.x, height}
	panel_window_set_frame(width, height)
}

// panel_mark_dirty draws once when the animation clock is idle. While a draw is
// in flight, it only flags the frame: the running draw already picks up the
// change, and a nested draw would present a stale-size frame after the correct
// one.
panel_mark_dirty :: proc() {
	if panel.drawing || panel_window_is_animating() {
		panel.draw_dirty = true
		return
	}
	panel_draw()
}

// panel_add_scroll queues one wheel delta; the display link applies it in the
// next frame so clay can smooth it.
panel_add_scroll :: proc(delta_x, delta_y: f32) {
	panel.scroll_delta.x += delta_x
	panel.scroll_delta.y += delta_y
}

panel_apply_scroll :: proc(delta_time: f32) {
	if panel.scroll_delta.x == 0 && panel.scroll_delta.y == 0 {
		return
	}
	hw_clay.update_scroll_containers(&panel.clay, false, {panel.scroll_delta.x, panel.scroll_delta.y}, delta_time)
	panel.scroll_delta = {0, 0}
}

panel_draw :: proc() {
	if panel.layer == nil || panel.queue == nil {
		return
	}
	panel.drawing = true
	defer panel.drawing = false

	// Pointer state and click handling run before the drawable is acquired:
	// a click can resize the panel (opening or closing settings), and the frame
	// must be encoded at the size it will be presented with.
	hw_clay.set_pointer_state(&panel.clay, panel_pointer_position(), panel_window.pointer_down)
	if panel_window.click_pending {
		panel_window.click_pending = false
		panel_handle_click()
	}

	scale := f32(1)
	if panel.window != nil {
		scale = f32(panel.window->backingScaleFactor())
	}
	drawable := panel.layer->nextDrawable()
	if drawable == nil {
		return
	}
	panel.layer->setContentsScale(NS.Float(scale))
	panel.layer->setDrawableSize({NS.Float(panel.width * scale), NS.Float(panel.height * scale)})

	metal.begin_texture_frame(&panel.gpu)
	coretext.begin_frame(&panel.text, scale, metal.atlas_io(&panel.gpu))
	draw.list_reset(&panel.list)

	panel_apply_scroll(PANEL_FRAME_SECONDS)
	hw_clay.set_layout_dimensions(&panel.clay, {panel.width, panel.height})
	rows := panel_rows()
	palette := panel_palette()
	commands := panel_build_layout(&panel.clay, rows, palette)

	draw.push_opacity(&panel.list, panel_opacity(panel.progress))
	draw.push_transform(&panel.list, panel_transform(
		panel.progress,
		panel.anchor.x,
		panel.anchor.y,
		panel.from.x,
		panel.from.y,
	))
	hw_clay_ui.render_commands(&panel.renderer, commands)
	if settings.open {
		panel_draw_settings_caret(palette)
	} else {
		panel_draw_sparklines(rows, palette)
	}
	draw.pop_transform(&panel.list)
	draw.pop_opacity(&panel.list)

	coretext.flush(&panel.text)

	command_buffer := panel.queue->commandBuffer()
	if !metal.encode_to_drawable(
		&panel.gpu,
		rawptr(command_buffer),
		rawptr(drawable->texture()),
		&panel.list,
		{panel.width, panel.height},
		scale,
		{0, 0, 0, 0},
	) {
		fmt.eprintln("[panel] encode failed")
		return
	}
	command_buffer->presentDrawable(drawable)
	command_buffer->commit()
	panel.draw_dirty = false
}

panel_build_layout :: proc(
	ctx: ^hw_clay.Context,
	rows: []Ui_Row,
	palette: Panel_Palette,
) -> []hw_clay.Render_Command {
	hw_clay.begin_layout(ctx)

	hw_clay.open_element(ctx, hw_clay.id("panel-root"))
	hw_clay.configure_element(ctx, {
		layout = {
			layout_direction = .Top_To_Bottom,
			sizing           = {hw_clay.grow(), hw_clay.grow()},
			padding          = {
				left   = PANEL_PADDING_HORIZONTAL,
				right  = PANEL_PADDING_HORIZONTAL,
				top    = PANEL_PADDING_VERTICAL,
				bottom = PANEL_PADDING_VERTICAL,
			},
		},
		background_color = palette.background,
		corner_radius    = hw_clay.corner_radius_all(PANEL_CORNER_RADIUS),
		border           = {color = palette.border, width = hw_clay.border_all(1)},
	})

	if settings.open {
		panel_settings_rows(ctx, palette)
	} else {
		panel_build_rows_list(ctx, rows, palette)
	}

	hw_clay.pop_element(ctx) // root
	return hw_clay.end_layout(ctx, PANEL_FRAME_SECONDS)
}

// panel_build_rows_list builds the scrollable group/process list.
panel_build_rows_list :: proc(ctx: ^hw_clay.Context, rows: []Ui_Row, palette: Panel_Palette) {
	hw_clay.open_element(ctx, hw_clay.id("panel-list"))
	hw_clay.configure_element(ctx, {
		layout = {sizing = {hw_clay.grow(), hw_clay.grow()}, layout_direction = .Top_To_Bottom},
		clip   = {vertical = true, child_offset = hw_clay.get_scroll_offset(ctx)},
	})

	stats := panel_stats()
	for row, index in rows {
		hw_clay.open_element(ctx, hw_clay.id_indexed("panel-row", u32(index)))
		hw_clay.configure_element(ctx, {
			layout = {
				sizing          = {hw_clay.grow(), hw_clay.fixed(PANEL_ROW_HEIGHT)},
				child_alignment = {y = .Center},
				child_gap       = 8,
			},
		})

		font, color := panel_row_style(row, palette)
		// The name grows so the stats sit against the panel's right padding.
		// Every row pushes the same enabled columns, empty where a row has no
		// value, so the table stays aligned vertically. The header spans the
		// full width because it has no stats; it carries the settings button.
		panel_push_text(ctx, row.name, FONT_BODY, color, {hw_clay.grow(), hw_clay.grow()}, .Left, true)
		if row.kind == .Header {
			panel_push_button(ctx, hw_clay.id("settings-gear"), "Settings", palette)
			hw_clay.pop_element(ctx)
			continue
		}
		if stats.cpu {
			panel_push_text(
				ctx,
				row.cpu,
				font,
				palette.text,
				{hw_clay.fixed(PANEL_STAT_CPU_WIDTH), hw_clay.grow()},
				.Right,
			)
		}
		if stats.memory {
			panel_push_text(
				ctx,
				row.memory,
				font,
				palette.text,
				{hw_clay.fixed(PANEL_STAT_MEMORY_WIDTH), hw_clay.grow()},
				.Right,
			)
		}
		if stats.window_cpu {
			panel_push_text(
				ctx,
				row.window_cpu,
				font,
				palette.secondary,
				{hw_clay.fixed(PANEL_STAT_WINDOW_CPU_WIDTH), hw_clay.grow()},
				.Right,
			)
			// The sparkline column reserves space for the series drawn after
			// the clay commands; only group rows carry one.
			hw_clay.open_element(ctx, hw_clay.id_indexed("panel-spark", u32(index)))
			hw_clay.configure_element(ctx, {
				layout = {
					sizing          = {hw_clay.fixed(PANEL_SPARK_WIDTH), hw_clay.grow()},
					child_alignment = {x = .Center, y = .Center},
				},
			})
			hw_clay.pop_element(ctx)
		}
		if stats.window_memory {
			panel_push_text(
				ctx,
				row.window_memory,
				font,
				palette.secondary,
				{hw_clay.fixed(PANEL_STAT_WINDOW_MEMORY_WIDTH), hw_clay.grow()},
				.Right,
			)
		}
		hw_clay.pop_element(ctx)
	}

	hw_clay.pop_element(ctx) // list
}

panel_row_style :: proc(row: Ui_Row, palette: Panel_Palette) -> (font: ui.Font_Handle, color: hw_clay.Color) {
	switch row.kind {
	case .Header, .Group:
		return FONT_BOLD, palette.text
	case .Note:
		return FONT_BODY, palette.secondary
	case .Process:
		return FONT_BODY, palette.text
	}
	return FONT_BODY, palette.text
}

// panel_push_text pushes one text element inside a sized wrapper. The name
// column grows; the fixed-width stat columns pass .Right as the wrapper's
// child alignment so values line up vertically across rows. Text elements
// always size to their content, so the wrapper carries the width and
// alignment. A clipped wrapper ignores its children's minimum widths and can
// shrink, which is what lets the growing name column yield space to the stats.
panel_push_text :: proc(
	ctx: ^hw_clay.Context,
	text: string,
	font: ui.Font_Handle,
	color: hw_clay.Color,
	sizing: hw_clay.Sizing,
	alignment: hw_clay.Alignment_X,
	clip_horizontal := false,
) {
	hw_clay.open_element(ctx)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = sizing,
			child_alignment = {x = alignment, y = .Center},
		},
		clip   = {horizontal = clip_horizontal},
	})
	hw_clay.push_text(ctx, text, {
		font_id   = u16(font),
		font_size = PANEL_FONT_SIZE,
		color     = color,
		wrap_mode = .None,
	})
	hw_clay.pop_element(ctx)
}

// ---------------------------------------------------------------- settings

// panel_settings_resized sizes the panel for the modal content and redraws.
panel_settings_resized :: proc() {
	height := clamp(
		f32(PANEL_PADDING_VERTICAL*2) + f32(SETTINGS_ROW_COUNT)*PANEL_ROW_HEIGHT,
		PANEL_MIN_HEIGHT,
		PANEL_MAX_HEIGHT,
	)
	panel_set_size(panel.width, height)
	panel_mark_dirty()
}

panel_settings_field_element :: proc(field: Settings_Field) -> hw_clay.Element_Id {
	return field == .Window ? hw_clay.id("settings-window") : hw_clay.id("settings-interval")
}

panel_settings_row_open :: proc(ctx: ^hw_clay.Context, index: int) {
	hw_clay.open_element(ctx, hw_clay.id_indexed("settings-row", u32(index)))
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.grow(), hw_clay.fixed(PANEL_ROW_HEIGHT)},
			child_alignment = {y = .Center},
			child_gap       = 8,
		},
	})
}

// panel_push_field pushes one editable value box; the text is left aligned so
// the caret can be measured from the box origin.
panel_push_field :: proc(
	ctx: ^hw_clay.Context,
	id: hw_clay.Element_Id,
	text: string,
	focused: bool,
	palette: Panel_Palette,
) {
	hw_clay.open_element(ctx, id)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.fixed(SETTINGS_FIELD_WIDTH), hw_clay.grow()},
			child_alignment = {x = .Left, y = .Center},
			padding         = {left = 4, right = 4},
		},
		background_color = focused ? palette.field_focus : palette.field,
		corner_radius    = hw_clay.corner_radius_all(4),
		border           = {color = palette.border, width = hw_clay.border_all(1)},
	})
	hw_clay.push_text(ctx, text, {
		font_id   = u16(FONT_BODY),
		font_size = PANEL_FONT_SIZE,
		color     = palette.text,
		wrap_mode = .None,
	})
	hw_clay.pop_element(ctx)
}

// panel_push_checkbox pushes a full-row toggle: label, then a small box that
// shows a check mark. The row carries the id, so the whole line is clickable.
panel_push_checkbox :: proc(
	ctx: ^hw_clay.Context,
	id: hw_clay.Element_Id,
	label: string,
	checked: bool,
	palette: Panel_Palette,
) {
	hw_clay.open_element(ctx, id)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.grow(), hw_clay.grow()},
			child_alignment = {y = .Center},
			child_gap       = 8,
		},
	})
	panel_push_text(ctx, label, FONT_BODY, palette.text, {hw_clay.grow(), hw_clay.grow()}, .Left)
	hw_clay.open_element(ctx)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.fixed(SETTINGS_CHECK_SIZE), hw_clay.fixed(SETTINGS_CHECK_SIZE)},
			child_alignment = {x = .Center, y = .Center},
		},
		background_color = checked ? palette.field_focus : palette.field,
		corner_radius    = hw_clay.corner_radius_all(4),
		border           = {color = palette.border, width = hw_clay.border_all(1)},
	})
	if checked {
		hw_clay.push_text(ctx, "✓", {
			font_id   = u16(FONT_BODY),
			font_size = PANEL_FONT_SIZE,
			color     = palette.text,
			wrap_mode = .None,
		})
	}
	hw_clay.pop_element(ctx)
	hw_clay.pop_element(ctx)
}

panel_push_button :: proc(
	ctx: ^hw_clay.Context,
	id: hw_clay.Element_Id,
	label: string,
	palette: Panel_Palette,
) {
	hw_clay.open_element(ctx, id)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.fixed(SETTINGS_BUTTON_WIDTH), hw_clay.grow()},
			child_alignment = {x = .Center, y = .Center},
		},
		background_color = palette.field,
		corner_radius    = hw_clay.corner_radius_all(4),
		border           = {color = palette.border, width = hw_clay.border_all(1)},
	})
	hw_clay.push_text(ctx, label, {
		font_id   = u16(FONT_BODY),
		font_size = PANEL_FONT_SIZE,
		color     = palette.text,
		wrap_mode = .None,
	})
	hw_clay.pop_element(ctx)
}

// panel_settings_rows builds the modal content inside the already open root.
panel_settings_rows :: proc(ctx: ^hw_clay.Context, palette: Panel_Palette) {
	row_index := 0

	panel_settings_row_open(ctx, row_index)
	panel_push_text(ctx, "Settings", FONT_BOLD, palette.text, {hw_clay.grow(), hw_clay.grow()}, .Left)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	panel_push_text(ctx, "History window (minutes)", FONT_BODY, palette.text, {hw_clay.grow(), hw_clay.grow()}, .Left)
	panel_push_field(
		ctx,
		hw_clay.id("settings-window"),
		settings.texts[.Window],
		settings.editing.active_field == settings_field_id(.Window),
		palette,
	)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	panel_push_text(ctx, "Sample interval (seconds)", FONT_BODY, palette.text, {hw_clay.grow(), hw_clay.grow()}, .Left)
	panel_push_field(
		ctx,
		hw_clay.id("settings-interval"),
		settings.texts[.Interval],
		settings.editing.active_field == settings_field_id(.Interval),
		palette,
	)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	panel_push_text(ctx, "Columns", FONT_BODY, palette.secondary, {hw_clay.grow(), hw_clay.grow()}, .Left)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	panel_push_checkbox(ctx, hw_clay.id("check-cpu"), "CPU", settings.draft.show_cpu, palette)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	panel_push_checkbox(ctx, hw_clay.id("check-memory"), "Memory", settings.draft.show_memory, palette)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	panel_push_checkbox(
		ctx,
		hw_clay.id("check-window-cpu"),
		"10-minute CPU average",
		settings.draft.show_window_cpu,
		palette,
	)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	panel_push_checkbox(
		ctx,
		hw_clay.id("check-window-memory"),
		"10-minute memory change",
		settings.draft.show_window_memory,
		palette,
	)
	hw_clay.pop_element(ctx)
	row_index += 1

	panel_settings_row_open(ctx, row_index)
	message_color := settings.message_is_error ? palette.error : palette.secondary
	panel_push_text(ctx, settings.message, FONT_BODY, message_color, {hw_clay.grow(), hw_clay.grow()}, .Left)
	panel_push_button(ctx, hw_clay.id("settings-cancel"), "Cancel", palette)
	panel_push_button(ctx, hw_clay.id("settings-save"), "Save", palette)
	hw_clay.pop_element(ctx)
}

// panel_pointer_position reports the pointer in clay coordinates; before the
// pointer has been seen, it is parked off panel so nothing is hovered.
panel_pointer_position :: proc() -> hw_clay.Vector2 {
	if !panel_window.pointer_valid {
		return {-1, -1}
	}
	return {panel_window.pointer.x, panel_window.pointer.y}
}

// panel_handle_click resolves a mouse-up against the previous frame's layout,
// which is what the user saw when they pressed.
panel_handle_click :: proc() {
	if !panel_window.visible || panel_window.animating {
		return
	}
	for id in hw_clay.get_pointer_over_ids(&panel.clay) {
		if settings_click(id) {
			return
		}
		if id == hw_clay.id("settings-gear") {
			settings_open()
			return
		}
	}
}

// panel_draw_settings_caret draws the caret in the focused settings field,
// after the clay commands, using the field's box and the measured prefix.
panel_draw_settings_caret :: proc(palette: Panel_Palette) {
	if !settings.open {
		return
	}
	field, found := settings_field_for_id(settings.editing.active_field)
	if !found {
		return
	}
	text := settings.texts[field]
	caret := clamp(settings.editing.caret_byte_offset, 0, len(text))
	data := hw_clay.get_element_data(&panel.clay, panel_settings_field_element(field))
	if !data.found {
		return
	}
	box := hw_clay_ui.rect_to_draw(&panel.renderer, data.bounding_box)
	config := hw_clay.Text_Config{font_id = u16(FONT_BODY), font_size = PANEL_FONT_SIZE}
	prefix_width := hw_clay_ui.measure_text(text[:caret], &config, &panel.renderer).width
	draw.solid(
		&panel.list,
		{box.x+4+prefix_width, box.y+3, 1, box.h-6},
		hw_clay_ui.color_to_draw(palette.text),
	)
}

// panel_palette follows the system appearance; the panel is opaque so it does
// not need a backdrop blur, only a background that matches the current mode.
panel_palette :: proc() -> Panel_Palette {
	if panel_is_dark() {
		return {
			background  = {24, 24, 26, 255},
			border      = {255, 255, 255, 28},
			text        = {235, 235, 240, 255},
			secondary   = {145, 145, 155, 255},
			field       = {40, 40, 44, 255},
			field_focus = {56, 56, 62, 255},
			error       = {235, 118, 118, 255},
		}
	}
	return {
		background  = {250, 250, 252, 255},
		border      = {0, 0, 0, 24},
		text        = {30, 30, 34, 255},
		secondary   = {105, 105, 115, 255},
		field       = {236, 236, 240, 255},
		field_focus = {224, 224, 230, 255},
		error       = {190, 60, 60, 255},
	}
}

panel_is_dark :: proc() -> bool {
	app := msg_id0(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	if app == nil {
		return true
	}
	appearance := msg_id0(app, sel_registerName("effectiveAppearance"))
	if appearance == nil {
		return true
	}
	name := nsstring_to_string(msg_id0(appearance, sel_registerName("name")))
	return strings.contains(name, "Dark")
}
