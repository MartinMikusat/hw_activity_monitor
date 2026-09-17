# hw_cpu_watchdog

A small macOS daemon that notices runaway processes and posts a Notification
Center banner. Notify only: it never kills anything.

It watches the whole process table, groups CPU by executable name, and alerts
when a group stays above a CPU budget for long enough. Grouping is what catches
the case that started this: three forgotten `hw_clay` demo processes at ~80%
CPU each kept a core busy for six hours without showing up in the battery menu.

## Why libproc instead of `ps`

`ps pcpu` is a lifetime average. Off-the-shelf CPU watchers that parse it sit on
a moving target: a process averaging 79% forever never trips an 80% threshold,
and a process that burned 200% for two minutes then idled looks calm. This
watchdog reads `proc_pid_rusage` (cumulative CPU nanoseconds per process) and
deltas it against the wall time between scans, so the number is the CPU used
since the last scan. Grouping also means N instances of one binary are judged
together instead of N separate small numbers.

## Usage

```
./build.sh [debug|release]   # build
./test.sh                    # rule-engine tests + compile check
./install.sh                 # build, install to ~/.local/bin, load LaunchAgent
./uninstall.sh               # unload and remove binary (config and logs kept)
hw_cpu_watchdog --once       # sample twice, print the busiest groups
```

Install loads `~/Library/LaunchAgents/com.halwayland.hw_cpu_watchdog.plist`
(`RunAtLoad`, `KeepAlive`, `ProcessType Background`). Logs:
`~/Library/Logs/hw_cpu_watchdog.log`.

## Configuration

Defaults live in `config.odin`; override fields in
`~/Library/Application Support/hw_cpu_watchdog/config.json` (absent fields keep
their default):

```json
{
  "interval_seconds": 5,
  "cpu_percent": 60,
  "sustained_seconds": 300,
  "cooldown_seconds": 1800,
  "safelist": ["odin", "clang", "swiftc", "xcodebuild", "zig"]
}
```

- `cpu_percent` is a budget per executable name summed over its processes, in
  percent of one core. Set 150 to catch only multi-instance leaks.
- `sustained_seconds` must pass before the first banner; `cooldown_seconds`
  gates repeat banners while the group stays hot.
- `safelist` entries are case-sensitive substrings of the executable name.
  Defaults cover compilers and system processes because builds legitimately peg
  every core. `hw_cpu_watchdog` itself is always safelisted.

## Notification attribution

Notifications are delivered through `osascript`, so they appear as **Script
Editor**. Approve notifications for Script Editor once, or the banners are
dropped silently. A bare binary cannot use `UNUserNotificationCenter`; wrapping
the daemon in a minimal `.app` bundle (or a signed helper) is the upgrade path
if proper attribution or action buttons are wanted.
