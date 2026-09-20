// Automatic updates from GitHub releases.
//
// The installed bundle checks the latest release at startup and once a day,
// downloads the archive with curl, verifies the SHA-256 published beside it,
// unpacks it, checks the code signature and the bundle's version, then swaps the
// bundle in place (keeping the previous one as `.backup`) and asks launchd to
// restart the daemon. Development binaries — any executable not inside a `.app`
// — never replace themselves.
//
// The trust anchor is the GitHub repository over TLS: the checksum travels in
// the same release as the archive, so it protects against a corrupted download,
// not against a compromised repository. Nothing is executed from the download
// before the swap; the running binary is the verification.

package activity_monitor

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:thread"
import "core:time"

UPDATE_API_LATEST :: "https://api.github.com/repos/MartinMikusat/hw_activity_monitor/releases/latest"
UPDATE_CHECK_INTERVAL :: 24 * time.Hour
UPDATE_COMMAND_TIMEOUT :: 180 * time.Second
UPDATE_ZIP_PREFIX :: "hw_activity_monitor-"

// update_auto_enabled is captured from the config at startup; the settings modal
// does not edit auto_update, so it needs no live plumbing.
update_auto_enabled: bool

Update_Asset :: struct {
	name:                 string,
	browser_download_url: string,
}

Update_Release :: struct {
	tag_name: string,
	assets:   []Update_Asset,
}

// ------------------------------------------------------------- pure helpers

// update_version_compare compares dotted numeric versions ("1.2.3" or
// "v1.2.3"); it returns -1, 0, or 1. Missing components count as zero, so
// "1.2" and "1.2.0" are equal.
update_version_compare :: proc(a, b: string) -> int {
	left := update_version_parts(a)
	right := update_version_parts(b)
	for index in 0 ..< max(len(left), len(right)) {
		left_value := index < len(left) ? left[index] : 0
		right_value := index < len(right) ? right[index] : 0
		if left_value < right_value {
			return -1
		}
		if left_value > right_value {
			return 1
		}
	}
	return 0
}

update_version_parts :: proc(version: string) -> []int {
	trimmed := strings.trim_space(version)
	if strings.has_prefix(trimmed, "v") {
		trimmed = trimmed[1:]
	}
	parts := make([dynamic]int, 0, 4, context.temp_allocator)
	for piece in strings.split(trimmed, ".", context.temp_allocator) {
		value, ok := strconv.parse_int(strings.trim_space(piece))
		if !ok {
			break
		}
		append(&parts, value)
	}
	return parts[:]
}

// update_bundle_path returns the `.app` bundle containing an executable path, or
// "" when the executable is not inside one (a development build).
update_bundle_path :: proc(executable_path: string) -> string {
	marker :: ".app/Contents/MacOS/"
	index := strings.index(executable_path, marker)
	if index < 0 {
		return ""
	}
	return executable_path[:index+len(".app")]
}

// update_first_token returns the first whitespace-separated token, which is the
// digest in a `shasum` line.
update_first_token :: proc(text: string) -> string {
	trimmed := strings.trim_space(text)
	if index := strings.index_byte(trimmed, ' '); index >= 0 {
		return trimmed[:index]
	}
	return trimmed
}

// ------------------------------------------------------------------ process

// update_join joins path elements, returning "" on failure.
update_join :: proc(parts: ..string) -> string {
	joined, err := filepath.join(parts, context.temp_allocator)
	if err != nil {
		return ""
	}
	return joined
}

// update_run runs a command and reports whether it exited successfully.
update_run :: proc(args: ..string) -> bool {
	process, start_err := os.process_start({command = args})
	if start_err != nil {
		return false
	}
	state, wait_err := os.process_wait(process, UPDATE_COMMAND_TIMEOUT)
	if wait_err != nil {
		return false
	}
	return state.success
}

// update_run_capture runs a command with stdout written to path.
update_run_capture :: proc(path: string, args: ..string) -> bool {
	file, open_err := os.open(path, {.Write, .Create, .Trunc})
	if open_err != nil {
		return false
	}
	defer os.close(file)
	process, start_err := os.process_start({command = args, stdout = file})
	if start_err != nil {
		return false
	}
	state, wait_err := os.process_wait(process, UPDATE_COMMAND_TIMEOUT)
	if wait_err != nil {
		return false
	}
	return state.success
}

// -------------------------------------------------------------------- update

// update_failure records a failed attempt with the stage that failed.
update_failure :: proc(stage: string) {
	log_event(monitor.log, "update_failed", fmt.tprintf("\"stage\":%s", log_string(stage)))
}

// update_verify_checksum compares the archive's SHA-256 with the digest
// published beside it.
update_verify_checksum :: proc(zip_path, digest_path, directory: string) -> bool {
	actual_path := update_join(directory, "digest.txt")
	if actual_path == "" || !update_run_capture(actual_path, "shasum", "-a", "256", zip_path) {
		return false
	}
	actual_data, actual_err := os.read_entire_file(actual_path, context.temp_allocator)
	published_data, published_err := os.read_entire_file(digest_path, context.temp_allocator)
	if actual_err != nil || published_err != nil {
		return false
	}
	actual := update_first_token(string(actual_data))
	published := update_first_token(string(published_data))
	return actual != "" && published != "" && strings.equal_fold(actual, published)
}

