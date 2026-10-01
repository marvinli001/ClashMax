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
#
# Every asset is checked against the sha256 in mihomo-manifest.json before it is
# unpacked, including one taken from MIHOMO_CORE_CACHE_DIR. That variable is
# optional: when set (CI points it at an actions/cache directory), downloaded
# archives are kept there and reused, so a cache hit skips the download but
# never the checksum.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="$ROOT_DIR/Resources/Core"
MANIFEST="$CORE_DIR/mihomo-manifest.json"
TARGET="$CORE_DIR/mihomo"
TMP_DIR="$(mktemp -d)"
CACHE_DIR="${MIHOMO_CORE_CACHE_DIR:-}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  # GitHub Actions turns this into an annotation on the manifest, so a red run
  # names the file to fix instead of only the step that failed.
  if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
    echo "::error file=Resources/Core/mihomo-manifest.json::$1"
  fi
  echo "error: $1" >&2
  exit 1
}

sha256_of() {
  /usr/bin/shasum -a 256 "$1" | awk '{print $1}'
}

if [[ -n "$CACHE_DIR" ]]; then
  mkdir -p "$CACHE_DIR"
fi

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

  if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
    fail "manifest sha256 for $name is not 64 lowercase hex characters: '$checksum'"
  fi

  url="https://github.com/MetaCubeX/mihomo/releases/download/$version/$name"
  archive="$TMP_DIR/$name"
  cached="${CACHE_DIR:+$CACHE_DIR/$name}"
  if [[ -n "$cached" && -f "$cached" ]]; then
    if [[ "$(sha256_of "$cached")" == "$checksum" ]]; then
      echo "using cached $cached"
      cp "$cached" "$archive"
    else
      # A stale or truncated cache entry; the download below is checked again.
      echo "discarding cached $cached: it does not match the manifest"
      rm -f "$cached"
    fi
  fi
  if [[ ! -f "$archive" ]]; then
    echo "downloading $url"
    /usr/bin/curl -L --fail --retry 3 --output "$archive" "$url" \
      || fail "could not download $url"
  fi

  actual="$(sha256_of "$archive")"
  if [[ "$actual" != "$checksum" ]]; then
    fail "checksum mismatch for $name: the manifest expects $checksum but the downloaded asset is $actual. Either the manifest was edited by hand or the upstream asset changed; refresh the sha256 from the release's GitHub API asset digest, never from the downloaded file."
  fi
  if [[ -n "$cached" && ! -f "$cached" ]]; then
    cp "$archive" "$cached"
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
