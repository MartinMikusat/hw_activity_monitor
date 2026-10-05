// Status item, snapshot model, and the bridge to the clay panel.
//
// The worker thread samples and posts Ui_Snapshots; this file applies them on
// the main thread (title, panel content) and owns the pure row model that the
// panel lays out. Everything inside the panel is drawn by panel.odin.

package activity_monitor

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

NSVARIABLE_STATUS_ITEM_LENGTH :: -1.0
// The status title is set in Iosevka, the panel's monospace face, at a menu bar
// size, with a little padding around the measured width.
STATUS_FONT_NAME :: "Iosevka"
STATUS_FONT_SIZE :: 13.0
STATUS_TITLE_PADDING :: f64(6)
// NSEventMask values are one bit per event type; the status button must be told
// to send its action for right clicks too, so the menu can pop up.
NSEVENT_MASK_LEFT_MOUSE_UP :: u64(1 << 2)
NSEVENT_MASK_RIGHT_MOUSE_UP :: u64(1 << 4)

Ui_Row_Kind :: enum {
	Header,
	Group,
	Process,
	Note,
}

Ui_Row :: struct {
	kind:          Ui_Row_Kind,
	key:           string, // group name; empty on header rows
	pid:           i32,    // process rows only
	rank:          int,    // 1-based: group rank, or rank inside its group
	name:          string,
	cpu:           string, // stat columns, empty on header and note rows
	gpu:           string,
	memory:        string,
	window_cpu:    string, // "avg 9.0%" over the history window
	window_memory: string, // "+340.0 MB" growth over the history window
	spark:         []f32,  // windowed CPU series, oldest first; group rows only
	spark_memory:  []f32,  // windowed footprint series, oldest first; group rows only
	cpu_peak:      f64,    // windowed CPU peak, for the chart's peak marker
	memory_peak:   u64,    // windowed footprint peak
}

// Stat_Selection is which of the five stat columns the panel shows. Group rows
// carry all of them; process rows carry instant CPU and memory only, with the
// window columns left empty so the table stays aligned.
Stat_Selection :: struct {
	cpu:           bool,
	gpu:           bool,
	memory:        bool,
	window_cpu:    bool,
	window_memory: bool,
}

