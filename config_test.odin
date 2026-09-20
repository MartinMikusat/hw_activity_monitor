// Config persistence and settings parsing tests: file I/O on a scratch path.

package activity_monitor

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
test_config_save_and_load_round_trip :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	path := fmt.tprintf(
		"%s/hw_activity_monitor_config_test_%d.json",
		os.temp_dir(context.temp_allocator),
		os.get_pid(),
	)
	defer os.remove(path)

	config := config_defaults()
	config.window_seconds = 900
	config.interval_seconds = 2
	config.show_window_cpu = false
	testing.expect(t, config_save(config, path))

	loaded := config_defaults()
	config_load(&loaded, path)
	testing.expect_value(t, loaded.window_seconds, f64(900))
	testing.expect_value(t, loaded.interval_seconds, f64(2))
	testing.expect_value(t, loaded.show_window_cpu, false)
	testing.expect_value(t, loaded.show_memory, true) // defaults survive absent keys
	testing.expect_value(t, loaded.cpu_percent, f64(60))
}

@(test)
test_config_apply_fields_parses_and_clamps :: proc(t: ^testing.T) {
	config := config_defaults()
	testing.expect(t, config_apply_fields(&config, "15", "3"))
	testing.expect_value(t, config.window_seconds, f64(900))
	testing.expect_value(t, config.interval_seconds, f64(3))

	testing.expect(t, !config_apply_fields(&config, "soon", "3"))
	testing.expect(t, !config_apply_fields(&config, "15", ""))

	testing.expect(t, config_apply_fields(&config, "0.1", "99999"))
	testing.expect_value(t, config.window_seconds, f64(60)) // clamped to a minute
	testing.expect_value(t, config.interval_seconds, f64(3600))
}
