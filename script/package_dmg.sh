#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 /path/to/ClashMax.app [output-directory]" >&2
  exit 2
fi

APP_PATH="$1"
OUTPUT_DIR="${2:-dist/dmg}"

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
DMG_NAME="ClashMax-${VERSION}.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-dmg-package.XXXXXX")"
STAGED_APP_PATH="$STAGING_DIR/$(basename "$APP_PATH")"
trap 'rm -rf "$STAGING_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"
rm -f "$DMG_PATH"

/usr/bin/ditto --noextattr --norsrc "$APP_PATH" "$STAGED_APP_PATH"
ln -s /Applications "$STAGING_DIR/Applications"
/usr/bin/hdiutil create -quiet -srcfolder "$STAGING_DIR" -format UDZO -volname "ClashMax" "$DMG_PATH"

echo "created $DMG_PATH"
echo "version $VERSION build $BUILD"
echo "next: upload $DMG_NAME to the GitHub release as an optional installer asset"
