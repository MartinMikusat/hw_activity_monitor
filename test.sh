#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "$ROOT/../odin_libraries" && pwd)
BUILD="$ROOT/build"
mkdir -p "$BUILD"
cd "$BUILD"

hw-odin test "$ROOT" \
  -define:ODIN_TEST_THREADS=1 \
  -collection:hw_clay="$ODIN_LIBS/hw_clay" \
  -collection:ui_framework="$ODIN_LIBS/hw_odin_ui_framework" \
  -extra-linker-flags:"-framework AppKit -framework Foundation -framework UserNotifications -framework Metal -framework QuartzCore -framework CoreText -framework CoreGraphics"
"$ROOT/build.sh" release >/dev/null
echo "[hw_activity_monitor] tests passed"