// update_check_and_install runs one update cycle. It returns after installing
// (the process is restarted) or after leaving the current bundle in place.
update_check_and_install :: proc() {
	defer free_all(context.temp_allocator)

	executable, executable_err := os.get_executable_path(context.temp_allocator)
	if executable_err != nil {
		return
	}
	bundle := update_bundle_path(executable)
	if bundle == "" {
		return // development binary: never replaces itself
	}

	directory := fmt.tprintf(
		"%s/hw_activity_monitor_update_%d",
		os.temp_dir(context.temp_allocator),
		os.get_pid(),
	)
	if os.make_directory_all(directory) != nil {
		return
	}
	defer os.remove_all(directory)

	release_path := update_join(directory, "release.json")
	// No `-f` here: a repository with no releases answers 404, and a machine
	// without network fails the same way. Both mean "nothing to do", not a
	// failed update, so they stay out of the event log.
	if release_path == "" ||
	   !update_run_capture(
		   release_path,
		   "curl",
		   "-sSL",
		   "-H",
		   "Accept: application/vnd.github+json",
		   UPDATE_API_LATEST,
	   ) {
		return
	}
	data, read_err := os.read_entire_file(release_path, context.temp_allocator)
	if read_err != nil {
		return
	}
	release: Update_Release
	if json.unmarshal(data, &release, allocator = context.temp_allocator) != nil {
		return
	}
	if release.tag_name == "" {
		return // no releases published yet
	}
	if update_version_compare(release.tag_name, VERSION) <= 0 {
		return // running the newest release
	}
	version := strings.trim_prefix(strings.trim_space(release.tag_name), "v")

	zip_name := fmt.tprintf("%s%s.zip", UPDATE_ZIP_PREFIX, version)
	digest_name := fmt.tprintf("%s.sha256", zip_name)
	zip_url, digest_url: string
	for asset in release.assets {
		if asset.name == zip_name {
			zip_url = asset.browser_download_url
		}
		if asset.name == digest_name {
			digest_url = asset.browser_download_url
		}
	}
	if zip_url == "" || digest_url == "" {
		update_failure("release_assets")
		return
	}
	log_event(monitor.log, "update_available", fmt.tprintf(
		"\"version\":%s,\"current\":%s",
		log_string(version),
		log_string(VERSION),
	))

	zip_path := update_join(directory, zip_name)
	digest_path := update_join(directory, digest_name)
	if zip_path == "" || digest_path == "" ||
	   !update_run_capture(zip_path, "curl", "-fsSL", "-o", zip_path, zip_url) ||
	   !update_run_capture(digest_path, "curl", "-fsSL", "-o", digest_path, digest_url) {
		update_failure("download")
		return
	}
	if !update_verify_checksum(zip_path, digest_path, directory) {
		update_failure("checksum")
		return
	}
	if !update_run("ditto", "-x", "-k", zip_path, directory) {
		update_failure("unpack")
		return
	}

	extracted := update_join(directory, "hw_activity_monitor.app")
	plist := update_join(extracted, "Contents", "Info.plist")
	version_path := update_join(directory, "version.txt")
	if extracted == "" || plist == "" || version_path == "" ||
	   !update_run("codesign", "--verify", "--deep", "--strict", extracted) {
		update_failure("signature")
		return
	}
	if !update_run_capture(
		version_path,
		"plutil",
		"-extract",
		"CFBundleShortVersionString",
		"raw",
		plist,
	) {
		update_failure("bundle_version")
		return
	}
	packaged_data, packaged_err := os.read_entire_file(version_path, context.temp_allocator)
	if packaged_err != nil || strings.trim_space(string(packaged_data)) != version {
		update_failure("bundle_version")
		return
	}

	// Swap, keeping the previous bundle for rollback if the new one misbehaves.
	backup := fmt.tprintf("%s.backup", bundle)
	_ = os.remove_all(backup)
	if os.rename(bundle, backup) != nil {
		update_failure("swap")
		return
	}
	if os.rename(extracted, bundle) != nil {
		_ = os.rename(backup, bundle)
		update_failure("swap")
		return
	}
	_ = update_run("codesign", "--force", "--sign", "-", bundle)

	log_event(monitor.log, "update_installed", fmt.tprintf(
		"\"version\":%s,\"previous\":%s,\"backup\":%s",
		log_string(version),
		log_string(VERSION),
		log_string(backup),
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

// update_worker checks the release feed at startup and once a day. It runs on
// its own thread so a slow download never delays sampling or alerts.
update_worker :: proc(_: ^thread.Thread) {
	context = runtime.default_context()
	for {
		if update_auto_enabled {
			update_check_and_install()
		}
		time.sleep(UPDATE_CHECK_INTERVAL)
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
