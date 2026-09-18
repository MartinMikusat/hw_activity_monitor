// Menu bar UI: a status item shows total CPU percent; clicking it opens a
// transient popover with the top process groups and their processes.
//
// The main thread only draws. NSApplication owns the run loop, and snapshots
// arrive from the sampler thread as dispatch_async_f work items that are
// applied here (title, row list, popover size). Nothing on the main thread
// ever samples the process table, so opening the popover animates smoothly.
// The table's data source and delegate are one dynamically registered
// Objective-C class whose methods read the rows of the current snapshot.

package activity_monitor

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:slice"

UI_WIDTH :: 440
UI_MIN_HEIGHT :: 160
UI_MAX_HEIGHT :: 560
UI_ROW_HEIGHT :: 20
UI_GROUP_LIMIT :: 10
UI_GROUP_MIN_PERCENT :: 0.5
UI_PROCESS_LIMIT_PER_GROUP :: 4
UI_PROCESS_MIN_PERCENT :: 1.0
UI_VALUE_COLUMN_WIDTH :: 92

NSRIGHT_TEXT_ALIGNMENT :: 2
NSACCESSORY_ACTIVATION_POLICY :: 1
NSPOPOVER_TRANSIENT_BEHAVIOR :: 1
NSMIN_Y_EDGE :: 1
NSVARIABLE_STATUS_ITEM_LENGTH :: -1.0
NSSCROLLER_STYLE_OVERLAY :: 1

foreign import dispatch "system:System"
foreign dispatch {
	dispatch_async_f :: proc(queue: rawptr, ctx: rawptr, work: proc "c" (rawptr)) ---
	// The main queue in libdispatch is the global `_dispatch_main_q`, not a
	// function: `dispatch_get_main_queue()` is a C macro over its address.
	_dispatch_main_q: Dispatch_Queue_Storage
}

Dispatch_Queue_Storage :: struct {
	_opaque: u8,
}

Ui_Row_Kind :: enum {
	Header,
	Group,
	Process,
	Note,
}

Ui_Row :: struct {
	kind:  Ui_Row_Kind,
	name:  string,
	value: string,
}

// Ui_Snapshot owns everything the table reads; the sampler thread builds one,
// hands it to the main thread, and the main thread frees the previous one.
Ui_Snapshot :: struct {
	allocator:     runtime.Allocator,
	total_percent: f64,
	process_count: int,
	rows:          []Ui_Row,
}

// ------------------------------------------------------------------- model

percent_text :: proc(percent: f64, allocator := context.temp_allocator) -> string {
	if percent < 10 {
		return fmt.aprintf("%.1f%%", percent, allocator = allocator)
	}
	return fmt.aprintf("%.0f%%", percent, allocator = allocator)
}

// ui_total_percent reports the sampled CPU as a share of all cores.
ui_total_percent :: proc(samples: []Process_Cpu, cpu_count: int) -> f64 {
	if cpu_count <= 0 {
		return 0
	}
	total: f64
	for sample in samples {
		total += sample.cpu_fraction
	}
	return clamp(total / f64(cpu_count) * 100, 0, 100)
}

sort_by_cpu :: proc(samples: []Process_Cpu) {
	slice.sort_by(samples, proc(a, b: Process_Cpu) -> bool {
		return a.cpu_fraction > b.cpu_fraction
	})
}

