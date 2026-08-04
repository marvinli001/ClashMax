#!/bin/sh
# Fixture checks for the generated-project guard.
#
# Everything here operates on temporary copies and snapshot JSON. The real
# ClashMax.xcodeproj is hashed before and after the whole run and must come out
# byte-identical, including when the wrapper is forced to roll back an install.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_TOOL="$SCRIPT_DIR/xcode_project_semantic_snapshot.sh"
GUARDED_BUILD="$SCRIPT_DIR/guarded_xcodebuild.sh"
ALLOWLIST="$ROOT_DIR/docs/superpowers/plans/2026-07-28-structured-logging-xcode-sources.allowlist"
PROJECT="$ROOT_DIR/ClashMax.xcodeproj"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-guard-fixture.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

expect_pass() {
  label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label (expected acceptance, got rejection)"; fi
}

expect_fail() {
  label="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$label (expected rejection, got acceptance)"; else ok "$label"; fi
}

project_hash() {
  find "$PROJECT" -type f -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1
}

compare() {
  bash "$SNAPSHOT_TOOL" compare --baseline "$WORK/base.json" --candidate "$1" \
    --sections "${2:-generatorSecurity,sources}" --allowlist "$ALLOWLIST"
}

# A mutation applied to a *copy* of the baseline snapshot, expressed as Python.
mutate() {
  # mutate <output> <python-body operating on `d`>
  out="$1"; shift
  CLASHMAX_FIXTURE_IN="$WORK/base.json" CLASHMAX_FIXTURE_OUT="$out" \
    python3 -c "
import json, os
d = json.load(open(os.environ['CLASHMAX_FIXTURE_IN']))
$1
json.dump(d, open(os.environ['CLASHMAX_FIXTURE_OUT'], 'w'))
"
}

for tool in "$SNAPSHOT_TOOL" "$GUARDED_BUILD"; do
  if [ ! -f "$tool" ]; then
    printf 'FAIL missing guard script: %s\n' "$tool"
    printf '\n1 failed, 0 passed\n'
    exit 1
  fi
done
[ -f "$ALLOWLIST" ] || { printf 'FAIL missing allowlist: %s\n' "$ALLOWLIST"; exit 1; }
[ -d "$PROJECT" ] || { printf 'FAIL no project to snapshot: %s\n' "$PROJECT"; exit 1; }

PROJECT_HASH_BEFORE="$(project_hash)"

bash "$SNAPSHOT_TOOL" snapshot --project "$PROJECT" --root "$ROOT_DIR" --output "$WORK/base.json"

# --- accepted cases -------------------------------------------------------
cp "$WORK/base.json" "$WORK/noop.json"
expect_pass "unchanged snapshot is accepted" compare "$WORK/noop.json"

mutate "$WORK/allowlisted.json" "
d['sources']['ClashMax'].append('ClashMax/Services/StructuredLogRecorder.swift')
d['sources']['ClashMax'].append('Shared/StructuredLogPrivacy.swift')
d['sources']['ClashMaxTests'].append('ClashMaxTests/LogChannelStoreTests.swift')
"
expect_pass "allowlisted source additions are accepted" compare "$WORK/allowlisted.json"

# --- rejected security cases ---------------------------------------------
mutate "$WORK/team.json" "d['generatorSecurity']['__project__']['buildSettings']['Release']['DEVELOPMENT_TEAM'] = 'AAAAAAAAAA'"
expect_fail "changed DEVELOPMENT_TEAM is rejected" compare "$WORK/team.json" generatorSecurity

mutate "$WORK/provisioning.json" "d['generatorSecurity']['ClashMax']['buildSettings']['Release']['PROVISIONING_PROFILE_SPECIFIER'] = 'Other Profile'"
expect_fail "changed provisioning profile is rejected" compare "$WORK/provisioning.json" generatorSecurity

mutate "$WORK/identity.json" "d['generatorSecurity']['__project__']['buildSettings']['Release']['CODE_SIGN_IDENTITY'] = 'Apple Development'"
expect_fail "changed signing identity is rejected" compare "$WORK/identity.json" generatorSecurity

mutate "$WORK/style.json" "d['generatorSecurity']['ClashMax']['targetAttributes']['ProvisioningStyle'] = 'Automatic'"
expect_fail "changed provisioning style is rejected" compare "$WORK/style.json" generatorSecurity

