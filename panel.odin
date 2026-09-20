// The panel surface: clay layout over the current snapshot, rendered through
// the ui_framework draw list into the panel's Metal layer.
//
// panel_window.odin owns the window, view, layer, input, and animation clock;
// this file owns the renderer, the layout, and the draw call. Every frame is
// laid out from scratch, so content changes and scrolling never touch AppKit
// views.

package activity_monitor

import "base:runtime"
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

PANEL_WIDTH :: 720
PANEL_MIN_HEIGHT :: 160
PANEL_MAX_HEIGHT :: 560
PANEL_ROW_HEIGHT :: f32(20)
PANEL_FONT_SIZE :: u16(12)
// Stats columns are fixed width so the CPU and memory values line up
// vertically across rows. The widths cover the widest realistic text at
// PANEL_FONT_SIZE (Iosevka at 12 px advances 6 px per character): "2400%",
// "1023.9 MB", "avg 2400%", and "+1023.9 MB". Everything left over belongs to
// the name column.
PANEL_STAT_CPU_WIDTH :: f32(42)
PANEL_STAT_MEMORY_WIDTH :: f32(62)
PANEL_STAT_WINDOW_CPU_WIDTH :: f32(42)
PANEL_STAT_WINDOW_MEMORY_WIDTH :: f32(70)
PANEL_SPARK_WIDTH :: f32(60)
// The rank column holds the index number on group rows; process rows keep the
// column empty and put their rank inline, indented, next to the label.
PANEL_RANK_WIDTH :: f32(22)
PANEL_PROCESS_RANK_WIDTH :: f32(38)
PANEL_PROCESS_RANK_CHARS :: 6

// The rank cell's text: the indented inline rank on process rows.
panel_process_rank_text :: proc(rank: int) -> string {
	if rank <= 0 {
		return ""
	}
	return fmt.tprintf("    %d", rank)
}
// The gap between a row's cells. Kept small so names get the space.
PANEL_ROW_GAP :: 6
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
	// Rank highlights: the row background and the index color for the top
	// consumer (red) and the next three (yellow).
	rank_red:        hw_clay.Color,
	rank_red_text:   hw_clay.Color,
	rank_yellow:     hw_clay.Color,
	rank_yellow_text: hw_clay.Color,
}

Panel_Mode :: enum {
	Popover,
	Maximized,
}

// Seconds for one direction of the cross-fade. There is no scale or translation
// on a mode switch: the window resizes instantly and only the content fades.
PANEL_MODE_FADE_SECONDS :: f32(0.15)
PANEL_MAXIMIZED_MARGIN :: f64(16)

panel_mode: Panel_Mode = .Popover

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
	// The maximized tree has its own clay context, so a mode switch can draw
	// both layouts in one frame without the two trees sharing element ids or
	// layout dimensions.
	clay_maximized: hw_clay.Context,
	memory_maximized: []u8,
	// Geometry.
	width:  f32,
	height: f32,
	// Animation progress (0 hidden, 1 settled) with its pivot and start offset,
	// set by panel_window.odin.
	progress: f32,
	anchor:   [2]f32,
	from:     [2]f32,
	// Mode cross-fade: 0 shows only the popover tree, 1 only the maximized tree.
	// `panel_mode` is already the target while this animates.
	crossfade:        f32,
	crossfade_target: f32,
	// A maximized open/close fades without the popover's scale and translation.
	fade_only: bool,
	// Pending wheel delta for the next frame, and a dirty flag for redraws that
	// happen outside the animation clock.
	scroll_delta: [2]f32,
	draw_dirty:   bool,
	// True while panel_draw runs: state changes made by a click handler must
	// not start a nested draw, and resizes must happen before the drawable is
	// acquired.
	drawing:        bool,
	draw_scheduled: bool,
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
	panel.memory_maximized = make([]u8, hw_clay.min_memory_size())
	if !hw_clay.initialize(
		&panel.clay_maximized,
		panel.memory_maximized,
		{panel.width, panel.height},
		{handler = panel_clay_error},
	) {
		fmt.eprintln("[panel] clay initialize failed for the maximized tree")
		return false
	}
	hw_clay.set_measure_text_function(&panel.clay_maximized, hw_clay_ui.measure_text, &panel.renderer)
	panel_sync_layer(panel.width, panel.height)
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
	fixed := PANEL_RANK_WIDTH
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
	// The rank cell and the name share the row with the stat columns, so there
	// is one more gap than stat columns.
	gaps := f32((columns + 1) * PANEL_ROW_GAP)
	width := f32(PANEL_WIDTH-PANEL_PADDING_HORIZONTAL*2) - fixed - gaps
	return int(width / (f32(PANEL_FONT_SIZE) * 0.5)) - 1
}

