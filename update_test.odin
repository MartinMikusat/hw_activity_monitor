// Updater tests: the pure pieces (version comparison, bundle discovery, release
// parsing, digest parsing). The download/swap path is exercised by hand.

package activity_monitor

import "core:encoding/json"
import "core:testing"

@(test)
test_update_version_compare :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, update_version_compare("1.2.3", "1.2.3"), 0)
	testing.expect_value(t, update_version_compare("v1.2.3", "1.2.3"), 0)
	testing.expect_value(t, update_version_compare("1.2", "1.2.0"), 0)
	testing.expect_value(t, update_version_compare("1.3", "1.2.9"), 1)
	testing.expect_value(t, update_version_compare("1.2", "1.2.1"), -1)
	testing.expect_value(t, update_version_compare("2.0.0", "10.0.0"), -1)
	testing.expect_value(t, update_version_compare("", "1.0.0"), -1)
	testing.expect_value(t, update_version_compare("1.0.0", ""), 1)
}

@(test)
test_update_bundle_path :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		update_bundle_path(
			"/Users/x/Applications/hw_activity_monitor.app/Contents/MacOS/hw_activity_monitor",
		),
		"/Users/x/Applications/hw_activity_monitor.app",
	)
	testing.expect_value(
		t,
		update_bundle_path("/Users/x/projects/hw_activity_monitor/build/hw_activity_monitor"),
		"",
	)
}

@(test)
test_update_first_token :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		update_first_token("abc123  hw_activity_monitor-1.2.0.zip\n"),
		"abc123",
	)
	testing.expect_value(t, update_first_token("abc123\n"), "abc123")
	testing.expect_value(t, update_first_token("   "), "")
}

@(test)
test_update_release_parsing :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	data := `{"tag_name":"v1.2.0","assets":[{"name":"hw_activity_monitor-1.2.0.zip","browser_download_url":"https://example.invalid/zip"},{"name":"hw_activity_monitor-1.2.0.zip.sha256","browser_download_url":"https://example.invalid/sha"}]}`
	release: Update_Release
	testing.expect(
		t,
		json.unmarshal(transmute([]u8)data, &release, allocator = context.temp_allocator) == nil,
	)
	testing.expect_value(t, release.tag_name, "v1.2.0")
	testing.expect_value(t, len(release.assets), 2)
	testing.expect_value(t, release.assets[0].name, "hw_activity_monitor-1.2.0.zip")
	testing.expect_value(t, release.assets[1].browser_download_url, "https://example.invalid/sha")
}
