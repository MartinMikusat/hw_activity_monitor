// Notification delivery through osascript. A bare (unbundled) binary cannot
// use UNUserNotificationCenter, and osascript delivers on Script Editor's
// behalf; see AGENTS.md for the bundle upgrade path.

package cpu_watchdog

import "core:os"
import "core:time"

// notify_osascript shows a Notification Center banner. The message travels as
// script arguments, so process names need no escaping.
notify_osascript :: proc(title, body: string) -> bool {
	process, start_err := os.process_start({
		command = {
			"/usr/bin/osascript",
			"-e",
			"on run argv",
			"-e",
			"display notification (item 1 of argv) with title (item 2 of argv)",
			"-e",
			"end run",
			body,
			title,
		},
	})
	if start_err != nil {
		return false
	}
	state, wait_err := os.process_wait(process, 10 * time.Second)
	if wait_err != nil {
		return false
	}
	return state.success
}
