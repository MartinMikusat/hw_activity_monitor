# hw_activity_monitor

A small macOS menu bar watchdog for runaway processes. A status item shows
total CPU percent; clicking it opens a popover with the top process groups and
their processes, CPU and memory footprint side by side. Notify only: it never
kills anything.

It watches the whole process table, groups CPU and memory by executable name,
and alerts when a group stays above either budget for long enough. Grouping is
what catches the case that started this: three forgotten `hw_clay` demo
processes at ~80% CPU each kept a core busy for six hours without showing up in
the battery menu.

## Why libproc instead of `ps`

`ps pcpu` is a lifetime average. Off-the-shelf CPU watchers that parse it sit on
a moving target: a process averaging 79% forever never trips an 80% threshold,
and a process that burned 200% for two minutes then idled looks calm. This
watchdog reads `proc_pid_rusage` (cumulative CPU nanoseconds per process) and
deltas it against the wall time between scans, so the number is the CPU used
since the last scan. The same call reports `ri_phys_footprint`, the number
Activity Monitor shows as Memory, so the memory column costs no extra syscall.
Grouping also means N instances of one binary are judged together instead of N
separate small numbers.

## Usage

```
./build.sh [debug|release]   # build
./test.sh                    # rule-engine tests + compile check
./install.sh                 # build, install the app bundle, load LaunchAgent
./uninstall.sh               # unload and remove bundle (config and logs kept)
./release.sh                 # build, zip, and publish a GitHub release
hw_activity_monitor --once   # sample twice, print the busiest groups with CPU and memory
hw_activity_monitor --version
```

Install copies the binary into `~/Applications/hw_activity_monitor.app` (a
minimal `LSUIElement` bundle, ad-hoc signed) and loads
`~/Library/LaunchAgents/com.halwayland.hw_activity_monitor.plist`
(`RunAtLoad`, `KeepAlive`, `ProcessType Background`). The first installed run
asks for notification permission; without it alerts only reach the log.

## Menu bar

The status item shows the sampled total CPU as a share of all cores ("12%").
Clicking it opens the panel: total CPU and process count, then the top groups
with their busiest processes underneath, each row carrying "CPU · memory" and
pids. A group stays listed while it is above the CPU floor or above a 1 GB
footprint, so a memory-heavy but idle process is still visible. Group rows also
carry the rolling window's average CPU, its signed memory change, and a
sparkline of the CPU series, so slow leaks and ramps are visible.

Rows stay where they are: every row carries its rank, computed from the
cumulative window (the larger of its share of the CPU budget and its share of
the memory budget), so from tick to tick only the rank numbers and values
change. Rank 1 is tinted red, ranks 2–4 yellow. **Sort** in the panel header
reorders the rows so their positions match their ranks; until you press it, the
order from the last sort is kept and new groups are appended at the bottom. The
panel sizes itself to the list, up to a maximum height, then scrolls.

The **Settings** button in the panel header opens an in-panel modal that edits
the history window, the sampling interval, and which of the four stat columns
the rows show. Saving writes
`~/Library/Application Support/hw_activity_monitor/config.json` and stages the
change for the worker, which picks it up on its next tick — the accumulated
history survives. Escape or clicking outside closes the modal without saving.

Right-clicking the status item opens its menu: **Open Settings** brings up the
panel already in the modal, and **Quit hw_activity_monitor** stops the daemon.
Because the LaunchAgent keeps the process alive, Quit unloads the agent first;
it stays stopped until `./install.sh` runs again or you log back in.

The panel is not an AppKit view hierarchy: `panel.odin` lays the list out with
hw_clay every frame and draws it through the ui_framework renderer (CoreText
text, draw list, Metal) into a borderless non-activating panel backed by a
CAMetalLayer. Opening and closing animate scale, translation, and opacity in
the draw list, driven by a display link that stays paused whenever the panel is
idle. AppKit supplies only the status item, the window surface, and input
events.

Sampling runs on a worker thread and reaches the UI as finished snapshots, so
opening the panel never waits on a scan of the process table. The list
refreshes on every sampling tick, which `interval_seconds` controls.

## Configuration

Defaults live in `config.odin`; override fields in
`~/Library/Application Support/hw_activity_monitor/config.json` (absent fields keep
their default):

