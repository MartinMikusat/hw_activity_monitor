# hw_activity_monitor

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
./install.sh                 # build, install the app bundle, load LaunchAgent
./uninstall.sh               # unload and remove bundle (config and logs kept)
hw_activity_monitor --once   # sample twice, print the busiest groups
```

Install copies the binary into `~/Applications/hw_activity_monitor.app` (a
minimal `LSUIElement` bundle, ad-hoc signed) and loads
`~/Library/LaunchAgents/com.halwayland.hw_activity_monitor.plist`
(`RunAtLoad`, `KeepAlive`, `ProcessType Background`). The first installed run
asks for notification permission; without it alerts only reach the log.

## Configuration

Defaults live in `config.odin`; override fields in
`~/Library/Application Support/hw_activity_monitor/config.json` (absent fields keep
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
  every core. `hw_activity_monitor` itself is always safelisted.

## Notification delivery

The installed daemon runs from its `.app` bundle and posts through
`UNUserNotificationCenter`, so banners are attributed to hw_activity_monitor
and the system asks for permission once. A bare binary has no bundle
identifier and cannot post that way, so development runs (the binary in
`build/`) fall back to `osascript`; macOS usually drops those banners unless
Script Editor has notification permission. Alerts always land in the log
regardless of delivery.

## Event log

The daemon appends one JSON object per line to
`~/Library/Logs/hw_activity_monitor.jsonl`; the file is never rewritten, so
agents and `jq` can read it like a stream:

```json
{"time":"2026-09-18T07:48:15Z","event":"alert","name":"yes","processes":1,"cpu_percent":100.0,"sustained_seconds":11,"pids":[98862],"notified":true}
```

Events: `started` (pid and effective config), `alert` (name, process count,
group CPU percent, sustained seconds, pids, whether a banner was requested),
`notification_authorization` (granted, or the error), and `notification_failed`
(the API error). Events are rare — one per alert episode — so the file is not
rotated.

```sh
jq -c 'select(.event=="alert")' ~/Library/Logs/hw_activity_monitor.jsonl
jq -r 'select(.event=="alert") | [.time,.name,.processes,.cpu_percent] | @tsv' ~/Library/Logs/hw_activity_monitor.jsonl
```

launchd's stdout/stderr file (`~/Library/Logs/hw_activity_monitor.launchd.log`)
keeps crash output.
