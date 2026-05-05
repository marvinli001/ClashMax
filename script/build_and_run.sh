#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ClashMax"
BUNDLE_ID="io.github.clashmax.ClashMax"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/ClashMaxLocal"
DERIVED_DATA="${CLASHMAX_DERIVED_DATA:-$DEFAULT_DERIVED_DATA}"
APP_BUNDLE="$DERIVED_DATA/Build/Products/Debug/$APP_NAME.app"
DESTINATION="${CLASHMAX_BUILD_DESTINATION:-generic/platform=macOS}"

detect_codesigning_identity() {
  if [[ -n "${CLASHMAX_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CLASHMAX_CODESIGN_IDENTITY"
    return 0
  fi

  local identity
  identity="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ || /"Developer ID Application:/ { print $2; exit }')"
  printf '%s\n' "$identity"
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$APP_BUNDLE"

xcodebuild \
  -project "$ROOT_DIR/ClashMax.xcodeproj" \
  -scheme "$APP_NAME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

SIGNING_IDENTITY="$(detect_codesigning_identity || true)"
if [[ -n "$SIGNING_IDENTITY" ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
    --entitlements "$ROOT_DIR/Config/ClashMaxHelper.entitlements" \
    "$APP_BUNDLE/Contents/Library/LaunchServices/ClashMaxHelper"

  for nested_binary in \
    "$APP_BUNDLE/Contents/MacOS/ClashMax.debug.dylib" \
    "$APP_BUNDLE/Contents/MacOS/__preview.dylib"
  do
    if [[ -f "$nested_binary" ]]; then
      codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$nested_binary"
    fi
  done

  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none \
    --entitlements "$ROOT_DIR/Config/ClashMax.entitlements" \
    "$APP_BUNDLE"
else
  echo "warning: no Apple Development or Developer ID signing identity found; TUN helper registration will not work with ad-hoc signing." >&2
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
