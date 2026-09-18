// Status item, snapshot model, and the bridge to the clay panel.
//
// The worker thread samples and posts Ui_Snapshots; this file applies them on
// the main thread (title, panel content) and owns the pure row model that the
// panel lays out. Everything inside the panel is drawn by panel.odin.

package activity_monitor

import "base:runtime"
import "core:fmt"
import "core:slice"

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

// Ui_Snapshot owns everything the panel reads; the sampler thread builds one,
// hands it to the main thread, and the main thread frees the previous one.
Ui_Snapshot :: struct {
	allocator:     runtime.Allocator,
	total_percent: f64,
	process_count: int,
	rows:          []Ui_Row,
}

Ui_State :: struct {
	app:         Id,
	status_item: Id,
	button:      Id,
	snapshot:    ^Ui_Snapshot,
}

ui_state: Ui_State
ui_snapshot_applied: bool

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

// ui_build_rows renders the panel contents: a header, then each top group with
// its busiest processes underneath. Members below UI_PROCESS_MIN_PERCENT are
// not counted as hidden; only rows cut by the per-group limit are noted. Every
// string is allocated with the caller's allocator so snapshots can be freed
// wholesale.
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

ui_start :: proc() -> bool {
	if !darwin_objc_init() {
		return false
	}
	app := msg_id0(objc_getClass("NSApplication"), sel_registerName("sharedApplication"))
	if app == nil {
		return false
	}
	ui_state.app = app
	msg_void_i(app, sel_registerName("setActivationPolicy:"), NSACCESSORY_ACTIVATION_POLICY)

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

	if !panel_window_init() {
		return false
	}
	msg_void_id(button, sel_registerName("setTarget:"), panel_window.controller)
	msg_void_sel(button, sel_registerName("setAction:"), sel_registerName("togglePanel:"))
	return true
}

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

// ui_status_button_screen_rect reports the status item's frame in screen
// coordinates; the panel anchors to it.
ui_status_button_screen_rect :: proc() -> Rect {
	if ui_state.button == nil {
		return {}
	}
	button_window := msg_id0(ui_state.button, sel_registerName("window"))
	if button_window == nil {
		return {}
	}
	bounds := msg_rect_0(ui_state.button, sel_registerName("bounds"))
	in_window := msg_rect_rect_id(ui_state.button, sel_registerName("convertRect:toView:"), bounds, nil)
	return msg_rect_rect(button_window, sel_registerName("convertRectToScreen:"), in_window)
}

// ---------------------------------------------------------------- snapshots

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

// ui_apply_snapshot runs on the main thread: title, panel content, then frees
// the snapshot it replaced.
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
		log_event(monitor.log, "ui_ready", fmt.tprintf("\"rows\":%d,\"panel\":\"clay\"", len(snapshot.rows)))
	}
	panel_content_changed()
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
