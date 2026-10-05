// Launch at login through SMAppService: macOS lists the app under System
// Settings > General > Login Items, where it can also be switched off. Only a
// copy running from hw_activity_monitor.app registers; a copy already started by
// a LaunchAgent would otherwise be launched twice.

package activity_monitor

import "core:fmt"
import "core:os"

login_item_register :: proc(enabled: bool) {
	if !enabled || darwin_objc_init() == false {
		return
	}
	executable, executable_err := os.get_executable_path(context.temp_allocator)
	if executable_err != nil || update_bundle_path(executable) == "" {
		return
	}
	if os.get_env("XPC_SERVICE_NAME", context.temp_allocator) == LAUNCH_AGENT_LABEL {
		return
	}
	service_class := objc_getClass("SMAppService")
	if service_class == nil {
		return
	}
	service := msg_id0(service_class, sel_registerName("mainAppService"))
	if service == nil {
		return
	}
	send := transmute(proc "c" (Id, Sel, rawptr) -> bool)objc_send_address
	if !send(service, sel_registerName("registerAndReturnError:"), nil) {
		log_event(monitor.log, "login_item_failed", "\"reason\":\"register\"")
	}
}
