// The panel window: a borderless, non-activating NSPanel whose content view is
// a bare CAMetalLayer. All pixels come from panel.odin; this file only owns the
// surface, the input events, and the open/close clock.
//
// The display link stays paused unless the panel is animating or a scroll is
// still settling, so an idle panel costs nothing.

package activity_monitor

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import NS "core:sys/darwin/Foundation"
import macos "ui_framework:macos"
import QC "vendor:darwin/QuartzCore"
import MTL "vendor:darwin/Metal"

PANEL_WINDOW_LEVEL_STATUS :: 25
PANEL_ANCHOR_GAP :: f64(6)
PANEL_SCREEN_MARGIN :: f64(8)


panel_ns :: proc(x, y, width, height: f64) -> NS.Rect {
	return {{NS.Float(x), NS.Float(y)}, {NS.Float(width), NS.Float(height)}}
}
PANEL_SCROLL_SETTLE_SECONDS :: f64(0.35)
NSEVENT_KEY_ESCAPE :: u16(53)

Panel_Window :: struct {
	window:        ^NS.Panel,
	view:          ^NS.View,
	controller:    ^NS.Object,
	display_link:  macos.Display_Link,
	visible:       bool,
	animating:     bool,
	opening:       bool,
	progress:      f32,
	last_time:     f64,
	has_time:      bool,
	scroll_until:  f64,
	pointer:       [2]f32, // clay coordinates, top-left origin
	pointer_valid: bool,
	pointer_down:  bool,
	click_pending: bool,
	// Set when the panel hides with settings open: the modal content stays for
	// the close animation, and settings close once the window is ordered out.
	close_settings_pending: bool,
}

panel_window: Panel_Window

panel_add_method :: proc(class: NS.Class, name: cstring, imp: rawptr, types: cstring) -> bool {
	return bool(NS.class_addMethod(class, NS.sel_registerName(name), auto_cast imp, types))
}

// --------------------------------------------------------------- lifecycle

