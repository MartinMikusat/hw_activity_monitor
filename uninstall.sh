#!/bin/sh
set -eu

LABEL=com.halwayland.hw_activity_monitor
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$PLIST" "$HOME/.local/bin/hw_activity_monitor"
echo "[hw_activity_monitor] uninstalled (config and logs kept)"