```json
{
  "interval_seconds": 5,
  "window_seconds": 600,
  "cpu_percent": 60,
  "memory_mb": 4096,
  "sustained_seconds": 300,
  "cooldown_seconds": 1800,
  "safelist": ["odin", "clang", "swiftc", "xcodebuild", "zig"],
  "show_cpu": true,
  "show_memory": true,
  "show_window_cpu": true,
  "show_window_memory": true,
  "auto_update": true
}
```

- `interval_seconds` is how often the process table is sampled.
- `window_seconds` is the rolling history window the panel's trend columns
  summarize (default ten minutes; clamped to 60 s–24 h).
- `cpu_percent` is a budget per executable name summed over its processes, in
  percent of one core. Set 150 to catch only multi-instance leaks.
- `memory_mb` is a footprint budget per executable name summed over its
  processes, in binary megabytes. `0` disables memory alerts; otherwise values
  are clamped to 64–1048576. The panel's 1 GB inclusion floor is independent of
  this setting.
- `sustained_seconds` must pass before the first banner; `cooldown_seconds`
  gates repeat banners while the group stays hot. Both windows apply to the CPU
  and memory budgets alike.
- `safelist` entries are case-sensitive substrings of the executable name.
  Defaults cover compilers and VM helpers because builds legitimately peg every
  core and a VM holds its assigned RAM. `hw_activity_monitor` itself is always
  safelisted.
- `show_*` keys pick the panel's four stat columns: instant CPU, instant
  memory, windowed CPU average, and windowed memory change.
- `auto_update` lets the installed app update itself from GitHub releases;
  `false` keeps it on the installed build until you run `./install.sh` again.

The settings modal edits `window_seconds`, `interval_seconds`, and the
`show_*` keys; everything else stays file-edited.

## Updates

The installed app updates itself from GitHub releases. At startup and once a
day it fetches the latest release, compares versions, and if newer downloads the
bundle, verifies the SHA-256 published beside the archive, checks the code
signature and the bundle's own version, then swaps the bundle in place —
keeping the previous one as `hw_activity_monitor.app.backup` — and restarts
through launchd. Nothing from the download runs before the swap; the checksum
and signature are the gate.

- Attempts land in the event log: `update_available`, `update_installed`,
  `update_failed` (with the failing stage). A missing release or no network is
  not a failure and stays silent.
- Development binaries never update themselves: only an executable inside a
  `.app` is replaced, so `build/hw_activity_monitor` is safe to run.
- **Check for Updates** in the status menu runs one check immediately.
- Cutting a release: bump `VERSION` in `version.odin`, commit, then run
  `./release.sh`. It builds the bundle, zips it with a `.sha256`, and publishes
  a GitHub release whose asset names (`hw_activity_monitor-<version>.zip` and
  `.zip.sha256`) are the updater's contract.

The trust anchor is the GitHub repository over TLS: the checksum travels in the
same release as the archive, so it protects against a corrupted download, not
against a compromised repository.

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
{"time":"2026-09-18T07:48:15Z","event":"alert","kind":"memory","name":"yes","processes":1,"cpu_percent":100.0,"memory_bytes":5368709120,"sustained_seconds":11,"pids":[98862],"notified":true}
```

Events: `started` (pid and effective config), `ui_ready` (first snapshot
applied to the menu bar), `alert` (kind `cpu` or `memory`, name, process count,
group CPU percent, footprint bytes, sustained seconds, pids, whether a banner
was requested), `settings_saved` (the window, interval, and column selection
the worker picked up), `panel_geometry` (a panel window or drawable size that
disagreed with the layout; the signature of a stale frame), `quit`,
`update_available`, `update_installed`, `update_failed` (with the stage),
`notification_authorization` (granted, or the error), and `notification_failed`
(the API error). Events are rare — one per alert episode — so the file is not
rotated.

```sh
jq -c 'select(.event=="alert")' ~/Library/Logs/hw_activity_monitor.jsonl
jq -r 'select(.event=="alert") | [.time,.name,.processes,.cpu_percent] | @tsv' ~/Library/Logs/hw_activity_monitor.jsonl
```

launchd's stdout/stderr file (`~/Library/Logs/hw_activity_monitor.launchd.log`)
keeps crash output.
