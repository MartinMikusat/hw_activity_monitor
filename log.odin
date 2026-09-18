// Append-only log at ~/Library/Logs/hw_activity_monitor.log. A log that cannot be
// opened disables logging but never stops the watchdog.

package activity_monitor

import "core:fmt"
import "core:os"
import "core:path/filepath"
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
	path, join_err := filepath.join({home, "Library/Logs/hw_activity_monitor.log"})
	if join_err != nil {
		return {}
	}
	file, open_err := os.open(path, {.Append, .Create, .Write})
	if open_err != nil {
		return Log{path = path}
	}
	return Log{file = file, path = path}
}

log_write :: proc(log: Log, message: string) {
	if log.file == nil {
		return
	}
	timestamp := time.now()
	date_buffer: [32]byte
	clock_buffer: [32]byte
	line := fmt.tprintf(
		"[%s %s] %s\n",
		time.to_string_yyyy_mm_dd(timestamp, date_buffer[:]),
		time.to_string_hms(timestamp, clock_buffer[:]),
		message,
	)
	os.write_string(log.file, line)
}

log_close :: proc(log: Log) {
	if log.file != nil {
		os.close(log.file)
	}
}
