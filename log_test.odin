// JSONL event log tests: pure formatting only.

package activity_monitor

import "core:testing"
import "core:time"

@(test)
test_log_string_escapes_json :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	testing.expect_value(t, log_string("plain"), "\"plain\"")
	testing.expect_value(t, log_string("quote\"and\\slash"), "\"quote\\\"and\\\\slash\"")
	testing.expect_value(t, log_string("tab\there"), "\"tab\\there\"")
}

@(test)
test_timestamp_iso8601_is_utc :: proc(t: ^testing.T) {
	testing.expect_value(t, timestamp_iso8601(time.Time{}), "1970-01-01T00:00:00Z")
}
