#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "$ROOT/../odin_libraries" && pwd)
BUILD="$ROOT/build"
mkdir -p "$BUILD"
cd "$BUILD"

MODE=${1:-release}
case "$MODE" in
  debug)
    FLAGS="-debug -o:none"
    ;;
  release)
    FLAGS="-o:speed"
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
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework UserNotifications -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics" \
  -out:"$BUILD/hw_activity_monitor"
echo "[hw_activity_monitor] built $BUILD/hw_activity_monitor ($MODE)"
