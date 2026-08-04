#!/bin/sh
# Regenerate the gitignored ClashMax.xcodeproj safely, then pass through to xcodebuild.
#
# Adding a Swift file to this repository requires re-running XcodeGen, and a regeneration
# is also the only moment signing, entitlements, capabilities, dependencies, or
# embed/copy phases could silently drift. This wrapper never lets XcodeGen touch the real
# worktree: it generates a candidate inside a disposable mirror, proves the candidate is
# semantically identical to the recorded baseline apart from allowlisted source
# additions, stages an install that carries user-owned files forward byte-for-byte, and
# only then atomically swaps the project into place. Any mismatch quarantines the
# candidate, restores the exact previous project bundle, and stops before xcodebuild runs.
#
# Usage:
#   guarded_xcodebuild.sh --initialize --allowlist FILE
#       Record the pre-change baseline and recoverable backup. Refuses to overwrite.
#   guarded_xcodebuild.sh --verify-only [--require-complete-allowlist]
#       Check the installed project against the baseline without regenerating or building.
#   guarded_xcodebuild.sh <xcodebuild arguments...>
#       Regenerate under guard, then exec /usr/bin/xcodebuild with the arguments unchanged.
#
# Environment:
#   CLASHMAX_GUARD_DIR           override the guard directory (tests use this)
#   CLASHMAX_GUARD_FORCE_ROLLBACK=1  force a post-install rollback to exercise recovery
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SNAPSHOT_TOOL="$SCRIPT_DIR/xcode_project_semantic_snapshot.sh"
GUARD_DIR="${CLASHMAX_GUARD_DIR:-$ROOT_DIR/DerivedData/StructuredLoggingProjectGuard}"
DEFAULT_ALLOWLIST="$ROOT_DIR/docs/superpowers/plans/2026-07-28-structured-logging-xcode-sources.allowlist"

PROJECT="$ROOT_DIR/ClashMax.xcodeproj"
BASELINE="$GUARD_DIR/baseline.json"
BEFORE_BACKUP="$GUARD_DIR/ClashMax.before.xcodeproj"
PREVIOUS_BACKUP="$GUARD_DIR/ClashMax.previous.xcodeproj"
REJECTED_DIR="$GUARD_DIR/rejected"
STAGED="$ROOT_DIR/ClashMax.staged.xcodeproj"

ALLOWLIST="$DEFAULT_ALLOWLIST"
MODE="build"
REQUIRE_COMPLETE=""

# Only the leading guard flags are consumed; everything else goes to xcodebuild verbatim.
while [ $# -gt 0 ]; do
  case "$1" in
    --initialize) MODE="initialize"; shift ;;
    --verify-only) MODE="verify"; shift ;;
    --require-complete-allowlist) REQUIRE_COMPLETE="--require-complete-allowlist"; shift ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    *) break ;;
  esac
done

log() { printf 'guard: %s\n' "$*" >&2; }
die() { printf 'guard: %s\n' "$*" >&2; exit 1; }

MIRROR=""
cleanup() {
  if [ -n "$MIRROR" ]; then rm -rf "$MIRROR"; fi
  rm -rf "$STAGED"
}
trap cleanup EXIT

snapshot() {
  # snapshot <project> <root> <output> [--include-preserved]
  bash "$SNAPSHOT_TOOL" snapshot --project "$1" --root "$2" --output "$3" ${4:+$4}
}

copy_preserved_into() {
  # copy_preserved_into <source-project> <destination-project>
  for relative in \
    "xcuserdata" \
    "project.xcworkspace/xcuserdata" \
    "project.xcworkspace/xcshareddata/swiftpm"; do
    if [ -e "$1/$relative" ]; then
      mkdir -p "$(dirname "$2/$relative")"
      rm -rf "$2/$relative"
      cp -R "$1/$relative" "$2/$relative"
    fi
  done
}

case "$MODE" in
  initialize)
    [ -d "$PROJECT" ] || die "no project to protect at $PROJECT"
    if [ -e "$GUARD_DIR" ]; then
      die "guard directory already exists: $GUARD_DIR (refusing to overwrite a baseline)"
    fi
    mkdir -p "$GUARD_DIR"
    cp -R "$PROJECT" "$BEFORE_BACKUP"
    snapshot "$PROJECT" "$ROOT_DIR" "$BASELINE"
    log "baseline recorded at $BASELINE"
    log "recoverable backup at $BEFORE_BACKUP"
    exit 0
    ;;
  verify)
    [ -f "$BASELINE" ] || die "no baseline; run --initialize first"
    snapshot "$PROJECT" "$ROOT_DIR" "$GUARD_DIR/installed.json"
    bash "$SNAPSHOT_TOOL" compare \
      --baseline "$BASELINE" --candidate "$GUARD_DIR/installed.json" \
      --sections generatorSecurity,sources \
      --allowlist "$ALLOWLIST" $REQUIRE_COMPLETE \
      || die "installed project does not satisfy the guard"
    cp "$GUARD_DIR/installed.json" "$GUARD_DIR/latest.json"
    log "installed project verified against baseline"
    exit 0
    ;;
esac

[ -f "$BASELINE" ] || die "no baseline; run --initialize first"
[ -d "$PROJECT" ] || die "no project at $PROJECT"
command -v xcodegen >/dev/null 2>&1 || die "xcodegen is required"

