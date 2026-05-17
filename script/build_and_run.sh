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
SYSTEM_EXTENSION="$APP_BUNDLE/Contents/Library/SystemExtensions/io.github.clashmax.ClashMax.NetworkExtension.systemextension"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
rm -rf "$APP_BUNDLE"

xcodebuild \
  -project "$ROOT_DIR/ClashMax.xcodeproj" \
  -scheme "$APP_NAME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_signatures() {
  codesign --verify --strict --verbose=2 "$APP_BUNDLE"
  if [[ ! -d "$SYSTEM_EXTENSION" ]]; then
    echo "error: missing embedded Network Extension: $SYSTEM_EXTENSION" >&2
    return 1
  fi
  codesign --verify --strict --verbose=2 "$SYSTEM_EXTENSION"
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
    verify_signatures
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
