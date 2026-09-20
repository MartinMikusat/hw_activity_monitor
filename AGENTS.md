# hw_activity_monitor

Standalone macOS watchdog daemon (package `activity_monitor`), notify-only: it
reports runaway CPU and memory and never kills anything.

- Build with `./build.sh [debug|release]`. Test with `./test.sh`. Install and
  remove with `./install.sh` / `./uninstall.sh`.
- UI: `ui.odin` owns the status item and the snapshot model; `panel.odin` owns
  the clay layout and the draw call; `panel_window.odin` owns the NSPanel,
  CAMetalLayer, input, and the display-link clock. The main thread only draws; `monitor_tick` runs on
  a worker thread (main.odin), builds a `Ui_Snapshot`, and posts it with
  `dispatch_async_f` to the main queue, which frees the snapshot it replaced.
  Never sample or touch AppKit off the main thread; if `ui_start` fails,
  `run_headless` keeps alerting with no UI.
- Settings live in `settings.odin`: the in-panel modal edits the history window,
  the sampling interval, and the four stat columns. Saving writes config.json
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
  scaled to its own peak, over a faint baseline, with a dot on the peak sample;
  the value and peak labels are clay text floating in the body, so the layout
  positions them. `panel_test.odin` checks the block and chart geometry against a
  real headless clay layout, which is how the dashboard is verified without
  driving the UI.
- The status item's right-click menu lives in `menu.odin` (AppKit NSMenu, the
  one place AppKit owns content because the status item is AppKit's). Its Quit
  boots out the LaunchAgent before exiting: `KeepAlive` would otherwise restart
  the daemon immediately, so a plain exit is not a quit. Its "Check for Updates"
  starts one check on its own thread.
- Updates live in `update.odin` and version identity in `version.odin` (the
  single source; `install.sh`, `release.sh`, and the updater all read it).
  `update_worker` checks the latest GitHub release at startup and daily on its
  own thread, then verifies the download's SHA-256, the bundle's code signature,
  and the bundle's `CFBundleShortVersionString` before swapping the `.app` in
  place (previous bundle kept as `.backup`) and restarting through launchd.
  Only executables inside a `.app` update themselves. `release.sh` (with
  `bundle.sh`) publishes the assets the updater expects by name; changing those
  names is a contract change. The log is guarded by a global mutex because the
  update thread is a second writer.
- Release only when the operator asks for it. The expected flow for a change is:
  implement it, commit, install it locally (`./install.sh`) and let the operator
  confirm the behavior on screen; bump `VERSION` and publish (`./release.sh`)
  only after that confirmation and only on an explicit request. A published
  release reaches every installed copy on its next check, so releasing is a
  distribution decision, not a commit step.
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
- The panel draws with hw_clay + `hw_clay:ui_framework` (CoreText, draw list,
  Metal); the build needs the `hw_clay` and `ui_framework` collections. Do not
  reintroduce AppKit view hierarchies for the panel content: layout, text, and
  scrolling all run through the draw list. The display link stays paused unless
  a scroll is settling.
- This panel is the reference implementation for the global Odin rule "own the
  stack: native frameworks are a last resort" (`.agents/skills/odin/SKILL.md`).
- `core:thread.create` returns a *suspended* thread: always follow it with
  `thread.start`; a second argument to `create` is the priority, not user data.
- Panel rows come from `ui_build_rows` (ui.odin), which is pure apart from its
  allocator and covered by `ui_test.odin`. Only rows cut by the per-group limit
  get a "… and N more" note.
- Design: `sampler.odin` (libproc), `rules.odin` (pure rule engine,
  `rules_test.odin` covers it), `config.odin`, `main.odin`, `log.odin`.
- LaunchAgent label `com.halwayland.hw_activity_monitor`; install.sh builds the
  minimal `~/Applications/hw_activity_monitor.app` bundle and loads the agent.
- Event log: append-only JSONL at `~/Library/Logs/hw_activity_monitor.jsonl`,
  one object per line, written by `log.odin`. This is the agent-facing record;
  do not turn it into a rewritten snapshot or add high-frequency sampling
  events. Events: `started`, `alert` (kind `cpu` or `memory`, name, processes,
  cpu_percent, memory_bytes, sustained_seconds, pids, notified),
  `settings_saved`, `panel_geometry` (a window/drawable size mismatch),
  `quit`, `update_available`, `update_installed`, `update_failed`,
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
- The bundle is `LSUIElement` and ad-hoc signed by install.sh. Do not switch it
  to `LSBackgroundOnly`: that build is refused notification authorization with
  "Notifications are not allowed for this application". Callbacks need the run
  loop pump in `wait_with_run_loop`.
- Detection is name-grouped on purpose: three instances of one binary at 80%
  each must alert as 240%, not three times at 80%. CPU and memory keep
  independent episodes per name: a dimension that drops below its budget resets
  even while the other stays hot.
