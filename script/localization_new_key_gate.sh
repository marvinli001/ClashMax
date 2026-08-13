#!/bin/sh
# Every new string-catalog key must ship a Simplified Chinese translation.
#
# 1.0.22 shipped the whole Quick Rules panel in English on Chinese systems:
# archiving in Xcode re-extracted Resources/Localizable.xcstrings and added 49
# keys, none of them translated, and nothing in CI noticed. LocalizationTests
# only asserts a hand-picked set of representative keys, so a key it does not
# name can go out untranslated without turning anything red.
#
# This is the ratchet. Every key without a zh-Hans value must appear in
# script/localization_untranslated_allowlist.txt, which snapshots the debt that
# already existed when the gate landed. A key that is not on that list fails the
# gate, and a listed key that has since been translated must leave the list, so
# the backlog can only shrink.
#
# usage: localization_new_key_gate.sh [options]
#   --catalog PATH        string catalog to check (default Resources/Localizable.xcstrings)
#   --allowlist PATH      allowlist to enforce (default script/localization_untranslated_allowlist.txt)
#   --base-ref REF        git ref to label offenders against (default: latest release tag)
#   --write-allowlist     rewrite the allowlist from the catalog's current state
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CATALOG="$ROOT_DIR/Resources/Localizable.xcstrings"
ALLOWLIST="$SCRIPT_DIR/localization_untranslated_allowlist.txt"
CATALOG_REPO_PATH="Resources/Localizable.xcstrings"
BASE_REF=""
WRITE=0
ref=""

while [ $# -gt 0 ]; do
  case "$1" in
    --catalog) CATALOG="$2"; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    --base-ref) BASE_REF="$2"; shift 2 ;;
    --write-allowlist) WRITE=1; shift ;;
    -h|--help) sed -n '/^# usage:/,/--write-allowlist /s/^# \{0,1\}//p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -f "$CATALOG" ] || { printf 'string catalog not found: %s\n' "$CATALOG" >&2; exit 2; }

