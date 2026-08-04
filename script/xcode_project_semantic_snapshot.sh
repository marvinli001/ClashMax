#!/bin/sh
# Canonical semantic snapshot / compare for the XcodeGen-generated ClashMax project.
#
# `ClashMax.xcodeproj` is gitignored user-owned state: regenerating it is the only way
# to pick up new source files, but a regeneration is also the only way signing,
# entitlements, capabilities, or embed phases could silently drift. This tool reduces a
# project bundle to three deliberately separate sections so a regeneration can be
# accepted on `sources` alone while `generatorSecurity` and `preservedFiles` must match
# byte-for-byte.
#
#   generatorSecurity  product types, build configurations and raw settings, project
#                      TargetAttributes/SystemCapabilities, entitlement + Info.plist
#                      paths with SHA-256 of their contents, target dependencies and
#                      product references, shell-script phase bodies and IO paths,
#                      copy/embed phase destinations and build-file attributes such as
#                      CodeSignOnCopy, and generated workspace/shared-scheme hashes.
#   sources            normalized target/path tuples only. The allowlist comparison is
#                      the *only* thing permitted to differ this section.
#   preservedFiles     non-generator-owned bundle contents (xcuserdata, SwiftPM
#                      Package.resolved) as byte hashes.
#
# Usage:
#   xcode_project_semantic_snapshot.sh snapshot --project P.xcodeproj --root REPO
#       [--include-preserved] [--output FILE]
#   xcode_project_semantic_snapshot.sh compare --baseline A.json --candidate B.json
#       --sections generatorSecurity[,sources][,preservedFiles]
#       [--allowlist FILE] [--require-complete-allowlist]
#   xcode_project_semantic_snapshot.sh compare-security BASELINE CANDIDATE
#   xcode_project_semantic_snapshot.sh compare-sources BASELINE CANDIDATE [ALLOWLIST]
#       positional shorthands for the two single-section comparisons run by hand.
#
# `compare` exits 0 when every requested section matches and prints only classified
# changed keys otherwise.
set -eu

usage() {
  sed -n '2,30p' "$0" >&2
  exit 2
}

MODE="${1:-}"
[ -n "$MODE" ] || usage
shift || true

PROJECT=""
ROOT=""
OUTPUT=""
INCLUDE_PRESERVED=0
BASELINE=""
CANDIDATE=""
SECTIONS="generatorSecurity,sources"
ALLOWLIST=""
REQUIRE_COMPLETE=0

# Positional convenience forms for the two comparisons that get run by hand:
#   compare-security BASELINE CANDIDATE
#   compare-sources  BASELINE CANDIDATE [ALLOWLIST]
case "$MODE" in
  compare-security)
    BASELINE="${1:?compare-security needs a baseline}"
    CANDIDATE="${2:?compare-security needs a candidate}"
    SECTIONS="generatorSecurity"
    MODE="compare"
    shift 2
    ;;
  compare-sources)
    BASELINE="${1:?compare-sources needs a baseline}"
    CANDIDATE="${2:?compare-sources needs a candidate}"
    SECTIONS="sources"
    MODE="compare"
    shift 2
    if [ $# -gt 0 ]; then
      case "$1" in
        --*) : ;;
        *) ALLOWLIST="$1"; shift ;;
      esac
    fi
    ;;
esac

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --root) ROOT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --include-preserved) INCLUDE_PRESERVED=1; shift ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    --candidate) CANDIDATE="$2"; shift 2 ;;
    --sections) SECTIONS="$2"; shift 2 ;;
    --allowlist) ALLOWLIST="$2"; shift 2 ;;
    --require-complete-allowlist) REQUIRE_COMPLETE=1; shift ;;
    *) echo "unknown argument: $1" >&2; usage ;;
  esac
done

