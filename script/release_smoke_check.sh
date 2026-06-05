#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_APP="/Applications/ClashMax.app"
DEFAULT_APPCAST="docs/appcast.xml"
DEFAULT_SPARKLE_DIR="dist/sparkle"
DEFAULT_REPORT_DIR="dist/release-smoke"
DEFAULT_SOAK_MINUTES=60
KEYCHAIN_SERVICE="io.github.clashmax.ClashMax"
HELPER_ID="io.github.clashmax.ClashMax.Helper"
NETWORK_EXTENSION_ID="io.github.clashmax.ClashMax.NetworkExtension"
SPARKLE_PLACEHOLDER="REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"

APP_BUNDLE="$DEFAULT_APP"
APPCAST_PATH="$DEFAULT_APPCAST"
SPARKLE_DIR="$DEFAULT_SPARKLE_DIR"
DMG_PATH=""
REPORT_DIR="$DEFAULT_REPORT_DIR"
LIVE_MODE=false
ALLOW_EMPTY_SUBSCRIPTIONS=false
SOAK_MINUTES="$DEFAULT_SOAK_MINUTES"

usage() {
  cat <<'USAGE'
usage: script/release_smoke_check.sh [options]

Options:
  --app /path/to/ClashMax.app
  --appcast docs/appcast.xml
  --sparkle-dir dist/sparkle
  --dmg dist/dmg/ClashMax-X.Y.Z.dmg
  --report-dir dist/release-smoke
  --preflight-only
  --live
  --soak-minutes 60
  --allow-empty-subscriptions
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      APP_BUNDLE="$2"
      shift 2
      ;;
    --appcast)
      APPCAST_PATH="$2"
      shift 2
      ;;
    --sparkle-dir)
      SPARKLE_DIR="$2"
      shift 2
      ;;
    --dmg)
      DMG_PATH="$2"
      shift 2
      ;;
    --report-dir)
      REPORT_DIR="$2"
      shift 2
      ;;
    --preflight-only)
      LIVE_MODE=false
      shift
      ;;
    --live)
      LIVE_MODE=true
      shift
      ;;
    --soak-minutes)
      SOAK_MINUTES="$2"
      shift 2
      ;;
    --allow-empty-subscriptions)
      ALLOW_EMPTY_SUBSCRIPTIONS=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$ROOT_DIR"
mkdir -p "$REPORT_DIR"
RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
REPORT_FILE="$REPORT_DIR/release-smoke-$RUN_ID.jsonl"
SUMMARY_FILE="$REPORT_DIR/release-smoke-$RUN_ID.summary.json"
EVIDENCE_DIR="$REPORT_DIR/release-smoke-$RUN_ID"
mkdir -p "$EVIDENCE_DIR"
: > "$REPORT_FILE"
SUBSCRIPTION_TMP="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-release-subscriptions.XXXXXX")"

cleanup() {
  rm -rf "$SUBSCRIPTION_TMP"
}
trap cleanup EXIT

FAILURES=0
WARNINGS=0
APP_VERSION=""
APP_BUILD=""

json_string() {
  /usr/bin/python3 - "$1" <<'PY'
import json
import sys
print(json.dumps(sys.argv[1]))
PY
}

record_event() {
  local event="$1"
  local status="$2"
  local message="$3"
  local details="{}"
  if [ "$#" -ge 4 ]; then
    details="$4"
  fi
  EVENT="$event" STATUS="$status" MESSAGE="$message" DETAILS="$details" /usr/bin/python3 - "$REPORT_FILE" <<'PY'
import datetime
import json
import os
import sys

details_raw = os.environ.get("DETAILS") or "{}"
try:
    details = json.loads(details_raw)
except json.JSONDecodeError:
    details = {"raw": details_raw}

payload = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "event": os.environ["EVENT"],
    "status": os.environ["STATUS"],
    "message": os.environ["MESSAGE"],
    "details": details,
}
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
PY

  printf '[%s] %s: %s\n' "$status" "$event" "$message"
  case "$status" in
    fail) FAILURES=$((FAILURES + 1)) ;;
    warn) WARNINGS=$((WARNINGS + 1)) ;;
  esac
}

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