// panel_rank_background tints the top of the ranking: red for the first place,
// yellow for the next three, on group rows only. Process rows stay uncolored —
// their rank number carries the highlight instead, so the group tint remains
// the loudest thing on the panel.
panel_rank_background :: proc(row: Ui_Row, palette: Panel_Palette) -> hw_clay.Color {
	if row.kind != .Group || row.rank <= 0 {
		return {}
	}
	return row.rank == 1 ? palette.rank_red : row.rank <= 4 ? palette.rank_yellow : hw_clay.Color{}
}

panel_rank_text_color :: proc(row: Ui_Row, palette: Panel_Palette) -> hw_clay.Color {
	switch row.rank {
	case 1:
		return palette.rank_red_text
	case 2, 3, 4:
		return palette.rank_yellow_text
	case:
		return palette.secondary
	}
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

// panel_draw_charts draws the maximized view's per-group charts (two stacked
// series with labels and peak markers). Filled in by the maximized layout.
panel_draw_charts :: proc(rows: []Ui_Row, palette: Panel_Palette) {
}

// panel_content_changed recomputes the panel height for the current content,
// resizes the window, and redraws if nothing else is driving the clock.
panel_content_changed :: proc() {
	if panel_mode == .Maximized {
		panel_set_size(panel_maximized_width(), panel_maximized_height())
		panel_mark_dirty()
		panel_check_geometry("content_changed")
		return
	}
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
	panel_check_geometry("content_changed")
}

// panel_screen_visible_frame is the visible frame of the screen the popover
// anchors to; the maximized panel fills it, inset by a margin.
panel_screen_visible_frame :: proc() -> NS.Rect {
	screen := NS.Screen.mainScreen()
	if screen == nil {
		return panel_ns(0, 0, 1440, 900)
	}
	return screen->visibleFrame()
}

panel_maximized_width :: proc() -> f32 {
	frame := panel_screen_visible_frame()
	return f32(f64(frame.size.width) - PANEL_MAXIMIZED_MARGIN * 2)
}

panel_maximized_height :: proc() -> f32 {
	frame := panel_screen_visible_frame()
	return f32(f64(frame.size.height) - PANEL_MAXIMIZED_MARGIN * 2)
}

// panel_begin_mode_switch changes between the popover and the maximized layout.
// The window resizes immediately and only the content cross-fades: the popover
// tree fades out over the maximized tree fading in. The mode is session state,
// so a restart starts in the popover.
panel_begin_mode_switch :: proc(mode: Panel_Mode) {
	if panel_mode == mode {
		return
	}
	panel_mode = mode
	panel.crossfade_target = mode == .Maximized ? 1 : 0
	panel_content_changed()
	panel_window_position()
	panel_window_begin_animation()
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

// panel_sync_layer makes the layer's geometry match the panel exactly:
// contents scale, frame, and drawable size. The layer is ours (the view was
// handed a CAMetalLayer), and AppKit only resizes it during a later layout
// pass, so without this the layer can present a surface sized for the previous
// content. Callers must run this before acquiring a drawable.
panel_sync_layer :: proc(width, height: f32) {
	if panel.layer == nil {
		return
	}
	scale := f32(1)
	if panel.window != nil {
		scale = f32(panel.window->backingScaleFactor())
	}
	panel.layer->setContentsScale(NS.Float(scale))
	panel.layer->setFrame({{0, 0}, {NS.Float(width), NS.Float(height)}})
	panel.layer->setDrawableSize({NS.Float(width * scale), NS.Float(height * scale)})
}

// panel_mark_dirty schedules a draw on the next main-queue turn. Drawing
// synchronously from an event handler can run before AppKit has applied a
// window resize, which leaves the layer presenting a stale surface; deferring
// lets the window, view, and layer settle first. While a draw is in flight the
// change is only flagged: the running draw picks it up.
panel_mark_dirty :: proc() {
	if panel.drawing || panel_window_is_animating() {
		panel.draw_dirty = true
		return
	}
	if panel.draw_scheduled {
		return
	}
	panel.draw_scheduled = true
	dispatch_async_f(&_dispatch_main_q, nil, panel_draw_deferred_c)
}

panel_draw_deferred_c :: proc "c" (data: rawptr) {
	context = runtime.default_context()
	panel.draw_scheduled = false
	if !panel_window.visible {
		return // nothing to show; the next show starts the clock
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

// panel_check_geometry reports a window or drawable whose height does not match
// the layout height: that mismatch is the signature of a stale frame (the
// content is encoded at one size and presented at another). It logs only when
// the mismatch changes, so normal use stays silent and a recurrence lands in
// the event log with the numbers.
Panel_Geometry :: struct {
	valid:           bool,
	tag:             string,
	height:          f32,
	window_height:   f32,
	drawable_height: f32,
}

panel_geometry_last: Panel_Geometry

panel_check_geometry :: proc(tag: string) {
	window_height: f32
	scale := f32(1)
	if panel.window != nil {
		frame := panel.window->frame()
		window_height = f32(frame.size.height)
		scale = f32(panel.window->backingScaleFactor())
	}
	drawable_height: f32
	if panel.layer != nil {
		size := panel.layer->drawableSize()
		drawable_height = f32(size.height)
	}
	window_mismatch := abs(window_height-panel.height) > 0.5
	drawable_mismatch := abs(drawable_height-panel.height*scale) > 1
	if !window_mismatch && !drawable_mismatch {
		panel_geometry_last = {valid = true, tag = tag, height = panel.height}
		return
	}
	if panel_geometry_last.valid &&
	   panel_geometry_last.tag == tag &&
	   panel_geometry_last.height == panel.height &&
	   panel_geometry_last.window_height == window_height &&
	   panel_geometry_last.drawable_height == drawable_height {
		return
	}
	panel_geometry_last = {
		valid           = true,
		tag             = tag,
		height          = panel.height,
		window_height   = window_height,
		drawable_height = drawable_height,
	}
	log_event(monitor.log, "panel_geometry", fmt.tprintf(
		"\"tag\":%s,\"panel_height\":%.0f,\"window_height\":%.0f,\"drawable_height\":%.0f,\"visible\":%v,\"animating\":%v,\"settings\":%v",
		log_string(tag),
		panel.height,
		window_height,
		drawable_height,
		panel_window.visible,
		panel_window.animating,
		settings.open,
	))
}

panel_draw :: proc() {
	if panel.layer == nil || panel.queue == nil {
		return
	}
	// Per-frame strings (rank numbers, bracketed labels) live in the temporary
	// allocator; release them once the frame has been encoded.
	defer free_all(context.temp_allocator)
	panel.drawing = true
	defer panel.drawing = false

	// Pointer state and click handling run before the drawable is acquired:
	// a click can resize the panel (opening or closing settings), and the frame
	// must be encoded at the size it will be presented with.
	hw_clay.set_pointer_state(&panel.clay, panel_pointer_position(), panel_window.pointer_down)
	hw_clay.set_pointer_state(&panel.clay_maximized, panel_pointer_position(), panel_window.pointer_down)
	if panel_window.click_pending {
		panel_window.click_pending = false
		panel_handle_click()
	}

	// The layer must match the panel before the drawable is acquired, so the
	// texture this frame encodes into is the size it presents at.
	panel_sync_layer(panel.width, panel.height)
	scale := f32(1)
	if panel.window != nil {
		scale = f32(panel.window->backingScaleFactor())
	}
	drawable := panel.layer->nextDrawable()
	if drawable == nil {
		if panel_window.visible {
			fmt.eprintln("[panel] draw: no drawable")
		}
		return
	}

	metal.begin_texture_frame(&panel.gpu)
	coretext.begin_frame(&panel.text, scale, metal.atlas_io(&panel.gpu))
	draw.list_reset(&panel.list)

	panel_apply_scroll(PANEL_FRAME_SECONDS)
	rows := panel_rows()
	palette := panel_palette()

	// Build only the trees that are on screen: one when settled, both during a
	// mode switch.
	maximized: []hw_clay.Render_Command
	popover: []hw_clay.Render_Command
	if panel_mode == .Maximized || panel.crossfade > 0 {
		hw_clay.set_layout_dimensions(&panel.clay_maximized, {panel.width, panel.height})
		maximized = panel_build_tree(&panel.clay_maximized, rows, palette, .Maximized)
	}
	if panel_mode == .Popover || panel.crossfade < 1 {
		hw_clay.set_layout_dimensions(&panel.clay, {panel.width, panel.height})
		popover = panel_build_tree(&panel.clay, rows, palette, .Popover)
	}

	panel_render_trees(maximized, popover, rows, palette)

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
	panel_check_geometry("draw")
}

// panel_render_trees draws the maximized tree, then the popover tree over it,
// each with its own opacity so a mode switch cross-fades the popover out while
// the maximized tree fades in. The maximized tree is always drawn with the
// identity transform (a mode switch and the maximized open/close only fade);
// the popover tree keeps its scale-and-slide animation unless a mode switch is
// in progress.
panel_render_trees :: proc(
	maximized: []hw_clay.Render_Command,
	popover: []hw_clay.Render_Command,
	rows: []Ui_Row,
	palette: Panel_Palette,
) {
	if len(maximized) > 0 {
		draw.push_opacity(&panel.list, panel_opacity(panel.progress) * panel.crossfade)
		hw_clay_ui.render_commands(&panel.renderer, maximized)
		panel_draw_charts(rows, palette)
		draw.pop_opacity(&panel.list)
	}
	if len(popover) > 0 {
		draw.push_opacity(&panel.list, panel_opacity(panel.progress) * (1 - panel.crossfade))
		popover_transform := panel.crossfade == 0
		if popover_transform {
			draw.push_transform(&panel.list, panel_transform(
				panel.progress,
				panel.anchor.x,
				panel.anchor.y,
				panel.from.x,
				panel.from.y,
			))
		}
		hw_clay_ui.render_commands(&panel.renderer, popover)
		if settings.open {
			panel_draw_settings_caret(palette)
		} else {
			panel_draw_sparklines(rows, palette)
		}
		if popover_transform {
			draw.pop_transform(&panel.list)
		}
		draw.pop_opacity(&panel.list)
	}
}

// panel_build_tree lays out one complete tree (popover or maximized) in its own
// clay context. Both trees exist only during a mode switch; a settled panel
// builds just its own.
panel_build_tree :: proc(
	ctx: ^hw_clay.Context,
	rows: []Ui_Row,
	palette: Panel_Palette,
	mode: Panel_Mode,
) -> []hw_clay.Render_Command {
	hw_clay.begin_layout(ctx)
	panel_build_root(ctx, rows, palette, mode)
	return hw_clay.end_layout(ctx, PANEL_FRAME_SECONDS)
}

// panel_build_root builds one layout tree: the popover (which owns the settings
// modal) or the maximized dashboard. The z-index tags the tree so the renderer
// can cross-fade them independently.
panel_build_root :: proc(
	ctx: ^hw_clay.Context,
	rows: []Ui_Row,
	palette: Panel_Palette,
	mode: Panel_Mode,
) {
	root_id := mode == .Maximized ? hw_clay.id("panel-root-maximized") : hw_clay.id("panel-root")
	hw_clay.open_element(ctx, root_id)
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
		// Only the outline: border_all would also set between_children, which
		// draws separator lines between the settings rows.
		border = {
			color = palette.border,
			width = {left = 1, right = 1, top = 1, bottom = 1},
		},
	})

	if mode == .Popover && settings.open {
		panel_settings_rows(ctx, palette)
	} else {
		panel_build_rows_list(ctx, rows, palette, mode)
	}

	hw_clay.pop_element(ctx) // root
}

// panel_build_rows_list builds the scrollable group/process list.
panel_build_rows_list :: proc(
	ctx: ^hw_clay.Context,
	rows: []Ui_Row,
	palette: Panel_Palette,
	mode: Panel_Mode,
) {
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
				child_gap       = PANEL_ROW_GAP,
			},
			background_color = panel_rank_background(row, palette),
		})

		font, color := panel_row_style(row, palette)
		// The header spans the full width and carries the panel buttons; data
		// rows start with the rank cell, then the growing name. Every row pushes
		// the same enabled columns, empty where a row has no value, so the table
		// stays aligned vertically.
		if row.kind == .Header {
			panel_push_text(ctx, row.name, FONT_BODY, color, {hw_clay.grow(), hw_clay.grow()}, .Left, true)
			panel_push_button(ctx, hw_clay.id("panel-sort"), "Sort", palette)
			if mode == .Maximized {
				panel_push_button(ctx, hw_clay.id("panel-restore"), "Restore", palette)
			} else {
				panel_push_button(ctx, hw_clay.id("panel-maximize"), "Maximize", palette)
				panel_push_button(ctx, hw_clay.id("settings-gear"), "Settings", palette)
			}
			hw_clay.pop_element(ctx)
			continue
		}
		rank_text := ""
		if row.kind == .Group {
			rank_text = row.rank > 0 ? fmt.tprintf("%d", row.rank) : ""
		}
		panel_push_text(
			ctx,
			rank_text,
			FONT_BODY,
			panel_rank_text_color(row, palette),
			{hw_clay.fixed(PANEL_RANK_WIDTH), hw_clay.grow()},
			.Right,
		)
		if row.kind == .Process {
			panel_push_text(
				ctx,
				panel_process_rank_text(row.rank),
				FONT_BODY,
				panel_rank_text_color(row, palette),
				{hw_clay.fixed(PANEL_PROCESS_RANK_WIDTH), hw_clay.grow()},
				.Right,
			)
		}
		panel_push_text(ctx, row.name, FONT_BODY, color, {hw_clay.grow(), hw_clay.grow()}, .Left, true)
		if stats.cpu {
			panel_push_text(
				ctx,
				row.cpu,
				FONT_BODY,
				palette.text,
				{hw_clay.fixed(PANEL_STAT_CPU_WIDTH), hw_clay.grow()},
				.Right,
			)
		}
		if stats.memory {
			panel_push_text(
				ctx,
				row.memory,
				FONT_BODY,
				palette.text,
				{hw_clay.fixed(PANEL_STAT_MEMORY_WIDTH), hw_clay.grow()},
				.Right,
			)
		}
		if stats.window_cpu {
			panel_push_text(
				ctx,
				row.window_cpu,
				FONT_BODY,
				palette.text,
				{hw_clay.fixed(PANEL_STAT_WINDOW_CPU_WIDTH), hw_clay.grow()},
				.Right,
			)
			// The sparkline column reserves space for the series drawn after
			// the clay commands; only group rows carry one.
			chart_label := mode == .Maximized ? "panel-chart" : "panel-spark"
			hw_clay.open_element(ctx, hw_clay.id_indexed(chart_label, u32(index)))
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
				FONT_BODY,
				palette.text,
				{hw_clay.fixed(PANEL_STAT_WINDOW_MEMORY_WIDTH), hw_clay.grow()},
				.Right,
			)
		}
		hw_clay.pop_element(ctx)
	}

	hw_clay.pop_element(ctx) // list
}

