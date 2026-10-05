#!/bin/sh
# Development watcher: owns one debug instance of the daemon, rebuilds on
# source changes and replaces the process only after a successful build.
#
# The installed LaunchAgent is booted out while the watcher runs (two daemons
# would show two status items and double every alert) and bootstrapped again on
# exit. The dev binary runs bare, outside a .app, so the updater never touches
# it; notifications fall back to osascript, so test those through ./install.sh.
set -u

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ODIN_LIBS=$(CDPATH= cd -- "$ROOT/../odin_libraries" && pwd)
BUILD="$ROOT/build"
NAME=hw_activity_monitor
LABEL=com.halwayland.hw_activity_monitor
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
MODE=${1:-debug}
case "$MODE" in
  debug|release) ;;
  *)
    echo "usage: ./dev.sh [debug|release]" >&2
    exit 2
    ;;
esac

EXECUTABLE="$BUILD/$NAME"
DSYM="$EXECUTABLE.dSYM"
LOCK="$BUILD/dev-watcher.lock"
WATCHER_PID_FILE="$LOCK/watcher.pid"
APP_PID_FILE="$LOCK/app.pid"
LOG_DIR="$BUILD/logs/$MODE"
RSS_LIMIT_MB=${HW_NATIVE_RSS_LIMIT_MB:-2048}
RSS_OVER_LIMIT_COUNT=0
APP_PID=""
APP_LOG=""
AGENT_WAS_LOADED=false

case "$RSS_LIMIT_MB" in
  ''|0|*[!0-9]*)
    echo "HW_NATIVE_RSS_LIMIT_MB must be a positive integer" >&2
    exit 2
    ;;
esac

# Sources only: the build directory holds the binary, dSYM and metallib, which
# change on every build and would retrigger the watcher forever.
fingerprint() {
  find "$ROOT" "$ODIN_LIBS/hw_clay" "$ODIN_LIBS/hw_odin_ui_framework" "$ODIN_LIBS/hw_odin_ui_components" \
    -path "$BUILD" -prune -o \
    -type f \( -name '*.odin' -o -name '*.m' -o -name '*.h' -o -name '*.metal' -o -name '*.plist' \) \
    -print0 2>/dev/null |
    xargs -0 stat -f '%m:%z:%N' 2>/dev/null
  stat -f '%m:%z:%N' "$ROOT/build.sh" "$ROOT/dev.sh" 2>/dev/null
}

process_ids_for_executable() {
  ps -axo pid=,comm= | awk -v executable="$EXECUTABLE" '$2 == executable {print $1}'
}