run_check() {
  local event="$1"
  local critical="$2"
  shift 2
  local output="$EVIDENCE_DIR/$(safe_name "$event").txt"

  printf '$ %s\n' "$*" > "$output"
  if "$@" >> "$output" 2>&1; then
    record_event "$event" pass "command succeeded" "{\"output\":$(json_string "$output")}"
    return 0
  else
    local exit_code=$?
    local details
    details="{\"exit_code\":$exit_code,\"output\":$(json_string "$output")}"
    if [ "$critical" = "critical" ]; then
      record_event "$event" fail "command failed" "$details"
    else
      record_event "$event" warn "command failed" "$details"
    fi
    return "$exit_code"
  fi
}

require_path() {
  local event="$1"
  local path="$2"
  local kind="$3"
  if [ "$kind" = "dir" ] && [ -d "$path" ]; then
    record_event "$event" pass "directory exists" "{\"path\":$(json_string "$path")}"
    return 0
  fi
  if [ "$kind" = "file" ] && [ -f "$path" ]; then
    record_event "$event" pass "file exists" "{\"path\":$(json_string "$path")}"
    return 0
  fi
  record_event "$event" fail "missing $kind" "{\"path\":$(json_string "$path")}"
  return 1
}

sanitize_url() {
  /usr/bin/python3 - "$1" <<'PY'
import re
import sys
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

raw = sys.argv[1]
try:
    parts = urlsplit(raw)
except ValueError:
    print("<redacted>")
    sys.exit(0)

netloc = parts.hostname or ""
if parts.port:
    netloc += f":{parts.port}"

query = urlencode([(name, "<redacted>") for name, _ in parse_qsl(parts.query, keep_blank_values=True)])
path = re.sub(r"/[A-Za-z0-9_-]{16,}(?=/|$)", "/<redacted>", parts.path)
print(urlunsplit((parts.scheme, netloc, path, query, "")))
PY
}

read_info_plist() {
  local info_plist="$APP_BUNDLE/Contents/Info.plist"
  require_path "app.info_plist" "$info_plist" file || return 1

  if ! APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist" 2>/dev/null)"; then
    record_event "app.version" fail "CFBundleShortVersionString is unreadable" "{}"
    APP_VERSION="unknown"
  fi
  if ! APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist" 2>/dev/null)"; then
    record_event "app.build" fail "CFBundleVersion is unreadable" "{}"
    APP_BUILD="unknown"
  fi
  local feed_url
  feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$info_plist" 2>/dev/null || true)"
  local public_key
  public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$info_plist" 2>/dev/null || true)"

  VERSION="$APP_VERSION" BUILD="$APP_BUILD" FEED_URL="$feed_url" PUBLIC_KEY="$public_key" PLACEHOLDER="$SPARKLE_PLACEHOLDER" /usr/bin/python3 - "$REPORT_FILE" <<'PY'
import base64
import datetime
import json
import os
import sys

key = os.environ.get("PUBLIC_KEY", "").strip()
details = {
    "version": os.environ.get("VERSION"),
    "build": os.environ.get("BUILD"),
    "feed_url": os.environ.get("FEED_URL"),
    "public_key_length": len(key),
}
status = "pass"
message = "Info.plist update metadata is configured"
if not key or key == os.environ["PLACEHOLDER"]:
    status = "fail"
    message = "SUPublicEDKey is missing or still uses the placeholder"
else:
    try:
        decoded = base64.b64decode(key, validate=True)
    except Exception:
        status = "fail"
        message = "SUPublicEDKey is not valid base64"
    else:
        details["decoded_public_key_bytes"] = len(decoded)
        if len(decoded) != 32:
            status = "fail"
            message = "SUPublicEDKey must decode to 32 bytes"

payload = {
    "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "event": "app.info_metadata",
    "status": status,
    "message": message,
    "details": details,
}
with open(sys.argv[1], "a", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")
print(status)
PY
  local status
  status="$(tail -n 1 "$REPORT_FILE" | /usr/bin/python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["status"])')"
  printf '[%s] app.info_metadata: Info.plist update metadata checked\n' "$status"
  case "$status" in
    fail) FAILURES=$((FAILURES + 1)) ;;
  esac
}

