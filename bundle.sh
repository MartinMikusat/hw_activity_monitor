#!/bin/sh
# bundle.sh <app_dir> <binary> <version>
#
# Creates a minimal LSUIElement .app bundle around an already built binary and
# ad-hoc signs it. install.sh and release.sh share this so the installed app and
# the release artifact are the same shape.
set -eu

APP_DIR=$1
BINARY=$2
VERSION=$3
LABEL=com.halwayland.hw_activity_monitor
EXECUTABLE="$APP_DIR/Contents/MacOS/hw_activity_monitor"

mkdir -p "$APP_DIR/Contents/MacOS"
cp -f "$BINARY" "$EXECUTABLE"

# The bundle identifier is what lets UNUserNotificationCenter deliver banners
# attributed to this app; the version keys are read by the updater and shown by
# `--version`.
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
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

# Ad-hoc signing: TCC and notification registration on recent macOS expect a
# code signature even for a locally built bundle.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true
