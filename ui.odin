// Status item, snapshot model, and the bridge to the clay panel.
//
// The worker thread samples and posts Ui_Snapshots; this file applies them on
// the main thread (title, panel content) and owns the pure row model that the
// panel lays out. Everything inside the panel is drawn by panel.odin.

package activity_monitor

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

NSVARIABLE_STATUS_ITEM_LENGTH :: -1.0

Ui_Row_Kind :: enum {
	Header,
	Group,
	Process,
	Note,
}

Ui_Row :: struct {
	kind:          Ui_Row_Kind,
	name:          string,
	cpu:           string, // stat columns, empty on header and note rows
	memory:        string,
	window_cpu:    string, // "avg 9.0%" over the history window
	window_memory: string, // "+340.0 MB" growth over the history window
	spark:         []f32,  // windowed CPU series, oldest first; group rows only
}

// Stat_Selection is which of the four stat columns the panel shows. Group rows
// carry all of them; process rows carry instant CPU and memory only, with the
// window columns left empty so the table stays aligned.
Stat_Selection :: struct {
	cpu:           bool,
	memory:        bool,
	window_cpu:    bool,
	window_memory: bool,
}

config_stat_selection :: proc(config: Config) -> Stat_Selection {
	return {
		cpu           = config.show_cpu,
		memory        = config.show_memory,
		window_cpu    = config.show_window_cpu,
		window_memory = config.show_window_memory,
	}
}

// Ui_Snapshot owns everything the panel reads; the sampler thread builds one,
// hands it to the main thread, and the main thread frees the previous one.
Ui_Snapshot :: struct {
	allocator:     runtime.Allocator,
	total_percent: f64,
	process_count: int,
	stats:         Stat_Selection,
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

// ui_elide shortens a row label to a character budget, ending it with an
// ellipsis; the result belongs to the caller's allocator.
ui_elide :: proc(name: string, limit: int, allocator := context.temp_allocator) -> string {
	if utf8.rune_count(name) <= limit {
		return strings.clone(name, allocator)
	}
	builder := strings.builder_make(allocator)
	written := 0
	for character in name {
		if written >= limit-1 {
			break
		}
		strings.write_rune(&builder, character)
		written += 1
	}
	strings.write_string(&builder, "…")
	return strings.to_string(builder)
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

// Ui_Build_Options carries what the row builder needs beyond the samples.
Ui_Build_Options :: struct {
	total_percent: f64,
	process_count: int,
	stats:         Stat_Selection,
}

// ui_build_rows renders the panel contents: a header, then each top group with
// its busiest processes underneath. Groups are shown while they are above the
// CPU floor or the memory floor, so a memory-heavy but idle process is visible;
// a group row carries the enabled stat columns, including the windowed average
// CPU, the signed window memory change, and the CPU series for the sparkline.
// Members below both process floors are not counted as hidden; only rows cut by
// the per-group limit are noted. Every string and series is allocated with the
// caller's allocator so snapshots can be freed wholesale.
ui_build_rows :: proc(
	groups: []Group_Sample,
	samples: []Process_Sample,
	trends: []Group_Trend,
	options: Ui_Build_Options,
	allocator := context.temp_allocator,
) -> []Ui_Row {
	rows := make([dynamic]Ui_Row, 0, 32, allocator)
	append(&rows, Ui_Row{
		kind = .Header,
		name = fmt.aprintf(
			"%.0f%% of all cores · %d processes",
			options.total_percent,
			options.process_count,
			allocator = allocator,
		),
	})

	by_pid := make(map[i32]Process_Sample, len(samples), context.temp_allocator)
	defer delete(by_pid)
	for sample in samples {
		by_pid[sample.pid] = sample
	}

	trend_by_name := make(map[string]int, len(trends), context.temp_allocator)
	defer delete(trend_by_name)
	for trend, index in trends {
		trend_by_name[trend.name] = index
	}

	name_chars := panel_name_chars(options.stats)
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

		group_suffix := fmt.tprintf(" ×%d", group.count)
		row := Ui_Row{
			kind = .Group,
			name = fmt.aprintf(
				"%s%s",
				ui_elide(
					group.name,
					max(8, name_chars-utf8.rune_count(group_suffix)),
					context.temp_allocator,
				),
				group_suffix,
				allocator = allocator,
			),
		}
		if options.stats.cpu {
			row.cpu = percent_text(group.cpu_percent, allocator)
		}
		if options.stats.memory {
			row.memory = format_bytes(group.memory_bytes, allocator)
		}
		if trend_index, found := trend_by_name[group.name]; found {
			trend := trends[trend_index]
			if options.stats.window_cpu {
				row.window_cpu = fmt.aprintf(
					"avg %s",
					percent_text(trend.cpu_avg, context.temp_allocator),
					allocator = allocator,
				)
				if len(trend.samples) >= 2 {
					row.spark = make([]f32, len(trend.samples), allocator)
					for sample, index in trend.samples {
						row.spark[index] = f32(sample.cpu_percent)
					}
				}
			}
			if options.stats.window_memory {
				row.window_memory = format_bytes_delta(trend.memory_growth, allocator)
			}
		}
		append(&rows, row)

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
			process_suffix := fmt.tprintf(" · %d", member.pid)
			process_row := Ui_Row{
				kind = .Process,
				name = fmt.aprintf(
					"    %s%s",
					ui_elide(
						member.name,
						max(8, name_chars-4-utf8.rune_count(process_suffix)),
						context.temp_allocator,
					),
					process_suffix,
					allocator = allocator,
				),
			}
			if options.stats.cpu {
				process_row.cpu = percent_text(member.cpu_fraction * 100, allocator)
			}
			if options.stats.memory {
				process_row.memory = format_bytes(member.memory_bytes, allocator)
			}
			append(&rows, process_row)
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
ui_post_snapshot :: proc(
	groups: []Group_Sample,
	samples: []Process_Sample,
	trends: []Group_Trend,
	options: Ui_Build_Options,
) {
	if ui_state.app == nil {
		return // headless fallback: nothing to draw
	}
	rows := ui_build_rows(groups, samples, trends, options, context.allocator)
	snapshot := new(Ui_Snapshot, context.allocator)
	snapshot^ = {
		allocator     = context.allocator,
		total_percent = options.total_percent,
		process_count = options.process_count,
		stats         = options.stats,
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
		if row.cpu != "" {
			delete(row.cpu, snapshot.allocator)
		}
		if row.memory != "" {
			delete(row.memory, snapshot.allocator)
		}
		if row.window_cpu != "" {
			delete(row.window_cpu, snapshot.allocator)
		}
		if row.window_memory != "" {
			delete(row.window_memory, snapshot.allocator)
		}
		if len(row.spark) > 0 {
			delete(row.spark, snapshot.allocator)
		}
	}
	delete(snapshot.rows, snapshot.allocator)
	free(snapshot, snapshot.allocator)
}
