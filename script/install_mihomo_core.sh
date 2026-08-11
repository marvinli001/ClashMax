#!/usr/bin/env bash
set -euo pipefail

# Downloads the upstream Mihomo release assets and merges them into a single
# universal binary at Resources/Core/mihomo.
#
# The merge is not cosmetic. macOS 26.4 and later warn users when an app bundle
# contains a Mach-O without an arm64 slice ("Intel app support is ending soon"),
# and it attributes the warning to the containing app even when that binary is
# never executed. Shipping one universal core keeps Intel Macs working while
# leaving no Intel-only component in the bundle.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/Resources/Core"
MANIFEST="$CORE_DIR/mihomo-manifest.json"
TARGET="$CORE_DIR/mihomo"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ ! -f "$MANIFEST" ]]; then
  echo "missing manifest: $MANIFEST" >&2
  exit 1
fi

version="$(/usr/bin/python3 - "$MANIFEST" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f)["version"])
PY
)"

/usr/bin/python3 - "$MANIFEST" > "$TMP_DIR/assets.tsv" <<'PY'
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    manifest = json.load(f)
for asset in manifest["assets"]:
    print(f'{asset["name"]}\t{asset["sha256"]}')
PY

slices=()
while IFS=$'\t' read -r name checksum; do
  [[ -n "$name" ]] || continue
  case "$name" in
    *arm64*) slice="$TMP_DIR/mihomo-darwin-arm64" ;;
    *amd64*) slice="$TMP_DIR/mihomo-darwin-amd64" ;;
    *)
      echo "skip unknown asset: $name" >&2
      continue
      ;;
  esac

  url="https://github.com/MetaCubeX/mihomo/releases/download/$version/$name"
  archive="$TMP_DIR/$name"
  echo "downloading $url"
  /usr/bin/curl -L --fail --retry 3 --output "$archive" "$url"

  actual="$(/usr/bin/shasum -a 256 "$archive" | awk '{print $1}')"
  if [[ "$actual" != "$checksum" ]]; then
    echo "checksum mismatch for $name" >&2
    echo "expected: $checksum" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi

  /usr/bin/gunzip -c "$archive" > "$slice"
  slices+=("$slice")
done < "$TMP_DIR/assets.tsv"

if [[ ${#slices[@]} -eq 0 ]]; then
  echo "manifest listed no usable darwin assets" >&2
  exit 1
fi

/usr/bin/lipo -create "${slices[@]}" -output "$TARGET"
/bin/chmod 0755 "$TARGET"

archs="$(/usr/bin/lipo -archs "$TARGET")"
echo "installed $TARGET ($archs)"

case " $archs " in
  *" arm64 "*) ;;
  *)
    echo "merged core is missing the arm64 slice: $archs" >&2
    exit 1
    ;;
esac

# Older checkouts shipped one file per architecture. Leaving the Intel-only file
# behind would put it right back into the app bundle.
rm -f "$CORE_DIR/mihomo-darwin-arm64" "$CORE_DIR/mihomo-darwin-amd64"
