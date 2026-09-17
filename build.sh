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

# shellcheck disable=SC2086
hw-odin build "$ROOT" $FLAGS -out:"$BUILD/hw_cpu_watchdog"
echo "[hw_cpu_watchdog] built $BUILD/hw_cpu_watchdog ($MODE)"