// ui_build_rows renders the popover contents: a header, then each top group
// with its busiest processes underneath. Members below UI_PROCESS_MIN_PERCENT
// are not counted as hidden; only rows cut by the per-group limit are noted.
// Every string in the result is allocated with the caller's allocator:
// ui_snapshot_destroy frees them all, so literals are not allowed here.
ui_build_rows :: proc(
	groups: []Group_Cpu,
	samples: []Process_Cpu,
	total_percent: f64,
	process_count: int,
	allocator := context.temp_allocator,
) -> []Ui_Row {
	rows := make([dynamic]Ui_Row, 0, 32, allocator)
	append(&rows, Ui_Row{
		kind = .Header,
		name = fmt.aprintf("%.0f%% of all cores · %d processes", total_percent, process_count, allocator = allocator),
	})

	by_pid := make(map[i32]f64, len(samples), context.temp_allocator)
	defer delete(by_pid)
	for sample in samples {
		by_pid[sample.pid] = sample.cpu_fraction
	}

	group_count := 0
	for group in groups {
		if group.cpu_percent < UI_GROUP_MIN_PERCENT {
			break // groups are sorted highest first
		}
		if group_count >= UI_GROUP_LIMIT {
			break
		}
		group_count += 1
		append(&rows, Ui_Row{
			kind  = .Group,
			name  = fmt.aprintf("%s ×%d", group.name, group.count, allocator = allocator),
			value = percent_text(group.cpu_percent, allocator),
		})

		members := make([dynamic]Process_Cpu, 0, len(group.pids), context.temp_allocator)
		defer delete(members)
		for pid in group.pids {
			if fraction, found := by_pid[pid]; found {
				append(&members, Process_Cpu{pid = pid, name = group.name, cpu_fraction = fraction})
			}
		}
		sort_by_cpu(members[:])

		eligible := 0
		for member in members {
			if member.cpu_fraction * 100 < UI_PROCESS_MIN_PERCENT {
				break // sorted highest first
			}
			eligible += 1
		}
		shown := min(eligible, UI_PROCESS_LIMIT_PER_GROUP)
		for member in members[:shown] {
			append(&rows, Ui_Row{
				kind  = .Process,
				name  = fmt.aprintf("    %s · %d", member.name, member.pid, allocator = allocator),
				value = percent_text(member.cpu_fraction * 100, allocator),
			})
		}
		if hidden := eligible - shown; hidden > 0 {
			append(&rows, Ui_Row{
				kind = .Note,
				name = fmt.aprintf("    … and %d more", hidden, allocator = allocator),
			})
		}
	}

	if group_count == 0 {
		append(&rows, Ui_Row{kind = .Note, name = fmt.aprintf("All quiet", allocator = allocator)})
	}
	return rows[:]
}

// --------------------------------------------------------------------- app

Ui_State :: struct {
	app:         Id,
	status_item: Id,
	button:      Id,
	popover:     Id,
	table:       Id,
	container:   Id,
	scroll:      Id,
	snapshot:    ^Ui_Snapshot,
	width:       f64,
	height:      f64,
}

ui_state: Ui_State
ui_snapshot_applied: bool

