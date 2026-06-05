#!/usr/bin/env bash
set -euo pipefail

APP_BUNDLE="/Applications/ClashMax.app"
STRICT=false
JSON_OUTPUT=""
HELPER_ID="io.github.clashmax.ClashMax.Helper"
NETWORK_EXTENSION_ID="io.github.clashmax.ClashMax.NetworkExtension"
ERRORS=0
WARNINGS=0
SUMMARY_DATA="$(mktemp "${TMPDIR:-/tmp}/clashmax-tun-smoke.XXXXXX")"

cleanup() {
  rm -f "$SUMMARY_DATA"
}
trap cleanup EXIT

usage() {
  cat <<'USAGE'
usage: script/tun_smoke_check.sh [--strict] [--json /path/to/summary.json] [/Applications/ClashMax.app]
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)
      STRICT=true
      shift
      ;;
    --json)
      JSON_OUTPUT="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      APP_BUNDLE="$1"
      shift
      ;;
  esac
done

HELPER="$APP_BUNDLE/Contents/Library/LaunchServices/ClashMaxHelper"
PLIST="$APP_BUNDLE/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
NETWORK_EXTENSION="$APP_BUNDLE/Contents/Library/SystemExtensions/$NETWORK_EXTENSION_ID.systemextension"
CORE_DIR="$APP_BUNDLE/Contents/Resources/Core"

section() {
  printf '\n== %s ==\n' "$1"
}

check_path() {
  if [ -e "$1" ]; then
    printf 'OK   %s\n' "$1"
    record_check "$2" "pass" "$1"
  else
    printf 'MISS %s\n' "$1"
    record_check "$2" "fail" "$1"
    if [ "$STRICT" = true ]; then
      ERRORS=$((ERRORS + 1))
    fi
  fi
}

record_check() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SUMMARY_DATA"
}

run_readonly() {
  name="$1"
  critical="$2"
  shift 2
  tmp_output="$(mktemp "${TMPDIR:-/tmp}/clashmax-tun-command.XXXXXX")"
  printf '$ %s\n' "$*"
  if "$@" > "$tmp_output" 2>&1; then
    cat "$tmp_output"
    record_check "$name" "pass" "$*"
    rm -f "$tmp_output"
    return 0
  else
    status=$?
    cat "$tmp_output"
    rm -f "$tmp_output"
    if [ "$critical" = "critical" ] && [ "$STRICT" = true ]; then
      record_check "$name" "fail" "$* exited $status"
      ERRORS=$((ERRORS + 1))
    else
      record_check "$name" "warn" "$* exited $status"
      WARNINGS=$((WARNINGS + 1))
    fi
    return 0
  fi
}

write_json_summary() {
  [ -n "$JSON_OUTPUT" ] || return 0
  mkdir -p "$(dirname "$JSON_OUTPUT")"
  /usr/bin/python3 - "$JSON_OUTPUT" "$APP_BUNDLE" "$STRICT" "$ERRORS" "$WARNINGS" "$SUMMARY_DATA" <<'PY'
import json
import sys

output, app, strict, errors, warnings, data_path = sys.argv[1:7]
checks = []
with open(data_path, "r", encoding="utf-8") as handle:
    for line in handle:
        name, status, message = line.rstrip("\n").split("\t", 2)
        checks.append({"name": name, "status": status, "message": message})

summary = {
    "app": app,
    "strict": strict == "true",
    "errors": int(errors),
    "warnings": int(warnings),
    "checks": checks,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(summary, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

section "Bundle"
check_path "$APP_BUNDLE" "app.bundle"
check_path "$HELPER" "helper.binary"
check_path "$PLIST" "helper.launchdaemon"
check_path "$NETWORK_EXTENSION" "network_extension.bundle"
check_path "$CORE_DIR/mihomo-manifest.json" "core.manifest"
check_path "$CORE_DIR/mihomo-darwin-arm64" "core.arm64"
check_path "$CORE_DIR/mihomo-darwin-amd64" "core.amd64"

section "Code Signatures"
if [ -d "$APP_BUNDLE" ]; then
  run_readonly "codesign.app" "critical" /usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
fi
if [ -f "$HELPER" ]; then
  run_readonly "codesign.helper" "critical" /usr/bin/codesign --verify --strict --verbose=2 "$HELPER"
fi
if [ -d "$NETWORK_EXTENSION" ]; then
  run_readonly "codesign.network_extension" "critical" /usr/bin/codesign --verify --strict --verbose=2 "$NETWORK_EXTENSION"
fi
for core in "$CORE_DIR"/mihomo-darwin-*; do
  [ -f "$core" ] || continue
  run_readonly "codesign.$(basename "$core")" "critical" /usr/bin/codesign --verify --strict --verbose=2 "$core"
done

section "Helper launchd State"
run_readonly "helper.launchd_state" "noncritical" /bin/launchctl print "system/$HELPER_ID"

section "Current Mihomo Processes"
run_readonly "mihomo.processes" "noncritical" /usr/bin/pgrep -fl mihomo

section "Current Interfaces And Routes"
run_readonly "network.interfaces" "critical" /sbin/ifconfig
run_readonly "network.routes" "critical" /usr/sbin/netstat -rn

section "Current DNS Snapshot"
run_readonly "network.dns" "critical" /usr/sbin/scutil --dns

section "Manual Gate"
cat <<'MANUAL'
This script is read-only. Continue with docs/TUN_SMOKE_TEST.md or script/release_smoke_check.sh --live for the installed-bundle checks:
- helper approval persistence after relaunch
- start/stop/restart TUN
- sleep/wake
- network switching
- non-proxy curl traffic
- UDP/QUIC
- DNS leak behavior
- route exclusions
- online TUN setting repair and safety-stop behavior
MANUAL

write_json_summary
if [ "$ERRORS" -gt 0 ]; then
  exit 1
fi
