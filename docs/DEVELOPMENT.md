# ClashMax Development Guide

This is the maintained entry point for repository development. Local `AGENTS.md`
may add workstation context; shared rules and acceptance procedures belong in tracked
files. Check current behavior against source and the version pins in `project.yml`,
`.swiftformat` and `Resources/Core/mihomo-manifest.json`. Product/security rules and
maintainer decisions remain authoritative; dated measurements retain their original scope.

## Documentation Map

| Need | Document |
| --- | --- |
| Product, installation and everyday capabilities | [README](../README.md) / [简体中文](../README.zh-CN.md) |
| Setup, architecture, source checks and development rules | This guide |
| Contribution and review workflow | [CONTRIBUTING](../CONTRIBUTING.md) |
| Implemented features, remaining work and acceptance gaps | [Roadmap](ROADMAP.md) / [简体中文](ROADMAP.zh-CN.md) |
| Per-release manual checklist, feature procedures and sign-off | [Manual test plan](MANUAL_TEST_PLAN.md) |
| Signed bundle, packaging and release gates | [Release guide](RELEASE.md) |
| TUN data plane and menu bar details | [TUN smoke test](TUN_SMOKE_TEST.md), [menu bar QA](MENU_BAR_RICH_PANEL_QA.md) |
| Security reports and licensing | [SECURITY](../SECURITY.md), [LICENSE](../LICENSE), [third-party notices](../THIRD_PARTY_NOTICES.md) |
| Core installation and integrity policy | [Core README](../Resources/Core/README.md) |
| Partially implemented structured logging design | [Design](superpowers/specs/2026-07-28-structured-logging-design.md), [plan](superpowers/plans/2026-07-28-structured-logging.md) |
| Historical design and measured decisions | [Roadmap archive](archive/ROADMAP-2026-11-17.md), [UI refresh](UI_REFRESH_PLAN.md), [Observation migration](superpowers/specs/2026-08-03-observable-migration-design.md), [v1.19.32 adaptation](MIHOMO_1_19_32.md) |
| Open-source maintenance program proposal | [Codex OSS plan](CODEX_OSS_PLAN.md); separate from app features |

The root `MANUAL_TEST_PLAN.md`, `docs/APP_UPDATES.md` and `AGENTS.md` are ignored
workstation files. They may retain local evidence or operator details, but a fresh clone
must be able to develop and find release acceptance from the tracked guides above.

## Local Setup

Use macOS with Xcode, its command-line tools, XcodeGen, and the exact SwiftFormat version
pinned by `.swiftformat`. The app deployment target is macOS 15+; CI's Xcode selection is
maintained in [ci.yml](../.github/workflows/ci.yml).

For a fresh clone without an existing generated project:

```bash
script/install_mihomo_core.sh
xcodegen generate
```

The installer downloads the manifest-pinned architecture assets, checks their sha256 and
merges a universal `Resources/Core/mihomo`. The binary and generated
`ClashMax.xcodeproj/` are not committed. See the [core README](../Resources/Core/README.md)
for caching and bundle requirements.

Open the generated project, or run a focused check:

```bash
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:ClashMaxTests/ConfigNormalizerTests
```

For an existing local project, regenerate only when new Swift files, membership or project
configuration require it. First establish that generation preserves the user's Xcode UI
signing/profile setup, capabilities, entitlements and existing NE App Group. Use the
[project snapshot](../script/xcode_project_semantic_snapshot.sh) and
[guarded build wrapper](../script/guarded_xcodebuild.sh) when applicable; a mismatch is a
blocker to generation, not permission to overwrite the user's project.

Run/restart the app only when that is part of the task:

```bash
./script/build_and_run.sh
```

This script stops the current ClashMax process, replaces its local Debug bundle, builds
with the existing signing configuration and launches it. `--verify` also launches the app;
it is not a read-only source check. Normal app startup can affect its managed network state.

## Source Layout

