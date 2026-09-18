// Notification delivery.
//
// Installed, the daemon runs from inside an .app bundle and posts through
// UNUserNotificationCenter, so banners are attributed to hw_activity_monitor
// and the user grants permission once. A bare binary has no bundle identifier
// and UNUserNotificationCenter refuses to deliver, so development runs fall
// back to osascript, which macOS usually drops unless Script Editor has
// notification permission; the fallback is for `--once` style checks, not for
// the installed daemon.

package activity_monitor

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"

Notify_Backend :: enum {
	Unavailable,
	User_Notification,
	Osascript,
}

// Objective-C global blocks for UNUserNotificationCenter callbacks.

Notification_Block_Descriptor :: struct {
	reserved: uint,
	size:     uint,
}

Notification_Auth_Block :: struct {
	isa:        ^intrinsics.objc_class,
	flags:      u32,
	reserved:   u32,
	invoke:     proc "c" (block: ^Notification_Auth_Block, granted: bool, error: Id),
	descriptor: ^Notification_Block_Descriptor,
}

Notification_Add_Block :: struct {
	isa:        ^intrinsics.objc_class,
	flags:      u32,
	reserved:   u32,
	invoke:     proc "c" (block: ^Notification_Add_Block, error: Id),
	descriptor: ^Notification_Block_Descriptor,
}

foreign import notification_blocks "system:System"
foreign notification_blocks {
	_NSConcreteGlobalBlock: intrinsics.objc_class
}

BLOCK_IS_GLOBAL :: u32(1 << 28)
AUTHORIZATION_ALERT_AND_SOUND :: uint(6)

notification_block_descriptor := Notification_Block_Descriptor{size = size_of(Notification_Auth_Block)}
notification_auth_block: Notification_Auth_Block
notification_add_block: Notification_Add_Block
notification_center: Id
notify_backend: Notify_Backend
notify_log: Log

notification_auth_completed :: proc "c" (block: ^Notification_Auth_Block, granted: bool, error: Id) {
	context = runtime.default_context()
	if error != nil {
		description := nsstring_to_string(msg_id0(error, sel_registerName("localizedDescription")))
		log_event(notify_log, "notification_authorization", fmt.tprintf(
			"\"granted\":false,\"error\":%s",
			log_string(description),
		))
		return
	}
	log_event(notify_log, "notification_authorization", fmt.tprintf("\"granted\":%v", granted))
}

notification_add_completed :: proc "c" (block: ^Notification_Add_Block, error: Id) {
	context = runtime.default_context()
	if error != nil {
		description := nsstring_to_string(msg_id0(error, sel_registerName("localizedDescription")))
		log_event(notify_log, "notification_failed", fmt.tprintf("\"error\":%s", log_string(description)))
	}
}

// notify_init picks the delivery path once at startup and requests
// authorization when the daemon runs from a bundle.
notify_init :: proc(log: Log) -> Notify_Backend {
	notify_log = log
	if !darwin_objc_init() {
		notify_backend = .Osascript
		return notify_backend
	}
	bundle := msg_id0(objc_getClass("NSBundle"), sel_registerName("mainBundle"))
	identifier := bundle == nil ? nil : msg_id0(bundle, sel_registerName("bundleIdentifier"))
	if identifier == nil {
		notify_backend = .Osascript
		return notify_backend
	}
	notification_center = msg_id0(
		objc_getClass("UNUserNotificationCenter"),
		sel_registerName("currentNotificationCenter"),
	)
	if notification_center == nil {
		notify_backend = .Osascript
		return notify_backend
	}

	notification_auth_block = {
		isa        = &_NSConcreteGlobalBlock,
		flags      = BLOCK_IS_GLOBAL,
		invoke     = notification_auth_completed,
		descriptor = &notification_block_descriptor,
	}
	notification_add_block = {
		isa        = &_NSConcreteGlobalBlock,
		flags      = BLOCK_IS_GLOBAL,
		invoke     = notification_add_completed,
		descriptor = &notification_block_descriptor,
	}

	request_authorization := transmute(proc "c" (Id, Sel, uint, ^Notification_Auth_Block))objc_send_address
	request_authorization(
		notification_center,
		sel_registerName("requestAuthorizationWithOptions:completionHandler:"),
		AUTHORIZATION_ALERT_AND_SOUND,
		&notification_auth_block,
	)
	notify_backend = .User_Notification
	return notify_backend
}

// notify posts one banner. The return value reports whether the backend
// accepted the request, not whether the banner was displayed.
notify :: proc(title, body: string) -> bool {
	#partial switch notify_backend {
	case .User_Notification:
		return notify_user_notification(title, body)
	case .Osascript:
		return notify_osascript(title, body)
	case:
		return false
	}
}

notify_user_notification :: proc(title, body: string) -> bool {
	if notification_center == nil || objc_send_address == nil {
		return false
	}
	pool := msg_id0(objc_getClass("NSAutoreleasePool"), sel_registerName("new"))
	defer msg_void0(pool, sel_registerName("drain"))
	content := msg_id0(objc_getClass("UNMutableNotificationContent"), sel_registerName("new"))
	if content == nil {
		return false
	}
	defer msg_void0(content, sel_registerName("release"))
	msg_void_id(content, sel_registerName("setTitle:"), nsstring(title))
	msg_void_id(content, sel_registerName("setBody:"), nsstring(body))
	msg_void_id(
		content,
		sel_registerName("setSound:"),
		msg_id0(objc_getClass("UNNotificationSound"), sel_registerName("defaultSound")),
	)
	identifier := fmt.aprintf(
		"activity-monitor-%d",
		time.to_unix_seconds(time.now()),
		allocator = context.temp_allocator,
	)
	request := msg_id_id_id(
		objc_getClass("UNNotificationRequest"),
		sel_registerName("requestWithIdentifier:content:trigger:"),
		nsstring(identifier),
		content,
		nil,
	)
	if request == nil {
		return false
	}
	add_request := transmute(proc "c" (Id, Sel, Id, ^Notification_Add_Block))objc_send_address
	add_request(
		notification_center,
		sel_registerName("addNotificationRequest:withCompletionHandler:"),
		request,
		&notification_add_block,
	)
	return true
}

// notify_osascript shows a banner through osascript. The message travels as
// script arguments, so process names need no escaping.
notify_osascript :: proc(title, body: string) -> bool {
	process, start_err := os.process_start({
		command = {
			"/usr/bin/osascript",
			"-e",
			"on run argv",
			"-e",
			"display notification (item 1 of argv) with title (item 2 of argv)",
			"-e",
			"end run",
			body,
			title,
		},
	})
	if start_err != nil {
		return false
	}
	state, wait_err := os.process_wait(process, 10 * time.Second)
	if wait_err != nil {
		return false
	}
	return state.success
}
