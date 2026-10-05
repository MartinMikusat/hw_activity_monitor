# hw_activity_monitor

Standalone macOS watchdog daemon (package `activity_monitor`), notify-only: it
reports runaway CPU and memory and never kills anything.

- Build with `./build.sh [debug|release]`. Test with `./test.sh`. Remove an
  installed copy with `./uninstall.sh`; there is no install script. `./dev.sh` is the development
  watcher: it boots out the installed LaunchAgent, runs one bare debug binary
  (outside a `.app`, so it never self-updates and notifications fall back to
  `osascript`), rebuilds on source changes, and restores the agent on exit.
- UI: `ui.odin` owns the status item and the snapshot model; `panel.odin` owns
  the clay layout and the draw call; `panel_window.odin` owns the NSPanel,
  CAMetalLayer, input, and the display-link clock. The main thread only draws; `monitor_tick` runs on
  a worker thread (main.odin), builds a `Ui_Snapshot`, and posts it with
  `dispatch_async_f` to the main queue, which frees the snapshot it replaced.
  Never sample or touch AppKit off the main thread; if `ui_start` fails,
  `run_headless` keeps alerting with no UI.
- Settings live in `settings.odin`: the in-panel modal edits the history window,
  the sampling interval, the five stat columns, and the theme (`System`, `Light`,
  `Dark`). The panel resolves the theme from the settings draft while the modal
  is open, so a choice previews at once, and from the running config otherwise;
  `config.json` stores it by name (`CONFIG_JSON_OPTIONS.use_enum_names`), and the
  status item keeps following the menu bar's own appearance rather than the
  panel's theme. Saving writes config.json
  and calls `monitor_request_config`, which stages the config under a mutex;
  the worker applies it at the start of its next tick, so the main thread never
  blocks and the history survives. `monitor.config` and `monitor.policy` are
  worker-owned after startup. Panel mouse and key events feed clay's pointer
  state and the `text_input` editing state; clicks resolve against the previous
  frame's element boxes, so the panel must be visible and settled for a click to
  count.
- Panel rows are ranked, not reordered, as data changes: `ui_build_rows` ranks
  groups and their processes by cumulative urgency (the larger of the windowed
  CPU share and the footprint share of their budgets) and stamps `key`, `pid`,
  and `rank` on every row. The display order is main-thread state
  (`Panel_Order` in ui.odin): `ui_order_rows` rewrites each snapshot into that
  order, appending new groups at the bottom and dropping names that have been
  absent past the history window, and `ui_sort_now` (the Sort button) adopts
  the rank order. Never sort rows in the worker: the list must not move without
  the operator asking.
- The maximized dashboard lays out one block per group: the group's rows in a
  text column, and a chart in a column a third of the panel's content wide that
  spans the block. A block is `panel_block_rows` tall — its own rows, at least
  `PANEL_CHART_MIN_ROWS` — so a short group gets blank rows and its chart always
  has room. `panel_draw_charts` draws the two series into the chart body after
  the clay commands (CPU in the text color, memory in the secondary color), each
  scaled to its own peak, over a faint baseline, with a dot on the peak sample.
  The values and peaks sit in a label column between the rows and the chart, one
  cell per series band so they never cover the series. `panel_test.odin` checks
  the block, column, label, and axis geometry against a real headless clay
  layout, which is how the dashboard is verified without driving the UI.
- The status item's right-click menu lives in `menu.odin` (AppKit NSMenu, the
  one place AppKit owns content because the status item is AppKit's). Its Quit
  boots out the LaunchAgent before exiting: `KeepAlive` would otherwise restart
  the daemon immediately, so a plain exit is not a quit. Its "Check for Updates"
  starts one check on its own thread.
- `login_item.odin` registers the app with `SMAppService` at startup (config key
  `launch_at_login`, default on) only when it runs inside `hw_activity_monitor.app`
  and launchd did not start it (`XPC_SERVICE_NAME`), so a LaunchAgent copy is
  never started twice.
- Updates match hw_fileManager: `update.odin` drives `hw_odin_native_update`
  (`-collection:native_update`), `version.odin` holds the compiled-in
  `HW_UPDATE_VERSION`, `HW_UPDATE_FEED_URL` and `HW_UPDATE_TEAM_ID` (`VERSION`
  is `dev` without them, and a build without them never updates). The worker
  checks `releases/latest/download/update.json` at startup and hourly on its own
  thread; the library verifies size, SHA-256 and a code requirement pinning the
  Developer ID team, bundle ID and version. A daemon has no quit to wait for, so
  a verified update is swapped in at once and launchd restarts it. Only a copy
  running as `hw_activity_monitor.app` updates; a local `build.sh` copy has no
  version and does not. The log is guarded by a global mutex because
  the update thread is a second writer.
- Release only when the operator asks for it, with the version they name:
  `python3 scripts/release_macos.py build <version> --notary-profile
  delta-support-native`, then `python3 scripts/release_macos.py publish
  dist.noindex/<version>` (clean, pushed commit; notarization uploads to Apple).
  The expected flow for a change is: implement it, commit, and let the
  operator install it and confirm the behavior on screen; release only after that
  confirmation. A published release reaches every installed copy on its next
  check, so releasing is a distribution decision, not a commit step. First
  install of a release: `ditto -x -k dist.noindex/<version>/hw_activity_monitor-<version>.zip
  ~/Applications`, then restart the agent.