# The Python payloads live in quoted here-documents so the shell never parses them.
snapshot_payload() {
  cat <<'CLASHMAX_SNAPSHOT_PY'
import hashlib
import json
import os
import plistlib
import subprocess
import sys

project = os.environ["CLASHMAX_SNAPSHOT_PROJECT"]
root = os.environ["CLASHMAX_SNAPSHOT_ROOT"]
include_preserved = os.environ["CLASHMAX_SNAPSHOT_PRESERVED"] == "1"

SECURITY_TARGETS = ("ClashMax", "ClashMaxHelper", "ClashMaxNetworkExtension")


def sha256_file(path):
    if not os.path.isfile(path):
        return None
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def load_pbxproj(bundle):
    raw = subprocess.run(
        ["/usr/bin/plutil", "-convert", "json", "-o", "-", os.path.join(bundle, "project.pbxproj")],
        check=True,
        capture_output=True,
    ).stdout
    return json.loads(raw)


doc = load_pbxproj(project)
objects = doc["objects"]
pbxproject = objects[doc["rootObject"]]


def obj(identifier):
    return objects.get(identifier) or {}


# Child -> parent map so a file reference can be resolved to a repository-relative path.
parent_of = {}
for identifier, node in objects.items():
    if node.get("isa") in ("PBXGroup", "PBXVariantGroup"):
        for child in node.get("children", []):
            parent_of[child] = identifier


def resolved_path(file_ref_id):
    """Repository-relative path of a file reference, walking up the group tree."""
    components = []
    current = file_ref_id
    seen = set()
    while current and current not in seen:
        seen.add(current)
        node = obj(current)
        source_tree = node.get("sourceTree")
        path = node.get("path")
        if path:
            components.append(path)
        if source_tree in ("SOURCE_ROOT", "<absolute>", "SDKROOT", "DEVELOPER_DIR", "BUILT_PRODUCTS_DIR"):
            break
        current = parent_of.get(current)
    return "/".join(reversed(components))


def build_settings_for(config_list_id):
    entries = {}
    for config_id in obj(config_list_id).get("buildConfigurations", []):
        config = obj(config_id)
        entries[config.get("name", config_id)] = config.get("buildSettings", {})
    return entries


def entitlement_and_info_paths(settings_by_config):
    """Every generator-managed Config file a target points at, with its content hash."""
    referenced = {}
    for settings in settings_by_config.values():
        for key in ("CODE_SIGN_ENTITLEMENTS", "INFOPLIST_FILE"):
            value = settings.get(key)
            if isinstance(value, str) and value:
                referenced[value] = sha256_file(os.path.join(root, value))
    return referenced


def phase_snapshot(phase_id):
    phase = obj(phase_id)
    isa = phase.get("isa")
    if isa == "PBXShellScriptBuildPhase":
        return {
            "isa": isa,
            "name": phase.get("name"),
            "shellPath": phase.get("shellPath"),
            "shellScript": phase.get("shellScript"),
            "inputPaths": phase.get("inputPaths", []),
            "outputPaths": phase.get("outputPaths", []),
            "alwaysOutOfDate": phase.get("alwaysOutOfDate"),
        }
    if isa == "PBXCopyFilesBuildPhase":
        files = []
        for build_file_id in phase.get("files", []):
            build_file = obj(build_file_id)
            files.append({
                "path": resolved_path(build_file.get("fileRef", "")),
                "attributes": (build_file.get("settings") or {}).get("ATTRIBUTES", []),
            })
        return {
            "isa": isa,
            "name": phase.get("name"),
            "dstPath": phase.get("dstPath"),
            "dstSubfolderSpec": phase.get("dstSubfolderSpec"),
            "files": sorted(files, key=lambda item: item["path"]),
        }
    if isa == "PBXFrameworksBuildPhase":
        return {
            "isa": isa,
            "files": sorted(
                resolved_path(obj(f).get("fileRef", "")) for f in phase.get("files", [])
            ),
        }
    # Sources and resources phases are membership, not security: they live in `sources`.
    return None


def dependency_snapshot(dependency_id):
    dependency = obj(dependency_id)
    target_id = dependency.get("target")
    name = obj(target_id).get("name") if target_id else dependency.get("name")
    proxy = obj(dependency.get("targetProxy", ""))
    return {
        "targetName": name,
        "proxyType": proxy.get("proxyType"),
        "remoteInfo": proxy.get("remoteInfo"),
    }


targets_by_name = {}
for target_id in pbxproject.get("targets", []):
    target = obj(target_id)
    targets_by_name[target.get("name", target_id)] = (target_id, target)

generator_security = {}
for name in SECURITY_TARGETS:
    if name not in targets_by_name:
        generator_security[name] = {"missing": True}
        continue
    target_id, target = targets_by_name[name]
    settings_by_config = build_settings_for(target.get("buildConfigurationList", ""))
    phases = [phase_snapshot(p) for p in target.get("buildPhases", [])]
    generator_security[name] = {
        "productType": target.get("productType"),
        "productName": target.get("productName"),
        "productReference": resolved_path(target.get("productReference", "")),
        "buildSettings": settings_by_config,
        "configurationNames": sorted(settings_by_config.keys()),
        "targetAttributes": (pbxproject.get("attributes", {}).get("TargetAttributes", {})).get(target_id, {}),
        "configFiles": entitlement_and_info_paths(settings_by_config),
        "dependencies": sorted(
            (dependency_snapshot(d) for d in target.get("dependencies", [])),
            key=lambda item: json.dumps(item, sort_keys=True),
        ),
        "packageProductDependencies": sorted(
            obj(p).get("productName", p) for p in target.get("packageProductDependencies", [])
        ),
        "phases": [p for p in phases if p is not None],
    }

generator_security["__project__"] = {
    "buildSettings": build_settings_for(pbxproject.get("buildConfigurationList", "")),
    "attributes": {
        key: value
        for key, value in pbxproject.get("attributes", {}).items()
        if key != "TargetAttributes"
    },
    "packageReferences": sorted(
        obj(p).get("repositoryURL", p) for p in pbxproject.get("packageReferences", [])
    ),
    "compatibilityVersion": pbxproject.get("compatibilityVersion"),
    "developmentRegion": pbxproject.get("developmentRegion"),
}

# Generated workspace + shared schemes are generator-owned and security relevant.
generated_hashes = {}
for relative in (
    "project.xcworkspace/contents.xcworkspacedata",
    "project.xcworkspace/xcshareddata/WorkspaceSettings.xcsettings",
):
    generated_hashes[relative] = sha256_file(os.path.join(project, relative))
schemes_dir = os.path.join(project, "xcshareddata", "xcschemes")
if os.path.isdir(schemes_dir):
    for entry in sorted(os.listdir(schemes_dir)):
        generated_hashes["xcshareddata/xcschemes/" + entry] = sha256_file(os.path.join(schemes_dir, entry))
generator_security["__generatedFiles__"] = generated_hashes

# `sources`: normalized target/path tuples, nothing else.
sources = {}
for name, (target_id, target) in sorted(targets_by_name.items()):
    paths = set()
    for phase_id in target.get("buildPhases", []):
        phase = obj(phase_id)
        if phase.get("isa") not in ("PBXSourcesBuildPhase", "PBXResourcesBuildPhase"):
            continue
        for build_file_id in phase.get("files", []):
            file_ref = obj(build_file_id).get("fileRef")
            if not file_ref:
                continue
            path = resolved_path(file_ref)
            if path:
                paths.add(path)
    sources[name] = sorted(paths)

preserved = {}
if include_preserved:
    preserved_roots = ("xcuserdata", "project.xcworkspace/xcuserdata", "project.xcworkspace/xcshareddata/swiftpm")
    for relative_root in preserved_roots:
        absolute_root = os.path.join(project, relative_root)
        if os.path.isfile(absolute_root):
            preserved[relative_root] = sha256_file(absolute_root)
        elif os.path.isdir(absolute_root):
            for dirpath, _, filenames in os.walk(absolute_root):
                for filename in sorted(filenames):
                    absolute = os.path.join(dirpath, filename)
                    preserved[os.path.relpath(absolute, project)] = sha256_file(absolute)

json.dump(
    {"generatorSecurity": generator_security, "sources": sources, "preservedFiles": preserved},
    sys.stdout,
    sort_keys=True,
    indent=2,
)
sys.stdout.write("\n")

CLASHMAX_SNAPSHOT_PY
}

