#!/bin/sh
# release.sh [version]
#
# Builds the release bundle, zips it with a SHA-256 checksum, and publishes a
# GitHub release. Without an argument the version comes from version.odin, which
# must already hold the new version: bump it, commit, then run this.
#
# The installed app checks the latest release and updates itself, so the asset
# names and the checksum file are part of that contract:
#   hw_activity_monitor-<version>.zip
#   hw_activity_monitor-<version>.zip.sha256
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION=${1:-$(sed -n 's/^VERSION :: "\(.*\)"/\1/p' "$ROOT/version.odin")}
if [ -z "$VERSION" ]; then
	echo "[release] cannot read VERSION from version.odin" >&2
	exit 1
fi

if [ -n "$(git -C "$ROOT" status --porcelain)" ]; then
	echo "[release] warning: the working tree has uncommitted changes" >&2
fi

STAGE="$ROOT/build/release"
APP="$STAGE/hw_activity_monitor.app"
ZIP_NAME="hw_activity_monitor-$VERSION.zip"
ZIP="$STAGE/$ZIP_NAME"

"$ROOT/build.sh" release
rm -rf "$STAGE"
mkdir -p "$STAGE"
"$ROOT/bundle.sh" "$APP" "$ROOT/build/hw_activity_monitor" "$VERSION"

# ditto keeps the bundle's signature and metadata intact.
ditto -c -k --keepParent "$APP" "$ZIP"
(
	cd "$STAGE"
	shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256"
)

gh release create "v$VERSION" "$ZIP" "$ZIP.sha256" \
	--title "hw_activity_monitor $VERSION" \
	--notes "Apple Silicon app bundle. Installed copies update themselves from this release; the checksum is in $(basename "$ZIP").sha256."

echo "[release] published v$VERSION ($ZIP_NAME)"
