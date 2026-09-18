# hw_activity_monitor

Standalone macOS watchdog daemon (package `activity_monitor`), notify-only: it
reports runaway CPU and never kills anything.

- Build with `./build.sh [debug|release]`. Test with `./test.sh`. Install and
  remove with `./install.sh` / `./uninstall.sh`.
- Design: `sampler.odin` (libproc), `rules.odin` (pure rule engine,
  `rules_test.odin` covers it), `config.odin`, `main.odin`, `log.odin`.
- LaunchAgent label `com.halwayland.hw_activity_monitor`; install.sh builds the
  minimal `~/Applications/hw_activity_monitor.app` bundle and loads the agent.
- Event log: append-only JSONL at `~/Library/Logs/hw_activity_monitor.jsonl`,
  one object per line, written by `log.odin`. This is the agent-facing record;
  do not turn it into a rewritten snapshot or add high-frequency sampling
  events. Events: `started`, `alert`, `notification_authorization`,
  `notification_failed`. Crash output stays in
  `~/Library/Logs/hw_activity_monitor.launchd.log`.
- Sampling uses libproc bindings from `core:sys/darwin/proc.odin`
  (`proc_listallpids`, `proc_pid_rusage`, `proc_pidpath`). Do not replace this
  with parsing `ps pcpu`: that is a lifetime average and hides recent load.
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
  each must alert as 240%, not three times at 80%.
