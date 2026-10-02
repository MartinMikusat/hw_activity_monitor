// gpu_test drives the real IORegistry: some client always holds accumulated
// GPU time on a running Mac, so the walk must find one and the counters must
// be monotonic. Everything else about GPU sampling is delta math covered by
// the sampler's structure.
package activity_monitor

import "core:testing"
import "core:time"

@(test)
test_gpu_time_by_pid_is_monotonic :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	first := gpu_time_by_pid(context.temp_allocator)
	defer delete(first)
	found := false
	for pid, ns in first {
		// A nonzero entry also proves the "pid N, name" creator parse: only
		// numbered creators get into the map at all.
		if pid > 0 && ns > 0 {
			found = true
			break
		}
	}
	testing.expect(t, found, "no process has accumulated GPU time")

	time.sleep(10 * time.Millisecond)
	second := gpu_time_by_pid(context.temp_allocator)
	defer delete(second)
	for pid, ns in second {
		if first_ns, ok := first[pid]; ok {
			testing.expect(t, ns >= first_ns, "GPU time went backwards")
		}
	}
}