mutate "$WORK/capabilities.json" "d['generatorSecurity']['ClashMax']['targetAttributes']['SystemCapabilities'] = {'com.apple.Sandbox': {'enabled': 1}}"
expect_fail "added SystemCapabilities is rejected" compare "$WORK/capabilities.json" generatorSecurity

mutate "$WORK/bundleid.json" "d['generatorSecurity']['ClashMaxHelper']['buildSettings']['Release']['PRODUCT_BUNDLE_IDENTIFIER'] = 'io.example.Rogue'"
expect_fail "changed bundle identifier is rejected" compare "$WORK/bundleid.json" generatorSecurity

mutate "$WORK/entpath.json" "
cfg = d['generatorSecurity']['ClashMax']['buildSettings']
for name in cfg:
    cfg[name]['CODE_SIGN_ENTITLEMENTS'] = 'Config/Rogue.entitlements'
"
expect_fail "changed entitlement path is rejected" compare "$WORK/entpath.json" generatorSecurity

mutate "$WORK/enthash.json" "
files = d['generatorSecurity']['ClashMax']['configFiles']
for key in files:
    files[key] = '0' * 64
"
expect_fail "changed entitlement/Info.plist content hash is rejected" compare "$WORK/enthash.json" generatorSecurity

mutate "$WORK/producttype.json" "d['generatorSecurity']['ClashMaxNetworkExtension']['productType'] = 'com.apple.product-type.app-extension'"
expect_fail "changed product type is rejected" compare "$WORK/producttype.json" generatorSecurity

mutate "$WORK/dependency.json" "d['generatorSecurity']['ClashMax']['dependencies'] = []"
expect_fail "removed target dependency is rejected" compare "$WORK/dependency.json" generatorSecurity

mutate "$WORK/copyphase.json" "
d['generatorSecurity']['ClashMax']['phases'].append({
    'isa': 'PBXCopyFilesBuildPhase',
    'name': 'Embed Rogue',
    'dstPath': '',
    'dstSubfolderSpec': 10,
    'files': [{'path': 'Rogue.framework', 'attributes': ['CodeSignOnCopy']}],
})
"
expect_fail "added copy/embed phase with CodeSignOnCopy is rejected" compare "$WORK/copyphase.json" generatorSecurity

mutate "$WORK/script.json" "
for phase in d['generatorSecurity']['ClashMax']['phases']:
    if phase.get('name') == 'Sign Nested Core Binaries':
        phase['shellScript'] = 'codesign --sign - /tmp/anything'
"
expect_fail "modified signing shell script is rejected" compare "$WORK/script.json" generatorSecurity

mutate "$WORK/scheme.json" "
files = d['generatorSecurity']['__generatedFiles__']
for key in files:
    files[key] = '1' * 64
"
expect_fail "changed generated workspace/scheme hash is rejected" compare "$WORK/scheme.json" generatorSecurity

# --- rejected source cases -----------------------------------------------
mutate "$WORK/removal.json" "d['sources']['ClashMax'] = [p for p in d['sources']['ClashMax'] if not p.endswith('AppModel.swift')]"
expect_fail "removed existing source is rejected" compare "$WORK/removal.json"

mutate "$WORK/unlisted.json" "d['sources']['ClashMax'].append('ClashMax/Services/NotInThePlan.swift')"
expect_fail "non-allowlisted source addition is rejected" compare "$WORK/unlisted.json"

mutate "$WORK/wrongtarget.json" "d['sources']['ClashMaxHelper'].append('ClashMax/Services/StructuredLogRecorder.swift')"
expect_fail "allowlisted path added to the wrong target is rejected" compare "$WORK/wrongtarget.json"

# --require-complete-allowlist must reject a project that is missing planned files.
if bash "$SNAPSHOT_TOOL" compare --baseline "$WORK/base.json" --candidate "$WORK/noop.json" \
    --sections sources --allowlist "$ALLOWLIST" --require-complete-allowlist >/dev/null 2>&1; then
  bad "--require-complete-allowlist rejects an incomplete project"
else
  ok "--require-complete-allowlist rejects an incomplete project"
fi

