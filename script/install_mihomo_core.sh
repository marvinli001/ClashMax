#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/Resources/Core"
MANIFEST="$CORE_DIR/mihomo-manifest.json"
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

/usr/bin/python3 - "$MANIFEST" <<'PY' | while IFS=$'\t' read -r name checksum; do
import json
import sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    manifest = json.load(f)
for asset in manifest["assets"]:
    print(f'{asset["name"]}\t{asset["sha256"]}')
PY
  case "$name" in
    *arm64*) target="$CORE_DIR/mihomo-darwin-arm64" ;;
    *amd64*) target="$CORE_DIR/mihomo-darwin-amd64" ;;
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

  /usr/bin/gunzip -c "$archive" > "$target"
  /bin/chmod 0755 "$target"
  echo "installed $target"
done