panel_window_init :: proc() -> bool {
	device := MTL.CreateSystemDefaultDevice()
	if device == nil {
		fmt.eprintln("[panel] no Metal device")
		return false
	}
	queue := device->newCommandQueue()
	if queue == nil {
		fmt.eprintln("[panel] no command queue")
		return false
	}

	controller := panel_make_controller()
	if controller == nil {
		return false
	}
	panel_window.controller = controller

	view_class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSView"), "ActivityMonitorPanelView", 0)
	if view_class == nil {
		return false
	}
	if !panel_add_method(view_class, "acceptsFirstResponder", rawptr(panel_accepts_first_responder), "B@:") ||
	   !panel_add_method(view_class, "acceptsFirstMouse:", rawptr(panel_accepts_first_mouse), "B@:@") ||
	   !panel_add_method(view_class, "scrollWheel:", rawptr(panel_scroll_callback), "v@:@") ||
	   !panel_add_method(view_class, "keyDown:", rawptr(panel_key_callback), "v@:@") ||
	   !panel_add_method(view_class, "mouseDown:", rawptr(panel_mouse_down_callback), "v@:@") ||
	   !panel_add_method(view_class, "mouseUp:", rawptr(panel_mouse_up_callback), "v@:@") ||
	   !panel_add_method(view_class, "mouseDragged:", rawptr(panel_mouse_dragged_callback), "v@:@") ||
	   !panel_add_method(view_class, "mouseMoved:", rawptr(panel_mouse_moved_callback), "v@:@") {
		return false
	}
	NS.objc_registerClassPair(view_class)

	window_class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSPanel"), "ActivityMonitorPanel", 0)
	if window_class == nil {
		return false
	}
	if !panel_add_method(window_class, "canBecomeKeyWindow", rawptr(panel_can_become_key), "B@:") {
		return false
	}
	NS.objc_registerClassPair(window_class)

	// NSWindowStyleMaskBorderless with NSWindowStyleMaskNonactivatingPanel: the
	// panel takes key focus for Escape and outside-click dismissal without
	// activating the app.
	// Borderless is the absence of the titled flags; the panel still takes key focus.
	style := NS.WindowStyleMask{.NonactivatingPanel}
	frame := NS.Rect{{0, 0}, {PANEL_WIDTH, PANEL_MIN_HEIGHT}}
	window := (^NS.Panel)(NS.class_createInstance(window_class, 0))
	window = (^NS.Panel)(window->initWithContentRect(frame, style, .Buffered, false))
	if window == nil {
		fmt.eprintln("[panel] could not create the panel window")
		return false
	}
	panel_window.window = window
	panel.window = window

	msg_void_bool(window, sel_registerName("setOpaque:"), false)
	msg_void_bool(window, sel_registerName("setAcceptsMouseMovedEvents:"), true)
	msg_void_id(window, sel_registerName("setBackgroundColor:"), msg_id0(objc_getClass("NSColor"), sel_registerName("clearColor")))
	msg_void_bool(window, sel_registerName("setHasShadow:"), false)
	msg_void_bool(window, sel_registerName("setMovable:"), false)
	msg_void_bool(window, sel_registerName("setReleasedWhenClosed:"), false)
	msg_void_i(window, sel_registerName("setLevel:"), PANEL_WINDOW_LEVEL_STATUS)
	msg_void_i(
		window,
		sel_registerName("setCollectionBehavior:"),
		int(NS.WindowCollectionBehavior{.Transient, .FullScreenAuxiliary}),
	)

	view := (^NS.View)(NS.class_createInstance(view_class, 0))
	if view == nil {
		return false
	}
	view = view->initWithFrame({{0, 0}, frame.size})
	if view == nil {
		return false
	}
	panel_window.view = view
	panel.view = view
	window->setContentView(view)
	view->setWantsLayer(true)

	layer := QC.MetalLayer.layer()
	if layer == nil {
		return false
	}
	layer->setDevice(device)
	layer->setPixelFormat(.BGRA8Unorm)
	layer->setFramebufferOnly(true)
	msg_void_bool(layer, sel_registerName("setOpaque:"), false)
	view->setLayer((^NS.Layer)(layer))

	if !panel_setup_renderer(layer, device, queue) {
		return false
	}

	delegate := panel_make_delegate()
	if delegate == nil {
		return false
	}
	window->setDelegate((^NS.WindowDelegate)(delegate))

	if !macos.display_link_start(&panel_window.display_link, rawptr(view), rawptr(controller), "panelFrame:") {
		fmt.eprintln("[panel] the display link did not start")
		return false
	}
	macos.display_link_set_paused(&panel_window.display_link, true)
	return true
}

panel_make_controller :: proc() -> ^NS.Object {
	class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "ActivityMonitorPanelController", 0)
	if class == nil {
		return nil
	}
	if !panel_add_method(class, "panelFrame:", rawptr(panel_frame_callback), "v@:@") ||
	   !panel_add_method(class, "togglePanel:", rawptr(panel_toggle_callback), "v@:@") ||
	   !panel_add_method(class, "openSettings:", rawptr(panel_open_settings_callback), "v@:@") ||
	   !panel_add_method(class, "quitApp:", rawptr(panel_quit_callback), "v@:@") {
		return nil
	}
	NS.objc_registerClassPair(class)
	return (^NS.Object)(NS.class_createInstance(class, 0))
}

panel_make_delegate :: proc() -> ^NS.Object {
	class := NS.objc_allocateClassPair(intrinsics.objc_find_class("NSObject"), "ActivityMonitorPanelDelegate", 0)
	if class == nil {
		return nil
	}
	if !panel_add_method(class, "windowDidResignKey:", rawptr(panel_window_did_resign_key), "v@:@") {
		return nil
	}
	NS.objc_registerClassPair(class)
	return (^NS.Object)(NS.class_createInstance(class, 0))
}