compare_payload() {
  cat <<'CLASHMAX_COMPARE_PY'
import json
import os
import sys

baseline = json.load(open(os.environ["CLASHMAX_COMPARE_BASELINE"]))
candidate = json.load(open(os.environ["CLASHMAX_COMPARE_CANDIDATE"]))
sections = [s for s in os.environ["CLASHMAX_COMPARE_SECTIONS"].split(",") if s]
allowlist_path = os.environ.get("CLASHMAX_COMPARE_ALLOWLIST") or ""
require_complete = os.environ.get("CLASHMAX_COMPARE_REQUIRE_COMPLETE") == "1"

failures = []


def flatten(value, prefix=""):
    if isinstance(value, dict):
        for key in sorted(value):
            yield from flatten(value[key], prefix + "/" + str(key))
    elif isinstance(value, list):
        yield prefix, json.dumps(value, sort_keys=True)
    else:
        yield prefix, value


def diff_exact(section):
    flat_baseline = dict(flatten(baseline.get(section, {})))
    flat_candidate = dict(flatten(candidate.get(section, {})))
    for key in sorted(set(flat_baseline) | set(flat_candidate)):
        before = flat_baseline.get(key, "<absent>")
        after = flat_candidate.get(key, "<absent>")
        if before != after:
            failures.append("%s%s: %r -> %r" % (section, key, before, after))


def load_allowlist():
    allowed = set()
    if not allowlist_path:
        return allowed
    with open(allowlist_path) as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line or line.lstrip().startswith("#"):
                continue
            target, _, path = line.partition("\t")
            if not path:
                failures.append("allowlist/malformed: %r is not target<TAB>path" % line)
                continue
            allowed.add((target.strip(), path.strip()))
    return allowed


def diff_sources():
    allowed = load_allowlist()
    baseline_sources = baseline.get("sources", {})
    candidate_sources = candidate.get("sources", {})
    used = set()
    for target in sorted(set(baseline_sources) | set(candidate_sources)):
        before = set(baseline_sources.get(target, []))
        after = set(candidate_sources.get(target, []))
        for removed in sorted(before - after):
            failures.append("sources/%s: removed %s" % (target, removed))
        for added in sorted(after - before):
            if (target, added) in allowed:
                used.add((target, added))
            else:
                failures.append("sources/%s: added %s (not in allowlist)" % (target, added))
    if require_complete:
        for target, path in sorted(allowed - used):
            failures.append("sources/%s: allowlisted %s is missing from the project" % (target, path))


for section in sections:
    if section == "sources":
        diff_sources()
    else:
        diff_exact(section)

if failures:
    sys.stderr.write("semantic project guard: %d classified change(s)\n" % len(failures))
    for failure in failures:
        sys.stderr.write("  " + failure + "\n")
    sys.exit(1)
sys.exit(0)
CLASHMAX_COMPARE_PY
}