stop_pid() {
  target_pid=$1
  kill -0 "$target_pid" 2>/dev/null || return 0
  kill "$target_pid" 2>/dev/null || true
  attempts=0
  while kill -0 "$target_pid" 2>/dev/null && [ "$attempts" -lt 40 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  if kill -0 "$target_pid" 2>/dev/null; then
    kill -KILL "$target_pid" 2>/dev/null || true
  fi
}

stop_owned_processes() {
  for target_pid in $(process_ids_for_executable); do
    stop_pid "$target_pid"
  done
}

suspend_installed_agent() {
  if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
    AGENT_WAS_LOADED=true
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    printf '[%s] installed agent stopped until the watcher exits\n' "$NAME"
  fi
}

resume_installed_agent() {
  if [ "$AGENT_WAS_LOADED" = true ] && [ -f "$PLIST" ]; then
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null ||
      printf '[%s] could not restart the installed agent; run ./install.sh\n' "$NAME" >&2
  fi
}

launch_app() {
  mkdir -p "$LOG_DIR"
  APP_LOG="$LOG_DIR/$(date '+%Y%m%d-%H%M%S').log"
  env MTL_DEBUG_LAYER=1 "$EXECUTABLE" >>"$APP_LOG" 2>&1 &
  APP_PID=$!
  printf '%s\n' "$APP_PID" > "$APP_PID_FILE"
  RSS_OVER_LIMIT_COUNT=0
  printf '[%s] launched pid %s (%s), log %s\n' "$NAME" "$APP_PID" "$MODE" "$APP_LOG"
}

archive_crash() {
  exit_status=$1
  archive="$BUILD/crashes/$MODE/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$archive"
  cp "$EXECUTABLE" "$archive/$NAME"
  [ -d "$DSYM" ] && cp -R "$DSYM" "$archive/"
  [ -f "$APP_LOG" ] && cp "$APP_LOG" "$archive/"
  latest_report=$(find "$HOME/Library/Logs/DiagnosticReports" -maxdepth 1 -type f -name "$NAME*.ips" -print 2>/dev/null |
    while IFS= read -r report; do stat -f '%m:%N' "$report"; done | sort -rn | sed -n '1s/^[0-9]*://p')
  [ -n "$latest_report" ] && [ -f "$latest_report" ] && cp "$latest_report" "$archive/"
  printf '[%s] process exited with status %s; archived diagnostics at %s\n' "$NAME" "$exit_status" "$archive" >&2
}

capture_memory_diagnostics() {
  diagnostics="$BUILD/diagnostics/$MODE/$(date '+%Y%m%d-%H%M%S')"
  mkdir -p "$diagnostics"
  vmmap -summary "$APP_PID" > "$diagnostics/vmmap.txt" 2>&1 || true
  leaks "$APP_PID" > "$diagnostics/leaks.txt" 2>&1 || true
  printf '[%s] captured memory diagnostics at %s\n' "$NAME" "$diagnostics" >&2
}

check_memory_limit() {
  rss_kb=$(ps -o rss= -p "$APP_PID" 2>/dev/null | tr -d ' ')
  case "$rss_kb" in ''|*[!0-9]*) return ;; esac
  if [ "$rss_kb" -gt $((RSS_LIMIT_MB * 1024)) ]; then
    RSS_OVER_LIMIT_COUNT=$((RSS_OVER_LIMIT_COUNT + 1))
    [ "$RSS_OVER_LIMIT_COUNT" -eq 2 ] && capture_memory_diagnostics
  else
    RSS_OVER_LIMIT_COUNT=0
  fi
}

rebuild_and_launch() {
  printf '\n[%s] rebuilding %s...\n' "$NAME" "$MODE"
  if ! "$ROOT/build.sh" "$MODE"; then
    printf '[%s] build failed; keeping pid %s running\n' "$NAME" "${APP_PID:-none}" >&2
    return 1
  fi
  if [ -n "$APP_PID" ]; then
    stop_pid "$APP_PID"
    wait "$APP_PID" 2>/dev/null || true
  fi
  stop_owned_processes
  launch_app
}

cleanup() {
  status=$?
  trap - INT TERM EXIT
  if [ -n "$APP_PID" ]; then
    stop_pid "$APP_PID"
    wait "$APP_PID" 2>/dev/null || true
  fi
  stop_owned_processes
  rm -f "$APP_PID_FILE" "$WATCHER_PID_FILE"
  rmdir "$LOCK" 2>/dev/null || true
  resume_installed_agent
  exit "$status"
}

mkdir -p "$BUILD"
if ! mkdir "$LOCK" 2>/dev/null; then
  existing=$(sed -n '1p' "$WATCHER_PID_FILE" 2>/dev/null || true)
  if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
    printf '[%s] dev watcher already running as pid %s\n' "$NAME" "$existing"
    exit 0
  fi
  rm -f "$APP_PID_FILE" "$WATCHER_PID_FILE"
  rmdir "$LOCK" 2>/dev/null || true
  mkdir "$LOCK"
fi

printf '%s\n' "$$" > "$WATCHER_PID_FILE"
trap cleanup INT TERM EXIT
suspend_installed_agent
stop_owned_processes
rebuild_and_launch || exit 1
LAST_FINGERPRINT=$(fingerprint | shasum | cut -d' ' -f1)

while :; do
  sleep 0.5
  if ! kill -0 "$APP_PID" 2>/dev/null; then
    wait "$APP_PID"
    app_status=$?
    rm -f "$APP_PID_FILE"
    if [ "$app_status" -ne 0 ]; then
      archive_crash "$app_status"
    else
      printf '[%s] process exited normally\n' "$NAME"
    fi
    exit "$app_status"
  fi

  check_memory_limit
  CURRENT_FINGERPRINT=$(fingerprint | shasum | cut -d' ' -f1)
  if [ "$CURRENT_FINGERPRINT" != "$LAST_FINGERPRINT" ]; then
    LAST_FINGERPRINT=$CURRENT_FINGERPRINT
    rebuild_and_launch || true
  fi
done