check_core_bundle() {
  local core_dir="$APP_BUNDLE/Contents/Resources/Core"
  require_path "core.directory" "$core_dir" dir || true
  require_path "core.manifest" "$core_dir/mihomo-manifest.json" file || true
  require_path "core.arm64" "$core_dir/mihomo-darwin-arm64" file || true
  require_path "core.amd64" "$core_dir/mihomo-darwin-amd64" file || true
  if [ -f "$core_dir/mihomo-manifest.json" ]; then
    if output="$(/usr/bin/python3 - "$core_dir/mihomo-manifest.json" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    manifest = json.load(handle)
assets = manifest.get("assets") or []
names = [asset.get("name", "") for asset in assets]
missing = []
if not manifest.get("version"):
    missing.append("version")
if not any("arm64" in name for name in names):
    missing.append("arm64 asset")
if not any("amd64" in name for name in names):
    missing.append("amd64 asset")
print(json.dumps({"version": manifest.get("version"), "assets": names, "missing": missing}, sort_keys=True))
sys.exit(1 if missing else 0)
PY
)"; then
      record_event "core.manifest_contents" pass "bundled core manifest is complete" "$output"
    else
      record_event "core.manifest_contents" fail "bundled core manifest is incomplete" "$output"
    fi
  fi
}

check_signatures() {
  local helper="$APP_BUNDLE/Contents/Library/LaunchServices/ClashMaxHelper"
  local extension="$APP_BUNDLE/Contents/Library/SystemExtensions/$NETWORK_EXTENSION_ID.systemextension"
  local core_dir="$APP_BUNDLE/Contents/Resources/Core"

  run_check "codesign.app" critical /usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE" || true
  run_check "codesign.helper" critical /usr/bin/codesign --verify --strict --verbose=2 "$helper" || true
  run_check "codesign.network_extension" critical /usr/bin/codesign --verify --strict --verbose=2 "$extension" || true
  for core in "$core_dir"/mihomo-darwin-*; do
    [ -f "$core" ] || continue
    run_check "codesign.$(basename "$core")" critical /usr/bin/codesign --verify --strict --verbose=2 "$core" || true
  done
  run_check "spctl.app" critical /usr/sbin/spctl --assess --type execute --verbose "$APP_BUNDLE" || true
}

