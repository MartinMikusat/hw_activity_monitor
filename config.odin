// Configuration: defaults in code, optional override file under
// ~/Library/Application Support/hw_activity_monitor/config.json. Fields present in
// the file replace the defaults; absent fields keep them.

package activity_monitor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

Config :: struct {
	interval_seconds:  f64,
	window_seconds:    f64,
	cpu_percent:       f64,
	memory_mb:         f64,
	sustained_seconds: f64,
	cooldown_seconds:  f64,
	safelist:          []string,
	show_cpu:          bool,
	show_memory:       bool,
	show_window_cpu:   bool,
	show_window_memory: bool,
	auto_update:       bool,
}

// Defaults are tuned for a single-core runaway like a forgotten demo window at
// 80%: 60% of one core sustained for five minutes, re-alerting every half hour.
// The panel's trend columns summarize a ten-minute window by default. Compilers
// are safelisted because building legitimately pegs every core, and VM helpers
// because a VM holds its assigned RAM and its guest load. The memory budget is
// an absolute per-group footprint: 4 GB sustained for the same window catches a
// leak without flagging healthy browser or editor use.
DEFAULT_SAFELIST := [?]string{
	"hw_activity_monitor",
	"osascript",
	"kernel_task",
	"WindowServer",
	"odin",
	"clang",
	"ld",
	"swiftc",
	"swift-frontend",
	"xcodebuild",
	"zig",
	"cargo",
	"rustc",
	"cmake",
	"ninja",
	"make",
	"Virtualization.VirtualMachine",
	"com.docker",
}

config_defaults :: proc() -> Config {
	return {
		interval_seconds  = 5,
		window_seconds    = 600,
		cpu_percent       = 60,
		memory_mb         = 4096,
		sustained_seconds = 300,
		cooldown_seconds  = 1800,
		safelist          = DEFAULT_SAFELIST[:],
		show_cpu          = true,
		show_memory       = true,
		show_window_cpu   = true,
		show_window_memory = true,
		auto_update       = true,
	}
}

config_path :: proc() -> string {
	home, home_err := os.user_home_dir(context.allocator)
	if home_err != nil {
		return ""
	}
	path, join_err := filepath.join({home, "Library/Application Support/hw_activity_monitor/config.json"})
	if join_err != nil {
		return ""
	}
	return path
}

// config_load merges the file at path over the given config. A missing or
// unreadable file is fine; a present but invalid file is reported and the
// defaults stay.
config_load :: proc(config: ^Config, path: string) {
	assert(config != nil, "config required")
	if path == "" {
		return
	}
	data, read_err := os.read_entire_file(path, context.temp_allocator)
	if read_err != nil {
		return
	}
	if unmarshal_err := json.unmarshal(data, config); unmarshal_err != nil {
		fmt.eprintf("hw_activity_monitor: %s is not valid JSON: %v; using defaults\n", path, unmarshal_err)
	}
}

config_validate :: proc(config: ^Config) {
	assert(config != nil, "config required")
	config.interval_seconds = clamp(config.interval_seconds, 1, 3600)
	config.window_seconds = clamp(config.window_seconds, 60, 86400)
	config.cpu_percent = clamp(config.cpu_percent, 1, 100000)
	if config.memory_mb <= 0 {
		config.memory_mb = 0 // zero disables memory alerts
	} else {
		config.memory_mb = clamp(config.memory_mb, 64, 1048576)
	}
	config.sustained_seconds = clamp(config.sustained_seconds, 10, 86400)
	config.cooldown_seconds = clamp(config.cooldown_seconds, 0, 86400)
}

// config_apply_fields parses the settings modal's text fields over a draft and
// clamps the result like config_validate. It returns false when a field is not
// a number.
config_apply_fields :: proc(config: ^Config, window_minutes, interval_seconds: string) -> bool {
	assert(config != nil, "config required")
	window, window_ok := strconv.parse_f64(strings.trim_space(window_minutes))
	interval, interval_ok := strconv.parse_f64(strings.trim_space(interval_seconds))
	if !window_ok || !interval_ok {
		return false
	}
	config.window_seconds = window * 60
	config.interval_seconds = interval
	config_validate(config)
	return true
}

// config_save writes the whole config as JSON, creating the config directory
// when it does not exist yet. The daemon reads the file at startup, so this is
// also the durable record of a settings change.
config_save :: proc(config: Config, path: string) -> bool {
	assert(path != "", "config path required")
	_ = os.make_directory_all(filepath.dir(path))
	data, marshal_err := json.marshal(config, {pretty = true}, context.temp_allocator)
	if marshal_err != nil {
		return false
	}
	return os.write_entire_file(path, data) == nil
}