ui_start :: proc() -> bool {
	if !darwin_objc_init() {
		return false
	}
	ui_state.width = UI_WIDTH
	ui_state.height = UI_MIN_HEIGHT

	app := msg_id0(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	if app == nil {
		return false
	}
	ui_state.app = app
	msg_void_i(app, sel_registerName("setActivationPolicy:"), NSACCESSORY_ACTIVATION_POLICY)

	ticker := ui_register_ticker()
	if ticker == nil {
		return false
	}

	status_bar := msg_id0(objc_getClass("NSStatusBar"), sel_registerName("systemStatusBar"))
	status_item := msg_id_f64(status_bar, sel_registerName("statusItemWithLength:"), NSVARIABLE_STATUS_ITEM_LENGTH)
	if status_item == nil {
		return false
	}
	ui_state.status_item = status_item
	button := msg_id0(status_item, sel_registerName("button"))
	if button == nil {
		return false
	}
	ui_state.button = button
	msg_void_id(button, sel_registerName("setTitle:"), nsstring("—"))
	msg_void_id(button, sel_registerName("setTarget:"), ticker)
	msg_void_sel(button, sel_registerName("setAction:"), sel_registerName("togglePopover:"))

	return ui_build_popover(ticker)
}

ui_register_ticker :: proc() -> Id {
	ticker_class := objc_allocateClassPair(objc_getClass("NSObject"), "ActivityMonitorTicker", 0)
	if ticker_class == nil {
		return nil
	}
	if !class_addMethod(ticker_class, sel_registerName("togglePopover:"), rawptr(ui_toggle_popover), "v@:@") ||
	   !class_addMethod(ticker_class, sel_registerName("numberOfRowsInTableView:"), rawptr(ui_table_row_count), "q@:@") ||
	   !class_addMethod(ticker_class, sel_registerName("tableView:viewForTableColumn:row:"), rawptr(ui_table_cell_view), "@@:@@q") {
		return nil
	}
	if protocol := objc_getProtocol("NSTableViewDataSource"); protocol != nil {
		_ = class_addProtocol(ticker_class, protocol)
	}
	if protocol := objc_getProtocol("NSTableViewDelegate"); protocol != nil {
		_ = class_addProtocol(ticker_class, protocol)
	}
	objc_registerClassPair(ticker_class)
	return msg_id0(ticker_class, sel_registerName("new"))
}

ui_build_popover :: proc(ticker: Id) -> bool {
	frame := Rect{{0, 0}, {UI_WIDTH, UI_MIN_HEIGHT}}

	table := msg_id_rect(
		msg_id0(objc_getClass("NSTableView"), sel_registerName("alloc")),
		sel_registerName("initWithFrame:"),
		frame,
	)
	if table == nil {
		return false
	}
	ui_state.table = table
	msg_void_id(table, sel_registerName("setHeaderView:"), nil)
	msg_void_f64(table, sel_registerName("setRowHeight:"), UI_ROW_HEIGHT)
	msg_void_bool(table, sel_registerName("setAllowsEmptySelection:"), true)
	msg_void_i(table, sel_registerName("setSelectionHighlightStyle:"), -1)
	msg_void_id(table, sel_registerName("setBackgroundColor:"), msg_id0(objc_getClass("NSColor"), sel_registerName("clearColor")))
	msg_void_id(table, sel_registerName("setDataSource:"), ticker)
	msg_void_id(table, sel_registerName("setDelegate:"), ticker)
	msg_void_id(table, sel_registerName("addTableColumn:"), ui_make_column("name", UI_WIDTH - UI_VALUE_COLUMN_WIDTH - 24))
	msg_void_id(table, sel_registerName("addTableColumn:"), ui_make_column("value", UI_VALUE_COLUMN_WIDTH))

	scroll := msg_id_rect(
		msg_id0(objc_getClass("NSScrollView"), sel_registerName("alloc")),
		sel_registerName("initWithFrame:"),
		frame,
	)
	if scroll == nil {
		return false
	}
	ui_state.scroll = scroll
	msg_void_bool(scroll, sel_registerName("setHasVerticalScroller:"), true)
	msg_void_bool(scroll, sel_registerName("setAutohidesScrollers:"), true)
	msg_void_i(scroll, sel_registerName("setScrollerStyle:"), NSSCROLLER_STYLE_OVERLAY)
	msg_void_bool(scroll, sel_registerName("setDrawsBackground:"), false)
	msg_void_id(scroll, sel_registerName("setDocumentView:"), table)

	container := msg_id_rect(
		msg_id0(objc_getClass("NSView"), sel_registerName("alloc")),
		sel_registerName("initWithFrame:"),
		frame,
	)
	if container == nil {
		return false
	}
	ui_state.container = container
	msg_void_id(container, sel_registerName("addSubview:"), scroll)

	controller := msg_id0(objc_getClass("NSViewController"), sel_registerName("new"))
	if controller == nil {
		return false
	}
	msg_void_id(controller, sel_registerName("setView:"), container)

	popover := msg_id0(msg_id0(objc_getClass("NSPopover"), sel_registerName("alloc")), sel_registerName("init"))
	if popover == nil {
		return false
	}
	msg_void_id(popover, sel_registerName("setContentViewController:"), controller)
	msg_void_i(popover, sel_registerName("setBehavior:"), NSPOPOVER_TRANSIENT_BEHAVIOR)
	msg_void_size(popover, sel_registerName("setContentSize:"), Size{UI_WIDTH, UI_MIN_HEIGHT})
	ui_state.popover = popover
	return true
}

ui_make_column :: proc(identifier: string, width: f64) -> Id {
	column := msg_id_id(
		msg_id0(objc_getClass("NSTableColumn"), sel_registerName("alloc")),
		sel_registerName("initWithIdentifier:"),
		nsstring(identifier),
	)
	if column != nil {
		msg_void_f64(column, sel_registerName("setWidth:"), width)
	}
	return column
}

// ui_resize sizes the popover to its content up to UI_MAX_HEIGHT. The popover
// keeps its current size while it is open so the list does not jump under the
// pointer.
ui_resize :: proc(height: f64) {
	if ui_state.popover == nil || ui_state.container == nil || ui_state.scroll == nil || ui_state.table == nil {
		return
	}
	if msg_bool_0(ui_state.popover, sel_registerName("isShown")) {
		return
	}
	if abs(height - ui_state.height) < 1 {
		return
	}
	ui_state.height = height
	frame := Rect{{0, 0}, {ui_state.width, height}}
	msg_void_size(ui_state.popover, sel_registerName("setContentSize:"), Size{ui_state.width, height})
	msg_void_rect(ui_state.container, sel_registerName("setFrame:"), frame)
	msg_void_rect(ui_state.scroll, sel_registerName("setFrame:"), frame)
	msg_void_rect(ui_state.table, sel_registerName("setFrame:"), frame)
}

// ui_run hands control to AppKit; it only returns when the app terminates.
ui_run :: proc() {
	if ui_state.app != nil {
		msg_void0(ui_state.app, sel_registerName("run"))
	}
}

ui_active_cpu_count :: proc() -> int {
	if objc_send_address == nil {
		return 1
	}
	info := msg_id0(objc_getClass("NSProcessInfo"), sel_registerName("processInfo"))
	count := msg_u64_0(info, sel_registerName("activeProcessorCount"))
	return count == 0 ? 1 : int(count)
}

// ui_post_snapshot builds one snapshot for the main thread. Sampler thread
// only: rows and strings belong to the snapshot until the main thread frees it.
ui_post_snapshot :: proc(total_percent: f64, groups: []Group_Cpu, samples: []Process_Cpu, process_count: int) {
	if ui_state.app == nil {
		return // headless fallback: nothing to draw
	}
	rows := ui_build_rows(groups, samples, total_percent, process_count, context.allocator)
	snapshot := new(Ui_Snapshot, context.allocator)
	snapshot^ = {
		allocator     = context.allocator,
		total_percent = total_percent,
		process_count = process_count,
		rows          = rows,
	}
	dispatch_async_f(&_dispatch_main_q, snapshot, ui_apply_snapshot_c)
}

ui_apply_snapshot_c :: proc "c" (raw_snapshot: rawptr) {
	context = runtime.default_context()
	ui_apply_snapshot((^Ui_Snapshot)(raw_snapshot))
}

// ui_apply_snapshot runs on the main thread: title, popover size, and table
// contents, then frees the snapshot it replaced.
ui_apply_snapshot :: proc(snapshot: ^Ui_Snapshot) {
	if ui_state.button != nil {
		msg_void_id(
			ui_state.button,
			sel_registerName("setTitle:"),
			nsstring(fmt.tprintf("%.0f%%", snapshot.total_percent)),
		)
	}
	previous := ui_state.snapshot
	ui_state.snapshot = snapshot
	if !ui_snapshot_applied {
		ui_snapshot_applied = true
		log_event(monitor.log, "ui_ready", fmt.tprintf("\"rows\":%d", len(snapshot.rows)))
	}
	ui_resize(clamp(f64(24 + len(snapshot.rows) * UI_ROW_HEIGHT), UI_MIN_HEIGHT, UI_MAX_HEIGHT))
	if ui_state.table != nil {
		msg_void0(ui_state.table, sel_registerName("reloadData"))
	}
	if previous != nil {
		ui_snapshot_destroy(previous)
	}
}

ui_snapshot_destroy :: proc(snapshot: ^Ui_Snapshot) {
	for row in snapshot.rows {
		if row.name != "" {
			delete(row.name, snapshot.allocator)
		}
		if row.value != "" {
			delete(row.value, snapshot.allocator)
		}
	}
	delete(snapshot.rows, snapshot.allocator)
	free(snapshot, snapshot.allocator)
}

// --------------------------------------------------------------- callbacks

ui_toggle_popover :: proc "c" (self: Id, cmd: Sel, sender: Id) {
	context = runtime.default_context()
	if ui_state.popover == nil || ui_state.button == nil {
		return
	}
	if msg_bool_0(ui_state.popover, sel_registerName("isShown")) {
		msg_void0(ui_state.popover, sel_registerName("close"))
		return
	}
	bounds := msg_rect_0(ui_state.button, sel_registerName("bounds"))
	msg_void_rect_id_i(
		ui_state.popover,
		sel_registerName("showRelativeToRect:ofView:preferredEdge:"),
		bounds,
		ui_state.button,
		NSMIN_Y_EDGE,
	)
}

ui_table_row_count :: proc "c" (self: Id, cmd: Sel, table: Id) -> i64 {
	context = runtime.default_context()
	if ui_state.snapshot == nil {
		return 0
	}
	return i64(len(ui_state.snapshot.rows))
}

ui_table_cell_view :: proc "c" (self: Id, cmd: Sel, table: Id, column: Id, row: i64) -> Id {
	context = runtime.default_context()
	if ui_state.snapshot == nil || row < 0 || int(row) >= len(ui_state.snapshot.rows) {
		return nil
	}
	entry := ui_state.snapshot.rows[row]
	is_value_column := nsstring_to_string(msg_id0(column, sel_registerName("identifier"))) == "value"

	text := entry.name
	if is_value_column {
		text = entry.value
	}
	label := msg_id_id(objc_getClass("NSTextField"), sel_registerName("labelWithString:"), nsstring(text))
	if label == nil {
		return nil
	}
	#partial switch entry.kind {
	case .Header, .Group:
		msg_void_id(
			label,
			sel_registerName("setFont:"),
			msg_id_f64(objc_getClass("NSFont"), sel_registerName("boldSystemFontOfSize:"), 12),
		)
	case .Note:
		msg_void_id(
			label,
			sel_registerName("setTextColor:"),
			msg_id0(objc_getClass("NSColor"), sel_registerName("secondaryLabelColor")),
		)
	case .Process:
	}
	if is_value_column {
		msg_void_i(label, sel_registerName("setAlignment:"), NSRIGHT_TEXT_ALIGNMENT)
	}
	return label
}
