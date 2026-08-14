#!/bin/sh
# SwiftFormat gate, scoped to the files a change already touches.
#
# ~100k lines of Swift written across many sessions had no formatter at all, so
# style consistency was maintained by hand. Reformatting everything in one go
# would bury real changes under thousands of whitespace lines and collide with
# any work in flight, so adoption is two-step:
#
#   1. this gate, which only inspects files the change under review touches, so
#      the tree converges as it is edited;
#   2. one separate mechanical commit that formats the remainder, once step 1
#      has been stable for a while and the working tree is quiet.
#
# Because of step 1, a file the change does not touch is allowed to be
# unformatted. `--all` reports the whole tree if you want to see the remaining
# debt; CI prints that number too, but never fails on it.
#
# usage: swiftformat_lint.sh [options]
#   --all                lint every Swift source file, not just changed ones
#   --fix                format the selected files in place instead of linting
#   --base REF           compare against REF instead of the auto-detected base
#   --summary            print only the per-rule violation tally
#   -h, --help           show this help
#
# environment:
#   SWIFTFORMAT          path to the swiftformat binary (default: from PATH)
#   SWIFTFORMAT_LINT_BASE  same as --base
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="$ROOT_DIR/.swiftformat"

# Every Swift file the project builds. Kept in sync with `sources:` in project.yml.
SOURCE_DIRS="ClashMax ClashMaxTests Shared ClashMaxHelper ClashMaxNetworkExtension"

MODE="changed"
ACTION="lint"
BASE="${SWIFTFORMAT_LINT_BASE:-}"
# Below this many violations, list them individually; above it, the per-rule
# tally is the only readable form. --summary forces the tally.
TALLY_THRESHOLD=50
FORCE_SUMMARY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --all) MODE="all"; shift ;;
    --fix) ACTION="fix"; shift ;;
    --base) BASE="$2"; shift 2 ;;
    --summary) FORCE_SUMMARY=1; TALLY_THRESHOLD=0; shift ;;
    -h|--help) sed -n '/^# usage:/,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

cd "$ROOT_DIR"
[ -f "$CONFIG" ] || { printf 'no .swiftformat at %s\n' "$CONFIG" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Binary and version
#
# A formatter is only a gate if everyone runs the same one: a different build
# reformats different lines and CI disagrees with the machine the change was
# written on. .swiftformat carries the pinned version as --minversion, which is
# also what the CI install step downloads, so this is the one place it lives.
#
# The match is exact, in both directions. A newer build is not "good enough"
# here: .swiftformat opts rules *out* with --disable rather than listing the set
# it wants with --rules, so a rule that a later release adds and enables by
# default applies to this repo too. Formatting with it produces a diff that CI,
# which downloads exactly the pinned version, then rejects -- which is the
# disagreement this check exists to prevent.
# ---------------------------------------------------------------------------

SWIFTFORMAT="${SWIFTFORMAT:-swiftformat}"
if ! command -v "$SWIFTFORMAT" >/dev/null 2>&1; then
  cat >&2 <<'EOF'
swiftformat not found.

  brew install swiftformat

or point SWIFTFORMAT at a binary. The pinned version is the --minversion line
in .swiftformat.
EOF
  exit 2
fi

PINNED_VERSION="$(sed -n 's/^--minversion[[:space:]]\{1,\}//p' "$CONFIG" | tr -d '[:space:]')"
HAVE_VERSION="$("$SWIFTFORMAT" --version | tr -d '[:space:]')"
if [ -n "$PINNED_VERSION" ] && [ "$HAVE_VERSION" != "$PINNED_VERSION" ]; then
  cat >&2 <<EOF
swiftformat $HAVE_VERSION is installed; this repository is pinned to $PINNED_VERSION.

Install the pinned build:

  https://github.com/nicklockwood/SwiftFormat/releases/tag/$PINNED_VERSION

or point SWIFTFORMAT at a $PINNED_VERSION binary. If the intent is to move the
pin, bump --minversion in .swiftformat together with SWIFTFORMAT_VERSION and
SWIFTFORMAT_LINUX_SHA256 in .github/workflows/ci.yml; CI asserts the two agree,
and the whole tree has to be reformatted with the new build in that same commit.
EOF
  exit 2
fi

# ---------------------------------------------------------------------------
# File selection
# ---------------------------------------------------------------------------

resolve_base() {
  # Explicit wins. github.event.before is all-zeros on a force push or a branch's
  # first push, so it is validated rather than trusted.
  if [ -n "$BASE" ] && git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
    printf '%s' "$BASE"
    return 0
  fi

  # Pull requests: the base branch, fetched on demand because a shallow checkout
  # may not have it.
  if [ -n "${GITHUB_BASE_REF:-}" ]; then
    if ! git rev-parse --verify --quiet "origin/$GITHUB_BASE_REF^{commit}" >/dev/null; then
      git fetch --no-tags --quiet origin "$GITHUB_BASE_REF" 2>/dev/null || true
    fi
    if git rev-parse --verify --quiet "origin/$GITHUB_BASE_REF^{commit}" >/dev/null; then
      printf 'origin/%s' "$GITHUB_BASE_REF"
      return 0
    fi
  fi

  # Local branch work: whatever master the machine already has.
  for candidate in origin/master master; do
    if git rev-parse --verify --quiet "$candidate^{commit}" >/dev/null &&
       [ "$(git rev-parse "$candidate")" != "$(git rev-parse HEAD)" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done

  # Nothing left to compare against: HEAD is already the branch everything
  # merges into. Deliberately not HEAD~1 -- on an up-to-date master that would
  # blame the previous commit's files for work this change never touched.
  return 1
}

# Paths that are Swift but not ours: the SPM checkouts under DerivedData, and
# any scratch worktree. Mirrors --exclude in .swiftformat.
drop_non_sources() {
  grep -v -e '^DerivedData' -e '^\.build/' -e '^\.worktrees/' || true
}

if [ "$MODE" = "all" ]; then
  SCOPE_LABEL="every Swift file"
  FILES="$(
    for d in $SOURCE_DIRS; do git ls-files -- "$d"; done | grep '\.swift$' | drop_non_sources | sort -u
  )"
else
  # A missing base is not fatal: uncommitted and untracked work is still worth
  # checking, and it is the case that matters most before a commit exists.
  BASE_REF="$(resolve_base || true)"
  if [ -n "$BASE_REF" ]; then
    SCOPE_LABEL="changed since $BASE_REF, plus uncommitted work"
  else
    SCOPE_LABEL="uncommitted work only; HEAD has nothing above its base"
  fi
  # `if` rather than `&&`: under `set -e` a short-circuited `&&` list would kill
  # the subshell and silently drop the sources listed after it.
  FILES="$(
    {
      if [ -n "$BASE_REF" ]; then
        git diff --name-only --diff-filter=ACMR "$BASE_REF...HEAD"
      fi
      if git rev-parse --verify --quiet HEAD >/dev/null; then
        git diff --name-only --diff-filter=ACMR HEAD
      fi
      git ls-files --others --exclude-standard
    } | grep '\.swift$' | drop_non_sources | sort -u
  )"
