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
FONT_BODY :: ui.Font_Handle(1)
FONT_BOLD :: ui.Font_Handle(2)

Panel_Palette :: struct {
	background: hw_clay.Color,
	border:     hw_clay.Color,
	text:       hw_clay.Color,
	secondary:  hw_clay.Color,
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
	return ui_state.snapshot.stats
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

// panel_content_changed recomputes the panel height for the current rows,
// resizes the window, and redraws if nothing else is driving the clock.
panel_content_changed :: proc() {
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

// panel_mark_dirty draws once when the animation clock is idle.
panel_mark_dirty :: proc() {
	if panel_window_is_animating() {
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

	hw_clay.set_pointer_state(&panel.clay, {-1, -1}, false)
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
	panel_draw_sparklines(rows, palette)
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
		// full width because it has no stats.
		panel_push_text(ctx, row.name, FONT_BODY, color, {hw_clay.grow(), hw_clay.grow()}, .Left, true)
		if row.kind == .Header {
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
	hw_clay.pop_element(ctx) // root
	return hw_clay.end_layout(ctx, PANEL_FRAME_SECONDS)
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

// panel_palette follows the system appearance; the panel is opaque so it does
// not need a backdrop blur, only a background that matches the current mode.
panel_palette :: proc() -> Panel_Palette {
	if panel_is_dark() {
		return {
			background = {24, 24, 26, 255},
			border     = {255, 255, 255, 28},
			text       = {235, 235, 240, 255},
			secondary  = {145, 145, 155, 255},
		}
	}
	return {
		background = {250, 250, 252, 255},
		border     = {0, 0, 0, 24},
		text       = {30, 30, 34, 255},
		secondary  = {105, 105, 115, 255},
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