panel_row_style :: proc(row: Ui_Row, palette: Panel_Palette) -> (font: ui.Font_Handle, color: hw_clay.Color) {
	// The list is deliberately all-regular: hierarchy comes from indentation,
	// the rank column, and the rank highlights, not from weight.
	switch row.kind {
	case .Note:
		return FONT_BODY, palette.secondary
	case .Header, .Group, .Process:
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

// panel_hovered reports whether the pointer is over this element in the
// previous frame's layout. Hover styling needs a redraw on pointer moves, which
// panel_pointer_update schedules.
panel_hovered :: proc(id: hw_clay.Element_Id) -> bool {
	for over in hw_clay.get_pointer_over_ids(&panel.clay) {
		if over == id {
			return true
		}
	}
	for over in hw_clay.get_pointer_over_ids(&panel.clay_maximized) {
		if over == id {
			return true
		}
	}
	return false
}

// panel_push_field pushes one editable value. It is flat like the buttons: no
// box and no border. The value is dimmed until the field is focused or hovered,
// and the caret marks the insertion point.
panel_push_field :: proc(
	ctx: ^hw_clay.Context,
	id: hw_clay.Element_Id,
	text: string,
	focused: bool,
	palette: Panel_Palette,
) {
	hovered := panel_hovered(id)
	hw_clay.open_element(ctx, id)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.fixed(SETTINGS_FIELD_WIDTH), hw_clay.grow()},
			child_alignment = {x = .Left, y = .Center},
			padding         = {left = 4, right = 4},
		},
	})
	hw_clay.push_text(ctx, text, {
		font_id   = u16(FONT_BODY),
		font_size = PANEL_FONT_SIZE,
		color     = focused || hovered ? palette.text : palette.secondary,
		wrap_mode = .None,
	})
	hw_clay.pop_element(ctx)
}