# 1. Generate the candidate inside a disposable mirror. XcodeGen never sees the worktree.
MIRROR="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-guard.XXXXXX")"
tar -C "$ROOT_DIR" \
  --exclude "./.git" \
  --exclude "./.worktrees" \
  --exclude "./DerivedData*" \
  --exclude "./ClashMax.xcodeproj" \
  --exclude "./ClashMax.staged.xcodeproj" \
  --exclude "./build" \
  --exclude "./dist" \
  --exclude "./.build" \
  -cf - . | tar -C "$MIRROR" -xf -

xcodegen generate \
  --spec "$MIRROR/project.yml" \
  --project "$MIRROR" \
  --project-root "$MIRROR" >/dev/null \
  || die "xcodegen failed inside the mirror; the real project was not touched"

CANDIDATE="$MIRROR/ClashMax.xcodeproj"
[ -d "$CANDIDATE" ] || die "xcodegen produced no project in the mirror"

# 2. Raw candidate: security must be byte-equal, sources may only add allowlisted files.
snapshot "$CANDIDATE" "$MIRROR" "$GUARD_DIR/candidate.json"
if ! bash "$SNAPSHOT_TOOL" compare \
  --baseline "$BASELINE" --candidate "$GUARD_DIR/candidate.json" \
  --sections generatorSecurity,sources --allowlist "$ALLOWLIST"; then
  mkdir -p "$REJECTED_DIR"
  rm -rf "$REJECTED_DIR/candidate.xcodeproj"
  cp -R "$CANDIDATE" "$REJECTED_DIR/candidate.xcodeproj"
  die "candidate project rejected; real project untouched, candidate quarantined in $REJECTED_DIR"
fi

# 3. Stage the validated candidate beside the real project and carry user-owned files
#    forward byte-for-byte, then require all three sections to pass.
rm -rf "$STAGED"
cp -R "$CANDIDATE" "$STAGED"
copy_preserved_into "$PROJECT" "$STAGED"
snapshot "$PROJECT" "$ROOT_DIR" "$GUARD_DIR/preserved-manifest.json" --include-preserved
snapshot "$STAGED" "$ROOT_DIR" "$GUARD_DIR/staged.json" --include-preserved
if ! bash "$SNAPSHOT_TOOL" compare \
  --baseline "$BASELINE" --candidate "$GUARD_DIR/staged.json" \
  --sections generatorSecurity,sources --allowlist "$ALLOWLIST"; then
  mkdir -p "$REJECTED_DIR"
  rm -rf "$REJECTED_DIR/staged.xcodeproj"
  mv "$STAGED" "$REJECTED_DIR/staged.xcodeproj"
  die "staged project rejected; real project untouched"
fi
if ! bash "$SNAPSHOT_TOOL" compare \
  --baseline "$GUARD_DIR/preserved-manifest.json" --candidate "$GUARD_DIR/staged.json" \
  --sections preservedFiles; then
  mkdir -p "$REJECTED_DIR"
  rm -rf "$REJECTED_DIR/staged.xcodeproj"
  mv "$STAGED" "$REJECTED_DIR/staged.xcodeproj"
  die "staged project lost user-owned files; real project untouched"
fi

# This repository lives in an iCloud-managed folder. Moving a bundle into a path that was
# just vacated is safe only as a same-volume rename; a cross-volume move lets iCloud
# "resolve" it by renaming the arrival to "ClashMax 2.xcodeproj", which looks exactly like
# a lost project. Keeping the guard directory on the project's volume prevents it, and
# this check makes any remaining case fail loudly instead of silently.
assert_project_landed() {
  if [ ! -d "$PROJECT" ]; then
    die "$1: no bundle at $PROJECT"
  fi
  for sibling in "$ROOT_DIR"/ClashMax\ [0-9]*.xcodeproj; do
    if [ -e "$sibling" ]; then
      die "$1: iCloud renamed the bundle to $(basename "$sibling"); rename it back to ClashMax.xcodeproj"
    fi
  done
}

# 4. Atomic install with a recoverable previous bundle kept until the install verifies.
rm -rf "$PREVIOUS_BACKUP"
mv "$PROJECT" "$PREVIOUS_BACKUP"
mv "$STAGED" "$PROJECT"
assert_project_landed "install"

install_failed() {
  mkdir -p "$REJECTED_DIR"
  rm -rf "$REJECTED_DIR/installed.xcodeproj"
  mv "$PROJECT" "$REJECTED_DIR/installed.xcodeproj"
  mv "$PREVIOUS_BACKUP" "$PROJECT"
  assert_project_landed "rollback"
  die "$1; previous project restored byte-for-byte"
}

snapshot "$PROJECT" "$ROOT_DIR" "$GUARD_DIR/installed.json" --include-preserved
bash "$SNAPSHOT_TOOL" compare \
  --baseline "$BASELINE" --candidate "$GUARD_DIR/installed.json" \
  --sections generatorSecurity,sources --allowlist "$ALLOWLIST" \
  || install_failed "installed project failed the security/source check"
bash "$SNAPSHOT_TOOL" compare \
  --baseline "$GUARD_DIR/preserved-manifest.json" --candidate "$GUARD_DIR/installed.json" \
  --sections preservedFiles \
  || install_failed "installed project lost user-owned files"
if [ "${CLASHMAX_GUARD_FORCE_ROLLBACK:-0}" = "1" ]; then
  install_failed "forced rollback requested"
fi

# The accepted snapshot is the evidence artifact the plan's by-hand comparisons read.
cp "$GUARD_DIR/installed.json" "$GUARD_DIR/latest.json"
log "project regenerated and verified"

if [ $# -eq 0 ]; then
  exit 0
fi
exec /usr/bin/xcodebuild "$@"
