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

embedded_system_extension() {
  local system_extensions_dir="$APP_BUNDLE/Contents/Library/SystemExtensions"
  if [[ ! -d "$system_extensions_dir" ]]; then
    return 0
  fi

  /usr/bin/find "$APP_BUNDLE/Contents/Library/SystemExtensions" \
    -maxdepth 1 \
    -name "*.systemextension" \
    -print \
    -quit 2>/dev/null || true
}

verify_signature() {
  local artifact="$1"
  if [[ ! -e "$artifact" ]]; then
    echo "error: missing artifact for signature verification: $artifact" >&2
    exit 1
  fi

  /usr/bin/codesign --verify --strict --verbose=2 "$artifact"
}

require_signed_entitlement() {
  local artifact="$1"
  local entitlement="$2"
  local entitlements_file
  entitlements_file="$(/usr/bin/mktemp)"

  if ! /usr/bin/codesign -d --entitlements :- "$artifact" >"$entitlements_file" 2>/dev/null; then
    rm -f "$entitlements_file"
    echo "error: could not read signed entitlements from artifact: $artifact" >&2
    exit 1
  fi

  if ! /usr/bin/grep -Fq "$entitlement" "$entitlements_file"; then
    rm -f "$entitlements_file"
    echo "error: signed artifact is missing entitlement marker '$entitlement': $artifact" >&2
    exit 1
  fi

  rm -f "$entitlements_file"
}

verify_signing() {
  local system_extension
  system_extension="$(embedded_system_extension)"
  if [[ -z "$system_extension" ]]; then
    echo "error: missing embedded system extension under $APP_BUNDLE/Contents/Library/SystemExtensions" >&2
    exit 1
  fi

  verify_signature "$APP_BUNDLE"
  require_signed_entitlement "$APP_BUNDLE" "com.apple.developer.system-extension.install"
  verify_signature "$system_extension"
  require_signed_entitlement "$system_extension" "app-proxy-provider-systemextension"
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
    verify_signing
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