| Path | Responsibility |
| --- | --- |
| `ClashMax/App` | App lifecycle, URL actions, App Intents and Shortcuts |
| `ClashMax/Stores` | Observable state and domain coordinators; `AppModel` still owns lifecycle orchestration |
| `ClashMax/Models` | Configuration, rules, diagnostic facts and pure builders |
| `ClashMax/Services` | Mihomo API/process, configuration materialization, disk/Keychain and macOS integrations |
| `ClashMax/Views` | SwiftUI workspaces, native input adapters, dashboard and menu bar |
| `Shared` | Cross-target protocols, bounded buffers and logging/privacy primitives |
| `ClashMaxHelper`, `ClashMaxNetworkExtension` | Privileged TUN ownership and transparent proxy provider |
| `ClashMaxTests` | XCTest/Swift Testing source verification |
| `Resources`, `Config`, `project.yml` | Localization/core manifest, target configuration and generated-project inputs |
| `script`, `.github/workflows` | Local verification, packaging and CI |
| `web`, `docs/web` | Public website source and generated static export; separate from native app UI |

Observation migration is implemented. Keep initialization priming with the properties it
serves (`didSet` does not run during `init`), preserve structural deduplication, and keep
high-frequency implementation state intentionally `@ObservationIgnored`. Check the current
stores/coordinators before adding behavior to `AppModel` or repeating an old extraction plan.

## Product And Runtime Boundaries

- Build a native macOS 15+ SwiftUI app. Gate newer platform APIs and supply practical fallbacks;
  use AppKit for integration gaps and SF Symbols for controls.
- The first screen is the proxy console. Keep profiles, proxies, connections, rules, logs,
  settings and menu bar controls quick to scan and operate.
- Preserve imported YAML. Generate app-managed runtime YAML before starting Mihomo.
- Bind the controller to `127.0.0.1`, generate a per-run secret and use Bearer authentication
  for controller access.
- User-mode core owns normal system proxy; the privileged helper owns TUN.
  macOS TUN YAML must not contain Linux-only `auto-redirect`.
