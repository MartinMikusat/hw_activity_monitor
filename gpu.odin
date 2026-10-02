// Per-process GPU sampling from the IORegistry. Apple ships no public API for
// per-process GPU utilization — task_info's task_gpu_utilisation is never
// populated — but every Metal command queue creates an AGXDeviceUserClient
// child of the GPU accelerator whose AppUsage entries carry accumulatedGPUTime,
// cumulative GPU nanoseconds. Summed per pid and differenced between scans, it
// gives GPU time since the last scan exactly the way CPU uses rusage deltas.
// World-readable: no sudo, no helper. The accelerator class is AGXAccelerator
// on Apple Silicon; Intel Macs expose IntelAccelerator and get nothing, so the
// map comes back empty there.
//
// GPU time sums across a process's command queues, so concurrent queues can
// push the fraction past 1.0, the same way CPU exceeds one core.

package activity_monitor

import "core:c"
import "core:strconv"
import "core:strings"
import "core:sys/darwin"
import "core:sys/darwin/CoreFoundation"
import "core:sys/posix"

IO_Object :: distinct darwin.mach_port_t
IO_Iterator :: IO_Object

IO_PLANE_SERVICES :: "IOService"
GPU_ACCELERATOR_CLASS :: "AGXAccelerator"

CF_NUMBER_SINT64 :: distinct c.long

foreign import core_foundation "system:CoreFoundation.framework"
foreign core_foundation {
	@(link_name="CFArrayGetCount")
	cf_array_count :: proc(array: CoreFoundation.TypeRef) -> CoreFoundation.Index ---
	@(link_name="CFArrayGetValueAtIndex")
	cf_array_value :: proc(array: CoreFoundation.TypeRef, index: CoreFoundation.Index) -> CoreFoundation.TypeRef ---
	@(link_name="CFDictionaryGetValue")
	cf_dictionary_value :: proc(dictionary, key: CoreFoundation.TypeRef) -> CoreFoundation.TypeRef ---
	@(link_name="CFNumberGetValue")
	cf_number_value :: proc(number: CoreFoundation.TypeRef, kind: CF_NUMBER_SINT64, value: rawptr) -> b8 ---
	@(link_name="CFStringGetCString")
	cf_string_c_string :: proc(the_string: CoreFoundation.TypeRef, buffer: [^]byte, buffer_size: CoreFoundation.Index, encoding: CoreFoundation.StringEncoding) -> b8 ---
	@(link_name="CFArrayGetTypeID")
	cf_array_type_id :: proc "c" () -> c.ulong ---
	@(link_name="CFDictionaryGetTypeID")
	cf_dictionary_type_id :: proc "c" () -> c.ulong ---
	@(link_name="CFGetTypeID")
	cf_type_id :: proc "c" (cf: CoreFoundation.TypeRef) -> c.ulong ---
}

foreign import iokit "system:IOKit.framework"
foreign iokit {
	@(link_name = "IOServiceGetMatchingServices")
	io_service_get_matching_services :: proc(main_port: darwin.mach_port_t, matching: CoreFoundation.TypeRef, existing: ^IO_Iterator) -> darwin.kern_return_t ---
	@(link_name = "IOServiceMatching")
	io_service_matching :: proc(name: cstring) -> CoreFoundation.TypeRef ---
	@(link_name = "IORegistryEntryGetChildIterator")
	io_registry_entry_get_child_iterator :: proc(entry: IO_Object, plane: cstring, existing: ^IO_Iterator) -> darwin.kern_return_t ---
	@(link_name = "IOIteratorNext")
	io_iterator_next :: proc(iterator: IO_Iterator) -> IO_Object ---
	@(link_name = "IORegistryEntryCreateCFProperty")
	io_registry_entry_create_cf_property :: proc(entry: IO_Object, key: CoreFoundation.TypeRef, allocator: rawptr, options: u32) -> CoreFoundation.TypeRef ---
	@(link_name = "IOObjectRelease")
	io_object_release :: proc(object: IO_Object) ---
}

