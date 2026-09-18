#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
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

# Foundation supplies NSBundle, UserNotifications the UN classes that
# notify.odin looks up through the Objective-C runtime at startup.
# shellcheck disable=SC2086
hw-odin build "$ROOT" $FLAGS \
  -extra-linker-flags:"-framework Foundation -framework UserNotifications" \
  -out:"$BUILD/hw_activity_monitor"
echo "[hw_activity_monitor] built $BUILD/hw_activity_monitor ($MODE)"