// ------------------------------------------------------------------ layout

panel_window_set_frame :: proc(width, height: f32) {
	window := panel_window.window
	if window == nil {
		return
	}
	panel_window_position()
	frame := window->frame()
	frame = panel_ns(
		f64(frame.origin.x),
		f64(frame.origin.y),
		f64(width),
		f64(height),
	)
	window->setFrame(frame, true)
}

// panel_window_position puts the panel under the status item, centered on the
// icon and clamped to the screen.
panel_window_position :: proc() {
	window := panel_window.window
	if window == nil {
		return
	}
	button_rect := ui_status_button_screen_rect()
	screen := NS.Screen.mainScreen()
	visible := screen != nil ? screen->visibleFrame() : panel_ns(0, 0, 1440, 900)

	visible_min_x := f64(visible.origin.x)
	visible_min_y := f64(visible.origin.y)
	visible_max_x := visible_min_x + f64(visible.size.width)

	width := f64(panel.width)
	height := f64(panel.height)
	center_x := f64(button_rect.origin.x) + f64(button_rect.size.width) / 2
	x := center_x - width / 2
	x = min(max(x, visible_min_x + PANEL_SCREEN_MARGIN), visible_max_x - width - PANEL_SCREEN_MARGIN)
	y := f64(button_rect.origin.y) - PANEL_ANCHOR_GAP - height
	if y < visible_min_y {
		y = f64(button_rect.origin.y + button_rect.size.height) + PANEL_ANCHOR_GAP
	}
	window->setFrame(panel_ns(x, y, width, height), false)
	// The pivot sits on the panel's top edge under the icon, in draw list
	// coordinates (bottom-left origin).
	panel.anchor = {f32(center_x - x), panel.height}
	// Keep the layer in step with the window: the next draw must not be the
	// thing that fixes the surface size.
	panel_sync_layer(panel.width, panel.height)
}

// --------------------------------------------------------------- animation

panel_window_toggle :: proc() {
	if panel_window.visible {
		panel_window_hide()
		return
	}
	panel_window_show()
}

panel_window_show :: proc() {
	window := panel_window.window
	if window == nil {
		return
	}
	panel_window_position()
	panel.progress = 0
	panel_window.progress = 0
	panel_window.opening = true
	panel_window.animating = true
	panel_window.visible = true
	panel_window.has_time = false
	panel_window.close_settings_pending = false
	msg_void0(window, sel_registerName("makeKeyAndOrderFront:"))
	if panel_window.view != nil {
		_ = window->makeFirstResponder((^NS.Responder)(panel_window.view))
	}
	macos.display_link_set_paused(&panel_window.display_link, false)
	panel_check_geometry("show")
}

// panel_window_hide closes the panel. Settings stay open through the close
// animation so the list never flashes mid-dismiss; they close once the window
// is ordered out.
panel_window_hide :: proc() {
	if !panel_window.visible {
		return
	}
	if panel_window.animating && !panel_window.opening {
		return // already closing
	}
	if settings.open {
		panel_window.close_settings_pending = true
	}
	panel_window.pointer_valid = false
	panel_window.pointer_down = false
	panel_window.click_pending = false
	panel_window.opening = false
	panel_window.animating = true
	panel_window.has_time = false
	macos.display_link_set_paused(&panel_window.display_link, false)
	panel_check_geometry("hide")
}

panel_window_is_animating :: proc() -> bool {
	return panel_window.animating
}

panel_window_begin_scrolling :: proc() {
	panel_window.scroll_until = macos.display_link_timestamp(&panel_window.display_link) + PANEL_SCROLL_SETTLE_SECONDS
	macos.display_link_set_paused(&panel_window.display_link, false)
}