# A key counts as translated when zh-Hans carries a non-empty stringUnit value,
# or plural variations. The catalog uses only stringUnit today; variations are
# accepted so a future plural entry is not read as missing.
JQ_MISSING='
def translated:
  (.localizations["zh-Hans"] // {}) as $zh
  | (($zh.stringUnit.value // "") != "") or (($zh.variations // null) != null);
[.strings | to_entries[] | select((.value | translated) | not) | .key] | sort
'

missing_json="$(jq "$JQ_MISSING" "$CATALOG")"
missing_count="$(printf '%s' "$missing_json" | jq 'length')"
total_count="$(jq '.strings | length' "$CATALOG")"

write_allowlist() {
  {
    cat <<'HEADER'
# Keys in Resources/Localizable.xcstrings that may ship without a Simplified
# Chinese translation. Enforced by script/localization_new_key_gate.sh.
#
# This is a debt snapshot, not a target. It was seeded on 2026-08-13 with the
# 219 keys that had no zh-Hans value at that point. Only 9 of them are
# punctuation or a bare format string ("#", "%@ · %@", "%lld"); the other 210
# are real UI copy that still renders in English on a Simplified Chinese system.
# The list may shrink freely, and should. Growing it means shipping more English
# text to those users, so a new line here needs a reason in the pull request.
#
# One JSON-encoded key per line, sorted by the gate; "#" starts a comment, and
# the empty key is the literal line "". Regenerate with:
#   script/localization_new_key_gate.sh --write-allowlist
HEADER
    printf '%s' "$missing_json" | jq -r '.[] | @json'
  } > "$ALLOWLIST"
}

read_allowlist() {
  # Comment and blank lines are dropped; every remaining line is one JSON string.
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$ALLOWLIST" \
    | sed -e '/^#/d' -e '/^$/d' \
    | jq -s 'sort'
}

if [ "$WRITE" -eq 1 ]; then
  previous_json='[]'
  if [ -f "$ALLOWLIST" ]; then
    previous_json="$(read_allowlist)"
  fi
  write_allowlist
  printf 'Wrote %s\n' "${ALLOWLIST#"$ROOT_DIR/"}"
  printf '  %s of %s keys have no zh-Hans value.\n' "$missing_count" "$total_count"
  added="$(jq -n --argjson a "$missing_json" --argjson b "$previous_json" '$a - $b')"
  removed="$(jq -n --argjson a "$missing_json" --argjson b "$previous_json" '$b - $a')"
  if [ "$(printf '%s' "$removed" | jq 'length')" -gt 0 ]; then
    printf '  dropped (now translated or gone):\n'
    printf '%s' "$removed" | jq -r '.[] | "    " + @json'
  fi
  if [ "$(printf '%s' "$added" | jq 'length')" -gt 0 ]; then
    printf '  NEWLY EXEMPT — these will now ship in English; translate them instead\n'
    printf '  unless they are punctuation or a bare format string:\n'
    printf '%s' "$added" | jq -r '.[] | "    " + @json'
  fi
  exit 0
fi

if [ ! -f "$ALLOWLIST" ]; then
  printf 'allowlist not found: %s\n' "$ALLOWLIST" >&2
  printf 'Seed it with: script/localization_new_key_gate.sh --write-allowlist\n' >&2
  exit 2
fi

allow_json="$(read_allowlist)"
verdict="$(jq -n --argjson missing "$missing_json" --argjson allow "$allow_json" \
  '{unexpected: ($missing - $allow), stale: ($allow - $missing)}')"
unexpected_count="$(printf '%s' "$verdict" | jq '.unexpected | length')"
stale_count="$(printf '%s' "$verdict" | jq '.stale | length')"

# Offenders are labelled against the previous release tag, because that is where
# they come from in practice: Xcode's archive step re-extracts the catalog and
# adds whatever the release's new UI code introduced. The label is a courtesy —
# the allowlist alone decides pass or fail, so a shallow clone with no tags still
# gets the same verdict.
base_keys_json=""
if [ "$unexpected_count" -gt 0 ] && git -C "$ROOT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  ref="$BASE_REF"
  [ -n "$ref" ] || ref="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)"
  if [ -n "$ref" ]; then
    base_keys_json="$(git -C "$ROOT_DIR" show "$ref:$CATALOG_REPO_PATH" 2>/dev/null \
      | jq '[.strings | keys[]]' 2>/dev/null || true)"
  fi
fi

status=0

if [ "$unexpected_count" -gt 0 ]; then
  status=1
  printf '\n%s untranslated key(s) are not on the allowlist:\n\n' "$unexpected_count"
  if [ -n "$base_keys_json" ]; then
    printf '%s' "$verdict" | jq -r --argjson base "$base_keys_json" --arg ref "$ref" '
      ([.unexpected[] | select(IN($base[]) | not)]) as $new
      | ([.unexpected[] | select(IN($base[]))]) as $old
      | (if ($new | length) > 0 then
           "  added since \($ref):", ($new[] | "    " + @json), ""
         else empty end),
        (if ($old | length) > 0 then
           "  already in \($ref), but never allowlisted:", ($old[] | "    " + @json), ""
         else empty end)'
  else
    printf '%s' "$verdict" | jq -r '.unexpected[] | "    " + @json'
    printf '\n'
  fi
  printf 'Add a zh-Hans translation for each key in %s.\n' "$CATALOG_REPO_PATH"
  printf 'If a key genuinely must not be translated, exempt it deliberately with\n'
  printf '  script/localization_new_key_gate.sh --write-allowlist\n'
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::error::%s new string-catalog key(s) have no Simplified Chinese translation\n' "$unexpected_count"
  fi
fi

if [ "$stale_count" -gt 0 ]; then
  status=1
  printf '\n%s allowlisted key(s) are now translated or gone from the catalog:\n\n' "$stale_count"
  printf '%s' "$verdict" | jq -r '.stale[] | "    " + @json'
  printf '\nThe allowlist only ever shrinks. Prune it with\n'
  printf '  script/localization_new_key_gate.sh --write-allowlist\n'
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::error::%s allowlisted key(s) are stale; regenerate the allowlist\n' "$stale_count"
  fi
fi

if [ "$status" -eq 0 ]; then
  printf 'String catalog: %s keys, %s without zh-Hans, all allowlisted.\n' "$total_count" "$missing_count"
fi

exit "$status"
