#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /path/to/ClashMax.app [output-directory]" >&2
  exit 2
fi

APP_PATH="$1"
OUTPUT_DIR="${2:-dist/sparkle}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "missing app bundle: $APP_PATH" >&2
  exit 1
fi

INFO_PLIST="$APP_PATH/Contents/Info.plist"
if [[ ! -f "$INFO_PLIST" ]]; then
  echo "missing Info.plist: $INFO_PLIST" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
ARCHIVE_NAME="ClashMax-${VERSION}.zip"
ARCHIVE_PATH="$OUTPUT_DIR/$ARCHIVE_NAME"

mkdir -p "$OUTPUT_DIR"
rm -f "$ARCHIVE_PATH"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

echo "created $ARCHIVE_PATH"
echo "version $VERSION build $BUILD"
echo "next: create GitHub release v$VERSION and upload $ARCHIVE_NAME"
