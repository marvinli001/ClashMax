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
# While the structured-logging work is adding Swift files, the project has to be
# regenerated under the guard rather than built directly. Callers inject that wrapper
# through CLASHMAX_XCODEBUILD_WRAPPER; it takes the same arguments as xcodebuild.
XCODEBUILD="${CLASHMAX_XCODEBUILD_WRAPPER:-xcodebuild}"

"$XCODEBUILD" test \
  -project ClashMax.xcodeproj \
  -scheme ClashMax \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/LocalizationTests
