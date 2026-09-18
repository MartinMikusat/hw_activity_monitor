#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD="$ROOT/build"
mkdir -p "$BUILD"
cd "$BUILD"

hw-odin test "$ROOT" -define:ODIN_TEST_THREADS=1
"$ROOT/build.sh" release >/dev/null
echo "[hw_activity_monitor] tests passed"
