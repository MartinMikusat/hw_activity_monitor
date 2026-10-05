package activity_monitor

import "core:testing"

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
	testing.expect_value(
		t,
		update_bundle_path(
			"/Users/x/Applications/hw_activity_monitor.app.backup/Contents/MacOS/hw_activity_monitor",
		),
		"",
	)
}