check_appcast() {
  if [ "$APP_VERSION" = "" ] || [ "$APP_BUILD" = "" ]; then
    record_event "appcast" fail "cannot compare appcast before app version is known" "{}"
    return
  fi
  require_path "appcast.file" "$APPCAST_PATH" file || return
  local result
  # appcast uses sparkle:shortVersionString and sparkle:version.
  if result="$(/usr/bin/python3 - "$APPCAST_PATH" "$APP_VERSION" "$APP_BUILD" <<'PY'
import json
import sys
import xml.etree.ElementTree as ET

path, expected_version, expected_build = sys.argv[1:4]
sparkle = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
root = ET.parse(path).getroot()
channel = root.find("channel")
item = channel.find("item") if channel is not None else None
if item is None:
    print(json.dumps({"errors": ["missing latest item"]}, sort_keys=True))
    sys.exit(1)

title = item.findtext("title")
build = item.findtext(f"{sparkle}version")
version = item.findtext(f"{sparkle}shortVersionString")
minimum = item.findtext(f"{sparkle}minimumSystemVersion")
enclosure = item.find("enclosure")
url = enclosure.attrib.get("url") if enclosure is not None else None
length = enclosure.attrib.get("length") if enclosure is not None else None
signature = enclosure.attrib.get(f"{sparkle}edSignature") if enclosure is not None else None
errors = []
if version != expected_version:
    errors.append(f"shortVersionString {version!r} != {expected_version!r}")
if build != expected_build:
    errors.append(f"version {build!r} != {expected_build!r}")
expected_suffix = f"/v{expected_version}/ClashMax-{expected_version}.zip"
if not url or expected_suffix not in url:
    errors.append("download URL does not point at the matching GitHub release asset")
if not signature:
    errors.append("missing EdDSA signature")
print(json.dumps({
    "title": title,
    "version": version,
    "build": build,
    "minimum_system_version": minimum,
    "url": url,
    "length": length,
    "has_signature": bool(signature),
    "errors": errors,
}, sort_keys=True))
sys.exit(1 if errors else 0)
PY
)"; then
    record_event "appcast.latest_item" pass "latest appcast item matches exported app" "$result"
  else
    record_event "appcast.latest_item" fail "latest appcast item does not match exported app" "$result"
  fi
}

check_sparkle_archive() {
  if [ "$APP_VERSION" = "" ]; then
    record_event "sparkle.archive" fail "cannot locate Sparkle archive before app version is known" "{}"
    return
  fi
  local archive="$SPARKLE_DIR/ClashMax-$APP_VERSION.zip"
  require_path "sparkle.archive" "$archive" file || return
  if [ -s "$archive" ]; then
    local size
    size="$(/usr/bin/stat -f '%z' "$archive")"
    record_event "sparkle.archive_size" pass "Sparkle archive is non-empty" "{\"path\":$(json_string "$archive"),\"bytes\":$size}"
  else
    record_event "sparkle.archive_size" fail "Sparkle archive is empty" "{\"path\":$(json_string "$archive")}"
  fi
}

check_dmg() {
  if [ -z "$DMG_PATH" ]; then
    DMG_PATH="dist/dmg/ClashMax-$APP_VERSION.dmg"
  fi
  require_path "dmg.file" "$DMG_PATH" file || return
  run_check "dmg.verify" critical /usr/bin/hdiutil verify "$DMG_PATH" || true

  local mount_dir
  mount_dir="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-dmg-smoke.XXXXXX")"
  local attached=false
  if /usr/bin/hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$DMG_PATH" > "$EVIDENCE_DIR/dmg.attach.txt" 2>&1; then
    attached=true
    if [ -d "$mount_dir/ClashMax.app" ] && [ "$(readlink "$mount_dir/Applications" 2>/dev/null || true)" = "/Applications" ]; then
      record_event "dmg.contents" pass "DMG contains ClashMax.app and Applications symlink" "{\"mount\":$(json_string "$mount_dir")}"
    else
      record_event "dmg.contents" fail "DMG does not contain expected install layout" "{\"mount\":$(json_string "$mount_dir")}"
    fi
  else
    record_event "dmg.attach" fail "DMG could not be attached read-only" "{\"output\":$(json_string "$EVIDENCE_DIR/dmg.attach.txt")}"
  fi
  if [ "$attached" = true ]; then
    /usr/bin/hdiutil detach "$mount_dir" > "$EVIDENCE_DIR/dmg.detach.txt" 2>&1 || record_event "dmg.detach" warn "DMG detach failed" "{\"output\":$(json_string "$EVIDENCE_DIR/dmg.detach.txt")}"
  fi
  rmdir "$mount_dir" 2>/dev/null || true
}

profile_manifest_path() {
  printf '%s/Library/Application Support/ClashMax/profiles.json' "$HOME"
}

subscription_profiles_json() {
  local manifest="$1"
  /usr/bin/python3 - "$manifest" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)
