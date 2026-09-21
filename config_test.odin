// Tests for the config's serialization contract: the theme is written by name so
// the file stays readable and hand-editable, and it survives a round trip.

package activity_monitor

import "core:encoding/json"
import "core:strings"
import "core:testing"

@(test)
config_theme_round_trips_by_name :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	config := config_defaults()
	config.theme = .Light

	data, marshal_err := json.marshal(config, CONFIG_JSON_OPTIONS, context.temp_allocator)
	if !testing.expect(t, marshal_err == nil, "marshal failed") {
		return
	}
	testing.expect(
		t,
		strings.contains(string(data), `"theme": "Light"`),
		"the theme is written by name, not by ordinal",
	)

	loaded := config_defaults()
	loaded.theme = .Dark
	if err := json.unmarshal(data, &loaded, allocator = context.temp_allocator); !testing.expect(t, err == nil, "unmarshal failed") {
		return
	}
	testing.expect_value(t, loaded.theme, Theme.Light)
	testing.expect_value(t, loaded.interval_seconds, f64(5))
	testing.expect_value(t, loaded.show_cpu, true)
}
