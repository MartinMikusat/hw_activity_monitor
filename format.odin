// Presentation formatting shared by alert text, the panel rows, and the
// `--once` output.

package activity_monitor

import "core:fmt"

// format_bytes renders a memory footprint with macOS-style binary units: KB
// below a MiB, MB below a GiB, GB above. Two decimals separate small GB values
// ("1.24 GB") while large ones stay short ("12.3 GB").
format_bytes :: proc(bytes: u64, allocator := context.temp_allocator) -> string {
	mib := f64(1 << 20)
	gib := f64(1 << 30)
	value := f64(bytes)
	switch {
	case value < mib:
		return fmt.aprintf("%.0f KB", value / 1024, allocator = allocator)
	case value < gib:
		return fmt.aprintf("%.1f MB", value / mib, allocator = allocator)
	case value < 10 * gib:
		return fmt.aprintf("%.2f GB", value / gib, allocator = allocator)
	case:
		return fmt.aprintf("%.1f GB", value / gib, allocator = allocator)
	}
}