profiles = []
for profile in data.get("profiles", []):
    source = profile.get("source") or {}
    if source.get("kind") == "subscription":
        profiles.append({
            "id": source.get("subscriptionID") or profile.get("id"),
            "profile_id": profile.get("id"),
            "name": profile.get("name") or "",
            "original_config_path": profile.get("originalConfigPath"),
        })
print(json.dumps(profiles, ensure_ascii=False, sort_keys=True))
PY
}

classify_subscription_body() {
  /usr/bin/python3 - "$1" "$2" "$3" <<'PY'
import base64
import json
import re
import sys

body_path, headers_path, sanitized_url = sys.argv[1:4]
raw = open(body_path, "rb").read()
headers = open(headers_path, "r", encoding="utf-8", errors="replace").read()
text = raw.decode("utf-8-sig", errors="replace")
lower = text[:4096].lower()
header_map = {}
for line in headers.splitlines():
    if ":" in line:
        name, value = line.split(":", 1)
        header_map[name.strip().lower()] = value.strip()

kind = "unknown"
needs_runtime = False
errors = []
if not raw:
    errors.append("empty response body")
elif "<html" in lower or "login" in lower and "proxies" not in lower:
    errors.append("response looks like a login or panel page")
elif re.search(r"(?m)^\s*(proxies|proxy-groups|proxy-providers|rules|mixed-port|port|dns|tun)\s*:", text):
    kind = "yaml"
elif re.search(r"(?m)^(ss|ssr|vmess|vless|trojan|hysteria2?|tuic)://", text.strip()):
    kind = "uri-provider"
    needs_runtime = True
else:
    try:
        decoded = base64.b64decode(re.sub(r"\s+", "", text), validate=False).decode("utf-8", errors="replace")
    except Exception:
        decoded = ""
    if re.search(r"(?m)^(ss|ssr|vmess|vless|trojan|hysteria2?|tuic)://", decoded.strip()):
        kind = "base64-uri-provider"
        needs_runtime = True

print(json.dumps({
    "sanitized_url": sanitized_url,
    "body_bytes": len(raw),
    "content_type": header_map.get("content-type"),
    "subscription_userinfo": header_map.get("subscription-userinfo"),
    "profile_update_interval": header_map.get("profile-update-interval"),
    "profile_web_page_url": header_map.get("profile-web-page-url"),
    "kind": kind,
    "needs_live_runtime_validation": needs_runtime,
    "errors": errors,
}, ensure_ascii=False, sort_keys=True))
sys.exit(1 if errors else 0)
PY
}

check_subscription_pool() {
  local manifest
  manifest="$(profile_manifest_path)"
  require_path "subscriptions.manifest" "$manifest" file || return

  local profiles_json
  if ! profiles_json="$(subscription_profiles_json "$manifest")"; then
    record_event "subscriptions.manifest_parse" fail "profile manifest could not be parsed" "{\"path\":$(json_string "$manifest")}"
    return
  fi

  local count
  count="$(PROFILES="$profiles_json" /usr/bin/python3 - <<'PY'
import json
import os
print(len(json.loads(os.environ["PROFILES"])))
PY
)"
  if [ "$count" = "0" ]; then
    if [ "$ALLOW_EMPTY_SUBSCRIPTIONS" = true ]; then
      record_event "subscriptions.pool" warn "no installed subscription profiles found" "{\"allow_empty\":true}"
    else
      record_event "subscriptions.pool" fail "no installed subscription profiles found" "{\"allow_empty\":false}"
    fi
    return
  fi
  record_event "subscriptions.pool" pass "installed subscription profiles found" "{\"count\":$count}"

  PROFILES="$profiles_json" /usr/bin/python3 - <<'PY' > "$EVIDENCE_DIR/subscription-profiles.jsonl"
import json
import os
for profile in json.loads(os.environ["PROFILES"]):
    print(json.dumps(profile, ensure_ascii=False, sort_keys=True))
