#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LABEL=com.halwayland.hw_activity_monitor
LEGACY_LABEL=com.halwayland.hw_cpu_watchdog
APP_DIR="$HOME/Applications/hw_activity_monitor.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/hw_activity_monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$ROOT/build.sh" release

VERSION=$(sed -n 's/^VERSION :: "\(.*\)"/\1/p' "$ROOT/version.odin")
if [ -z "$VERSION" ]; then
	echo "[hw_activity_monitor] cannot read VERSION from version.odin" >&2
	exit 1
fi

# The daemon runs inside a minimal .app bundle: a bundle identifier is what
# lets UNUserNotificationCenter deliver banners attributed to this app.
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
"$ROOT/bundle.sh" "$APP_DIR" "$ROOT/build/hw_activity_monitor" "$VERSION"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$EXECUTABLE</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/hw_activity_monitor.launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/hw_activity_monitor.launchd.log</string>
</dict>
</plist>
EOF

# Replace any previous install, including the pre-rename daemon.
for stale_label in "$LABEL" "$LEGACY_LABEL"; do
	launchctl bootout "gui/$(id -u)/$stale_label" 2>/dev/null || true
done
rm -f "$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist" \
      "$HOME/.local/bin/hw_activity_monitor" \
      "$HOME/.local/bin/hw_cpu_watchdog" \
      "$HOME/Library/Logs/hw_cpu_watchdog.log" \
      "$HOME/Library/Logs/hw_cpu_watchdog.launchd.log"

# bootout returns before launchd has finished removing the old instance, so an
# immediate bootstrap can fail with a transient I/O error. Retry briefly.
attempt=1
until launchctl bootstrap "gui/$(id -u)" "$PLIST"; do
	if [ "$attempt" -ge 3 ]; then
		echo "[hw_activity_monitor] launchctl bootstrap failed" >&2
		exit 1
	fi
	attempt=$((attempt + 1))
	sleep 1
done

echo "[hw_activity_monitor] installed $APP_DIR"
echo "[hw_activity_monitor] events: $HOME/Library/Logs/hw_activity_monitor.jsonl"