- The panel owns its CAMetalLayer geometry. `panel_sync_layer` sets the
  contents scale, layer frame, and drawable size; it runs whenever the window
  frame changes and again before every `nextDrawable`, because a drawable
  acquired before the size is set is a frame behind and the layer would present
  a surface sized for the previous content. Never set the drawable size after
  acquiring. `panel_mark_dirty` defers the draw to the next main-queue turn
  (coalesced) so it cannot race a window resize; while a draw is in flight it
  only sets `draw_dirty`, and pointer/click handling runs before the drawable is
  acquired. The panel does not animate: it appears and disappears at once, and
  `setAnimationBehavior:` is None so AppKit cannot animate the window either. On
  show, the layer is filled before the window is ordered in and drawn again
  right after, because an off-screen layer may refuse a drawable; on hide the
  window is ordered out in the same turn and settings close with it.
  `panel_check_geometry` logs a `panel_geometry` event when the window or
  drawable height disagrees with the layout height: that mismatch is the
  signature of a stale frame, and the event keeps the numbers for next time.
- The panel draws with hw_clay + `ui_framework:clay` (CoreText, draw list,
  Metal); the build needs the `hw_clay` and `ui_framework` collections. Do not
  reintroduce AppKit view hierarchies for the panel content: layout, text, and
  scrolling all run through the draw list. The display link stays paused unless
  a scroll is settling.
- This panel is the reference implementation for the global Odin rule "own the
  stack: native frameworks are a last resort" (`.agents/skills/odin/SKILL.md`).
- `core:thread.create` returns a *suspended* thread: always follow it with
  `thread.start`; a second argument to `create` is the priority, not user data.
- Panel rows come from `ui_build_rows` (ui.odin), which is pure apart from its
  allocator, the display state it carries forward, and the clock passed in, and
  is covered by `ui_test.odin`. Only rows cut by the per-group limit get a
  "… and N more" note. Rows are sticky through `Ui_Display_State` (sampler-thread
  state in `Monitor_State`): a process that has had a row keeps it while it
  lives, and a group keeps the high-water number of process rows, filled from
  its ranked members when a row is freed by an exit, so the list does not shift
  as processes cross the display floors. The note is sticky too. Entries are
  pruned once their group has been gone for the history window, and the popover's
  height cap leaves room for the extra rows. A labels row under the header names
  the stat columns: it pushes the same cells as the data rows (and, in the
  maximized view, the same label and chart columns as a block) so every label
  lines up with the values under it.
- Design: `sampler.odin` (libproc), `process_detail.odin` (per-pid label from argv and cwd: script behind python/node, Chromium helper role, tool name for version-named binaries; read once per pid and cached), `gpu.odin` (IORegistry GPU time per pid,
  `gpu_test.odin` drives the real registry), `rules.odin` (pure rule engine,
  `rules_test.odin` covers it), `config.odin`, `main.odin`, `log.odin`.
- LaunchAgent label `com.halwayland.hw_activity_monitor`; `bundle.sh` builds the
  minimal `.app` bundle for the release tool.
- Event log: append-only JSONL at `~/Library/Logs/hw_activity_monitor.jsonl`,
  one object per line, written by `log.odin`. This is the agent-facing record;
  do not turn it into a rewritten snapshot or add high-frequency sampling
  events. Events: `started`, `alert` (kind `cpu` or `memory`, name, processes,
  cpu_percent, memory_bytes, sustained_seconds, pids, notified),
  `settings_saved`, `panel_geometry` (a window/drawable size mismatch),
  `quit`, `login_item_failed`, `update_available`, `update_installed`, `update_failed`,
  `notification_authorization`, `notification_failed`. Crash output stays in
  `~/Library/Logs/hw_activity_monitor.launchd.log`.
- Sampling uses libproc bindings from `core:sys/darwin/proc.odin`
  (`proc_listallpids`, `proc_pid_rusage`, `proc_pidpath`). `proc_pid_rusage`
  supplies both the cumulative CPU times and `ri_phys_footprint`, the memory
  number Activity Monitor shows. Do not replace this with parsing `ps pcpu`:
  that is a lifetime average and hides recent load.
- `rules.odin` must stay free of I/O and clocks past the monotonic timestamp
  passed in.
- Notifications post through `UNUserNotificationCenter` (the Objective-C
  helpers live in `darwin.odin`, mirroring `hw_calendar/darwin.odin`) and only
  work from inside the bundle. A bare binary falls back to `osascript`, which
  macOS usually drops; build.sh and test.sh link `-framework Foundation
  -framework UserNotifications` for the class lookups.
- The bundle is `LSUIElement` and ad-hoc signed by bundle.sh. Do not switch it
  to `LSBackgroundOnly`: that build is refused notification authorization with
  "Notifications are not allowed for this application". Callbacks need the run
  loop pump in `wait_with_run_loop`.
- Detection is name-grouped on purpose: three instances of one binary at 80%
  each must alert as 240%, not three times at 80%. CPU and memory keep
  independent episodes per name: a dimension that drops below its budget resets
  even while the other stays hot.