- Keep the app's existing TUN stack and System DNS ownership decisions documented in the
  [roadmap](ROADMAP.md#retained-runtime-decisions).
- The historical MVP excluded telemetry, accounts, node collection, subscription analytics,
  embedded Sub-Store and Sparkle. Sparkle is now an existing, documented dependency and its
  maintenance is allowed. The other exclusions remain unless explicitly expanded.
- Follow the roadmap's [three layers and invariants](ROADMAP.md#2-design-principles--the-three-layers):
  fixes/forms write ordinary rules/snippets, with visible YAML, diff and rollback.

## Security, Signing And Licensing

- Keep ClashMax GPL-3.0-compatible. Do not copy proprietary code/assets/UI;
  `666OS/ClashMac` is product inspiration only. GPL adaptations retain notices and attribution;
  prefer implementing behavior in Swift. Sparkle is MIT.
- Helper/XPC boundaries validate app-provided paths and do not interpolate them into shell commands.
- Keep credentials, controller secrets, subscription URLs and private profile data out of output,
  logs, screenshots and external tools. Use the existing redaction boundaries for diagnostics.
- Signing team, profiles, bundle IDs, signing style/certificates, hardened runtime, capabilities,
  entitlements and dependency/embed settings are user-owned. Changes require an explicit request;
  preserve the existing NE App Group `group.678WA95W4U.io.github.clashmax.ClashMax.network-extension`.
- Real system proxy, DNS, routing, TUN/helper and System Extension operations need authorization
  covering the live operation. Record the baseline, restore test changes and check only the
  test's processes/listeners and network changes. The user performs administrator approval.
- Unsigned source tests cannot establish signed Helper/NE behavior, notarization or release readiness.
  Use the [release guide](RELEASE.md) for those gates.

## Build And Verification

Choose checks by the changed behavior:

| Change | Verification |
| --- | --- |
| Documentation/instructions only | Review diff, local links/anchors and preservation of unrelated work; no formatter, generation, app launch or application tests |
| Focused source change | Affected test class or test method first; build/check the affected behavior |
| Broad/cross-cutting source change or explicit full verification | Full suite, compared with the baseline |
| Swift changes | Exact pinned formatter on the task's files |
| User-visible strings | Localization gate and new-key translations |
| Release or signed system integration | [Release gates](RELEASE.md) and recorded manual observations |

Full source-test command:

```bash
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

Keep logs and `.xcresult`. Report actual `PASS`, `FAIL`, `BLOCKED` or `NOT RUN`, including
skips and the remaining unverified behavior. Broaden/repeat checks after a new change,
failure or unresolved risk; a documentation cleanup does not need an app test run.

[CI](../.github/workflows/ci.yml) runs hygiene checks, source tests, localization and an
unsigned universal Release build with a bundle-layout check. Both macOS jobs install the
manifest-pinned core. The test job sets `TEST_RUNNER_CLASHMAX_REQUIRE_BUNDLED_CORE=1`, so
missing real-core prerequisites fail instead of silently skipping. An ordinary local
checkout without the core can still skip those tests; install the core when their behavior
is the claim being verified.

### Code Formatting

[SwiftFormat](https://github.com/nicklockwood/SwiftFormat) must match the exact
`--minversion` in `.swiftformat`, including CI. Newer releases can enable additional rules
and produce changes the pinned CI does not accept. If Homebrew has moved past the pin,
install that release directly or set `SWIFTFORMAT` to its binary. A pin change includes the
CI version/checksum and the separately scoped normalization it requires.

```bash
script/swiftformat_lint.sh
script/swiftformat_lint.sh --fix
script/swiftformat_lint.sh --all --summary
```

Before `--fix`, verify the script's selection belongs to the task: it includes branch
changes and all uncommitted/untracked Swift files. If it includes unrelated work, use the
pinned formatter with `--config .swiftformat` on an explicit list of the task's edited paths.
Review the resulting diff and do not format unrelated files.

The current gate converges touched files incrementally. Whole-tree formatting remains a
separate explicitly scoped change at a quiet point with a clean tree. For that change:

1. Format with `script/swiftformat_lint.sh --all --fix` and verify idempotence.
2. Build/run the full source suite and `script/localization_gate.sh`; lint alone does not prove compilation.
3. Keep the mechanical change separate and record its revision in `.git-blame-ignore-revs`.

Token-moving rules such as `trailingCommas`, `hoistTry`, `redundantSelf` and `sortImports`
mean `git diff -w` is not a sufficient review. Preserve the configuration's disabled rules:
normalization must not restructure deliberate code. `--self-required` protects escaping
`os.Logger` interpolations; formatting multiline localized literals can change key values.
`project.yml` editor indentation and `.swiftformat` both use two spaces.

### Localization

`Resources/Localizable.xcstrings` is the source of user-visible strings. New keys require
`zh-Hans`; existing untranslated debt is explicitly bounded by the allowlist.

```bash
script/localization_gate.sh
script/localization_new_key_gate.sh
```

The full gate validates/compiles the catalog, checks new keys and runs localization tests.
The standalone new-key check needs `jq`, not Xcode. Remove translated keys from the allowlist;
growing it needs a stated reason. Its own fixtures are in `script/test_localization_new_key_gate.sh`.
Run the full gate after string changes and before shipping, **again after archive**: Xcode's
extraction can add untranslated keys after an earlier successful check.

### Specialized Verification

- Group-delay transport benchmark: `script/bench_group_delay.py`, using the bundled core or
  `--core PATH`. It starts isolated loopback cores, then tears them down; `--nodes`,
  `--concurrency`, `--timeout-ms` and `--keep` control the run. The
  [recorded measurement](MANUAL_TEST_PLAN.md#transport-level-measurement-done-2026-08-29)
  does not establish app scrolling/cancel behavior.
- Signed release entry point: `script/release_smoke_check.sh`; see the
  [release guide](RELEASE.md) for preflight, live scope, evidence and publication order.
- Menu bar and TUN procedures: [menu bar QA](MENU_BAR_RICH_PANEL_QA.md),
  [TUN smoke test](TUN_SMOKE_TEST.md). They are acceptance procedures, not automatic authorization
  to restart the app or alter the user's network.

## UI Constraints

- Keep operational screens dense and calm, using native lists/tables, split views,
  segmented controls, toggles, menus and icon buttons.
- Avoid decorative heroes, nested cards, oversized compact-panel type and one-hue palettes.
- Make stopped, starting, running, crashed, helper unavailable, no profile, no core and
  validation-failed states explicit. Give actionable, specific recovery messages.
- Loading skeletons use the shared SwiftUI-Shimmer primitives only for temporary async
  runtime/network loading. Stopped, empty, failed, security-sensitive and recovery states
  keep their real content.
- System materials belong to the appropriate window/control layer; validate real
  MenuBarExtra presentation and macOS 15 fallbacks separately from fixture content.
