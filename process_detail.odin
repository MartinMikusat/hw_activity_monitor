// What a process is running, beyond its executable name: the script behind
// python/node, the Chromium helper role, the working directory of a tool whose
// executable name says nothing (a version number, `node`). Read once per pid
// from the argument vector (KERN_PROCARGS2) and the working directory; both are
// refused for other users' processes, which then keep an empty detail.

package activity_monitor

import "base:runtime"
import "core:c"
import "core:path/filepath"
import "core:strings"
import "core:sys/darwin"
import "core:sys/posix"

foreign import detail_system "system:System"
foreign detail_system {
	sysctl :: proc(name: [^]c.int, namelen: c.uint, oldp: rawptr, oldlenp: ^c.size_t, newp: rawptr, newlen: c.size_t) -> c.int ---
}

CTL_KERN        :: 1
KERN_PROCARGS2  :: 49
PROCARGS_BUFFER :: 256 * 1024 // arguments and environment; only the arguments are used

INTERPRETER_PREFIXES :: [?]string{"python", "node", "bun", "deno", "ruby", "perl", "php", "tsx", "ts-node"}

Detail_Entry :: struct {
	name:   string,
	detail: string,
}

process_arguments :: proc(pid: posix.pid_t, buffer: []byte, allocator := context.temp_allocator) -> []string {
	mib := [3]c.int{CTL_KERN, KERN_PROCARGS2, c.int(pid)}
	length := c.size_t(len(buffer))
	if sysctl(&mib[0], 3, raw_data(buffer), &length, nil, 0) != 0 || length < size_of(i32) {
		return nil
	}
	data := buffer[:length]
	argc := int((^i32)(raw_data(data))^)
	cursor := size_of(i32)
	for cursor < len(data) && data[cursor] != 0 { 	// executable path
		cursor += 1
	}
	for cursor < len(data) && data[cursor] == 0 { 	// padding
		cursor += 1
	}
	args := make([dynamic]string, 0, argc, allocator)
	for len(args) < argc && cursor < len(data) {
		end := cursor
		for end < len(data) && data[end] != 0 {
			end += 1
		}
		append(&args, string(data[cursor:end]))
		cursor = end + 1
	}
	return args[:]
}

process_cwd_base :: proc(pid: posix.pid_t) -> string {
	info: darwin.proc_vnodepathinfo
	if darwin.proc_pidinfo(pid, .VNODEPATHINFO, 0, &info, size_of(info)) != size_of(info) {
		return ""
	}
	path := string(cstring(&info.pvi_cdir.vip_path[0]))
	if path == "/" {
		return ""
	}
	return filepath.base(path)
}

// process_detail_text is pure: the arguments and the working-directory base
// in, one short label out. Empty means the name already says it all.
process_detail_text :: proc(name: string, args: []string, cwd: string, allocator := context.temp_allocator) -> string {
	if len(args) == 0 {
		return ""
	}
	for prefix in INTERPRETER_PREFIXES {
		if strings.has_prefix(name, prefix) {
			return interpreter_detail(args, cwd, allocator)
		}
	}
	if label := chromium_detail(args, allocator); label != "" {
		return label
	}
	command := filepath.base(args[0])
	if command != "" && command != name && !strings.has_prefix(args[0], "-") {
		return with_cwd(command, cwd, allocator)
	}
	return ""
}

interpreter_detail :: proc(args: []string, cwd: string, allocator: runtime.Allocator) -> string {
	target := ""
	for index := 1; index < len(args); index += 1 {
		arg := args[index]
		if arg == "-m" && index + 1 < len(args) {
			return with_cwd(strings.concatenate({"-m ", args[index + 1]}, allocator), cwd, allocator)
		}
		if arg == "-c" || arg == "-e" || arg == "-p" {
			return with_cwd(arg, cwd, allocator)
		}
		if !strings.has_prefix(arg, "-") {
			target = arg
			break
		}
	}
	if target == "" {
		return ""
	}
	directory, file := filepath.split(target)
	parent := filepath.base(strings.trim_right(directory, "/"))
	label := file
	if parent != "" && parent != "." && parent != "/" {
		label = strings.concatenate({parent, "/", file}, allocator)
	}
	return with_cwd(label, cwd, allocator)
}

chromium_detail :: proc(args: []string, allocator: runtime.Allocator) -> string {
	kind, sub_type: string
	extension := false
	for arg in args[1:] {
		switch {
		case strings.has_prefix(arg, "--type="):
			kind = arg[len("--type="):]
		case strings.has_prefix(arg, "--utility-sub-type="):
			sub_type = arg[len("--utility-sub-type="):]
		case arg == "--extension-process":
			extension = true
		}
	}
	switch {
	case extension:
		return "extension"
	case sub_type != "":
		dot := strings.last_index_byte(sub_type, '.')
		return strings.clone(sub_type[dot + 1:], allocator)
	case kind == "gpu-process":
		return "gpu"
	}
	return ""
}

with_cwd :: proc(label, cwd: string, allocator: runtime.Allocator) -> string {
	if cwd == "" {
		return strings.clone(label, allocator)
	}
	return strings.concatenate({label, " (", cwd, ")"}, allocator)
}