PY

  while IFS= read -r profile_json; do
    local sub_id
    sub_id="$(PROFILE="$profile_json" /usr/bin/python3 - <<'PY'
import json
import os
print(json.loads(os.environ["PROFILE"])["id"])
PY
)"
    local name
    name="$(PROFILE="$profile_json" /usr/bin/python3 - <<'PY'
import json
import os
print(json.loads(os.environ["PROFILE"]).get("name") or "")
PY
)"
    local account="subscription.$sub_id"
    local url
    local keychain_error="$EVIDENCE_DIR/subscription-$sub_id-keychain.txt"
    if ! url="$(/usr/bin/security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" -w 2>"$keychain_error")"; then
      record_event "subscription.keychain" fail "subscription URL missing from Keychain" "{\"profile\":$(json_string "$name"),\"account\":$(json_string "$account"),\"output\":$(json_string "$keychain_error")}"
      continue
    fi

    local sanitized
    sanitized="$(sanitize_url "$url")"
    local headers="$SUBSCRIPTION_TMP/subscription-$sub_id.headers"
    local body="$SUBSCRIPTION_TMP/subscription-$sub_id.body"
    local curl_meta="$SUBSCRIPTION_TMP/subscription-$sub_id.curl"
    if /usr/bin/curl --fail --location --silent --show-error --max-time 30 --connect-timeout 15 \
      --user-agent "clash.meta" --dump-header "$headers" --output "$body" \
      --write-out 'http_code=%{http_code}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n' \
      "$url" > "$curl_meta" 2>&1; then
      local details
      if details="$(classify_subscription_body "$body" "$headers" "$sanitized")"; then
        record_event "subscription.fetch" pass "subscription fetched and decoded" "$details"
      else
        record_event "subscription.fetch" fail "subscription response is not usable" "$details"
        continue
      fi
      local kind
      kind="$(DETAILS="$details" /usr/bin/python3 - <<'PY'
import json
import os
print(json.loads(os.environ["DETAILS"]).get("kind"))
PY
)"
      if [ "$kind" = "yaml" ]; then
        local arch core_binary
        arch="$(uname -m)"
        case "$arch" in
          arm64) core_binary="$APP_BUNDLE/Contents/Resources/Core/mihomo-darwin-arm64" ;;
          x86_64) core_binary="$APP_BUNDLE/Contents/Resources/Core/mihomo-darwin-amd64" ;;
          *) core_binary="" ;;
        esac
        if [ -n "$core_binary" ] && [ -x "$core_binary" ]; then
          local validation_output="$SUBSCRIPTION_TMP/subscription-$sub_id.mihomo-validate"
          if "$core_binary" -t -f "$body" > "$validation_output" 2>&1; then
            record_event "subscription.$sub_id.mihomo_validate" pass "bundled Mihomo accepted subscription YAML" "{\"sanitized_url\":$(json_string "$sanitized")}"
          else
            local validation_status=$?
            record_event "subscription.$sub_id.mihomo_validate" fail "bundled Mihomo rejected subscription YAML" "{\"sanitized_url\":$(json_string "$sanitized"),\"exit_code\":$validation_status}"
          fi
        else
          record_event "subscription.$sub_id.mihomo_validate" warn "no executable bundled core for this architecture" "{\"arch\":$(json_string "$arch")}"
        fi
      else
        record_event "subscription.$sub_id.runtime_validation" warn "provider or URI content needs live runtime validation" "$details"
      fi
    else
      local curl_output
      curl_output="$(cat "$curl_meta" 2>/dev/null || true)"
      record_event "subscription.fetch" fail "subscription fetch failed" "{\"profile\":$(json_string "$name"),\"sanitized_url\":$(json_string "$sanitized"),\"output\":$(json_string "$curl_output")}"
    fi
  done < "$EVIDENCE_DIR/subscription-profiles.jsonl"
}

