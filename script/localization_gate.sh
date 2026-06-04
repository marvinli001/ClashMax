#!/bin/sh
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMPDIR_LOCAL="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-localization.XXXXXX")"

cleanup() {
  rm -rf "$TMPDIR_LOCAL"
}
trap cleanup EXIT

cd "$ROOT_DIR"

jq empty Resources/Localizable.xcstrings
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$TMPDIR_LOCAL" --dry-run
xcodebuild test \
  -project ClashMax.xcodeproj \
  -scheme ClashMax \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/LocalizationTests
