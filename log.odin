// Append-only JSONL event log at ~/Library/Logs/hw_activity_monitor.jsonl.
//
// One JSON object per line, appended and never rewritten, so agents can read
// it with jq or a line parser and reconstruct what the daemon saw. Events are
// rare (one per alert episode), so the file is not rotated. The schema is
// documented in AGENTS.md; launchd's stdout/stderr file keeps crash output.

package activity_monitor

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Log :: struct {
	file: ^os.File,
	path: string,
}

log_open :: proc() -> Log {
	home, home_err := os.user_home_dir(context.allocator)
	if home_err != nil {
		return {}
	}
	path, join_err := filepath.join({home, "Library/Logs/hw_activity_monitor.jsonl"})
	if join_err != nil {
		return {}
	}
	file, open_err := os.open(path, {.Append, .Create, .Write})
	if open_err != nil {
		return Log{path = path}
	}
	return Log{file = file, path = path}
}

log_close :: proc(log: Log) {
	if log.file != nil {
		os.close(log.file)
	}
}

// log_event appends one line: {"time":"...","event":"...",<fields>}. Fields are
// pre-formatted `"key":value` pairs; wrap string values in log_string. The line
// is assembled field by field because fmt's format syntax reserves `{`.
log_event :: proc(log: Log, event: string, fields: string) {
	if log.file == nil {
		return
	}
	builder := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder, "{\"time\":\"")
	strings.write_string(&builder, timestamp_iso8601(time.now()))
	strings.write_string(&builder, "\",\"event\":")
	strings.write_string(&builder, log_string(event))
	strings.write_byte(&builder, ',')
	strings.write_string(&builder, fields)
	strings.write_string(&builder, "}\n")
	os.write_string(log.file, strings.to_string(builder))
}

// log_string renders a JSON string literal with the escaping JSON requires.
log_string :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	strings.write_byte(&builder, '"')
	for character in value {
		switch character {
		case '"':
			strings.write_string(&builder, "\\\"")
		case '\\':
			strings.write_string(&builder, "\\\\")
		case '\n':
			strings.write_string(&builder, "\\n")
		case '\r':
			strings.write_string(&builder, "\\r")
		case '\t':
			strings.write_string(&builder, "\\t")
		case:
			if character < 0x20 {
				strings.write_string(&builder, "\\u00")
				fmt.sbprintf(&builder, "%02x", u8(character))
			} else {
				strings.write_rune(&builder, character)
			}
		}
	}
	strings.write_byte(&builder, '"')
	return strings.to_string(builder)
}

timestamp_iso8601 :: proc(moment: time.Time) -> string {
	datetime, ok := time.time_to_datetime(moment)
	if !ok {
		return "1970-01-01T00:00:00Z"
	}
	return fmt.tprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		datetime.year,
		int(datetime.month),
		datetime.day,
		datetime.hour,
		datetime.minute,
		datetime.second,
	)
}