preflight() {
  local helper="$APP_BUNDLE/Contents/Library/LaunchServices/ClashMaxHelper"
  local plist="$APP_BUNDLE/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
  local extension="$APP_BUNDLE/Contents/Library/SystemExtensions/$NETWORK_EXTENSION_ID.systemextension"

  require_path "app.bundle" "$APP_BUNDLE" dir || true
  require_path "helper.binary" "$helper" file || true
  require_path "helper.launchdaemon" "$plist" file || true
  require_path "network_extension.bundle" "$extension" dir || true
  read_info_plist || true
  check_core_bundle
  check_signatures
  check_appcast || true
  check_sparkle_archive || true
  check_dmg || true
  check_subscription_pool || true
}

capture_live_snapshot() {
  local prefix="$1"
  run_check "$prefix.systemextensions" noncritical /usr/bin/systemextensionsctl list || true
  run_check "$prefix.helper_launchd" noncritical /bin/launchctl print "system/$HELPER_ID" || true
  run_check "$prefix.mihomo_processes" noncritical /usr/bin/pgrep -fl mihomo || true
  run_check "$prefix.dns" critical /usr/sbin/scutil --dns || true
  run_check "$prefix.routes" critical /usr/sbin/netstat -rn || true
  run_check "$prefix.non_proxy_curl" noncritical /usr/bin/curl --proxy "" --location --silent --show-error --max-time 20 --output /dev/null --write-out 'http_code=%{http_code}\nremote_ip=%{remote_ip}\n' https://example.com || true
}

live_smoke() {
  record_event "live.mode" pass "starting live release smoke" "{\"soak_minutes\":$SOAK_MINUTES}"
  capture_live_snapshot "live.before"

  if [ ! -t 0 ]; then
    record_event "live.interaction" fail "live mode requires an interactive terminal" "{}"
    return
  fi

  printf '\nStart ClashMax from %s, select TUN or NE Proxy, approve macOS prompts, then press Enter.\n' "$APP_BUNDLE"
  read -r _
  capture_live_snapshot "live.after_start"

  local minute=0
  while [ "$minute" -lt "$SOAK_MINUTES" ]; do
    minute=$((minute + 1))
    capture_live_snapshot "live.soak.$minute"
    if [ "$minute" -lt "$SOAK_MINUTES" ]; then
      sleep 60
    fi
  done

  printf '\nSleep and wake the Mac, then press Enter. Type "skip" to record a release-blocking gap.\n'
  local wake_response
  read -r wake_response
  if [ "$wake_response" = "skip" ]; then
    record_event "live.sleep_wake" fail "sleep/wake was skipped and remains a release-blocking gap" "{}"
  else
    capture_live_snapshot "live.after_wake"
    record_event "live.sleep_wake" pass "wake evidence captured" "{}"
  fi
}

write_summary() {
  FAILURES="$FAILURES" WARNINGS="$WARNINGS" REPORT_FILE="$REPORT_FILE" LIVE_MODE="$LIVE_MODE" APP="$APP_BUNDLE" /usr/bin/python3 - "$SUMMARY_FILE" <<'PY'
import json
import os
import sys

summary = {
    "app": os.environ["APP"],
    "live_mode": os.environ["LIVE_MODE"] == "true",
    "failures": int(os.environ["FAILURES"]),
    "warnings": int(os.environ["WARNINGS"]),
    "events": os.environ["REPORT_FILE"],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(summary, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY
  printf 'summary: %s\n' "$SUMMARY_FILE"
  printf 'events: %s\n' "$REPORT_FILE"
}

preflight
if [ "$LIVE_MODE" = true ]; then
  if [ "$FAILURES" -gt 0 ]; then
    record_event "live.skipped" fail "preflight failures must be resolved before live smoke" "{}"
  else
    live_smoke
  fi
fi

write_summary
if [ "$FAILURES" -gt 0 ]; then
  exit 1
fi
