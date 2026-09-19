// Configuration: defaults in code, optional override file under
// ~/Library/Application Support/hw_activity_monitor/config.json. Fields present in
// the file replace the defaults; absent fields keep them.

package activity_monitor

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"

Config :: struct {
	interval_seconds:  f64,
	cpu_percent:       f64,
	memory_mb:         f64,
	sustained_seconds: f64,
	cooldown_seconds:  f64,
	safelist:          []string,
}

// Defaults are tuned for a single-core runaway like a forgotten demo window at
// 80%: 60% of one core sustained for five minutes, re-alerting every half hour.
// Compilers are safelisted because building legitimately pegs every core, and
// VM helpers because a VM holds its assigned RAM and its guest load. The memory
// budget is an absolute per-group footprint: 4 GB sustained for the same window
// catches a leak without flagging healthy browser or editor use.
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
		cpu_percent       = 60,
		memory_mb         = 4096,
		sustained_seconds = 300,
		cooldown_seconds  = 1800,
		safelist          = DEFAULT_SAFELIST[:],
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
	config.cpu_percent = clamp(config.cpu_percent, 1, 100000)
	if config.memory_mb <= 0 {
		config.memory_mb = 0 // zero disables memory alerts
	} else {
		config.memory_mb = clamp(config.memory_mb, 64, 1048576)
	}
	config.sustained_seconds = clamp(config.sustained_seconds, 10, 86400)
	config.cooldown_seconds = clamp(config.cooldown_seconds, 0, 86400)
}