case "$MODE" in
  snapshot)
    [ -n "$PROJECT" ] || { echo "snapshot requires --project" >&2; exit 2; }
    [ -d "$PROJECT" ] || { echo "not a project bundle: $PROJECT" >&2; exit 2; }
    [ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$PROJECT")" && pwd)"
    CLASHMAX_SNAPSHOT_PROJECT="$PROJECT" \
    CLASHMAX_SNAPSHOT_ROOT="$ROOT" \
    CLASHMAX_SNAPSHOT_PRESERVED="$INCLUDE_PRESERVED" \
    python3 -c "$(snapshot_payload)" > "${OUTPUT:-/dev/stdout}"
    ;;
  compare)
    [ -n "$BASELINE" ] && [ -n "$CANDIDATE" ] || { echo "compare requires --baseline and --candidate" >&2; exit 2; }
    CLASHMAX_COMPARE_BASELINE="$BASELINE" \
    CLASHMAX_COMPARE_CANDIDATE="$CANDIDATE" \
    CLASHMAX_COMPARE_SECTIONS="$SECTIONS" \
    CLASHMAX_COMPARE_ALLOWLIST="$ALLOWLIST" \
    CLASHMAX_COMPARE_REQUIRE_COMPLETE="$REQUIRE_COMPLETE" \
    python3 -c "$(compare_payload)"
    ;;
  *)
    usage
    ;;
esac
