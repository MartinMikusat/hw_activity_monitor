# hw_activity_monitor

Standalone macOS watchdog daemon (package `activity_monitor`), notify-only: it
reports runaway CPU and memory and never kills anything.

- Build with `./build.sh [debug|release]`. Test with `./test.sh`. Install and
  remove with `./install.sh` / `./uninstall.sh`.
- UI: `ui.odin` owns the status item and the snapshot model; `panel.odin` owns
  the clay layout and the draw call; `panel_window.odin` owns the NSPanel,
  CAMetalLayer, input, and the display-link clock; `panel_animation.odin` is
  the pure open/close math. The main thread only draws; `monitor_tick` runs on
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
  frame's element boxes, so the panel must be settled (visible, not animating)
  for a click to count.
- Panel rows are ranked, not reordered, as data changes: `ui_build_rows` ranks
  groups and their processes by cumulative urgency (the larger of the windowed
  CPU share and the footprint share of their budgets) and stamps `key`, `pid`,
  and `rank` on every row. The display order is main-thread state
  (`Panel_Order` in ui.odin): `ui_order_rows` rewrites each snapshot into that
  order, appending new groups at the bottom and dropping names that have been
  absent past the history window, and `ui_sort_now` (the Sort button) adopts
  the rank order. Never sort rows in the worker: the list must not move without
  the operator asking.
- The status item's right-click menu lives in `menu.odin` (AppKit NSMenu, the
  one place AppKit owns content because the status item is AppKit's). Its Quit
  boots out the LaunchAgent before exiting: `KeepAlive` would otherwise restart
  the daemon immediately, so a plain exit is not a quit.
- The panel owns its CAMetalLayer geometry. `panel_sync_layer` sets the
  contents scale, layer frame, and drawable size; it runs whenever the window
  frame changes and again before every `nextDrawable`, because a drawable
  acquired before the size is set is a frame behind and the layer would present
  a surface sized for the previous content. Never set the drawable size after
  acquiring. `panel_mark_dirty` defers the draw to the next main-queue turn
  (coalesced) so it cannot race a window resize; while a draw is in flight it
  only sets `draw_dirty`, and pointer/click handling runs before the drawable is
  acquired. Settings stay open through the close animation and close only after
  the window is ordered out, so dismissing the panel never flashes the list.
  `panel_check_geometry` logs a `panel_geometry` event when the window or
  drawable height disagrees with the layout height: that mismatch is the
  signature of a stale frame, and the event keeps the numbers for next time.
- The panel draws with hw_clay + `hw_clay:ui_framework` (CoreText, draw list,
  Metal); the build needs the `hw_clay` and `ui_framework` collections. Do not
  reintroduce AppKit view hierarchies for the panel content: layout, text,
  scrolling, and the animation all run through the draw list. Push opacity and
  transform around `render_commands` (draw.push_opacity/push_transform). The
  display link stays paused unless animating or a scroll is settling.
- This panel is the reference implementation for the global Odin rule "own the
  stack: native frameworks are a last resort" (`.agents/skills/odin/SKILL.md`).
- `core:thread.create` returns a *suspended* thread: always follow it with
  `thread.start`; a second argument to `create` is the priority, not user data.
- Panel rows come from `ui_build_rows` (ui.odin), which is pure apart from its
  allocator and covered by `ui_test.odin`. Only rows cut by the per-group limit
  get a "… and N more" note. `panel_animation_test.odin` covers the curve and
  transform.
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
  `quit`, `notification_authorization`, `notification_failed`. Crash output
  stays in `~/Library/Logs/hw_activity_monitor.launchd.log`.
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