// gpu_time_by_pid walks the GPU accelerator's user clients once and returns the
// cumulative GPU nanoseconds for every pid that has ever submitted work. The
// map belongs to the caller's allocator.
gpu_time_by_pid :: proc(allocator := context.allocator) -> map[posix.pid_t]u64 {
	totals := make(map[posix.pid_t]u64, 0, allocator)
	matching := io_service_matching(GPU_ACCELERATOR_CLASS) // consumed by the lookup below
	accelerators: IO_Iterator
	if io_service_get_matching_services(0, matching, &accelerators) != 0 {
		return totals
	}
	defer io_object_release(IO_Object(accelerators))

	for accelerator := io_iterator_next(accelerators); accelerator != 0; accelerator = io_iterator_next(accelerators) {
		clients: IO_Iterator
		if io_registry_entry_get_child_iterator(accelerator, IO_PLANE_SERVICES, &clients) != 0 {
			io_object_release(accelerator)
			continue
		}
		for client := io_iterator_next(clients); client != 0; client = io_iterator_next(clients) {
			creator := io_registry_entry_create_cf_property(
				client,
				CoreFoundation.TypeRef(CoreFoundation.STR("IOUserClientCreator")),
				nil,
				0,
			)
			if creator == nil {
				io_object_release(client)
				continue
			}
			pid := gpu_client_pid(creator)
			CoreFoundation.CFRelease(creator)
			if pid <= 0 {
				io_object_release(client)
				continue
			}

			usage := io_registry_entry_create_cf_property(client, CoreFoundation.TypeRef(CoreFoundation.STR("AppUsage")), nil, 0)
			if usage != nil {
				if gpu_ns, ok := gpu_client_time(usage); ok {
					totals[posix.pid_t(pid)] += gpu_ns
				}
				CoreFoundation.CFRelease(usage)
			}
			io_object_release(client)
		}
		io_object_release(clients)
		io_object_release(accelerator)
	}
	return totals
}

// gpu_client_pid reads "pid 413, WindowServer"; only numbered creators belong
// to a process. The string is owned by the registry; do not free it.
gpu_client_pid :: proc(creator: CoreFoundation.TypeRef) -> i32 {
	creator_name: [256]byte
	if !cf_string_c_string(
		creator,
		raw_data(creator_name[:]),
		CoreFoundation.Index(len(creator_name)),
		CoreFoundation.StringEncoding(CoreFoundation.StringBuiltInEncodings.UTF8),
	) {
		return -1
	}
	text := string(creator_name[:])
	prefix := "pid "
	if !strings.has_prefix(text, prefix) {
		return -1
	}
	rest := text[len(prefix):]
	digits := 0
	for digits < len(rest) && rest[digits] >= '0' && rest[digits] <= '9' {
		digits += 1
	}
	if digits == 0 {
		return -1
	}
	pid, ok := strconv.parse_int(rest[:digits])
	if !ok || pid <= 0 || pid > 1 << 31 - 1 {
		return -1
	}
	return i32(pid)
}

// gpu_client_time sums accumulatedGPUTime across the AppUsage array's entries,
// one per command queue; an empty array (a client that never submitted) is a
// valid zero.
gpu_client_time :: proc(usage: CoreFoundation.TypeRef) -> (u64, bool) {
	if cf_type_id(usage) != cf_array_type_id() {
		return 0, false
	}
	total: u64
	for index := 0; index < int(cf_array_count(usage)); index += 1 {
		entry := cf_array_value(usage, CoreFoundation.Index(index))
		if entry == nil || cf_type_id(entry) != cf_dictionary_type_id() {
			continue
		}
		gpu_time := cf_dictionary_value(entry, CoreFoundation.TypeRef(CoreFoundation.STR("accumulatedGPUTime")))
		if gpu_time == nil {
			continue
		}
		nanoseconds: i64
		if cf_number_value(gpu_time, CF_NUMBER_SINT64(4), &nanoseconds) && nanoseconds > 0 {
			total += u64(nanoseconds)
		}
	}
	return total, true
}