// panel_tick advances the animation and redraws; it runs only while the display
// link is unpaused.
panel_tick :: proc(timestamp: f64) {
	delta: f64
	if panel_window.has_time && timestamp > panel_window.last_time {
		delta = min(timestamp - panel_window.last_time, f64(0.1))
	}
	panel_window.last_time = timestamp
	panel_window.has_time = true

	if panel_window.animating {
		if panel_window.opening {
			panel_window.progress = min(panel_window.progress + f32(delta) / PANEL_OPEN_SECONDS, 1)
			if panel_window.progress >= 1 {
				panel_window.animating = false
			}
		} else {
			panel_window.progress = max(panel_window.progress - f32(delta) / PANEL_CLOSE_SECONDS, 0)
			if panel_window.progress <= 0 {
				panel_window.animating = false
				panel_window.visible = false
				msg_void_id(panel_window.window, sel_registerName("orderOut:"), nil)
				if panel_window.close_settings_pending {
					panel_window.close_settings_pending = false
					settings_close()
				}
			}
		}
		panel.progress = panel_window.progress
	}

	panel_draw()

	if !panel_window.animating && timestamp >= panel_window.scroll_until {
		macos.display_link_set_paused(&panel_window.display_link, true)
	}
}

// --------------------------------------------------------------- callbacks

panel_frame_callback :: proc "c" (self: NS.id, cmd: NS.SEL, timer: NS.id) {
	context = runtime.default_context()
	panel_tick(macos.display_link_timestamp(&panel_window.display_link))
}

// panel_toggle_callback opens the panel on a left click and pops the status
// menu on a right click.
panel_toggle_callback :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) {
	context = runtime.default_context()
	app := msg_id0(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	event := app == nil ? nil : msg_id0(app, sel_registerName("currentEvent"))
	if event != nil {
		event_type := NS.Event_type((^NS.Event)(event))
		if event_type == .RightMouseUp || event_type == .RightMouseDown {
			status_menu_show(sender, event)
			return
		}
	}
	panel_window_toggle()
}

panel_scroll_callback :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	delta_x, delta_y := event->scrollingDelta()
	panel_add_scroll(f32(delta_x), f32(delta_y))
	panel_window_begin_scrolling()
}

// panel_pointer_update converts an event location into clay coordinates
// (top-left origin) and redraws.
panel_pointer_update :: proc(event: ^NS.Event, down: bool) {
	view := panel_window.view
	if view == nil {
		return
	}
	in_window := event->locationInWindow()
	in_view := view->convertPointFromView(in_window, nil)
	panel_window.pointer = {f32(in_view.x), f32(panel.height-f32(in_view.y))}
	panel_window.pointer_valid = true
	panel_window.pointer_down = down
	panel_mark_dirty()
}

panel_mouse_down_callback :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	panel_pointer_update(event, true)
}

panel_mouse_up_callback :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	panel_pointer_update(event, false)
	panel_window.click_pending = true
	panel_mark_dirty()
}

panel_mouse_dragged_callback :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	panel_pointer_update(event, true)
}

panel_mouse_moved_callback :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	panel_pointer_update(event, panel_window.pointer_down)
}

panel_key_callback :: proc "c" (self: NS.id, cmd: NS.SEL, event: ^NS.Event) {
	context = runtime.default_context()
	if settings_key(event) {
		return
	}
	if event->keyCode() == NSEVENT_KEY_ESCAPE {
		panel_window_hide()
	}
}

panel_accepts_first_responder :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {
	return true
}

// acceptsFirstMouse keeps the panel's first click when the app is not the
// active one: without it macOS swallows the click that would focus the window.
panel_accepts_first_mouse :: proc "c" (self: NS.id, cmd: NS.SEL, event: NS.id) -> bool {
	return true
}

panel_can_become_key :: proc "c" (self: NS.id, cmd: NS.SEL) -> bool {
	return true
}

panel_window_did_resign_key :: proc "c" (self: NS.id, cmd: NS.SEL, notification: NS.id) {
	context = runtime.default_context()
	if !panel_window.visible || panel_window.animating {
		return
	}
	panel_window_hide()
}
