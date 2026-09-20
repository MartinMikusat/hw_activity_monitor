// Minimal Objective-C runtime glue for the menu bar UI and notification
// delivery, mirroring the helper set in hw_calendar/darwin.odin.

package activity_monitor

import "core:dynlib"
import "core:strings"

Id :: rawptr
Sel :: rawptr

NSACCESSORY_ACTIVATION_POLICY :: 1

// The main dispatch queue is the global `_dispatch_main_q`: in C
// `dispatch_get_main_queue()` is a macro over its address. Snapshots hop from
// the sampler thread to the main thread through dispatch_async_f.
foreign import dispatch "system:System"
foreign dispatch {
	dispatch_async_f  :: proc(queue: rawptr, ctx: rawptr, work: proc "c" (rawptr)) ---
	_dispatch_main_q: Dispatch_Queue_Storage
}

Dispatch_Queue_Storage :: struct {
	_opaque: u8,
}

Point :: struct {x, y: f64}
Size :: struct {width, height: f64}
Rect :: struct {origin: Point, size: Size}

foreign import objc "system:objc"
foreign objc {
	objc_getClass          :: proc "c" (name: cstring) -> Id ---
	objc_getProtocol       :: proc "c" (name: cstring) -> Id ---
	sel_registerName       :: proc "c" (name: cstring) -> Sel ---
	objc_allocateClassPair :: proc "c" (superclass: Id, name: cstring, extra: uint) -> Id ---
	objc_registerClassPair :: proc "c" (cls: Id) ---
	class_addMethod        :: proc "c" (cls: Id, name: Sel, imp: rawptr, types: cstring) -> bool ---
	class_addProtocol      :: proc "c" (cls: Id, protocol: Id) -> bool ---
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

msg_id_id :: proc(receiver: Id, selector: Sel, argument: Id) -> Id {
	send := transmute(proc "c" (Id, Sel, Id) -> Id)objc_send_address
	return send(receiver, selector, argument)
}

msg_id_id_id :: proc(receiver: Id, selector: Sel, a, b, c: Id) -> Id {
	send := transmute(proc "c" (Id, Sel, Id, Id, Id) -> Id)objc_send_address
	return send(receiver, selector, a, b, c)
}

msg_id_id2 :: proc(receiver: Id, selector: Sel, a, b: Id) -> Id {
	send := transmute(proc "c" (Id, Sel, Id, Id) -> Id)objc_send_address
	return send(receiver, selector, a, b)
}

msg_void_id_id_id :: proc(receiver: Id, selector: Sel, a, b, c: Id) {
	send := transmute(proc "c" (Id, Sel, Id, Id, Id))objc_send_address
	send(receiver, selector, a, b, c)
}

msg_void_u :: proc(receiver: Id, selector: Sel, value: u64) {
	send := transmute(proc "c" (Id, Sel, u64))objc_send_address
	send(receiver, selector, value)
}

msg_id_f64 :: proc(receiver: Id, selector: Sel, value: f64) -> Id {
	send := transmute(proc "c" (Id, Sel, f64) -> Id)objc_send_address
	return send(receiver, selector, value)
}

// nsfont_attribute_name resolves AppKit's NSFontAttributeName global (an
// NSString pointer) through the framework handle. It is used to build the
// attributed status title, which is what makes AppKit measure the title with
// our font instead of the menu bar font.
NSFontAttributeName_symbol: ^Id

nsfont_attribute_name :: proc() -> Id {
	if NSFontAttributeName_symbol == nil {
		handle, loaded := dynlib.load_library("/System/Library/Frameworks/AppKit.framework/AppKit")
		if !loaded {
			return nil
		}
		address, found := dynlib.symbol_address(handle, "NSFontAttributeName")
		if !found {
			return nil
		}
		NSFontAttributeName_symbol = (^Id)(address)
	}
	return NSFontAttributeName_symbol^
}

msg_id_id_f64 :: proc(receiver: Id, selector: Sel, first: Id, second: f64) -> Id {
	send := transmute(proc "c" (Id, Sel, Id, f64) -> Id)objc_send_address
	return send(receiver, selector, first, second)
}

msg_id_f64_f64 :: proc(receiver: Id, selector: Sel, first, second: f64) -> Id {
	send := transmute(proc "c" (Id, Sel, f64, f64) -> Id)objc_send_address
	return send(receiver, selector, first, second)
}

msg_id_id_u :: proc(receiver: Id, selector: Sel, first: Id, second: uint) -> Id {
	send := transmute(proc "c" (Id, Sel, Id, uint) -> Id)objc_send_address
	return send(receiver, selector, first, second)
}

msg_size_0 :: proc(receiver: Id, selector: Sel) -> Size {
	send := transmute(proc "c" (Id, Sel) -> Size)objc_send_address
	return send(receiver, selector)
}

msg_void_i :: proc(receiver: Id, selector: Sel, value: int) {
	send := transmute(proc "c" (Id, Sel, int))objc_send_address
	send(receiver, selector, value)
}

msg_void_sel :: proc(receiver: Id, selector: Sel, value: Sel) {
	send := transmute(proc "c" (Id, Sel, Sel))objc_send_address
	send(receiver, selector, value)
}

msg_void_bool :: proc(receiver: Id, selector: Sel, value: bool) {
	send := transmute(proc "c" (Id, Sel, bool))objc_send_address
	send(receiver, selector, value)
}

msg_void_f64 :: proc(receiver: Id, selector: Sel, value: f64) {
	send := transmute(proc "c" (Id, Sel, f64))objc_send_address
	send(receiver, selector, value)
}

msg_void_size :: proc(receiver: Id, selector: Sel, value: Size) {
	send := transmute(proc "c" (Id, Sel, Size))objc_send_address
	send(receiver, selector, value)
}

msg_id_rect :: proc(receiver: Id, selector: Sel, value: Rect) -> Id {
	send := transmute(proc "c" (Id, Sel, Rect) -> Id)objc_send_address
	return send(receiver, selector, value)
}

msg_void_rect :: proc(receiver: Id, selector: Sel, value: Rect) {
	send := transmute(proc "c" (Id, Sel, Rect))objc_send_address
	send(receiver, selector, value)
}

msg_bool_0 :: proc(receiver: Id, selector: Sel) -> bool {
	send := transmute(proc "c" (Id, Sel) -> bool)objc_send_address
	return send(receiver, selector)
}

msg_u64_0 :: proc(receiver: Id, selector: Sel) -> u64 {
	send := transmute(proc "c" (Id, Sel) -> u64)objc_send_address
	return send(receiver, selector)
}

msg_rect_0 :: proc(receiver: Id, selector: Sel) -> Rect {
	send := transmute(proc "c" (Id, Sel) -> Rect)objc_send_address
	return send(receiver, selector)
}

msg_rect_rect :: proc(receiver: Id, selector: Sel, value: Rect) -> Rect {
	send := transmute(proc "c" (Id, Sel, Rect) -> Rect)objc_send_address
	return send(receiver, selector, value)
}

msg_rect_rect_id :: proc(receiver: Id, selector: Sel, value: Rect, view: Id) -> Rect {
	send := transmute(proc "c" (Id, Sel, Rect, Id) -> Rect)objc_send_address
	return send(receiver, selector, value, view)
}

msg_void_rect_id_i :: proc(receiver: Id, selector: Sel, rect: Rect, view: Id, edge: int) {
	send := transmute(proc "c" (Id, Sel, Rect, Id, int))objc_send_address
	send(receiver, selector, rect, view, edge)
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