# --- wrapper: preserved files survive a forced post-install rollback -------
if command -v xcodegen >/dev/null 2>&1; then
  # Deliberately on the project's own volume, not in $WORK: the wrapper's rollback moves a
  # bundle back to ClashMax.xcodeproj, and only a same-volume rename is atomic. From a
  # different filesystem, iCloud resolves the arrival by renaming it "ClashMax 2.xcodeproj".
  GUARD_SANDBOX="$ROOT_DIR/DerivedData/GuardFixture.$$"
  trap 'rm -rf "$WORK" "$GUARD_SANDBOX"' EXIT
  RESOLVED="$PROJECT/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
  if [ -s "$RESOLVED" ]; then
    RESOLVED_BEFORE="$(shasum -a 256 "$RESOLVED" | cut -d' ' -f1)"
    CLASHMAX_GUARD_DIR="$GUARD_SANDBOX" bash "$GUARDED_BUILD" --initialize --allowlist "$ALLOWLIST" >/dev/null 2>&1 \
      || bad "wrapper --initialize records a baseline"
    if [ -f "$GUARD_SANDBOX/baseline.json" ]; then
      ok "wrapper --initialize records a baseline"
    else
      bad "wrapper --initialize records a baseline"
    fi
    if CLASHMAX_GUARD_DIR="$GUARD_SANDBOX" bash "$GUARDED_BUILD" --initialize --allowlist "$ALLOWLIST" >/dev/null 2>&1; then
      bad "wrapper --initialize refuses to overwrite an existing baseline"
    else
      ok "wrapper --initialize refuses to overwrite an existing baseline"
    fi
    if CLASHMAX_GUARD_DIR="$GUARD_SANDBOX" CLASHMAX_GUARD_FORCE_ROLLBACK=1 \
        bash "$GUARDED_BUILD" --allowlist "$ALLOWLIST" >"$WORK/rollback.log" 2>&1; then
      bad "forced rollback fails the wrapper"
    else
      ok "forced rollback fails the wrapper"
    fi
    # Proves the rollback happened *after* a real install rather than the guard
    # bailing out earlier for an unrelated reason.
    if [ -d "$GUARD_SANDBOX/rejected/installed.xcodeproj" ]; then
      ok "forced rollback quarantines the installed project"
    else
      bad "forced rollback quarantines the installed project (guard stopped before install; see $WORK/rollback.log)"
      sed -n '1,20p' "$WORK/rollback.log" | sed 's/^/     /'
    fi
    if [ -d "$PROJECT" ] && [ -z "$(find "$ROOT_DIR" -maxdepth 1 -name 'ClashMax [0-9]*.xcodeproj' -print -quit)" ]; then
      ok "rollback restores the bundle to its own path"
    else
      bad "rollback restores the bundle to its own path (iCloud may have renamed it)"
    fi
    RESOLVED_AFTER="$(shasum -a 256 "$RESOLVED" | cut -d' ' -f1)"
    if [ "$RESOLVED_BEFORE" = "$RESOLVED_AFTER" ]; then
      ok "Package.resolved survives a forced rollback byte-for-byte"
    else
      bad "Package.resolved survives a forced rollback byte-for-byte"
    fi
  else
    printf 'skip Package.resolved rollback check (no resolved package file)\n'
  fi
else
  printf 'skip wrapper rollback checks (xcodegen unavailable)\n'
fi

# --- localization gate must route through the injected wrapper ------------
STUB="$WORK/stub_xcodebuild.sh"
STUB_LOG="$WORK/stub.log"
cat > "$STUB" <<STUB_EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$STUB_LOG"
exit 0
STUB_EOF
chmod +x "$STUB"
: > "$STUB_LOG"
if CLASHMAX_XCODEBUILD_WRAPPER="$STUB" sh "$SCRIPT_DIR/localization_gate.sh" >/dev/null 2>&1; then
  invocations="$(wc -l < "$STUB_LOG" | tr -d ' ')"
  if [ "$invocations" = "1" ]; then
    ok "localization gate calls the injected wrapper exactly once"
  else
    bad "localization gate calls the injected wrapper exactly once (saw $invocations)"
  fi
  if grep -q '^test ' "$STUB_LOG" && grep -q -- '-only-testing:ClashMaxTests/LocalizationTests' "$STUB_LOG"; then
    ok "localization gate passes test and the localization selector"
  else
    bad "localization gate passes test and the localization selector"
  fi
else
  bad "localization gate runs with an injected wrapper"
fi

# --- the real project must be untouched by this entire fixture ------------
if [ "$PROJECT_HASH_BEFORE" = "$(project_hash)" ]; then
  ok "real ClashMax.xcodeproj is byte-identical after the fixture"
else
  bad "real ClashMax.xcodeproj is byte-identical after the fixture"
fi

printf '\n%d failed, %d passed\n' "$FAIL" "$PASS"
[ "$FAIL" -eq 0 ] || exit 1
