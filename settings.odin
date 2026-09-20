// The in-panel settings modal: window and interval fields, the stat column
// picker, validation, persistence, and the live config request. panel.odin
// renders this state with hw_clay and routes clicks and keys here.

package activity_monitor

import "core:fmt"
import "core:strings"
import NS "core:sys/darwin/Foundation"
import text_input "hw_odin_ui_components:text_input"
import hw_clay "hw_clay:."

Settings_Field :: enum {
	Window,
	Interval,
}

SETTINGS_FIELDS := [?]Settings_Field{.Window, .Interval}

// Key codes from Carbon's Events.h, matching the panel's Escape handling.
SETTINGS_KEY_RETURN :: u16(36)
SETTINGS_KEY_TAB :: u16(48)
SETTINGS_KEY_BACKSPACE :: u16(51)
SETTINGS_KEY_ESCAPE :: u16(53)
SETTINGS_KEY_HOME :: u16(115)
SETTINGS_KEY_FORWARD_DELETE :: u16(117)
SETTINGS_KEY_END :: u16(119)
SETTINGS_KEY_LEFT :: u16(123)
SETTINGS_KEY_RIGHT :: u16(124)
SETTINGS_KEY_DOWN :: u16(125)
SETTINGS_KEY_UP :: u16(126)
SETTINGS_KEY_A :: u16(0)

Settings :: struct {
	open:             bool,
	draft:            Config, // edited copy; written on save
	original:         Config, // restored on cancel
	texts:            [Settings_Field]string, // owned field text
	editing:          text_input.State,
	message:          string, // owned status line
	message_is_error: bool,
}

settings: Settings

settings_field_id :: proc(field: Settings_Field) -> text_input.Field_ID {
	return text_input.Field_ID(u64(field) + 1)
}

settings_field_for_id :: proc(id: text_input.Field_ID) -> (Settings_Field, bool) {
	for field in SETTINGS_FIELDS {
		if settings_field_id(field) == id {
			return field, true
		}
	}
	return .Window, false
}

// settings_open starts editing from the config carried by the latest snapshot,
// so the modal always shows what the daemon is actually running.
settings_open :: proc() {
	if ui_state.snapshot == nil {
		return
	}
	settings.draft = ui_state.snapshot.config
	settings.original = ui_state.snapshot.config
	for field in SETTINGS_FIELDS {
		delete(settings.texts[field])
	}
	settings.texts[.Window] = fmt.aprintf("%.0f", settings.draft.window_seconds / 60)
	settings.texts[.Interval] = fmt.aprintf("%.0f", settings.draft.interval_seconds)
	settings.editing = {}
	settings.message = ""
	settings.message_is_error = false
	settings.open = true
	panel_settings_resized()
}

settings_close :: proc() {
	settings.open = false
	text_input.blur(&settings.editing)
	panel_content_changed()
}

// settings_save parses the fields, writes the config file, and asks the worker
// to pick the new config up on its next tick; the accumulated history is not
// touched.
settings_save :: proc() {
	config := settings.draft
	if !config_apply_fields(&config, settings.texts[.Window], settings.texts[.Interval]) {
		settings.message = "Window and interval must be numbers."
		settings.message_is_error = true
		panel_mark_dirty()
		return
	}
	path := config_path()
	if path == "" || !config_save(config, path) {
		settings.message = "Could not write the config file."
		settings.message_is_error = true
		panel_mark_dirty()
		return
	}
	monitor_request_config(config)
	settings_close()
}

settings_active_text :: proc() -> ^string {
	field, found := settings_field_for_id(settings.editing.active_field)
	if !found {
		return nil
	}
	return &settings.texts[field]
}

settings_focus_field :: proc(field: Settings_Field) {
	text := settings.texts[field]
	_ = text_input.focus(&settings.editing, settings_field_id(field), text)
	text_input.move_line_end(&settings.editing, text, false)
	panel_mark_dirty()
}

