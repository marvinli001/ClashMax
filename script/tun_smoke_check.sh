#!/bin/sh
set -eu

APP_BUNDLE="${1:-/Applications/ClashMax.app}"
HELPER_ID="io.github.clashmax.ClashMax.Helper"
HELPER="$APP_BUNDLE/Contents/Library/LaunchServices/ClashMaxHelper"
PLIST="$APP_BUNDLE/Contents/Library/LaunchDaemons/$HELPER_ID.plist"
CORE_DIR="$APP_BUNDLE/Contents/Resources/Core"

section() {
  printf '\n== %s ==\n' "$1"
}

check_path() {
  if [ -e "$1" ]; then
    printf 'OK   %s\n' "$1"
  else
    printf 'MISS %s\n' "$1"
  fi
}

run_readonly() {
  printf '$ %s\n' "$*"
  "$@" 2>&1 || true
}

section "Bundle"
check_path "$APP_BUNDLE"
check_path "$HELPER"
check_path "$PLIST"
check_path "$CORE_DIR/mihomo-manifest.json"
check_path "$CORE_DIR/mihomo-darwin-arm64"
check_path "$CORE_DIR/mihomo-darwin-amd64"

section "Code Signatures"
if [ -d "$APP_BUNDLE" ]; then
  run_readonly /usr/bin/codesign --verify --strict --verbose=2 "$APP_BUNDLE"
fi
if [ -f "$HELPER" ]; then
  run_readonly /usr/bin/codesign --verify --strict --verbose=2 "$HELPER"
fi
for core in "$CORE_DIR"/mihomo-darwin-*; do
  [ -f "$core" ] || continue
  run_readonly /usr/bin/codesign --verify --strict --verbose=2 "$core"
done

section "Helper launchd State"
run_readonly /bin/launchctl print "system/$HELPER_ID"

section "Current Mihomo Processes"
run_readonly /usr/bin/pgrep -fl mihomo

section "Current Interfaces And Routes"
run_readonly /sbin/ifconfig
run_readonly /usr/sbin/netstat -rn

section "Current DNS Snapshot"
run_readonly /usr/sbin/scutil --dns

section "Manual Gate"
cat <<'MANUAL'
This script is read-only. Continue with docs/TUN_SMOKE_TEST.md for the manual installed-bundle checks:
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
