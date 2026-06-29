#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Yap"
BUILD_PRODUCT="YapApp"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SOURCE_INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
SOURCE_ICON="$ROOT_DIR/Resources/AppIcon.icns"

kill_existing() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$BUILD_PRODUCT" >/dev/null 2>&1 || true
}

stage_bundle() {
  local built_binary
  swift build --configuration debug
  built_binary="$(swift build --show-bin-path)/$BUILD_PRODUCT"
  rm -rf "$APP_BUNDLE"
  mkdir -p "$APP_MACOS"
  mkdir -p "$APP_RESOURCES"
  cp "$built_binary" "$APP_BINARY"
  chmod +x "$APP_BINARY"
  cp "$SOURCE_INFO_PLIST" "$INFO_PLIST"
  cp "$SOURCE_ICON" "$APP_RESOURCES/AppIcon.icns"
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