// panel_push_checkbox pushes a full-row toggle: label, then a bracketed mark.
// The row carries the id, so the whole line is clickable; hovering swaps the
// mark's colors like a button.
panel_push_checkbox :: proc(
	ctx: ^hw_clay.Context,
	id: hw_clay.Element_Id,
	label: string,
	checked: bool,
	palette: Panel_Palette,
) {
	hovered := panel_hovered(id)
	hw_clay.open_element(ctx, id)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.grow(), hw_clay.grow()},
			child_alignment = {y = .Center},
			child_gap       = PANEL_ROW_GAP,
		},
	})
	panel_push_text(ctx, label, FONT_BODY, palette.text, {hw_clay.grow(), hw_clay.grow()}, .Left)
	hw_clay.open_element(ctx)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.fit(), hw_clay.grow()},
			child_alignment = {x = .Right, y = .Center},
		},
		background_color = hovered ? palette.text : hw_clay.Color{},
	})
	hw_clay.push_text(ctx, checked ? "[✓]" : "[ ]", {
		font_id   = u16(FONT_BODY),
		font_size = PANEL_FONT_SIZE,
		color     = hovered ? palette.background : palette.text,
		wrap_mode = .None,
	})
	hw_clay.pop_element(ctx)
	hw_clay.pop_element(ctx)
}

