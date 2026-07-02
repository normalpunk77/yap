#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Yap"
BUILD_PRODUCT="YapApp"
# Diag logs under this subsystem (see Sources/YapCore/Diagnostics.swift).
BUNDLE_ID="com.yap"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Reuse the ONE canonical staging (scripts/build-app.sh): it signs the bundle with the
# stable "Yap Self-Signed" identity when present. The old private dist/ staging was a
# SECOND, unsigned copy of the app — a fresh TCC identity every run, competing
# permission grants, and Keychain re-prompts. One bundle path, one identity.
APP_BUNDLE="$ROOT_DIR/build/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

kill_existing() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$BUILD_PRODUCT" >/dev/null 2>&1 || true
}

stage_bundle() {
  bash "$ROOT_DIR/scripts/build-app.sh" debug
}

launch_bundle() {
  /usr/bin/open -n "$APP_BUNDLE"
}

wait_for_process() {
  local tries=50
  while (( tries > 0 )); do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
    tries=$((tries - 1))
  done
  return 1
}

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
  exit 2
}

kill_existing
stage_bundle

case "$MODE" in
  run)
    launch_bundle
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    launch_bundle
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    launch_bundle
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    launch_bundle
    wait_for_process
    ;;
  *)
    usage
    ;;
esac
