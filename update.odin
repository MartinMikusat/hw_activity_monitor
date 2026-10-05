// Automatic updates from GitHub releases through hw_odin_native_update.
//
// A release carries update.json and one notarized archive. The updater trusts
// the code signature (Developer ID team, bundle ID, announced version), not the
// feed. A daemon has no quit to wait for, so a verified update is swapped in at
// once and launchd restarts the process. Builds without a compiled-in release
// version, and any copy not running as hw_activity_monitor.app, never update.

package activity_monitor

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"
import native_update "native_update:."

UPDATE_BUNDLE_NAME :: "hw_activity_monitor.app"
UPDATE_INTERVAL :: time.Hour

// update_auto_enabled is captured from the config at startup; the settings modal
// does not edit auto_update, so it needs no live plumbing.
update_auto_enabled: bool

// update_busy serializes checks: the hourly worker and the menu's manual check
// must never stage and apply two updates at once.
update_busy: bool

update_config :: proc() -> native_update.Config {
	return {
		feed_url    = UPDATE_FEED_URL,
		bundle_id   = LAUNCH_AGENT_LABEL,
		team_id     = UPDATE_TEAM_ID,
		bundle_name = UPDATE_BUNDLE_NAME,
	}
}

// update_bundle_path returns the installed `.app` containing an executable path,
// or "" when the executable is not inside hw_activity_monitor.app (a development
// build, or the binary run on its own).
update_bundle_path :: proc(executable_path: string) -> string {
	marker :: "/" + UPDATE_BUNDLE_NAME + "/Contents/MacOS/"
	index := strings.index(executable_path, marker)
	if index < 0 {
		return ""
	}
	return executable_path[:index + len(marker) - len("/Contents/MacOS/")]
}

// update_failure records a failed attempt in the event log.
update_failure :: proc(reason: string) {
	log_event(monitor.log, "update_failed", fmt.tprintf("\"stage\":%s", log_string(reason)))
}

// update_check_and_install runs one update cycle: check the feed, stage and
// verify a newer release, swap it in and restart. It returns when there is
// nothing to do or the attempt failed; an unreachable feed is not a failure.
update_check_and_install :: proc() {
	if UPDATE_VERSION == "" || UPDATE_FEED_URL == "" || UPDATE_TEAM_ID == "" {
		return
	}
	if intrinsics.atomic_exchange(&update_busy, true) {
		return
	}
	defer intrinsics.atomic_store(&update_busy, false)
	defer free_all(context.temp_allocator)

	executable, executable_err := os.get_executable_path(context.temp_allocator)
	if executable_err != nil {
		return
	}
	installed := update_bundle_path(executable)
	if installed == "" {
		return
	}

	prepared := native_update.prepare(update_config(), UPDATE_VERSION)
	defer native_update.discard(&prepared)
	switch prepared.status {
	case .Up_To_Date, .Idle, .Checking:
		return
	case .Error:
		update_failure(prepared.error)
		return
	case .Ready:
	}

	version := prepared.manifest.version
	log_event(monitor.log, "update_available", fmt.tprintf(
		"\"version\":%s,\"current\":%s",
		log_string(version),
		log_string(VERSION),
	))
	if message := native_update.apply(update_config(), &prepared, installed); message != "" {
		update_failure(message)
		return
	}
	log_event(monitor.log, "update_installed", fmt.tprintf(
		"\"version\":%s,\"previous\":%s",
		log_string(version),
		log_string(VERSION),
	))
	update_restart()
}

// update_restart asks launchd to restart the daemon so the new bundle takes
// over, then exits. Without a loaded agent the exit is enough: KeepAlive
// restarts the service.
update_restart :: proc() {
	command := fmt.tprintf(
		"launchctl kickstart -k gui/%d/%s",
		int(posix.getuid()),
		LAUNCH_AGENT_LABEL,
	)
	process, start_err := os.process_start({command = {"/bin/sh", "-c", command}})
	if start_err == nil {
		_, _ = os.process_wait(process, 10 * time.Second)
	}
	os.exit(0)
}

// update_worker checks the release feed at startup and then hourly. It runs on
// its own thread so a slow download never delays sampling or alerts.
update_worker :: proc(_: ^thread.Thread) {
	context = runtime.default_context()
	for {
		if update_auto_enabled {
			update_check_and_install()
		}
		time.sleep(UPDATE_INTERVAL)
	}
}

update_check_thread :: proc(_: ^thread.Thread) {
	context = runtime.default_context()
	update_check_and_install()
}

// update_check_now starts one check on its own thread: the status menu's
// "Check for Updates".
update_check_now :: proc() {
	worker := thread.create(update_check_thread)
	if worker != nil {
		thread.start(worker)
	}
}
