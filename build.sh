#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "$ROOT/../odin_libraries" && pwd)
BUILD="$ROOT/build"
mkdir -p "$BUILD"
# The app embeds this precompiled shader library (shaders.odin).
sh "$ODIN_LIBS/hw_odin_ui_framework/scripts/build-metallib.sh" "$BUILD/ui.metallib"
cd "$BUILD"

MODE=${1:-release}
case "$MODE" in
  debug)
    FLAGS="-debug -o:none"
    ;;
  release)
    FLAGS="-o:speed"
    # The release tool compiles the version and feed in; without them the app never updates.
    if [ -n "${HW_UPDATE_VERSION:-}" ]; then
      FLAGS="$FLAGS -define:HW_UPDATE_VERSION=$HW_UPDATE_VERSION -define:HW_UPDATE_FEED_URL=$HW_UPDATE_FEED_URL -define:HW_UPDATE_TEAM_ID=$HW_UPDATE_TEAM_ID"
    fi
    ;;
  *)
    echo "usage: ./build.sh [debug|release]" >&2
    exit 2
    ;;
esac

# The panel is laid out with hw_clay and drawn through the ui_framework
# renderer: CoreText text, draw list, Metal encoder. Foundation supplies
# NSBundle, AppKit the status item and panel window; UserNotifications the
# notification class lookups in notify.odin.
# shellcheck disable=SC2086
hw-odin build "$ROOT" $FLAGS \
  -collection:hw_clay="$ODIN_LIBS/hw_clay" \
  -collection:ui_framework="$ODIN_LIBS/hw_odin_ui_framework" \
  -collection:hw_odin_ui_components="$ODIN_LIBS/hw_odin_ui_components" \
  -collection:native_update="$ODIN_LIBS/hw_odin_native_update" \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework UserNotifications -framework ServiceManagement -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics" \
  -out:"$BUILD/hw_activity_monitor"
echo "[hw_activity_monitor] built $BUILD/hw_activity_monitor ($MODE)"
if [ "$MODE" = "release" ]; then
  # The release tool signs, notarizes and packages this bundle.
  rm -rf "$BUILD/hw_activity_monitor-release.app"
  "$ROOT/bundle.sh" "$BUILD/hw_activity_monitor-release.app" "$BUILD/hw_activity_monitor" "${HW_UPDATE_VERSION:-0.0.0}"
fi