settings_cycle_field :: proc() {
	field, found := settings_field_for_id(settings.editing.active_field)
	if !found {
		settings_focus_field(.Window)
		return
	}
	next := field == .Window ? Settings_Field.Interval : Settings_Field.Window
	settings_focus_field(next)
}

settings_edit_insert :: proc(text: string) {
	target := settings_active_text()
	if target == nil {
		return
	}
	if text_input.replace_selection(&settings.editing, target, text) {
		panel_mark_dirty()
	}
}

settings_edit_delete :: proc(backward: bool) {
	target := settings_active_text()
	if target == nil {
		return
	}
	deleted := backward ? text_input.delete_backward(&settings.editing, target) : text_input.delete_forward(&settings.editing, target)
	if deleted {
		panel_mark_dirty()
	}
}

// settings_key handles one key event while the modal is open. It returns true
// when the modal consumed the key.
settings_key :: proc(event: ^NS.Event) -> bool {
	if !settings.open {
		return false
	}
	modifiers := event->modifierFlags()
	key := event->keyCode()
	switch key {
	case SETTINGS_KEY_ESCAPE:
		settings_close()
		return true
	case SETTINGS_KEY_RETURN:
		settings_save()
		return true
	case SETTINGS_KEY_TAB:
		settings_cycle_field()
		return true
	case SETTINGS_KEY_BACKSPACE:
		settings_edit_delete(true)
		return true
	case SETTINGS_KEY_FORWARD_DELETE:
		settings_edit_delete(false)
		return true
	case SETTINGS_KEY_LEFT:
		if target := settings_active_text(); target != nil {
			text_input.move_left(&settings.editing, target^, .Shift in modifiers)
			panel_mark_dirty()
		}
		return true
	case SETTINGS_KEY_RIGHT:
		if target := settings_active_text(); target != nil {
			text_input.move_right(&settings.editing, target^, .Shift in modifiers)
			panel_mark_dirty()
		}
		return true
	case SETTINGS_KEY_HOME:
		if target := settings_active_text(); target != nil {
			text_input.move_line_start(&settings.editing, target^, .Shift in modifiers)
			panel_mark_dirty()
		}
		return true
	case SETTINGS_KEY_END:
		if target := settings_active_text(); target != nil {
			text_input.move_line_end(&settings.editing, target^, .Shift in modifiers)
			panel_mark_dirty()
		}
		return true
	case SETTINGS_KEY_UP, SETTINGS_KEY_DOWN:
		return true // single line fields
	case SETTINGS_KEY_A:
		if .Command in modifiers {
			if target := settings_active_text(); target != nil {
				text_input.set_selection(&settings.editing, target^, 0, len(target^))
				panel_mark_dirty()
			}
			return true
		}
	}

	characters := nsstring_to_string(event->characters())
	if characters != "" && characters[0] >= 0x20 {
		settings_edit_insert(characters)
	}
	return true
}

// settings_click handles a click on one of the modal's element ids; it returns
// true when the id belonged to the modal.
settings_click :: proc(id: hw_clay.Element_Id) -> bool {
	if !settings.open {
		return false
	}
	switch {
	case id == hw_clay.id("settings-window"):
		settings_focus_field(.Window)
		return true
	case id == hw_clay.id("settings-interval"):
		settings_focus_field(.Interval)
		return true
	case id == hw_clay.id("check-cpu"):
		settings.draft.show_cpu = !settings.draft.show_cpu
		panel_mark_dirty()
		return true
	case id == hw_clay.id("check-memory"):
		settings.draft.show_memory = !settings.draft.show_memory
		panel_mark_dirty()
		return true
	case id == hw_clay.id("check-window-cpu"):
		settings.draft.show_window_cpu = !settings.draft.show_window_cpu
		panel_mark_dirty()
		return true
	case id == hw_clay.id("check-window-memory"):
		settings.draft.show_window_memory = !settings.draft.show_window_memory
		panel_mark_dirty()
		return true
	case id == hw_clay.id("settings-save"):
		settings_save()
		return true
	case id == hw_clay.id("settings-cancel"):
		settings_close()
		return true
	}
	return false
}
