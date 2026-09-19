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

// metric_text renders one row's metrics as "240% · 3.4 GB". Intermediates live
// in temporary storage so only the result is charged to allocator.
metric_text :: proc(cpu_percent: f64, memory_bytes: u64, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"%s · %s",
		percent_text(cpu_percent, context.temp_allocator),
		format_bytes(memory_bytes, context.temp_allocator),
		allocator = allocator,
	)
}

// ui_total_percent reports the sampled CPU as a share of all cores.
ui_total_percent :: proc(samples: []Process_Sample, cpu_count: int) -> f64 {
	if cpu_count <= 0 {
		return 0
	}
	total: f64
	for sample in samples {
		total += sample.cpu_fraction
	}
	return clamp(total / f64(cpu_count) * 100, 0, 100)
}

sort_by_cpu :: proc(samples: []Process_Sample) {
	slice.sort_by(samples, proc(a, b: Process_Sample) -> bool {
		return a.cpu_fraction > b.cpu_fraction
	})
}

// ui_build_rows renders the panel contents: a header, then each top group with
// its busiest processes underneath. Groups are shown while they are above the
// CPU floor or the memory floor, so a memory-heavy but idle process is visible;
// a group row carries "CPU · memory". Members below both process floors are not
// counted as hidden; only rows cut by the per-group limit are noted. Every
// string is allocated with the caller's allocator so snapshots can be freed
// wholesale.
ui_build_rows :: proc(
	groups: []Group_Sample,
	samples: []Process_Sample,
	total_percent: f64,
	process_count: int,
	allocator := context.temp_allocator,
) -> []Ui_Row {
	rows := make([dynamic]Ui_Row, 0, 32, allocator)
	append(&rows, Ui_Row{
		kind = .Header,
		name = fmt.aprintf("%.0f%% of all cores · %d processes", total_percent, process_count, allocator = allocator),
	})

	by_pid := make(map[i32]Process_Sample, len(samples), context.temp_allocator)
	defer delete(by_pid)
	for sample in samples {
		by_pid[sample.pid] = sample
	}

	group_count := 0
	for group in groups {
		cpu_active := group.cpu_percent >= UI_GROUP_MIN_PERCENT
		memory_active := group.memory_bytes >= u64(UI_GROUP_MEMORY_MIN_MB) * (1 << 20)
		if !cpu_active && !memory_active {
			continue // groups are sorted by CPU, so a memory-heavy group can be anywhere
		}
		if group_count >= UI_GROUP_LIMIT {
			break
		}
		group_count += 1
		append(&rows, Ui_Row{
			kind  = .Group,
			name  = fmt.aprintf("%s ×%d", group.name, group.count, allocator = allocator),
			value = metric_text(group.cpu_percent, group.memory_bytes, allocator),
		})

		members := make([dynamic]Process_Sample, 0, len(group.pids), context.temp_allocator)
		defer delete(members)
		for pid in group.pids {
			if sample, found := by_pid[pid]; found {
				append(&members, sample)
			}
		}
		sort_by_cpu(members[:])

		eligible := make([dynamic]Process_Sample, 0, len(members), context.temp_allocator)
		defer delete(eligible)
		for member in members {
			cpu_member := member.cpu_fraction * 100 >= UI_PROCESS_MIN_PERCENT
			memory_member := member.memory_bytes >= u64(UI_PROCESS_MEMORY_MIN_MB) * (1 << 20)
			if !cpu_member && !memory_member {
				continue
			}
			append(&eligible, member)
		}
		shown := min(len(eligible), UI_PROCESS_LIMIT_PER_GROUP)
		for member in eligible[:shown] {
			append(&rows, Ui_Row{
				kind  = .Process,
				name  = fmt.aprintf("    %s · %d", member.name, member.pid, allocator = allocator),
				value = metric_text(member.cpu_fraction * 100, member.memory_bytes, allocator),
			})
		}
		if hidden := len(eligible) - shown; hidden > 0 {
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
ui_post_snapshot :: proc(total_percent: f64, groups: []Group_Sample, samples: []Process_Sample, process_count: int) {
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
