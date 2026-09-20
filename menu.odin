// The status item's context menu: open the panel directly in settings, or stop
// the daemon. The menu is AppKit's because the status item is AppKit's; the
// panel content stays clay.

package activity_monitor

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:time"

LAUNCH_AGENT_LABEL :: "com.halwayland.hw_activity_monitor"

status_menu: Id

// status_menu_show pops the status item menu for a right-click. The menu is
// built once and kept for the process lifetime.
status_menu_show :: proc(button: Id, event: Id) {
	if status_menu == nil {
		status_menu = status_menu_build()
	}
	if status_menu == nil || event == nil {
		return
	}
	msg_void_id_id_id(
		objc_getClass("NSMenu"),
		sel_registerName("popUpContextMenu:withEvent:forView:"),
		status_menu,
		event,
		button,
	)
}

status_menu_build :: proc() -> Id {
	menu := msg_id0(objc_getClass("NSMenu"), sel_registerName("new"))
	if menu == nil {
		return nil
	}
	settings_item := msg_id_id_id(
		menu,
		sel_registerName("addItemWithTitle:action:keyEquivalent:"),
		nsstring("Open Settings"),
		sel_registerName("openSettings:"),
		nsstring(""),
	)
	msg_void_id(settings_item, sel_registerName("setTarget:"), panel_window.controller)

	msg_void_id(
		menu,
		sel_registerName("addItem:"),
		msg_id0(objc_getClass("NSMenuItem"), sel_registerName("separatorItem")),
	)

	quit_item := msg_id_id_id(
		menu,
		sel_registerName("addItemWithTitle:action:keyEquivalent:"),
		nsstring("Quit hw_activity_monitor"),
		sel_registerName("quitApp:"),
		nsstring(""),
	)
	msg_void_id(quit_item, sel_registerName("setTarget:"), panel_window.controller)
	return menu
}

// panel_open_settings_callback opens the panel directly in settings, whether it
// is closed or showing the list.
panel_open_settings_callback :: proc "c" (self: Id, cmd: Sel, sender: Id) {
	context = runtime.default_context()
	settings_open()
	if panel_window.visible {
		panel_mark_dirty()
	} else {
		panel_window_show()
	}
}

panel_quit_callback :: proc "c" (self: Id, cmd: Sel, sender: Id) {
	context = runtime.default_context()
	monitor_quit()
}

// monitor_quit stops the daemon for good. launchd keeps the process alive, so a
// plain exit would be restarted: unload the LaunchAgent first, then exit. A
// bare development binary has no agent to unload and just exits.
monitor_quit :: proc() {
	log_event(monitor.log, "quit", "\"source\":\"status_menu\"")
	command := fmt.tprintf("launchctl bootout gui/%d/%s", int(posix.getuid()), LAUNCH_AGENT_LABEL)
	process, start_err := os.process_start({command = {"/bin/sh", "-c", command}})
	if start_err == nil {
		_, _ = os.process_wait(process, 5 * time.Second)
	}
	os.exit(0)
}