// panel_push_button pushes a bracketed text button: no box, no padding, no
// rounding — just the text — and on hover the text and background colors swap
// in a rectangle that hugs the glyphs.
panel_push_button :: proc(
	ctx: ^hw_clay.Context,
	id: hw_clay.Element_Id,
	label: string,
	palette: Panel_Palette,
) {
	hovered := panel_hovered(id)
	hw_clay.open_element(ctx, id)
	hw_clay.configure_element(ctx, {
		layout = {
			sizing          = {hw_clay.fit(), hw_clay.grow()},
			child_alignment = {x = .Center, y = .Center},
		},
		background_color = hovered ? palette.text : hw_clay.Color{},
	})
	hw_clay.push_text(ctx, fmt.tprintf("[%s]", label), {
		font_id   = u16(FONT_BODY),
		font_size = PANEL_FONT_SIZE,
		color     = hovered ? palette.background : palette.text,
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
// panel_click handles the ids both trees share: the header buttons and the mode
// switch. It returns true when the id was consumed.
panel_click :: proc(id: hw_clay.Element_Id) -> bool {
	if id == hw_clay.id("panel-sort") {
		ui_sort_now()
		panel_mark_dirty()
		return true
	}
	if id == hw_clay.id("panel-maximize") {
		panel_begin_mode_switch(.Maximized)
		return true
	}
	if id == hw_clay.id("panel-restore") {
		panel_begin_mode_switch(.Popover)
		return true
	}
	return false
}

// panel_handle_click resolves a mouse-up against the previous frame's layout,
// which is what the user saw when they pressed. Both trees are consulted: the
// maximized one for its buttons, the popover one for its buttons and for the
// settings modal.
panel_handle_click :: proc() {
	if !panel_window.visible || panel_window.animating {
		return
	}
	if panel.crossfade != panel.crossfade_target {
		return // a mode switch is in flight; ignore clicks until it settles
	}
	for id in hw_clay.get_pointer_over_ids(&panel.clay_maximized) {
		if panel_click(id) {
			return
		}
	}
	for id in hw_clay.get_pointer_over_ids(&panel.clay) {
		if settings_click(id) {
			return
		}
		if id == hw_clay.id("settings-gear") {
			settings_open()
			return
		}
		if panel_click(id) {
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
			rank_red        = {225, 70, 70, 54},
			rank_red_text   = {255, 138, 138, 255},
			rank_yellow     = {225, 180, 70, 46},
			rank_yellow_text = {248, 208, 120, 255},
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
		rank_red        = {220, 60, 60, 46},
		rank_red_text   = {186, 32, 32, 255},
		rank_yellow     = {226, 176, 50, 52},
		rank_yellow_text = {150, 112, 10, 255},
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
