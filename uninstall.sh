#!/bin/sh
set -eu

LABEL=com.halwayland.hw_cpu_watchdog
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$HOME/.local/bin/hw_cpu_watchdog"
echo "[hw_cpu_watchdog] uninstalled (config and logs kept)"
