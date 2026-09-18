#!/bin/sh
set -eu

LABEL=com.halwayland.hw_activity_monitor
LEGACY_LABEL=com.halwayland.hw_cpu_watchdog

for stale_label in "$LABEL" "$LEGACY_LABEL"; do
	launchctl bootout "gui/$(id -u)/$stale_label" 2>/dev/null || true
done
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
rm -rf "$HOME/Applications/hw_activity_monitor.app"
rm -f "$HOME/.local/bin/hw_activity_monitor" "$HOME/.local/bin/hw_cpu_watchdog"
echo "[hw_activity_monitor] uninstalled (config and logs kept)"
