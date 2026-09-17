#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LABEL=com.halwayland.hw_cpu_watchdog
BIN_DIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$ROOT/build.sh" release
mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp -f "$ROOT/build/hw_cpu_watchdog" "$BIN_DIR/hw_cpu_watchdog"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BIN_DIR/hw_cpu_watchdog</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ProcessType</key>
	<string>Background</string>
	<key>StandardOutPath</key>
	<string>$HOME/Library/Logs/hw_cpu_watchdog.launchd.log</string>
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/hw_cpu_watchdog.launchd.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "[hw_cpu_watchdog] installed $BIN_DIR/hw_cpu_watchdog"
echo "[hw_cpu_watchdog] log: $HOME/Library/Logs/hw_cpu_watchdog.log"
