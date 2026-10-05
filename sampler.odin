// Per-process CPU and memory sampling through libproc. proc_pid_rusage reports
// cumulative CPU time per process; the delta between two scans divided by the
// wall time between them gives the CPU actually used since the last scan,
// instead of the lifetime average that `ps pcpu` reports. The same call reports
// physical footprint, a level, so memory needs no delta and is correct from the
// first scan.
//
// The rusage times are in mach timebase ticks, not nanoseconds: on Apple
// Silicon one tick is 125/3 ns (24 MHz), so the deltas must be scaled by
// mach_timebase_info. Measured against `ps` otherwise: a 100% process reads 2.4%.

package activity_monitor

import "core:path/filepath"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"
import "core:time"

foreign import system_lib "system:System"
foreign system_lib {
	mach_timebase_info :: proc(info: ^Mach_Timebase) -> i32 ---
}

Mach_Timebase :: struct {
	numer: u32,
	denom: u32,
}

Sampler :: struct {
	previous_total: map[posix.pid_t]u64, // pid -> cumulative CPU ticks
	previous_gpu:   map[posix.pid_t]u64, // pid -> cumulative GPU nanoseconds
	details:        map[posix.pid_t]Detail_Entry, // pid -> label, read once per process
	args_buffer:    []byte,
	last_tick:      time.Tick,
	ticks_to_seconds: f64,
	has_previous:   bool,
}

sampler_destroy :: proc(sampler: ^Sampler) {
	delete(sampler.previous_total)
	delete(sampler.previous_gpu)
	for _, entry in sampler.details {
		delete(entry.name)
		delete(entry.detail)
	}
	delete(sampler.details)
	delete(sampler.args_buffer)
}

// sampler_scan returns one sample per process whose rusage could be read, with
// cpu_fraction relative to the wall time since the previous scan. The first
// scan after startup reports zero fractions: a delta needs two points.
sampler_scan :: proc(sampler: ^Sampler, scratch := context.temp_allocator) -> []Process_Sample {
	assert(sampler != nil, "sampler required")
	if sampler.ticks_to_seconds == 0 {
		timebase: Mach_Timebase
		if mach_timebase_info(&timebase) != 0 || timebase.denom == 0 {
			sampler.ticks_to_seconds = 1e-9 // Intel: ticks are nanoseconds
		} else {
			sampler.ticks_to_seconds = f64(timebase.numer) / f64(timebase.denom) / 1e9
		}
	}
	count := darwin.proc_listallpids(nil, 0)
	if count <= 0 {
		return nil
	}
	pids := make([]i32, count + 64, scratch)
	listed := darwin.proc_listallpids(raw_data(pids), i32(len(pids) * size_of(i32)))
	if listed <= 0 {
		return nil
	}
	if int(listed) < len(pids) {
		pids = pids[:int(listed)]
	}

	now := time.tick_now()
	wall_seconds: f64
	if sampler.has_previous {
		wall_seconds = time.duration_seconds(time.tick_diff(sampler.last_tick, now))
	}

	gpu_totals := gpu_time_by_pid(context.allocator)

	previous := sampler.previous_total
	fresh := make(map[posix.pid_t]u64, len(pids), context.allocator)
	fresh_details := make(map[posix.pid_t]Detail_Entry, len(pids), context.allocator)
	if sampler.args_buffer == nil {
		sampler.args_buffer = make([]byte, PROCARGS_BUFFER)
	}
	samples := make([dynamic]Process_Sample, 0, len(pids), scratch)
	path_buffer: [posix.PATH_MAX]byte

	for pid_value in pids {
		if pid_value <= 0 {
			continue
		}
		pid := posix.pid_t(pid_value)
		usage: darwin.rusage_info_v0
		if darwin.proc_pid_rusage(pid, .V0, &usage) != 0 {
			continue // other users' processes may refuse; they are not ours to alert on
		}
		path_length := darwin.proc_pidpath(pid, &path_buffer[0], u32(len(path_buffer)))
		if path_length <= 0 {
			continue
		}

		total := usage.ri_user_time + usage.ri_system_time
		fraction: f64
		if old_total, found := previous[pid]; found && wall_seconds > 0 && total >= old_total {
			fraction = f64(total-old_total) * sampler.ticks_to_seconds / wall_seconds
		}

		gpu_total := gpu_totals[pid]
		gpu_fraction: f64
		if old_gpu, found := sampler.previous_gpu[pid]; found && wall_seconds > 0 && gpu_total >= old_gpu {
			gpu_fraction = f64(gpu_total-old_gpu) / 1e9 / wall_seconds
		}

		fresh[pid] = total
		name := filepath.base(string(path_buffer[:path_length]))
		entry, known := sampler.details[pid]
		if known && entry.name == name {
			delete_key(&sampler.details, pid)
		} else {
			if known {
				delete(entry.name)
				delete(entry.detail)
				delete_key(&sampler.details, pid)
			}
			args := process_arguments(pid, sampler.args_buffer)
			entry = Detail_Entry{
				name   = strings.clone(name),
				detail = strings.clone(process_detail_text(name, args, process_cwd_base(pid))),
			}
		}
		fresh_details[pid] = entry
		append(&samples, Process_Sample{
			pid          = i32(pid),
			name         = strings.clone(name, scratch),
			detail       = strings.clone(entry.detail, scratch),
			cpu_fraction = fraction,
			gpu_fraction = gpu_fraction,
			memory_bytes = usage.ri_phys_footprint,
		})
	}

	for _, entry in sampler.details { // exited processes
		delete(entry.name)
		delete(entry.detail)
	}
	delete(sampler.details)
	sampler.details = fresh_details
	delete(previous) // counters of exited processes disappear with the old map
	delete(sampler.previous_gpu)
	sampler.previous_total = fresh
	sampler.previous_gpu = gpu_totals
	sampler.last_tick = now
	sampler.has_previous = true
	return samples[:]
}
