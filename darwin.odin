// Minimal Objective-C runtime glue for notification delivery, mirroring the
// helper set in hw_calendar/darwin.odin, trimmed to what notifications need.

package activity_monitor

import "core:dynlib"
import "core:strings"

Id :: rawptr
Sel :: rawptr

foreign import objc "system:objc"
foreign objc {
	objc_getClass    :: proc "c" (name: cstring) -> Id ---
	sel_registerName :: proc "c" (name: cstring) -> Sel ---
}

objc_send_address: rawptr

darwin_objc_init :: proc() -> bool {
	if objc_send_address != nil {
		return true
	}
	handle, loaded := dynlib.load_library("/usr/lib/libobjc.A.dylib")
	if !loaded {
		return false
	}
	objc_send_address, loaded = dynlib.symbol_address(handle, "objc_msgSend")
	return loaded
}

msg_id0 :: proc(receiver: Id, selector: Sel) -> Id {
	send := transmute(proc "c" (Id, Sel) -> Id)objc_send_address
	return send(receiver, selector)
}

msg_void0 :: proc(receiver: Id, selector: Sel) {
	send := transmute(proc "c" (Id, Sel))objc_send_address
	send(receiver, selector)
}

msg_void_id :: proc(receiver: Id, selector: Sel, argument: Id) {
	send := transmute(proc "c" (Id, Sel, Id))objc_send_address
	send(receiver, selector, argument)
}

msg_id_id_id :: proc(receiver: Id, selector: Sel, a, b, c: Id) -> Id {
	send := transmute(proc "c" (Id, Sel, Id, Id, Id) -> Id)objc_send_address
	return send(receiver, selector, a, b, c)
}

msg_id_f64 :: proc(receiver: Id, selector: Sel, value: f64) -> Id {
	send := transmute(proc "c" (Id, Sel, f64) -> Id)objc_send_address
	return send(receiver, selector, value)
}

nsstring :: proc(value: string) -> Id {
	if len(value) == 0 {
		return msg_id0(objc_getClass("NSString"), sel_registerName("string"))
	}
	c_value := strings.clone_to_cstring(value, context.temp_allocator)
	send := transmute(proc "c" (Id, Sel, cstring) -> Id)objc_send_address
	return send(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), c_value)
}

// nsstring_to_string borrows the bytes inside the NSString; copy before the
// object is released.
nsstring_to_string :: proc(value: Id) -> string {
	if value == nil {
		return ""
	}
	send := transmute(proc "c" (Id, Sel) -> cstring)objc_send_address
	c_value := send(value, sel_registerName("UTF8String"))
	if c_value == nil {
		return ""
	}
	return string(c_value)
}