config_stat_selection :: proc(config: Config) -> Stat_Selection {
	return {
		cpu           = config.show_cpu,
		gpu           = config.show_gpu,
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
	config:        Config,
	rows:          []Ui_Row,
	groups_text:   string, // for the Copy button
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

// ui_group_urgency ranks what is consuming the most of its budget over the
// history window: the larger of the windowed CPU share and the footprint share.
// A disabled memory budget leaves the CPU share. Ranks drive the panel's index
// numbers and highlights, not the alerts.
ui_group_urgency :: proc(cpu_avg: f64, memory_bytes: u64, config: Config) -> f64 {
	cpu_share := config.cpu_percent > 0 ? cpu_avg / config.cpu_percent : 0
	memory_share: f64
	if config.memory_mb > 0 {
		memory_share = f64(memory_bytes) / (config.memory_mb * f64(1 << 20))
	}
	return max(cpu_share, memory_share)
}

// ui_process_urgency is the same measure for one process, from its current
// values because history is kept per group.
ui_process_urgency :: proc(sample: Process_Sample, config: Config) -> f64 {
	return ui_group_urgency(sample.cpu_fraction * 100, sample.memory_bytes, config)
}

Ranked_Group :: struct {
	group:   Group_Sample,
	cpu_avg: f64,
	urgency: f64,
}

Ranked_Process :: struct {
	sample:  Process_Sample,
	urgency: f64,
}

// Ui_Build_Options carries what the row builder needs beyond the samples.
Ui_Build_Options :: struct {
	total_percent: f64,
	process_count: int,
	config:        Config, // the snapshot carries it for the settings modal
	display:       ^Ui_Display_State,
	now:           time.Tick,
}

// Ui_Display_State keeps the list from shifting as processes cross the display
// floors. A process that has been given a row keeps it while it lives, and a
// group that has grown to N process rows keeps N slots, so rows are added but
// never taken away for going quiet; a row freed by an exit is filled from the
// group's next-ranked process. The state belongs to the sampler thread and is
// carried into every build; entries are dropped once their group has been gone
// for the history window.
Ui_Display_State :: struct {
	groups: map[string]Ui_Display_Group,
}

Ui_Display_Group :: struct {
	// The pids with a row now, in rank order, the high-water number of rows,
	// whether a "… and N more" note has been shown, and when the group was last
	// seen above the group floor.
	pids: [dynamic]i32,
	rows: int,
	note: bool,
	seen: time.Tick,
}

ui_display_init :: proc(state: ^Ui_Display_State) {
	if state.groups == nil {
		state.groups = make(map[string]Ui_Display_Group)
	}
}

ui_display_destroy :: proc(state: ^Ui_Display_State) {
	for name, group in state.groups {
		delete(group.pids)
		delete(name)
	}
	delete(state.groups)
	state.groups = nil
}

// ui_display_group returns the group's entry, creating it on first sight.
ui_display_group :: proc(state: ^Ui_Display_State, name: string) -> ^Ui_Display_Group {
	ui_display_init(state)
	if entry, found := &state.groups[name]; found {
		return entry
	}
	key := strings.clone(name)
	state.groups[key] = Ui_Display_Group{}
	return &state.groups[key]
}

// ui_display_prune drops the entries of groups that have been gone longer than
// the history window.
ui_display_prune :: proc(state: ^Ui_Display_State, now: time.Tick, window: time.Duration) {
	if state.groups == nil {
		return
	}
	stale := make([dynamic]string, 0, len(state.groups), context.temp_allocator)
	defer delete(stale)
	for name, group in state.groups {
		if time.tick_diff(group.seen, now) > window {
			append(&stale, name)
		}
	}
	for name in stale {
		group, found := state.groups[name]
		if !found {
			continue
		}
		delete(group.pids)
		// Odin's maps store the key they were given, so its memory is freed
		// here: delete_key hands the stored key back, and only then is it safe
		// to free. Freeing it first would leave delete_key hashing freed bytes.
		deleted, _ := delete_key(&state.groups, name)
		delete(deleted)
	}
}

// ui_display_remember records the rows a group is showing.
ui_display_remember :: proc(display: ^Ui_Display_Group, selected: []Process_Sample) {
	clear(&display.pids)
	for member in selected {
		append(&display.pids, member.pid)
	}
	display.rows = max(display.rows, len(selected))
}

// ui_selected_contains is whether a pid already has a row in this build.
ui_selected_contains :: proc(selected: []Process_Sample, pid: i32) -> bool {
	for member in selected {
		if member.pid == pid {
			return true
		}
	}
	return false
}

ui_display_contains :: proc(pids: []i32, pid: i32) -> bool {
	for candidate in pids {
		if candidate == pid {
			return true
		}
	}
	return false
}

// ui_process_eligible is whether a process earns a row on its own, by the
// instant CPU or the footprint floor.
ui_process_eligible :: proc(sample: Process_Sample, config: Config) -> bool {
	cpu_active := sample.cpu_fraction * 100 >= UI_PROCESS_MIN_PERCENT
	memory_active := sample.memory_bytes >= u64(UI_PROCESS_MEMORY_MIN_MB) * (1 << 20)
	return cpu_active || memory_active
}

// ui_build_rows renders the panel contents: a header, then each top group with
// its busiest processes underneath. Groups are shown while they are above the
// CPU floor or the memory floor, so a memory-heavy but idle process is visible;
// a group row carries the enabled stat columns, including the windowed average
// CPU, the signed window memory change, and the CPU series for the sparkline.
// Members below both process floors are not counted as hidden; only rows cut by
// the per-group limit are noted. Rows are sticky through options.display: a
// process that has had a row keeps it, and a group keeps the row count it has
// grown to, so the list does not shift as processes cross the floors. Every
// string and series is allocated with the caller's allocator so snapshots can be
// freed wholesale.
ui_build_rows :: proc(
	groups: []Group_Sample,
	samples: []Process_Sample,
	trends: []Group_Trend,
	options: Ui_Build_Options,
	allocator := context.temp_allocator,
) -> []Ui_Row {
	rows := make([dynamic]Ui_Row, 0, 32, allocator)
	stats := config_stat_selection(options.config)
	ui_display_prune(options.display, options.now, time.Duration(options.config.window_seconds*f64(time.Second)))
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

	// Groups are ranked by cumulative urgency, not the instant CPU order the
	// worker passes in, so the index numbers and highlights reflect the window.
	ranked := make([dynamic]Ranked_Group, 0, len(groups), context.temp_allocator)
	defer delete(ranked)
	for group in groups {
		cpu_avg := group.cpu_percent
		if trend_index, found := trend_by_name[group.name]; found {
			cpu_avg = trends[trend_index].cpu_avg
		}
		append(&ranked, Ranked_Group{
			group   = group,
			cpu_avg = cpu_avg,
			urgency = ui_group_urgency(cpu_avg, group.memory_bytes, options.config),
		})
	}
	slice.sort_by(ranked[:], proc(a, b: Ranked_Group) -> bool {
		if a.urgency != b.urgency {
			return a.urgency > b.urgency
		}
		return a.group.name < b.group.name
	})

	name_chars := panel_name_chars(stats)
	group_count := 0
	for entry in ranked {
		group := entry.group
		// The CPU floor is judged on the windowed average, not the instant
		// sample: a group hovering at the floor would otherwise flicker in and
		// out of the list (and resize the panel) every tick.
		cpu_active := entry.cpu_avg >= UI_GROUP_MIN_PERCENT
		memory_active := group.memory_bytes >= u64(UI_GROUP_MEMORY_MIN_MB) * (1 << 20)
		if !cpu_active && !memory_active {
			continue
		}
		if group_count >= UI_GROUP_LIMIT {
			break
		}
		group_count += 1

		group_suffix := fmt.tprintf(" ×%d", group.count)
		row := Ui_Row{
			kind = .Group,
			key  = strings.clone(group.name, allocator),
			rank = group_count,
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
		if stats.cpu {
			row.cpu = percent_text(group.cpu_percent, allocator)
		}
		if stats.gpu {
			// The group's GPU load is its members' current GPU time; the history
			// tracks CPU and memory only.
			group_gpu: f64
			for pid in group.pids {
				if sample, found := by_pid[pid]; found {
					group_gpu += sample.gpu_fraction
				}
			}
			row.gpu = percent_text(group_gpu * 100, allocator)
		}
		if stats.memory {
			row.memory = format_bytes(group.memory_bytes, allocator)
		}
		if trend_index, found := trend_by_name[group.name]; found {
			trend := trends[trend_index]
			if stats.window_cpu {
				row.window_cpu = percent_text(trend.cpu_avg, allocator)
				row.cpu_peak = trend.cpu_peak
				row.memory_peak = trend.memory_peak
				if len(trend.samples) >= 2 {
					row.spark = make([]f32, len(trend.samples), allocator)
					row.spark_memory = make([]f32, len(trend.samples), allocator)
					for sample, index in trend.samples {
						row.spark[index] = f32(sample.cpu_percent)
						row.spark_memory[index] = f32(sample.memory_bytes)
					}
				}
			}
			if stats.window_memory {
				row.window_memory = format_bytes_delta(trend.memory_growth, allocator)
			}
		}
		append(&rows, row)

		// Processes are ranked by their current urgency inside the group; the
		// group's history is the only cumulative record kept.
		ranked_members := make([dynamic]Ranked_Process, 0, len(group.pids), context.temp_allocator)
		defer delete(ranked_members)
		for pid in group.pids {
			if sample, found := by_pid[pid]; found {
				append(&ranked_members, Ranked_Process{
					sample  = sample,
					urgency = ui_process_urgency(sample, options.config),
				})
			}
		}
		slice.sort_by(ranked_members[:], proc(a, b: Ranked_Process) -> bool {
			if a.urgency != b.urgency {
				return a.urgency > b.urgency
			}
			return a.sample.pid < b.sample.pid
		})

		eligible := make([dynamic]Process_Sample, 0, len(ranked_members), context.temp_allocator)
		defer delete(eligible)
		for member in ranked_members {
			if ui_process_eligible(member.sample, options.config) {
				append(&eligible, member.sample)
			}
		}

		// Sticky rows: a process that has had a row keeps it while it lives, and
		// the group keeps the number of rows it has grown to, so processes
		// crossing the floors add rows but do not take them away.
		display := ui_display_group(options.display, group.name)
		display.seen = options.now
		selected := make([dynamic]Process_Sample, 0, len(ranked_members), context.temp_allocator)
		defer delete(selected)
		for member in ranked_members {
			if len(selected) >= UI_PROCESS_LIMIT_PER_GROUP {
				break
			}
			if ui_process_eligible(member.sample, options.config) || ui_display_contains(display.pids[:], member.sample.pid) {
				append(&selected, member.sample)
			}
		}
		// A row freed by an exit is filled from the ranked members, so the
		// group's row count stays where it was.
		target := min(UI_PROCESS_LIMIT_PER_GROUP, max(display.rows, len(selected)))
		target = min(target, len(ranked_members))
		for member in ranked_members {
			if len(selected) >= target {
				break
			}
			if !ui_selected_contains(selected[:], member.sample.pid) {
				append(&selected, member.sample)
			}
		}
		ui_display_remember(display, selected[:])

		for member, index in selected {
			process_suffix := fmt.tprintf(" · %d", member.pid)
			process_row := Ui_Row{
				kind = .Process,
				key  = strings.clone(group.name, allocator),
				pid  = member.pid,
				rank = index + 1,
				name = fmt.aprintf(
					"%s%s",
					ui_elide(
						ui_process_label(member),
						max(8, name_chars-PANEL_PROCESS_RANK_CHARS-utf8.rune_count(process_suffix)),
						context.temp_allocator,
					),
					process_suffix,
					allocator = allocator,
				),
			}
			if stats.cpu {
				process_row.cpu = percent_text(member.cpu_fraction * 100, allocator)
			}
			if stats.gpu {
				process_row.gpu = percent_text(member.gpu_fraction * 100, allocator)
			}
			if stats.memory {
				process_row.memory = format_bytes(member.memory_bytes, allocator)
			}
			append(&rows, process_row)
		}
		eligible_shown := 0
		for member in selected {
			if ui_process_eligible(member, options.config) {
				eligible_shown += 1
			}
		}
		hidden := len(eligible) - eligible_shown
		if hidden > 0 {
			display.note = true
		}
		if display.note {
			// Sticky too: the note keeps its row even when nothing is hidden,
			// so its appearance does not shift the list.
			name := ""
			if hidden > 0 {
				name = fmt.aprintf("    … and %d more", hidden, allocator = allocator)
			}
			append(&rows, Ui_Row{
				kind = .Note,
				key  = strings.clone(group.name, allocator),
				name = name,
			})
		}
	}

	if group_count == 0 {
		append(&rows, Ui_Row{kind = .Note, name = fmt.aprintf("All quiet", allocator = allocator)})
	}
	return rows[:]
}

// -------------------------------------------------------------- row order

// Panel_Group_Order is one group's place in the panel: the group name and the
// pid order of its process rows. The strings and pid lists are owned.
Panel_Group_Order :: struct {
	name:    string,
	pids:    [dynamic]i32,
	present: bool,      // true while the group is in the snapshot
	absent:  time.Tick, // when the group last went missing
}

// Panel_Order is the panel's stable row order. It survives snapshots, so rows
// only move when the operator presses Sort; between sorts only the rank numbers
// and values change.
Panel_Order :: struct {
	groups: [dynamic]Panel_Group_Order,
}

panel_order: Panel_Order

ui_order_destroy :: proc(order: ^Panel_Order) {
	assert(order != nil, "order required")
	for &entry in order.groups {
		delete(entry.name, context.allocator)
		delete(entry.pids)
	}
	delete(order.groups)
	order.groups = nil
}

ui_order_find :: proc(order: ^Panel_Order, name: string) -> int {
	for &entry, index in order.groups {
		if entry.name == name {
			return index
		}
	}
	return -1
}

// ui_order_adopt makes the order match the ranks carried by the rows: the Sort
// button's action. Groups are ordered by their rank and each group's processes
// by theirs, so the rows physically move to where the index numbers say they
// belong.
ui_order_adopt :: proc(order: ^Panel_Order, rows: []Ui_Row) {
	assert(order != nil, "order required")
	ui_order_destroy(order)

	Ranked_Key :: struct {
		key:  string,
		rank: int,
	}
	keys := make([dynamic]Ranked_Key, 0, 8, context.temp_allocator)
	defer delete(keys)
	for row in rows {
		if row.kind != .Group {
			continue
		}
		known := false
		for entry in keys {
			if entry.key == row.key {
				known = true
				break
			}
		}
		if !known {
			append(&keys, Ranked_Key{key = row.key, rank = row.rank})
		}
	}
	slice.sort_by(keys[:], proc(a, b: Ranked_Key) -> bool {
		return a.rank < b.rank
	})

	for entry in keys {
		group := Panel_Group_Order{name = strings.clone(entry.key), present = true}

		Ranked_Pid :: struct {
			pid:  i32,
			rank: int,
		}
		pids := make([dynamic]Ranked_Pid, 0, 4, context.temp_allocator)
		defer delete(pids)
		for row in rows {
			if row.kind == .Process && row.key == entry.key {
				append(&pids, Ranked_Pid{pid = row.pid, rank = row.rank})
			}
		}
		slice.sort_by(pids[:], proc(a, b: Ranked_Pid) -> bool {
			return a.rank < b.rank
		})
		for ranked in pids {
			append(&group.pids, ranked.pid)
		}
		append(&order.groups, group)
	}
}

// ui_order_append_block appends one group's rows: the group row, its process
// rows in the stored pid order (new pids appended in row order), then the note.
ui_order_append_block :: proc(ordered: ^[dynamic]Ui_Row, rows: []Ui_Row, entry: ^Panel_Group_Order) {
	for row in rows {
		if row.kind == .Group && row.key == entry.name {
			append(ordered, row)
			break
		}
	}
	for pid in entry.pids {
		for row in rows {
			if row.kind == .Process && row.key == entry.name && row.pid == pid {
				append(ordered, row)
				break
			}
		}
	}
	for row in rows {
		if row.kind != .Process || row.key != entry.name {
			continue
		}
		known := false
		for pid in entry.pids {
			if pid == row.pid {
				known = true
				break
			}
		}
		if !known {
			append(&entry.pids, row.pid)
			append(ordered, row)
		}
	}
	for row in rows {
		if row.kind == .Note && row.key == entry.name {
			append(ordered, row)
		}
	}
}

// ui_order_rows returns the rows in the panel's stable order: the header first,
// then each group block in stored order, with groups that appear for the first
// time appended at the end. A group missing from the snapshot keeps its place
// until it has been absent longer than the grace period, so a momentary gap
// does not reshuffle the list.
ui_order_rows :: proc(
	order: ^Panel_Order,
	rows: []Ui_Row,
	now: time.Tick,
	grace: time.Duration,
	allocator := context.temp_allocator,
) -> []Ui_Row {
	assert(order != nil, "order required")
	ordered := make([dynamic]Ui_Row, 0, len(rows), allocator)

	for row in rows {
		if row.kind == .Header {
			append(&ordered, row)
		}
	}

	for &entry in order.groups {
		present := false
		for row in rows {
			if row.kind == .Group && row.key == entry.name {
				present = true
				break
			}
		}
		if !present {
			if entry.present {
				entry.present = false
				entry.absent = now
			}
			continue
		}
		entry.present = true
		ui_order_append_block(&ordered, rows, &entry)
	}

	for row in rows {
		if row.kind != .Group || ui_order_find(order, row.key) != -1 {
			continue
		}
		entry := Panel_Group_Order{name = strings.clone(row.key), present = true}
		append(&order.groups, entry)
		ui_order_append_block(&ordered, rows, &order.groups[len(order.groups)-1])
	}

	// Standalone notes ("All quiet") belong to no group and keep their place at
	// the end of the list.
	for row in rows {
		if row.kind == .Note && row.key == "" {
			append(&ordered, row)
		}
	}

	stale := make([dynamic]int, 0, len(order.groups), context.temp_allocator)
	for &entry, index in order.groups {
		if entry.present {
			continue
		}
		if time.tick_diff(entry.absent, now) > grace {
			append(&stale, index)
		}
	}
	for index := len(stale) - 1; index >= 0; index -= 1 {
		entry := &order.groups[stale[index]]
		delete(entry.name, context.allocator)
		delete(entry.pids)
		ordered_remove(&order.groups, stale[index])
	}
	delete(stale)
	return ordered[:]
}

// ui_snapshot_reorder rewrites the snapshot's rows into the panel's stable
// order. Main thread only.
ui_snapshot_reorder :: proc(snapshot: ^Ui_Snapshot) {
	grace := time.Duration(snapshot.config.window_seconds * f64(time.Second))
	rows := ui_order_rows(
		&panel_order,
		snapshot.rows,
		time.tick_now(),
		grace,
		snapshot.allocator,
	)
	delete(snapshot.rows, snapshot.allocator)
	snapshot.rows = rows
}

// ui_sort_now makes the panel's order match the ranks: the Sort button's
// action. The current snapshot is re-ordered immediately; later snapshots
// arrive already ranked and are re-ordered into the same stable order.
ui_sort_now :: proc() {
	snapshot := ui_state.snapshot
	if snapshot == nil {
		return
	}
	ui_order_adopt(&panel_order, snapshot.rows)
	ui_snapshot_reorder(snapshot)
}

DIAGNOSTICS_PROCESSES_PER_GROUP :: 10
DIAGNOSTICS_LOG_LINES :: 2000
DIAGNOSTICS_OTHER_EVENTS :: 10

// ui_groups_text lists every group above the panel floors with its heaviest
// processes, for the Copy button. Sampler thread only; the text belongs to the
// snapshot.
ui_groups_text :: proc(
	groups: []Group_Sample,
	samples: []Process_Sample,
	trends: []Group_Trend,
	config: Config,
	allocator: runtime.Allocator,
) -> string {
	by_pid := make(map[i32]Process_Sample, len(samples), context.temp_allocator)
	for sample in samples {
		by_pid[sample.pid] = sample
	}
	trend_by_name := make(map[string]Group_Trend, len(trends), context.temp_allocator)
	for trend in trends {
		trend_by_name[trend.name] = trend
	}
	ranked := make([dynamic]Ranked_Group, 0, len(groups), context.temp_allocator)
	for group in groups {
		cpu_avg := group.cpu_percent
		if trend, found := trend_by_name[group.name]; found {
			cpu_avg = trend.cpu_avg
		}
		append(&ranked, Ranked_Group{
			group   = group,
			cpu_avg = cpu_avg,
			urgency = ui_group_urgency(cpu_avg, group.memory_bytes, config),
		})
	}
	slice.sort_by(ranked[:], proc(a, b: Ranked_Group) -> bool {
		if a.urgency != b.urgency {
			return a.urgency > b.urgency
		}
		return a.group.name < b.group.name
	})

	builder := strings.builder_make(context.temp_allocator)
	shown := 0
	for entry in ranked {
		group := entry.group
		cpu_active := entry.cpu_avg >= UI_GROUP_MIN_PERCENT
		memory_active := group.memory_bytes >= u64(UI_GROUP_MEMORY_MIN_MB) * (1 << 20)
		if !cpu_active && !memory_active {
			continue
		}
		if shown >= UI_GROUP_LIMIT {
			break
		}
		shown += 1
		fmt.sbprintf(
			&builder,
			"%d. %s x%d: cpu %s, gpu %s, memory %s",
			shown,
			group.name,
			group.count,
			percent_text(group.cpu_percent, context.temp_allocator),
			percent_text(ui_group_gpu(group, by_pid) * 100, context.temp_allocator),
			format_bytes(group.memory_bytes),
		)
		if trend, found := trend_by_name[group.name]; found {
			fmt.sbprintf(
				&builder,
				"; window: cpu avg %s, cpu peak %s, memory peak %s, memory change %s",
				percent_text(trend.cpu_avg, context.temp_allocator),
				percent_text(trend.cpu_peak, context.temp_allocator),
				format_bytes(trend.memory_peak),
				format_bytes_delta(trend.memory_growth),
			)
		}
		strings.write_byte(&builder, '\n')

		members := make([dynamic]Process_Sample, 0, len(group.pids), context.temp_allocator)
		for pid in group.pids {
			if sample, found := by_pid[pid]; found {
				append(&members, sample)
			}
		}
		slice.sort_by(members[:], proc(a, b: Process_Sample) -> bool {
			if a.memory_bytes != b.memory_bytes {
				return a.memory_bytes > b.memory_bytes
			}
			return a.pid < b.pid
		})
		for member in members[:min(len(members), DIAGNOSTICS_PROCESSES_PER_GROUP)] {
			fmt.sbprintf(
				&builder,
				"    pid %d%s: cpu %s, gpu %s, memory %s\n",
				member.pid,
				member.detail == "" ? "" : fmt.tprintf(" (%s)", member.detail),
				percent_text(member.cpu_fraction * 100, context.temp_allocator),
				percent_text(member.gpu_fraction * 100, context.temp_allocator),
				format_bytes(member.memory_bytes),
			)
		}
		if len(members) > DIAGNOSTICS_PROCESSES_PER_GROUP {
			fmt.sbprintf(&builder, "    ... and %d more, by memory\n", len(members) - DIAGNOSTICS_PROCESSES_PER_GROUP)
		}
	}
	return strings.clone(strings.to_string(builder), allocator)
}

ui_group_gpu :: proc(group: Group_Sample, by_pid: map[i32]Process_Sample) -> f64 {
	total: f64
	for pid in group.pids {
		if sample, found := by_pid[pid]; found {
			total += sample.gpu_fraction
		}
	}
	return total
}

Event_Summary :: struct {
	count:        int,
	first, last:  string,
	processes:    int,
	cpu_percent:  f64,
	memory_bytes: f64,
}

// ui_events_text condenses the event log: repeated alerts collapse to one line
// per kind and name with a count and time span, and the other events are
// listed by their last few occurrences.
ui_events_text :: proc(path: string, builder: ^strings.Builder) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	lines := strings.split_lines(strings.trim_space(string(data)), context.temp_allocator)
	lines = lines[max(0, len(lines) - DIAGNOSTICS_LOG_LINES):]

	summaries := make(map[string]Event_Summary, 8, context.temp_allocator)
	order := make([dynamic]string, context.temp_allocator)
	others := make([dynamic]string, context.temp_allocator)
	for line in lines {
		value, parse_err := json.parse(transmute([]byte)line, allocator = context.temp_allocator)
		object, is_object := value.(json.Object)
		if parse_err != nil || !is_object {
			continue
		}
		event, _ := object["event"].(json.String)
		time_text, _ := object["time"].(json.String)
		if event != "alert" {
			append(&others, line)
			continue
		}
		kind, _ := object["kind"].(json.String)
		name, _ := object["name"].(json.String)
		key := fmt.tprintf("%s %s", kind, name)
		summary, seen := summaries[key]
		if !seen {
			append(&order, key)
			summary.first = time_text
		}
		summary.count += 1
		summary.last = time_text
		processes, _ := object["processes"].(json.Float)
		cpu, _ := object["cpu_percent"].(json.Float)
		memory, _ := object["memory_bytes"].(json.Float)
		summary.processes = int(processes)
		summary.cpu_percent = cpu
		summary.memory_bytes = memory
		summaries[key] = summary
	}

	strings.write_string(builder, "\nalerts, repeats collapsed:\n")
	if len(order) == 0 {
		strings.write_string(builder, "none\n")
	}
	for key in order {
		summary := summaries[key]
		fmt.sbprintf(
			builder,
			"%s: %d alerts, %s to %s; latest %d processes, cpu %s, memory %s\n",
			key,
			summary.count,
			summary.first,
			summary.last,
			summary.processes,
			percent_text(summary.cpu_percent, context.temp_allocator),
			format_bytes(u64(summary.memory_bytes)),
		)
	}
	strings.write_string(builder, "\nother recent events (JSONL):\n")
	for line in others[max(0, len(others) - DIAGNOSTICS_OTHER_EVENTS):] {
		strings.write_string(builder, line)
		strings.write_byte(builder, '\n')
	}
}

// ui_diagnostics_text renders the current snapshot, the running settings and
// the event log as plain text for pasting into an LLM.
ui_diagnostics_text :: proc(snapshot: ^Ui_Snapshot, allocator := context.temp_allocator) -> string {
	config := snapshot.config
	builder := strings.builder_make(allocator)
	fmt.sbprintf(&builder, "hw_activity_monitor %s diagnostics\n", VERSION)
	fmt.sbprintf(
		&builder,
		"%s of all cores (%d cores), %d processes\n",
		percent_text(snapshot.total_percent),
		os.get_processor_core_count(),
		snapshot.process_count,
	)
	fmt.sbprintf(
		&builder,
		"settings: interval %.0fs, window %.0fs, cpu budget %.0f%% of one core, memory budget %.0f MB per group, sustained %.0fs, cooldown %.0fs\n",
		config.interval_seconds,
		config.window_seconds,
		config.cpu_percent,
		config.memory_mb,
		config.sustained_seconds,
		config.cooldown_seconds,
	)
	strings.write_string(&builder, "\ngroups by urgency (same-named processes), heaviest processes by memory:\n")
	strings.write_string(&builder, snapshot.groups_text)
	if monitor.log.path != "" {
		ui_events_text(monitor.log.path, &builder)
	}
	return strings.to_string(builder)
}

// ui_copy_diagnostics puts the diagnostics on the general pasteboard. Main thread only.
ui_copy_diagnostics :: proc() {
	snapshot := ui_state.snapshot
	if snapshot == nil {
		return
	}
	text := ui_diagnostics_text(snapshot)
	pasteboard := msg_id0(objc_getClass("NSPasteboard"), sel_registerName("generalPasteboard"))
	if pasteboard == nil {
		return
	}
	msg_void0(pasteboard, sel_registerName("clearContents"))
	msg_id_id2(pasteboard, sel_registerName("setString:forType:"), nsstring(text), nsstring("public.utf8-plain-text"))
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
	ui_set_status_title("—")

	if !panel_window_init() {
		return false
	}
	msg_void_id(button, sel_registerName("setTarget:"), panel_window.controller)
	msg_void_sel(button, sel_registerName("setAction:"), sel_registerName("togglePanel:"))
	msg_void_u(
		button,
		sel_registerName("sendActionOn:"),
		NSEVENT_MASK_LEFT_MOUSE_UP | NSEVENT_MASK_RIGHT_MOUSE_UP,
	)
	return true
}

ui_run :: proc() {
	if ui_state.app != nil {
		msg_void0(ui_state.app, sel_registerName("run"))
	}
}

// ui_status_font returns the font the status title is drawn with: Iosevka, the
// panel's monospace face, then the system monospaced font, then the menu bar
// font.
ui_status_font :: proc() -> Id {
	font := msg_id_id_f64(
		objc_getClass("NSFont"),
		sel_registerName("fontWithName:size:"),
		nsstring(STATUS_FONT_NAME),
		STATUS_FONT_SIZE,
	)
	if font == nil {
		font = msg_id_f64_f64(
			objc_getClass("NSFont"),
			sel_registerName("monospacedSystemFontOfSize:weight:"),
			0,
			0,
		)
	}
	if font == nil {
		font = msg_id_f64(objc_getClass("NSFont"), sel_registerName("menuBarFontOfSize:"), 0)
	}
	return font
}

// ui_set_status_title draws the title in the status font and pins the status
// item's length to the measured width. A plain title is measured with the menu
// bar font, which is proportional, so the item would resize as the digits
// change; the attributed title and the explicit length keep it still, and it
// grows only when the text gains a character (at 100%).
ui_set_status_title :: proc(text: string) {
	item := ui_state.status_item
	button := ui_state.button
	if item == nil || button == nil {
		return
	}
	font := ui_status_font()
	attribute_name := nsfont_attribute_name()
	attributes: Id
	if font != nil && attribute_name != nil {
		attributes = msg_id_id2(
			objc_getClass("NSDictionary"),
			sel_registerName("dictionaryWithObject:forKey:"),
			font,
			attribute_name,
		)
	}
	attributed: Id
	if attributes != nil {
		allocated := msg_id0(objc_getClass("NSAttributedString"), sel_registerName("alloc"))
		attributed = msg_id_id2(
			allocated,
			sel_registerName("initWithString:attributes:"),
			nsstring(text),
			attributes,
		)
	}
	if attributed != nil {
		msg_void_id(button, sel_registerName("setAttributedTitle:"), attributed)
		size := msg_size_0(attributed, sel_registerName("size"))
		msg_void_f64(item, sel_registerName("setLength:"), f64(size.width) + STATUS_TITLE_PADDING)
		return
	}
	// Fallbacks: a plain title with the variable length.
	msg_void_id(button, sel_registerName("setTitle:"), nsstring(text))
	msg_void_f64(item, sel_registerName("setLength:"), NSVARIABLE_STATUS_ITEM_LENGTH)
}

// ui_active_cpu_count reports the number of active cores, or 1 before AppKit is
// available.
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
		config        = options.config,
		rows          = rows,
		groups_text   = ui_groups_text(groups, samples, trends, options.config, context.allocator),
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
	// The number is padded to two characters so the title is three characters
	// wide (" 5%", "12%") and only reaches four at 100%; with the monospaced
	// status font and the pinned item length the width stays put.
	ui_set_status_title(fmt.tprintf("%2.0f%%", snapshot.total_percent))
	ui_snapshot_reorder(snapshot)
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
	// The title string and any other per-snapshot temporaries are done.
	free_all(context.temp_allocator)
}

ui_snapshot_destroy :: proc(snapshot: ^Ui_Snapshot) {
	for row in snapshot.rows {
		if row.key != "" {
			delete(row.key, snapshot.allocator)
		}
		if row.name != "" {
			delete(row.name, snapshot.allocator)
		}
		if row.cpu != "" {
			delete(row.cpu, snapshot.allocator)
		}
		if row.gpu != "" {
			delete(row.gpu, snapshot.allocator)
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
		if len(row.spark_memory) > 0 {
			delete(row.spark_memory, snapshot.allocator)
		}
	}
	delete(snapshot.rows, snapshot.allocator)
	delete(snapshot.groups_text, snapshot.allocator)
	free(snapshot, snapshot.allocator)
}

ui_process_label :: proc(sample: Process_Sample) -> string {
	return sample.detail if sample.detail != "" else sample.name
}