fi

# Split on newlines only, so a path with a space in it survives, and drop the
# entries that are in the diff but not on disk (deleted, or renamed away).
set --
old_ifs="$IFS"
IFS='
'
# shellcheck disable=SC2086
for f in $FILES; do
  if [ -f "$f" ]; then
    set -- "$@" "$f"
  fi
done
IFS="$old_ifs"

if [ "$#" -eq 0 ]; then
  printf 'no Swift files to check (%s).\n' "$SCOPE_LABEL"
  exit 0
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

if [ "$ACTION" = "fix" ]; then
  printf 'Formatting %d Swift file(s) (%s).\n' "$#" "$SCOPE_LABEL"
  "$SWIFTFORMAT" --quiet "$@"
  exit 0
fi

printf 'Checking %d Swift file(s) (%s).\n' "$#" "$SCOPE_LABEL"

if [ "$FORCE_SUMMARY" -eq 0 ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  # Turns every violation into a file/line annotation, so a red run points at the
  # code in the diff view instead of at a summary line buried in the log.
  # Rewritten on the way out: GitHub only attaches an annotation to the diff when
  # the path is repo-relative, and the reporter emits warnings even though this
  # step is what fails the job.
  status=0
  output="$("$SWIFTFORMAT" --lint --quiet --reporter github-actions-log "$@" 2>&1)" || status=$?
  printf '%s\n' "$output" | sed -e "s|$ROOT_DIR/||g" -e 's|^::warning |::error |'
else
  # Compiler-style `path:line:col: error: (rule) reason`, minus the progress
  # chatter, with paths made repo-relative so they stay clickable.
  status=0
  output="$("$SWIFTFORMAT" --lint "$@" 2>&1)" || status=$?
  diagnostics="$(printf '%s\n' "$output" | grep ': error: (' | sed "s|$ROOT_DIR/||" || true)"
  count="$(printf '%s' "$diagnostics" | grep -c . || true)"
  if [ "$count" -gt "$TALLY_THRESHOLD" ]; then
    # A whole-tree run prints thousands of lines nobody reads; the per-rule tally
    # is what tells you what the remaining debt actually consists of.
    printf '%s\n' "$diagnostics" | sed -n 's/^.*: error: (\([A-Za-z]*\)).*/\1/p' | sort | uniq -c | sort -rn
    printf '%s violations in total.\n' "$count"
  elif [ "$count" -gt 0 ]; then
    printf '%s\n' "$diagnostics"
  fi
fi

if [ "$status" -eq 0 ]; then
  echo "SwiftFormat: clean."
  exit 0
fi

cat >&2 <<EOF

SwiftFormat found unformatted code in the files above.

  script/swiftformat_lint.sh --fix

formats exactly the same set. Only files this change touches are checked, so a
fix here should be small; if it is not, the file was simply never formatted
before and this is the pass that does it.
EOF
exit 1
