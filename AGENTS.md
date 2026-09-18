# hw_activity_monitor

Standalone macOS watchdog daemon (package `activity_monitor`), notify-only: it
reports runaway CPU and never kills anything.

- Build with `./build.sh [debug|release]`. Test with `./test.sh`. Install and
  remove with `./install.sh` / `./uninstall.sh`.
- LaunchAgent label `com.halwayland.hw_activity_monitor`; binary at
  `~/.local/bin/hw_activity_monitor`; log at `~/Library/Logs/hw_activity_monitor.log`.
- Sampling uses libproc bindings from `core:sys/darwin/proc.odin`
  (`proc_listallpids`, `proc_pid_rusage`, `proc_pidpath`). Do not replace this
  with parsing `ps pcpu`: that is a lifetime average and hides recent load.
- `rules.odin` is the pure rule engine and must stay free of I/O and clocks
  past the monotonic timestamp passed in; `rules_test.odin` covers it.
- Notifications go through `osascript` because a bare binary cannot use
  `UNUserNotificationCenter` without an app bundle. Banners appear as Script
  Editor. If attribution or action buttons become necessary, add a minimal
  `.app` wrapper and lift the notification code from
  `hw_agents/archive/launcher-scheduler/agent_scheduler_darwin.odin`.
- Detection is name-grouped on purpose: three instances of one binary at 80%
  each must alert as 240%, not three times at 80%.
