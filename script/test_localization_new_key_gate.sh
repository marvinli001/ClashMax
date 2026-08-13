#!/bin/sh
# Fixture checks for the new-key translation gate.
#
# A gate that cannot fail is worse than no gate, so every case here drives
# localization_new_key_gate.sh against a throwaway catalog and allowlist in a
# temporary directory and asserts the verdict. The last case runs it against the
# repository's real catalog, which must pass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$SCRIPT_DIR/localization_new_key_gate.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-localization-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

# expect_status <label> <expected-exit> <args...>
expect_status() {
  label="$1"; expected="$2"; shift 2
  actual=0
  "$@" >"$WORK/out.txt" 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    ok "$label"
  else
    bad "$label (expected exit $expected, got $actual)"
    sed -e 's/^/       /' "$WORK/out.txt"
  fi
}

gate() { sh "$GATE" --catalog "$WORK/catalog.xcstrings" --allowlist "$WORK/allowlist.txt" "$@"; }

# catalog <python-body building `strings`>
catalog() {
  CLASHMAX_FIXTURE_OUT="$WORK/catalog.xcstrings" python3 -c "
import json, os
def zh(value):
    return {'localizations': {'zh-Hans': {'stringUnit': {'state': 'translated', 'value': value}}}}
strings = {}
$1
json.dump({'sourceLanguage': 'en', 'strings': strings, 'version': '1.0'},
          open(os.environ['CLASHMAX_FIXTURE_OUT'], 'w'))
"
}

allowlist() {
  printf '# fixture allowlist\n' > "$WORK/allowlist.txt"
  for key in "$@"; do
    printf '%s\n' "$key" >> "$WORK/allowlist.txt"
  done
}

if [ ! -x "$GATE" ]; then
  printf 'FAIL gate is missing or not executable: %s\n' "$GATE"
  printf '\n1 failed, 0 passed\n'
  exit 1
fi

catalog "strings['Quick Rules'] = zh('快捷规则')"
allowlist
expect_status 'fully translated catalog passes' 0 gate

catalog "
strings['Quick Rules'] = zh('快捷规则')
strings['Placement'] = {}
"
expect_status 'new untranslated key fails' 1 gate
grep -q '"Placement"' "$WORK/out.txt" && ok 'failure names the offending key' \
  || bad 'failure names the offending key'

allowlist '"Placement"'
expect_status 'allowlisted untranslated key passes' 0 gate

# The ratchet: a key that has since been translated must leave the allowlist,
# otherwise the list silently keeps growing past what is actually untranslated.
catalog "
strings['Quick Rules'] = zh('快捷规则')
strings['Placement'] = zh('插入位置')
"
expect_status 'stale allowlist entry fails' 1 gate
grep -q 'now translated or gone' "$WORK/out.txt" && ok 'stale failure explains itself' \
  || bad 'stale failure explains itself'

catalog "strings['Quick Rules'] = zh('快捷规则')"
expect_status 'allowlisted key no longer in the catalog fails' 1 gate

expect_status '--write-allowlist rewrites the list' 0 gate --write-allowlist
expect_status 'gate passes after --write-allowlist' 0 gate

# An empty zh-Hans value is a missing translation, not a translation.
catalog "
strings['Quick Rules'] = zh('')
"
allowlist
expect_status 'empty zh-Hans value counts as untranslated' 1 gate

# Plural entries carry variations instead of a stringUnit; they are translated.
catalog "
strings['%lld nodes'] = {'localizations': {'zh-Hans': {'variations': {'plural': {'other': {'stringUnit': {'state': 'translated', 'value': '%lld 个节点'}}}}}}}
"
expect_status 'plural variations count as translated' 0 gate

rm -f "$WORK/allowlist.txt"
expect_status 'missing allowlist is a usage error, not a gate failure' 2 gate

expect_status 'the repository catalog and allowlist agree' 0 \
  sh "$GATE" --catalog "$ROOT_DIR/Resources/Localizable.xcstrings" \
             --allowlist "$SCRIPT_DIR/localization_untranslated_allowlist.txt"

printf '\n%s failed, %s passed\n' "$FAIL" "$PASS"
[ "$FAIL" -eq 0 ]
