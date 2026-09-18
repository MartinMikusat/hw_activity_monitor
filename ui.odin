// Menu bar UI: a status item shows total CPU percent; clicking it opens a
// transient popover with the top process groups and their processes.
//
// Everything here runs on the main thread. NSApplication owns the run loop and
// an NSTimer calls one monitor tick per interval, which samples, evaluates
// alerts, refreshes the title, and reloads the table. The table's data source
// and delegate are a single dynamically registered Objective-C class whose
// methods read the rows built by ui_build_rows into a per-tick arena.

package activity_monitor

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strings"

UI_WIDTH :: 340
UI_HEIGHT :: 420
UI_GROUP_LIMIT :: 10
UI_GROUP_MIN_PERCENT :: 0.5
UI_PROCESS_LIMIT_PER_GROUP :: 4
UI_PROCESS_MIN_PERCENT :: 1.0
UI_ARENA_SIZE :: 128 * 1024

NSTABLE_ROW_HEIGHT :: 20
NSRIGHT_TEXT_ALIGNMENT :: 2
NSACCESSORY_ACTIVATION_POLICY :: 1
NSPOPOVER_TRANSIENT_BEHAVIOR :: 1
NSMIN_Y_EDGE :: 1
NSVARIABLE_STATUS_ITEM_LENGTH :: -1.0

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
// with its busiest processes underneath, then nothing else. Rows live in the
// caller's allocator; the daemon passes its per-tick arena.
ui_build_rows :: proc(
	groups: []Group_Cpu,
	samples: []Process_Cpu,
	total_percent: f64,
	process_count: int,
	allocator := context.temp_allocator,
) -> []Ui_Row {
	rows := make([dynamic]Ui_Row, 0, 32, allocator)
	append(&rows, Ui_Row{
		kind  = .Header,
		name  = fmt.aprintf("%.0f%% of all cores · %d processes", total_percent, process_count, allocator = allocator),
		value = "",
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

		shown := 0
		for member in members {
			if member.cpu_fraction * 100 < UI_PROCESS_MIN_PERCENT {
				break
			}
			if shown >= UI_PROCESS_LIMIT_PER_GROUP {
				break
			}
			shown += 1
			append(&rows, Ui_Row{
				kind  = .Process,
				name  = fmt.aprintf("    %s · %d", member.name, member.pid, allocator = allocator),
				value = percent_text(member.cpu_fraction * 100, allocator),
			})
		}
		if remaining := len(members) - shown; remaining > 0 {
			append(&rows, Ui_Row{
				kind = .Note,
				name = fmt.aprintf("    … and %d more", remaining, allocator = allocator),
			})
		}
	}

	if group_count == 0 {
		append(&rows, Ui_Row{kind = .Note, name = "All quiet"})
	}
	return rows[:]
}

// --------------------------------------------------------------------- app

Ui_State :: struct {
	app:          Id,
	status_item:  Id,
	button:       Id,
	popover:      Id,
	table:        Id,
	ticker:       Id,
	rows:         []Ui_Row,
	arena:        mem.Arena,
	arena_buffer: []byte,
}

ui_state: Ui_State
ui_on_tick: proc()

ui_start :: proc(config: Config, on_tick: proc()) -> bool {
	assert(on_tick != nil, "tick callback required")
	if !darwin_objc_init() {
		return false
	}
	ui_on_tick = on_tick
	ui_state.arena_buffer = make([]byte, UI_ARENA_SIZE)
	mem.arena_init(&ui_state.arena, ui_state.arena_buffer)

	app := msg_id0(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	if app == nil {
		return false
	}
	ui_state.app = app
	msg_void_i(app, sel_registerName("setActivationPolicy:"), NSACCESSORY_ACTIVATION_POLICY)

	ticker_class := objc_allocateClassPair(objc_getClass("NSObject"), "ActivityMonitorTicker", 0)
	if ticker_class == nil {
		return false
	}
	if !class_addMethod(ticker_class, sel_registerName("tick:"), rawptr(ui_timer_fired), "v@:@") ||
	   !class_addMethod(ticker_class, sel_registerName("togglePopover:"), rawptr(ui_toggle_popover), "v@:@") ||
	   !class_addMethod(ticker_class, sel_registerName("numberOfRowsInTableView:"), rawptr(ui_table_row_count), "q@:@") ||
	   !class_addMethod(ticker_class, sel_registerName("tableView:viewForTableColumn:row:"), rawptr(ui_table_cell_view), "@@:@@q") {
		return false
	}
	if protocol := objc_getProtocol("NSTableViewDataSource"); protocol != nil {
		_ = class_addProtocol(ticker_class, protocol)
	}
	if protocol := objc_getProtocol("NSTableViewDelegate"); protocol != nil {
		_ = class_addProtocol(ticker_class, protocol)
	}
	objc_registerClassPair(ticker_class)
	ticker := msg_id0(ticker_class, sel_registerName("new"))
	if ticker == nil {
		return false
	}
	ui_state.ticker = ticker

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

	if !ui_build_popover(ticker) {
		return false
	}

	msg_timer(
		objc_getClass("NSTimer"),
		sel_registerName("scheduledTimerWithTimeInterval:target:selector:userInfo:repeats:"),
		config.interval_seconds,
		ticker,
		sel_registerName("tick:"),
		nil,
		true,
	)
	return true
}

ui_build_popover :: proc(ticker: Id) -> bool {
	frame := Rect{{0, 0}, {UI_WIDTH, UI_HEIGHT}}

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
	msg_void_f64(table, sel_registerName("setRowHeight:"), NSTABLE_ROW_HEIGHT)
	msg_void_bool(table, sel_registerName("setAllowsEmptySelection:"), true)
	msg_void_i(table, sel_registerName("setSelectionHighlightStyle:"), -1)
	msg_void_id(table, sel_registerName("setBackgroundColor:"), msg_id0(objc_getClass("NSColor"), sel_registerName("clearColor")))
	msg_void_id(table, sel_registerName("setDataSource:"), ticker)
	msg_void_id(table, sel_registerName("setDelegate:"), ticker)
	msg_void_id(table, sel_registerName("addTableColumn:"), ui_make_column("name", f64(UI_WIDTH) - 96))
	msg_void_id(table, sel_registerName("addTableColumn:"), ui_make_column("value", 76))

	scroll := msg_id_rect(
		msg_id0(objc_getClass("NSScrollView"), sel_registerName("alloc")),
		sel_registerName("initWithFrame:"),
		frame,
	)
	if scroll == nil {
		return false
	}
	msg_void_bool(scroll, sel_registerName("setHasVerticalScroller:"), true)
	msg_void_bool(scroll, sel_registerName("setAutohidesScrollers:"), true)
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
	msg_void_size(popover, sel_registerName("setContentSize:"), Size{UI_WIDTH, UI_HEIGHT})
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

// ui_update refreshes the title and the popover table; main thread only.
ui_update :: proc(total_percent: f64, groups: []Group_Cpu, samples: []Process_Cpu, process_count: int) {
	if ui_state.button == nil {
		return
	}
	msg_void_id(ui_state.button, sel_registerName("setTitle:"), nsstring(fmt.tprintf("%.0f%%", total_percent)))
	if ui_state.table == nil {
		return
	}
	mem.arena_free_all(&ui_state.arena)
	ui_state.rows = ui_build_rows(
		groups,
		samples,
		total_percent,
		process_count,
		mem.arena_allocator(&ui_state.arena),
	)
	msg_void0(ui_state.table, sel_registerName("reloadData"))
}

// --------------------------------------------------------------- callbacks

ui_timer_fired :: proc "c" (self: Id, cmd: Sel, timer: Id) {
	context = runtime.default_context()
	if ui_on_tick != nil {
		ui_on_tick()
	}
}

ui_toggle_popover :: proc "c" (self: Id, cmd: Sel, sender: Id) {
	context = runtime.default_context()
	if ui_state.popover == nil || ui_state.button == nil {
		return
	}
	if msg_bool_0(ui_state.popover, sel_registerName("isShown")) {
		msg_void0(ui_state.popover, sel_registerName("close"))
		return
	}
	if ui_on_tick != nil {
		ui_on_tick() // fresh numbers on open
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
	return i64(len(ui_state.rows))
}

ui_table_cell_view :: proc "c" (self: Id, cmd: Sel, table: Id, column: Id, row: i64) -> Id {
	context = runtime.default_context()
	if row < 0 || int(row) >= len(ui_state.rows) {
		return nil
	}
	entry := ui_state.rows[row]
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
