#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LABEL=com.halwayland.hw_activity_monitor
LEGACY_LABEL=com.halwayland.hw_cpu_watchdog
APP_DIR="$HOME/Applications/hw_activity_monitor.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/hw_activity_monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$ROOT/build.sh" release

# The daemon runs inside a minimal .app bundle: a bundle identifier is what
# lets UNUserNotificationCenter deliver banners attributed to this app.
mkdir -p "$APP_DIR/Contents/MacOS" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp -f "$ROOT/build/hw_activity_monitor" "$EXECUTABLE"

cat > "$APP_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>hw_activity_monitor</string>
	<key>CFBundleIdentifier</key>
	<string>$LABEL</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>hw_activity_monitor</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

# Ad-hoc signing: TCC and notification registration on recent macOS expect a
# code signature even for a locally built bundle.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

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
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "[hw_activity_monitor] installed $APP_DIR"
echo "[hw_activity_monitor] log: $HOME/Library/Logs/hw_activity_monitor.log"
