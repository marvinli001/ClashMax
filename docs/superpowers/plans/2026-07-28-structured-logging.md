# Structured Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build two genuinely independent, persistent logging channels for ClashMax application events and Mihomo/Helper/NE/TUN runtime events, with safe Support Debug by default and a native SwiftUI log viewer.

**Architecture:** A shared producer layer removes credentials before any producer-owned buffer, then a main-app recorder validates, sequences, projects, samples, stores, and persists events. Application and runtime channels use separate observable stores and rotating JSONL files; the SwiftUI page consumes immutable snapshots through pure query and viewport policies, while every copy/export/diagnostics path forces the same Support projection.

**Tech Stack:** Swift 6, SwiftUI on macOS 15+, Observation (`@Observable`/`@Environment`), Foundation actors and JSONL, AppKit only for clipboard/folder integration, XCTest/Swift Testing, XcodeGen.

---

## Scope and execution guardrails

- Implement against the confirmed design at `docs/superpowers/specs/2026-07-28-structured-logging-design.md`.
- Keep this as one plan because the producer integrations are not independently shippable: all four runtime sources must terminate in the same recorder, privacy projection, stores, persistence, and UI.
- Do not modify `Config/*.entitlements`, signing identities, provisioning profiles, App Group identifiers, embed/signing scripts, or Signing & Capabilities.
- Do not start a real Mihomo process, install/register Helper or Network Extension, change System Proxy/DNS/routes, or run sleep/wake acceptance during automated implementation.
- The ignored local `ClashMax.xcodeproj` is user-owned state. Never invoke `xcodegen` directly after implementation begins. Task 1 installs a guarded wrapper that candidate-generates inside an isolated file-tree mirror, semantically compares App/Helper/NE signing, entitlements, capabilities, generator-managed Config files, dependencies, shell scripts, and copy/embed phases against a pre-change snapshot, validates an exact target/path source allowlist, and only then atomically installs the validated project bundle.
- Every later `xcodebuild test` or `xcodebuild build` command in this plan runs through that guarded wrapper. This both preserves the Xcode project and regenerates membership when a newly created Swift/test file appears. A semantic mismatch must restore/quarantine without auto-accepting the change, stop the task immediately, and request user direction.
- The App and Helper targets recursively include `Shared`, but the Network Extension target lists Shared files explicitly; every new Shared logging file must be added to that explicit list.
- `ClashMaxTests` is an App-hosted unit-test target and cannot directly `@testable import` private Helper/NE products. Put cross-target parsing, redaction, event construction, and retention policy in Shared for executable tests; use existing project/source contract tests only for private target wiring.
- Use `@superpowers:test-driven-development` for every task and `@superpowers:verification-before-completion` before reporting completion.
- Baseline in this worktree is `798 PASS / 1 SKIP / 0 FAIL` (799 total), recorded in `DerivedData/TestResults/StructuredLoggingBaselineClean.xcresult`.
- The immutable implementation-diff baseline is commit `6b7f114`; final configuration/signing guards must compare committed history from that commit, not only the current working tree.

## File map

### Generated Xcode project safety

- Create `script/xcode_project_semantic_snapshot.sh`
  - Canonical JSON snapshot/compare for App, Helper, and Network Extension target product types, raw build configurations/settings, `TargetAttributes`/`SystemCapabilities`, entitlement paths and file hashes, target dependencies, shell-script phases, copy/embed phases and `CodeSignOnCopy` attributes, workspace/shared-scheme hashes, preserved non-generator project contents, plus separately comparable target/source membership.
- Create `script/guarded_xcodebuild.sh`
  - Candidate `xcodegen`, semantic/source checks, recoverable actual-project backup/restore, then pass-through to `/usr/bin/xcodebuild`.
- Create `script/test_xcode_project_guard.sh`
  - Fixture checks for accepted no-op/allowlisted source additions and rejected signing, capability, embed, script, removal, and unexpected-source changes.
- Modify `script/localization_gate.sh`
  - Accept an injected guarded-build path so structured-logging verification cannot bypass project protection.
- Create `docs/superpowers/plans/2026-07-28-structured-logging-xcode-sources.allowlist`
  - Exact target/path tuples for every new Swift source/test file named by this plan; Task 1 may add only the current subset and Task 15 requires the complete set.
- Keep the pre-change semantic snapshot and recoverable project backup under ignored `DerivedData/StructuredLoggingProjectGuard/`; do not commit the local `.xcodeproj` or snapshot.

### Shared producer boundary

- Create `Shared/StructuredLogProducer.swift`
  - Shared enums for level, audience, and source plus `ProducerLogEvent`.
- Create `Shared/StructuredLogPrivacy.swift`
  - Foundation-only credential and metadata redaction.
- Create `Shared/SanitizedLineAccumulator.swift`
  - Bounded chunk-to-line assembly that emits only redacted lines.
- All three Shared files must compile in App, Helper, and Network Extension targets without AppKit, SwiftUI, Observation, or App-only types.
- Modify `project.yml`
  - Add the three new Shared logging files to the explicit Network Extension source list only.
  - Do not touch any target settings, entitlements, signing, or embedding.

### Main-app model, pipeline, and storage

- Create `ClashMax/Models/StructuredLogEvent.swift`
  - Channel/event model, validation, filter mapping, quality counters, deterministic sort.
- Create `ClashMax/Services/StructuredLogProjection.swift`
  - Support and Developer projections; Support formatting input.
- Create `ClashMax/Services/StructuredLogPersistence.swift`
  - Fixed-path rotating JSONL actor, bounded recovery, clear, and flush.
- Create `ClashMax/Services/StructuredLogSampler.swift`
  - Important-event bypass and short-window fingerprint aggregation.
- Create `ClashMax/Stores/LogChannelStore.swift`
  - Reusable marker-generic `@MainActor @Observable` bounded store with batched publication and generation-safe clear/recovery.
- Create `ClashMax/Services/StructuredLogRecorder.swift`
  - Channel validation, sequence assignment, central redaction, sampling, persistence ordering, recovery, clear, and bounded termination flush.
- Create `ClashMax/Models/LogPresentation.swift`
  - Pure query/filter/search, tab state, runtime-card selection, and viewport follow policy.
- Create `ClashMax/Stores/LogNavigationState.swift`
  - Small independent `@Observable` cross-page navigation request.
- Create `ClashMax/Services/StructuredLogExport.swift`
  - One Support formatter shared by clipboard, file export, and diagnostics.

### Existing integration points

- Modify `ClashMax/Support/RuntimePaths.swift`
  - Fixed application/runtime log URLs and retained-cap constants.
- Modify `ClashMax/Stores/RuntimeDataStore.swift`
  - Remove old log ownership only after all consumers migrate.
- Modify `ClashMax/Models/CoreModels.swift`
  - Default missing runtime log level to `debug`; remove legacy `LogEntry`/`LogVisibility` at the end.
- Modify `ClashMax/Services/SystemProxyController.swift`
  - Separate executable arguments from redacted display descriptions.
- Modify `ClashMax/Services/TunRuntimeInspector.swift`
  - Use a safe display description and emit change-oriented TUN input.
- Create `ClashMax/Services/TunDiagnosticsEventDiffer.swift`
  - Pure stable-ID diff for TUN, route, DNS, refresh, and repair events.
- Modify `ClashMax/Services/CoreProcessController.swift`
  - Source-redacted, line-bounded stdout/stderr with distinct stream labels.
- Modify `ClashMax/Services/MihomoAPIClient.swift`
  - Structured `/logs` query and backward-compatible decoding.
- Modify `Shared/HelperProtocol.swift`, `ClashMaxHelper/main.swift`, and `ClashMax/Services/TunnelHelperClient.swift`
  - Structured Helper ring, old-text compatibility, and incremental import.
- Modify `Shared/NetworkExtensionRuntimeConstants.swift`, `ClashMaxNetworkExtension/TransparentProxyProvider.swift`, and `ClashMax/Services/NetworkExtensionController.swift`
  - Backward-compatible shared event ring with source-side redaction.
- Modify `ClashMax/Stores/AppModel.swift`
  - Own/inject the logging subsystem and record App/Mihomo/Helper/NE/TUN events.
- Modify `ClashMax/App/ClashMaxApp.swift`
  - Environment injection, one-time recovery, and bounded termination flush.

### SwiftUI and output surfaces

- Modify `ClashMax/Views/LogsView.swift`
  - Parent page orchestration, active-channel toolbar, current-tab search, actions, and confirmations.
- Create `ClashMax/Views/Logs/LogChannelPane.swift`
  - Per-channel query task, content states, lazy list, and scroll integration.
- Create `ClashMax/Views/Logs/StructuredLogRow.swift`
  - Expandable, accessible structured row with stable semantic styling.
- Create `ClashMax/Views/Dashboard/RecentRuntimeLogsCard.swift`
  - Runtime-only Support summary reused by Home and Status.
- Modify `ClashMax/Views/ContentView.swift`
  - Consume explicit log-navigation requests.
- Modify `ClashMax/Views/Dashboard/RunningDashboardView.swift`
  - Runtime-only Support card and runtime-tab jump.
- Modify `Resources/Localizable.xcstrings`
  - English and Simplified Chinese strings for all new UI and failure states.

### Tests

- Create:
  - `ClashMaxTests/StructuredLogProducerTests.swift`
  - `ClashMaxTests/StructuredLogEventTests.swift`
  - `ClashMaxTests/StructuredLogProjectionTests.swift`
  - `ClashMaxTests/StructuredLogPersistenceTests.swift`
  - `ClashMaxTests/StructuredLogSamplerTests.swift`
  - `ClashMaxTests/LogChannelStoreTests.swift`
  - `ClashMaxTests/StructuredLogRecorderTests.swift`
  - `ClashMaxTests/StructuredApplicationEventCoverageTests.swift`
  - `ClashMaxTests/LogPresentationTests.swift`
  - `ClashMaxTests/StructuredLogExportTests.swift`
  - `ClashMaxTests/AppTerminationLoggingTests.swift`
  - `ClashMaxTests/LogsViewLayoutTests.swift`
- Modify focused existing suites:
  - `ClashMaxTests/SystemProxyControllerTests.swift`
  - `ClashMaxTests/CoreProcessControllerTests.swift`
  - `ClashMaxTests/MihomoAPIClientTests.swift`
  - `ClashMaxTests/DashboardRuntimeStateTests.swift`
  - `ClashMaxTests/TunnelHelperClientTests.swift`
  - `ClashMaxTests/TunnelHelperValidationTests.swift`
  - `ClashMaxTests/NetworkExtensionControllerTests.swift`
  - `ClashMaxTests/TunRuntimeInspectorTests.swift`
  - `ClashMaxTests/RuntimeDataStoreTests.swift`
  - `ClashMaxTests/MenuBarRuntimePresentationTests.swift`
  - `ClashMaxTests/LocalizationTests.swift`
  - `ClashMaxTests/TestDoubles.swift`

## Task 1: Shared producer types and source-side credential redaction

**Files:**
- Create: `script/xcode_project_semantic_snapshot.sh`
- Create: `script/guarded_xcodebuild.sh`
- Create: `script/test_xcode_project_guard.sh`
- Modify: `script/localization_gate.sh`
- Create: `docs/superpowers/plans/2026-07-28-structured-logging-xcode-sources.allowlist`
- Create: `Shared/StructuredLogProducer.swift`
- Create: `Shared/StructuredLogPrivacy.swift`
- Create: `Shared/SanitizedLineAccumulator.swift`
- Modify: `project.yml`
- Create: `ClashMaxTests/StructuredLogProducerTests.swift`

- [ ] **Step 1: Write the generated-project guard fixtures and exact source allowlist**

Before adding any Swift source/test file, create a shell fixture test for the still-missing guard. It works only on temporary copies/snapshots and requires:

- an unchanged snapshot comparison to pass;
- an allowlisted source addition to pass;
- a changed `DEVELOPMENT_TEAM`, provisioning setting, signing identity/style, bundle ID, entitlement path/content hash, `TargetAttributes`/`SystemCapabilities`, target product/dependency, `CodeSignOnCopy`/copy/embed phase, or signing shell script to fail;
- an existing source removal or non-allowlisted source addition to fail;
- a failure to leave the real `ClashMax.xcodeproj` byte-identical.
- an existing non-empty SwiftPM `Package.resolved` to survive a successful staged install and a forced post-install rollback byte-for-byte.
- `localization_gate.sh` with an injected guarded-build stub to invoke that stub exactly once with `test` and the localization selector, never its direct fallback.

Create the tab-separated allowlist as exact `target<TAB>repository-relative-path` tuples. It contains:

- the three new Shared files for `ClashMax`, `ClashMaxHelper`, and `ClashMaxNetworkExtension`;
- every new `ClashMax/Models`, `Services`, `Stores`, and `Views` Swift file in this plan for `ClashMax`;
- all twelve new test files in the global **Tests** file map for `ClashMaxTests`;
- no modified existing file, script, resource, config file, or wildcard.

- [ ] **Step 2: Run the guard fixture and confirm the red state**

Run:

```bash
bash script/test_xcode_project_guard.sh
```

Expected: `FAIL` because the snapshot and guarded-build scripts do not exist.

- [ ] **Step 3: Implement and initialize the semantic project guard**

`xcode_project_semantic_snapshot.sh` must use `plutil` plus canonical `jq -S` output to resolve target object IDs into stable target/path names. Keep three deliberately separate top-level sections:

- `generatorSecurity`;
- `sources`;
- `preservedFiles`.

`generatorSecurity` includes, for `ClashMax`, `ClashMaxHelper`, and `ClashMaxNetworkExtension`:

- product type and configuration names/raw build settings;
- project `TargetAttributes`, `SystemCapabilities`, provisioning style, and development team;
- entitlement paths plus SHA-256 of the referenced entitlement files;
- target dependencies and product references;
- shell-script phase name/body/input/output paths;
- copy/embed phase destination, subpath, referenced product/path, and build-file attributes such as `CodeSignOnCopy`;
- Info.plist paths/hashes where capability declarations live.
- generated workspace/shared-scheme hashes.

Keep normalized target/source tuples in `sources` so only the allowlist comparison may differ them. Put only non-generator-owned project contents such as `xcuserdata` and `project.xcworkspace/xcshareddata/swiftpm/Package.resolved` in the byte-hash `preservedFiles` manifest. A raw candidate is compared only on `generatorSecurity` and `sources`; `preservedFiles` is compared only after those files have been copied into the staged bundle. Never drop or move a field merely to make a mismatch pass.

`guarded_xcodebuild.sh` must:

1. On one explicit `--initialize`, refuse an existing guard directory, copy the whole current ignored project to `DerivedData/StructuredLoggingProjectGuard/ClashMax.before.xcodeproj`, and write its canonical semantic baseline before any Swift source is added.
2. For every normal invocation, create a fresh temporary project-root mirror with `mktemp -d`; copy the worktree into it while explicitly excluding `.git`, `.worktrees`, `DerivedData`, `ClashMax.xcodeproj`, build products, and the guard directory. Do not use symlinks for `Config`, `project.yml`, sources, or resources.
3. Run `xcodegen generate --spec <mirror>/project.yml --project <mirror> --project-root <mirror>` only inside that mirror. XcodeGen must never receive the real worktree as project root and must never run against the real worktree.
4. Compare the raw candidate only on `generatorSecurity` and every generator-managed `info.path`/`entitlements.path` content hash; these must be byte-identical to baseline. Its `sources` may contain no removal and only a current subset of the exact allowlist. Do not compare `preservedFiles` yet because a fresh candidate does not own them.
5. Build a same-parent staged project bundle from the validated candidate, then carry forward the baseline/current `preservedFiles` manifest (`xcuserdata`, SwiftPM `Package.resolved`, and any other classified preserved path) byte-for-byte. Snapshot the completed staged bundle using real worktree Config hashes and require all three sections to pass: baseline-equal `generatorSecurity`, allowlisted `sources`, and exact `preservedFiles`.
6. Only after the full staged comparison passes, atomically rename the current project to the recoverable guard backup and the staged bundle to `ClashMax.xcodeproj`; never regenerate or copy any Config/Info.plist/entitlement file into the real worktree. Snapshot the installed project and require the same full three-section result. On any mismatch, move the rejected project into the ignored guard directory, atomically restore the exact previous project bundle including `Package.resolved`/`xcuserdata`, print only classified changed keys, exit nonzero, and stop before invoking `/usr/bin/xcodebuild`.
7. Otherwise pass all remaining arguments unchanged to `/usr/bin/xcodebuild`.
8. Support `--verify-only`; with `--require-complete-allowlist`, require final security equality plus every and only allowlisted new target/source tuple, without regenerating or building.

Modify `localization_gate.sh` to accept an optional task-specific `CLASHMAX_XCODEBUILD_WRAPPER` path. When set, it must call `bash "$CLASHMAX_XCODEBUILD_WRAPPER" test ...`; otherwise it retains `/usr/bin/xcodebuild` for unrelated workflows. Never evaluate a command string. All localization-gate invocations later in this plan must set the wrapper variable.

Initialize:

```bash
bash script/guarded_xcodebuild.sh --initialize \
  --allowlist docs/superpowers/plans/2026-07-28-structured-logging-xcode-sources.allowlist
```

Expected: the ignored baseline/backup exists; `git status --short` has no Xcode project, Config, signing, entitlement, or capability change.

- [ ] **Step 4: Run the guard fixture and no-op candidate gate**

Run:

```bash
bash script/test_xcode_project_guard.sh
bash script/guarded_xcodebuild.sh build \
  -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Expected: fixture `PASS`, candidate/current semantic checks `PASS`, and `BUILD SUCCEEDED`. If the current user-owned project already differs semantically from `project.yml`, stop here and ask the user; never normalize it silently.

- [ ] **Step 5: Write failing producer tests**

Add tests that require aliases and unknown values to normalize without losing the raw value:

```swift
func testProducerLevelNormalizesAliasesAndPreservesUnknownRawValue() {
  XCTAssertEqual(StructuredLogLevel(normalizing: "warn"), .warning)
  XCTAssertEqual(StructuredLogLevel(normalizing: "panic"), .critical)
  let normalized = StructuredLogLevel.normalized("notice")
  XCTAssertEqual(normalized.level, .info)
  XCTAssertEqual(normalized.originalValue, "notice")
}
```

Use one unique sentinel in Bearer, Authorization, Cookie, URL userinfo/query/path, proxy URI password/UUID, private key/PSK, and a home-directory path. Assert the sentinel and the full home path are absent, stable error codes remain, and a second pass is byte-identical.

```swift
func testCredentialRedactionIsComprehensiveAndIdempotent() {
  let sentinel = "CLASHMAX_SECRET_7F4B"
  let input = """
  Authorization: Bearer \(sentinel)
  Cookie: session=\(sentinel)
  https://user:\(sentinel)@example.com/sub/\(sentinel)?token=\(sentinel)
  vmess://uuid-\(sentinel)@proxy.example:443
  private-key: \(sentinel) psk=\(sentinel)
  /Users/tester/Library/Application Support/ClashMax/Runtime/\(sentinel).yaml
  errorDomain=NSURLErrorDomain errorCode=-1004
  """
  let once = StructuredLogRedactor.redactCredentials(
    in: input,
    homeDirectory: "/Users/tester"
  )
  XCTAssertFalse(once.contains(sentinel))
  XCTAssertFalse(once.contains("/Users/tester"))
  XCTAssertTrue(once.contains("NSURLErrorDomain"))
  XCTAssertTrue(once.contains("-1004"))
  XCTAssertEqual(
    StructuredLogRedactor.redactCredentials(in: once, homeDirectory: "/Users/tester"),
    once
  )
}
```

Cover a secret split across chunks, multiple lines in one chunk, invalid UTF-8, end-of-stream flush, and an overlong line. Require that only completed, redacted lines are returned and that `truncatedLineCount` increments without retaining an unbounded raw fragment.

- [ ] **Step 6: Run the producer tests through the guarded project and confirm red**

Run:

```bash
bash script/guarded_xcodebuild.sh test \
  -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogProducerTests
```

Expected: the guard accepts only the newly added allowlisted test membership, then the test build `FAIL`s because `StructuredLogLevel`, `ProducerLogEvent`, `StructuredLogRedactor`, and `SanitizedLineAccumulator` do not exist.

- [ ] **Step 7: Implement the shared API**

Use these public shapes; split the declarations, redactor, and accumulator into the three responsibility-focused Shared files and keep them Foundation-only:

```swift
enum StructuredLogLevel: String, Codable, CaseIterable, Sendable {
  case trace, debug, info, warning, error, critical
}

enum LogAudience: String, Codable, Sendable {
  case support, developer
}

enum LogSource: String, Codable, CaseIterable, Sendable {
  case clashMax, mihomo, helper, networkExtension, tun
}

struct ProducerLogEvent: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var timestamp: Date
  var source: LogSource
  var category: String
  var code: String
  var level: StructuredLogLevel
  var audience: LogAudience
  var message: String
  var metadata: [String: String]
}

enum StructuredLogRedactor {
  static func redactCredentials(in value: String, homeDirectory: String? = nil) -> String
  static func redactCredentials(
    in metadata: [String: String],
    homeDirectory: String? = nil
  ) -> [String: String]
}

struct SanitizedLineAccumulator {
  init(maximumLineBytes: Int = 16_384, homeDirectory: String? = nil)
  mutating func append(_ data: Data) -> [String]
  mutating func finish() -> [String]
  private(set) var truncatedLineCount: Int
}
```

Redact before appending a completed line to any retained array. Do not retain more than `maximumLineBytes` plus the smallest delimiter look-behind required by the redactor.

- [ ] **Step 8: Add only the three explicit Shared entries to the NE spec**

Add only:

```yaml
      - path: Shared/StructuredLogProducer.swift
      - path: Shared/StructuredLogPrivacy.swift
      - path: Shared/SanitizedLineAccumulator.swift
```

under `targets.ClashMaxNetworkExtension.sources`. Do not invoke `xcodegen` directly. The next guarded build candidate must show the same three filenames newly included in App and Helper through their recursive `Shared` source plus the three explicit NE target memberships—no other existing membership or security semantic may change.

- [ ] **Step 9: Run producer tests and a compile gate through the guard**

Run the focused test command from Step 6, then:

```bash
bash script/guarded_xcodebuild.sh build \
  -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Expected: both commands end with `SUCCEEDED`.

- [ ] **Step 10: Inspect Task 1 project-safety evidence**

Run:

```bash
bash script/xcode_project_semantic_snapshot.sh compare-security \
  DerivedData/StructuredLoggingProjectGuard/baseline.json \
  DerivedData/StructuredLoggingProjectGuard/latest.json
bash script/xcode_project_semantic_snapshot.sh compare-sources \
  DerivedData/StructuredLoggingProjectGuard/baseline.json \
  DerivedData/StructuredLoggingProjectGuard/latest.json \
  docs/superpowers/plans/2026-07-28-structured-logging-xcode-sources.allowlist
git diff --exit-code -- Config '*.entitlements'
git diff -- project.yml
```

Expected: security comparison `PASS`; source comparison contains only the current allowlisted subset; Config/entitlements are unchanged; `project.yml` has exactly the three explicit NE Shared entries. Any other result is `BLOCKED`, not a reason to edit signing or capability state.

- [ ] **Step 11: Commit**

```bash
git add script/xcode_project_semantic_snapshot.sh \
  script/guarded_xcodebuild.sh \
  script/test_xcode_project_guard.sh \
  script/localization_gate.sh \
  docs/superpowers/plans/2026-07-28-structured-logging-xcode-sources.allowlist \
  Shared/StructuredLogProducer.swift \
  Shared/StructuredLogPrivacy.swift \
  Shared/SanitizedLineAccumulator.swift \
  project.yml \
  ClashMaxTests/StructuredLogProducerTests.swift
git commit -m "feat: add shared structured log privacy boundary"
```

## Task 2: Safe command descriptions and bounded pre-recorder output tails

**Files:**
- Modify: `ClashMax/Services/SystemProxyController.swift`
- Modify: `ClashMax/Services/TunRuntimeInspector.swift`
- Modify: `ClashMax/Services/CoreProcessController.swift`
- Modify: `ClashMaxTests/SystemProxyControllerTests.swift`
- Modify: `ClashMaxTests/TunRuntimeInspectorTests.swift`
- Modify: `ClashMaxTests/CoreProcessControllerTests.swift`
- Modify: `ClashMaxTests/TestDoubles.swift`

- [ ] **Step 1: Write a failing timeout-leak test**

Create a `CommandInvocation` whose executable arguments contain a sentinel Bearer value but whose display description contains `<redacted>`. Run a one-second hanging fixture and assert `error.localizedDescription` contains the safe display text and never the sentinel.

- [ ] **Step 2: Write failing TUN display-command tests**

Retain the existing assertion that real curl arguments contain the Bearer header, and add a separate assertion that the recorded display description is:

```text
/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer <redacted> http://127.0.0.1:9097/version
```

- [ ] **Step 3: Run the two narrow suites**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/SystemProxyControllerTests \
  -only-testing:ClashMaxTests/TunRuntimeInspectorTests
```

Expected: `FAIL` because command execution has no separate display description.

- [ ] **Step 4: Implement `CommandInvocation` without breaking existing fakes**

Use a protocol requirement with a default bridge:

```swift
struct CommandInvocation: Sendable {
  var executable: String
  var arguments: [String]
  var displayDescription: String
}

protocol CommandRunning: Sendable {
  func run(_ executable: String, _ arguments: [String]) async throws -> String
  func run(_ invocation: CommandInvocation) async throws -> String
}

extension CommandRunning {
  func run(_ invocation: CommandInvocation) async throws -> String {
    try await run(invocation.executable, invocation.arguments)
  }
}
```

`ProcessCommandRunner.run(_ invocation:)` must use real arguments for `Process.arguments`, but only `StructuredLogRedactor.redactCredentials(in: invocation.displayDescription)` in timeout/error text. The old two-argument overload constructs a redacted display description and forwards to the invocation overload.

- [ ] **Step 5: Convert only the authenticated TUN curl call**

Keep every existing command runner fake working via the default bridge. Pass the real secret only in `arguments`; pass the explicit `<redacted>` header in `displayDescription`.

- [ ] **Step 6: Write failing `LiveOutputDrain` privacy tests**

Feed stdout/stderr chunks where a secret crosses boundaries. Require distinct `ProcessOutputLine.stream` values, no raw secret in `tail(maxBytes:)`, and a truncation counter for a 32 KiB unterminated line.

- [ ] **Step 7: Implement separate sanitized stdout/stderr accumulators**

Add:

```swift
enum ProcessOutputStream: String, Sendable { case stdout, stderr }

struct ProcessOutputLine: Equatable, Sendable {
  var timestamp: Date
  var stream: ProcessOutputStream
  var text: String
}
```

`FoundationProcessLauncher` must keep separate pipes and call `SanitizedLineAccumulator` before `LiveOutputDrain` retains a line. Add an optional output callback to the launcher/process seam, but do not route it to the new recorder until Task 8. Update fakes with a default no-op callback.

Preserve existing launch fakes by declaring a second protocol requirement with `onOutput`, then supplying this default bridge:

```swift
extension CoreProcessLaunching {
  func launch(
    executable: URL,
    arguments: [String],
    environment: [String: String],
    workDirectory: URL,
    onOutput: @escaping @Sendable (ProcessOutputLine) -> Void
  ) throws -> RunningCoreProcess {
    try launch(
      executable: executable,
      arguments: arguments,
      environment: environment,
      workDirectory: workDirectory
    )
  }
}
```

`FoundationProcessLauncher` implements the callback overload; specialized output tests use a recording launcher. The bridge intentionally emits nothing for unrelated existing fakes.

- [ ] **Step 8: Run the three focused suites**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/SystemProxyControllerTests \
  -only-testing:ClashMaxTests/TunRuntimeInspectorTests \
  -only-testing:ClashMaxTests/CoreProcessControllerTests
```

Expected: `PASS`; the real command runner cancellation/large-output tests remain green.

- [ ] **Step 9: Commit**

```bash
git add ClashMax/Services/SystemProxyController.swift \
  ClashMax/Services/TunRuntimeInspector.swift \
  ClashMax/Services/CoreProcessController.swift \
  ClashMaxTests/SystemProxyControllerTests.swift \
  ClashMaxTests/TunRuntimeInspectorTests.swift \
  ClashMaxTests/CoreProcessControllerTests.swift \
  ClashMaxTests/TestDoubles.swift
git commit -m "fix: redact producer output before retention"
```

## Task 3: Structured event model, level filters, and privacy projections

**Files:**
- Create: `ClashMax/Models/StructuredLogEvent.swift`
- Create: `ClashMax/Services/StructuredLogProjection.swift`
- Create: `ClashMaxTests/StructuredLogEventTests.swift`
- Create: `ClashMaxTests/StructuredLogProjectionTests.swift`

- [ ] **Step 1: Write channel/source validation and stable-identity tests**

Require `.application + .clashMax` and all four runtime sources to succeed, while `.runtime + .clashMax` and `.application + .mihomo` fail with `StructuredLogValidationError.invalidSource`.

Before implementing `StableLogIdentity`, require a valid producer UUID to round-trip unchanged and a non-UUID Helper/NE producer ID to map to the same fixed expected UUID across repeated calls and fresh identity instances. Changing either source or producer ID must change the result. This is the primitive red test; Task 6 later tests recorder-level deduplication integration.

- [ ] **Step 2: Write the six-level to five-filter mapping tests**

```swift
XCTAssertTrue(LogLevelFilter.debug.matches(.trace))
XCTAssertTrue(LogLevelFilter.debug.matches(.debug))
XCTAssertTrue(LogLevelFilter.error.matches(.error))
XCTAssertTrue(LogLevelFilter.error.matches(.critical))
XCTAssertFalse(LogLevelFilter.info.matches(.debug))
```

Also require `critical` to keep a distinct symbol/style even though it filters under Error.

- [ ] **Step 3: Write visibility tests**

Assert `.debug + .support` is visible in ordinary mode, `.debug + .developer` is hidden in ordinary mode, and credentials remain hidden in both ordinary and Developer projection.

- [ ] **Step 4: Write Support identity-redaction tests**

Use a safe event containing an IP, domain, node, profile, app identifier, and user path. Require stable short hashes within one `SupportProjectionContext`, different context salts across sessions, and preservation of `errorDomain`, `errorCode`, `stage`, `durationMs`, and counts.

- [ ] **Step 5: Run the model/projection tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogEventTests \
  -only-testing:ClashMaxTests/StructuredLogProjectionTests
```

Expected: `FAIL` because the main-app event and projections do not exist.

- [ ] **Step 6: Implement the event and validation API**

Use:

```swift
enum LogChannel: String, Codable, CaseIterable, Hashable, Sendable {
  case application, runtime
}

struct StructuredLogEvent: Identifiable, Codable, Equatable, Sendable {
  var schemaVersion: Int
  var id: UUID
  var sequence: UInt64
  var timestamp: Date
  var receivedAt: Date
  var channel: LogChannel
  var source: LogSource
  var category: String
  var code: String
  var level: StructuredLogLevel
  var audience: LogAudience
  var message: String
  var metadata: [String: String]
  var sessionID: UUID
  var operationID: UUID?
  var repetitionCount: Int
}
```

Provide `LogChannel.accepts(_:)`, `StructuredLogEvent.validate()`, and a stable comparator ordered by `receivedAt`, then `sessionID.uuidString`, then `sequence`.

Add `StableLogIdentity.eventID(source:producerID:)`: use the producer UUID directly when valid; otherwise derive a deterministic UUID from a SHA-256 digest of `source + producerID`. Never fall back to a fresh random UUID for a stable foreign ID, or repeated Helper/NE polls would duplicate the same event.

Model writer health without retaining arbitrary error text:

```swift
enum LogWriterOperation: String, Codable, Sendable {
  case open, append, rotate, compact, flush, clear, unknown
}

struct LogWriterIssue: Equatable, Codable, Sendable {
  var operation: LogWriterOperation
  var safeDomain: String
  var code: Int
  var occurredAt: Date
}
```

`safeDomain` is an allowlisted classification (`NSPOSIXErrorDomain`, `NSCocoaErrorDomain`, or `other`), never the raw localized description. `LogQualitySnapshot` stores `latestWriterIssue: LogWriterIssue?`, not an unrestricted string or path.

- [ ] **Step 7: Implement explicit projection results**

Do not mutate stored events. Return:

```swift
struct ProjectedLogEvent: Identifiable, Equatable, Sendable {
  var id: UUID
  var timestamp: Date
  var receivedAt: Date
  var level: StructuredLogLevel
  var source: LogSource
  var category: String
  var code: String
  var message: String
  var metadata: [String: String]
  var operationID: UUID?
  var repetitionCount: Int
}

enum StructuredLogProjection {
  static func support(_ event: StructuredLogEvent, context: SupportProjectionContext) -> ProjectedLogEvent
  static func developer(_ event: StructuredLogEvent) -> ProjectedLogEvent
}
```

The Developer path still calls credential redaction. The Support path first applies the same credential pass, then identity/network minimization.

- [ ] **Step 8: Run focused tests**

Run the command from Step 5.

Expected: `PASS`.

- [ ] **Step 9: Commit**

```bash
git add ClashMax/Models/StructuredLogEvent.swift \
  ClashMax/Services/StructuredLogProjection.swift \
  ClashMaxTests/StructuredLogEventTests.swift \
  ClashMaxTests/StructuredLogProjectionTests.swift
git commit -m "feat: define structured log events and projections"
```

## Task 4: Independent rotating JSONL persistence and bounded recovery

**Files:**
- Create: `ClashMax/Services/StructuredLogPersistence.swift`
- Modify: `ClashMax/Support/RuntimePaths.swift`
- Create: `ClashMaxTests/StructuredLogPersistenceTests.swift`
- Modify: `ClashMaxTests/ProfileStoreTests.swift`

- [ ] **Step 1: Write fixed-path and permission tests**

Create isolated `RuntimePaths`, append one event to each channel, and assert:

- `application.current.jsonl` and `runtime.current.jsonl` are separate regular files.
- directory mode is `0700`; file mode is `0600`.
- no caller-provided filename/path exists in the API.
- replacing either current file with a symlink is rejected before read or write.

- [ ] **Step 2: Write small-policy rotation tests**

Inject a policy such as 512 bytes and three files. Append enough events to rotate, then assert numbered files stay within the channel, the other channel is untouched, oldest excess files are removed, and all JSONL lines decode.

Attempt to append one encoded record larger than `maximumFileBytes`. Require a typed `recordTooLarge` failure before any bytes are written and prove no current or rotated file exceeds the configured limit. Task 6 separately proves the central recorder bounds normal Mihomo messages/metadata below this persistence guard.

- [ ] **Step 3: Write record-age retention and disk-budget tests**

Inject a clock and create all of these fixtures:

- a recently modified current file containing one event whose `receivedAt` is older than seven days and one current event;
- a recently modified rotated file containing both expired and retained records;
- a wholly expired rotated file;
- over-budget application and runtime file families.

Run maintenance, then require both `loadTail` and the rewritten JSONL files to contain no record older than the cutoff. File modification time alone must not decide retention: mixed-age current and rotated files are compacted so their valid recent records survive while expired records are physically removed. Require each archive actor to rewrite/delete only its own file family. `current + rotated` must never exceed five files for that channel; at 4 MiB each this independently bounds each channel near 20 MiB and both channels near 40 MiB without cross-actor deletion races.

- [ ] **Step 4: Write bounded recovery tests**

Cover:

- one corrupt line between valid lines, with `skippedLineCount == 1`;
- an event with a future schema version and unknown optional field;
- 2,100 application events loading only the newest 2,000;
- 5,100 runtime events loading only the newest 5,000;
- stable ordering and duplicate-ID removal, with the last JSONL occurrence winning so an append-only repetition-count update restores the newest representation;
- no API that returns unbounded disk history.

Add a recorder integration assertion in Task 6: each channel with skipped recovery lines increments `decodeFailureCount` and emits exactly one in-memory Support warning with code `log.persistence.corrupt-lines-skipped`. That warning must use the recorder's non-recursive emergency path, must not re-read or append to the damaged file, and must never echo the corrupt line.

- [ ] **Step 5: Run persistence tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogPersistenceTests \
  -only-testing:ClashMaxTests/ProfileStoreTests/testRuntimePathsPrepareDirectoriesUseOwnerOnlyPermissions
```

Expected: `FAIL` because persistence does not exist.

- [ ] **Step 6: Add fixed URLs and constants**

Add to `RuntimePaths`:

```swift
func currentLogURL(for channel: LogChannel) -> URL
func rotatedLogURL(for channel: LogChannel, index: Int) -> URL
```

Use only fixed stems from `LogChannel`; never interpolate profile/source/user input. Add `applicationRetainedLogLimit = 2_000` and `runtimeRetainedLogLimit = 5_000`.

- [ ] **Step 7: Implement the persistence actor**

Use:

```swift
struct StructuredLogFilePolicy: Sendable {
  var maximumFileBytes: Int = 4 * 1_024 * 1_024
  var maximumFilesPerChannel: Int = 5
  var maximumAge: TimeInterval = 7 * 24 * 60 * 60
  var maximumRecordBytes: Int = 256 * 1_024
}

struct LogRecoveryResult: Sendable {
  var events: [StructuredLogEvent]
  var skippedLineCount: Int
}

actor StructuredLogPersistence {
  func append(_ event: StructuredLogEvent) async throws
  func loadTail(limit: Int) async throws -> LogRecoveryResult
  func clear() async throws
  func flush() async throws
}
```

Before every read/write, use `lstat`; open readers with `O_RDONLY | O_NOFOLLOW | O_CLOEXEC` and appenders with `O_NOFOLLOW | O_APPEND | O_CREAT | O_CLOEXEC`; verify each resulting descriptor with `fstat` is a regular file before consuming or writing bytes. This closes the check/open race that a preflight-only URL check would leave. Encode and size-check a complete line before rotation; reject it if it exceeds either `maximumRecordBytes` or `maximumFileBytes`, and never create an over-limit file. Rotate by same-directory rename, count the current file inside `maximumFilesPerChannel`, apply `0600` after create/rename, stream files from oldest to newest, and keep only a bounded in-memory tail. Each channel actor cleans only its own file family. Do not reuse `SecureFileIO.writePrivateData`, because its whole-file atomic replacement is not an append primitive.

Retention is record-based, using recorder-owned `receivedAt` rather than producer-controlled timestamps or filesystem modification dates. On recovery and at most once per 24 hours before append, stream the channel's bounded file family, discard expired records, resolve duplicate IDs with the last occurrence winning, and repack retained records into fixed-name files under the same size/count policy. Perform compaction inside the channel actor with fixed sibling temporary names, `O_EXCL | O_NOFOLLOW`, descriptor validation, `fsync`, and same-directory rename; clean up only that channel's temporary/file family. This guarantees old records are physically removed even when they share a recently modified file with current records.

- [ ] **Step 8: Run persistence and path tests**

Run the command from Step 5.

Expected: `PASS`.

- [ ] **Step 9: Commit**

```bash
git add ClashMax/Services/StructuredLogPersistence.swift \
  ClashMax/Support/RuntimePaths.swift \
  ClashMaxTests/StructuredLogPersistenceTests.swift \
  ClashMaxTests/ProfileStoreTests.swift
git commit -m "feat: persist independent rotating log channels"
```

## Task 5: Sampling and independent observable channel stores

**Files:**
- Create: `ClashMax/Services/StructuredLogSampler.swift`
- Create: `ClashMax/Stores/LogChannelStore.swift`
- Create: `ClashMaxTests/StructuredLogSamplerTests.swift`
- Create: `ClashMaxTests/LogChannelStoreTests.swift`

- [ ] **Step 1: Write sampler tests**

Require Warning/Error/Critical, lifecycle, repair, stream-final-failure, overflow, and persistence-failure codes to bypass sampling. Require repeated Debug/Trace events with the same `source + code + category + support fingerprint` inside one second to produce one event with the same ID and an increased `repetitionCount`; the recorder must append that updated representation to JSONL so last-occurrence-wins recovery preserves the final count.

- [ ] **Step 2: Write independent-capacity tests**

Create marker-distinct stores with tiny limits. Overflow the runtime store and assert application events/counts are unchanged; overflow application and assert runtime is unchanged. Add a compile/use test proving both can be injected and read by SwiftUI without one replacing the other by type.

- [ ] **Step 3: Write 250 ms coalescing tests**

Append a burst, assert observable `events` is unchanged before flush, then one publication contains the whole bounded burst. Inject a short interval or explicit `flushPending()` for deterministic tests.

- [ ] **Step 4: Write generation-safe clear/recovery tests**

Schedule a publish, clear, then allow the old task to fire. Assert old events do not reappear. Start history merge, append live events, finish recovery late, and assert live events remain, duplicate IDs collapse, and the final tail is stable.

- [ ] **Step 5: Run focused tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogSamplerTests \
  -only-testing:ClashMaxTests/LogChannelStoreTests
```

Expected: `FAIL` because sampler/store types do not exist.

- [ ] **Step 6: Implement the sampler**

Keep the sampler pure and clock-injected:

```swift
struct StructuredLogSampler: Sendable {
  mutating func consume(
    _ event: StructuredLogEvent,
    now: Date
  ) -> LogSamplingDecision
}

enum LogSamplingDecision: Equatable, Sendable {
  case append(StructuredLogEvent)
  case replace(id: UUID, with: StructuredLogEvent)
  case drop
}
```

Expose merged/dropped counters; never make the UI infer quality from message text.

- [ ] **Step 7: Implement the reusable observable store**

Use:

```swift
enum ApplicationLogStoreTag {}
enum RuntimeLogStoreTag {}

typealias ApplicationLogStore = LogChannelStore<ApplicationLogStoreTag>
typealias RuntimeLogStore = LogChannelStore<RuntimeLogStoreTag>

@MainActor
@Observable
final class LogChannelStore<Tag> {
  let channel: LogChannel
  private(set) var events: [StructuredLogEvent] = []
  private(set) var quality = LogQualitySnapshot.empty
  private(set) var recoveryState: LogRecoveryState = .idle

  func append(_ event: StructuredLogEvent)
  func replace(id: UUID, with event: StructuredLogEvent)
  func mergeRecovered(_ events: [StructuredLogEvent], skippedLineCount: Int)
  func flushPending()
  func clearInMemory()
}
```

Mark pending buffer/task/generation with `@ObservationIgnored`. Keep channel validation inside `append`, even though the recorder also validates. The marker generic is intentional: SwiftUI type-based environment injection cannot distinguish two instances of the exact same runtime type.

- [ ] **Step 8: Run focused tests**

Run the command from Step 5.

Expected: `PASS`.

- [ ] **Step 9: Commit**

```bash
git add ClashMax/Services/StructuredLogSampler.swift \
  ClashMax/Stores/LogChannelStore.swift \
  ClashMaxTests/StructuredLogSamplerTests.swift \
  ClashMaxTests/LogChannelStoreTests.swift
git commit -m "feat: add independent observable log stores"
```

## Task 6: Central recorder, ordered writes, recovery, clear, and flush

**Files:**
- Create: `ClashMax/Services/StructuredLogRecorder.swift`
- Create: `ClashMaxTests/StructuredLogRecorderTests.swift`
- Modify: `ClashMaxTests/TestDoubles.swift`

- [ ] **Step 1: Write validation and sequencing tests**

Require invalid channel/source pairs to be rejected without touching either store or file. Require application and runtime sequences to each begin at zero for one App session and advance independently. Feed the same non-UUID foreign producer ID twice and require deterministic identity/deduplication.

- [ ] **Step 2: Write central defense-in-depth tests**

Feed a producer event that deliberately bypasses the shared producer redactor. Assert sentinel credentials are absent from the stored event and JSONL line.

Feed an exceptionally large Mihomo message and metadata dictionary. Require the recorder to redact first, then apply deterministic UTF-8-safe limits to message length, metadata key/value length, metadata count, and total encoded record size. Assert the retained record has an explicit truncation marker, preserves stable code/error/stage fields, and stays below persistence `maximumRecordBytes`; no secret may be reconstructed at a truncation boundary.

- [ ] **Step 3: Write ordered-write and failure-isolation tests**

Use a recording persistence fake. Assert append order matches sequence order per channel and application writer failure does not stop runtime writes. Make the first application append throw and the next application append succeed: the second event must reach disk in order, `latestWriterIssue` must clear after success, and a later independent failure may create a new warning. A failed task must never poison that channel's future task chain.

Use a thrown error whose localized description/path contains the compound credential and home-directory sentinel. Assert the store retains only typed `LogWriterIssue(operation:safeDomain:code:occurredAt:)`, the emergency Support warning contains only that classification, and neither the snapshot, displayed presentation input, nor any event contains the sentinel. During one continuous failure streak, emit exactly one non-recursive warning.

- [ ] **Step 4: Write recovery and clear tests**

Start recovery, append live events, finish recovery late, then clear one channel while writes/publish tasks are pending. Assert:

- history never overwrites live events;
- a recovery result with corrupt lines increments that channel's `decodeFailureCount` and produces exactly one `log.persistence.corrupt-lines-skipped` Support warning through the emergency path, even when more than one line was skipped;
- the corrupt-history warning contains only channel/count metadata, is not written back to persistence, and cannot recursively create another warning if the writer is already failing;
- clear removes only the selected channel's memory and files;
- a prior generation cannot resurrect events;
- the other channel remains readable and writable.

- [ ] **Step 5: Write bounded flush tests**

Use a persistence fake that hangs. Require `flushForTermination(channels:deadline:)` to return at the one absolute injected-clock deadline and report the affected channel without blocking the other. Cover both-channel and application-only sets so Task 13 can perform a second best-effort application flush without resetting the total timeout budget.

- [ ] **Step 6: Run recorder tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogRecorderTests
```

Expected: `FAIL` because the recorder does not exist.

- [ ] **Step 7: Implement recorder inputs and ownership**

Use a main-actor recorder so sequence assignment and UI-store mutation are deterministic:

```swift
@MainActor
final class StructuredLogRecorder {
  let sessionID: UUID
  let applicationStore: ApplicationLogStore
  let runtimeStore: RuntimeLogStore

  @discardableResult
  func record(
    _ producer: ProducerLogEvent,
    channel: LogChannel,
    operationID: UUID? = nil,
    receivedAt: Date = Date()
  ) -> UUID?

  func recoverHistory() async
  func clear(_ channel: LogChannel) async throws
  func flushForTermination(
    channels: Set<LogChannel>,
    deadline: ContinuousClock.Instant
  ) async -> LogFlushResult
}
```

Maintain one persistence task chain per channel. A new write awaits completion of the previous task for that channel but never inherits its thrown failure and never waits on the other channel's chain: catch/classify failures inside each link, complete that link normally, and always attempt the next current-generation append. Capture generation in every write/clear task. Reset the per-channel warning latch and clear `latestWriterIssue` only after a later successful write.

Before store/persistence submission, run central credential redaction and `StructuredLogBounds`: cap UTF-8-safe message/key/value lengths, metadata count, and total encoded size while preserving required stable diagnostic fields. Persistence retains its own hard `recordTooLarge` rejection as defense in depth.

- [ ] **Step 8: Implement classified, non-recursive emergency reporting**

Persistence faults must discard raw `Error.localizedDescription`, paths, and underlying userInfo after mapping operation, allowlisted domain, integer code, and time into `LogWriterIssue`. Put that typed issue in `LogQualitySnapshot` and append at most one fixed-copy in-memory Support warning through a direct emergency method that never calls persistence or the sampler. Recovery passes `skippedLineCount` to the store quality counters and uses the same direct path once per channel/session for `log.persistence.corrupt-lines-skipped`; never include undecodable bytes in message or metadata.

- [ ] **Step 9: Run recorder plus persistence/store tests**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogRecorderTests \
  -only-testing:ClashMaxTests/StructuredLogPersistenceTests \
  -only-testing:ClashMaxTests/LogChannelStoreTests
```

Expected: `PASS`.

- [ ] **Step 10: Commit**

```bash
git add ClashMax/Services/StructuredLogRecorder.swift \
  ClashMaxTests/StructuredLogRecorderTests.swift \
  ClashMaxTests/TestDoubles.swift
git commit -m "feat: coordinate structured log recording"
```

## Task 7: Application channel migration and default Support Debug

**Files:**
- Modify: `ClashMax/Models/CoreModels.swift`
- Modify: `ClashMax/Services/MihomoAPIClient.swift`
- Create: `ClashMax/Stores/LogNavigationState.swift`
- Modify: `ClashMax/Stores/AppModel.swift`
- Modify: `ClashMax/App/ClashMaxApp.swift`
- Modify: `ClashMax/Views/LogsView.swift`
- Create: `ClashMaxTests/StructuredApplicationEventCoverageTests.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift`
- Modify: `ClashMaxTests/MihomoAPIClientTests.swift`
- Modify: `ClashMaxTests/LocalizationTests.swift`
- Modify: `ClashMaxTests/TestDoubles.swift`

- [ ] **Step 1: Write default-log-level migration tests**

Require `RuntimeOverrides.defaultForLaunch().logLevel == "debug"` and decoding JSON with no `logLevel` to use `debug`; retain tests proving explicitly persisted `info`, `warning`, and `error` values survive unchanged.

- [ ] **Step 2: Write a behavioral application-event coverage matrix**

Create `StructuredApplicationEventCoverageTests` around an isolated `AppModel` and deterministic fakes. Exercise successful, failed, cancelled, timed-out, and superseded paths rather than searching only for existing log calls. Assert events use `.application/.clashMax`, stable `category/code`, operation IDs where applicable, duration/error metadata, and Support audience for actionable Debug. Reuse the existing `startTaskID`, `stopTaskID`, reload token, and repair token as operation IDs instead of generating unrelated IDs at each stage.

At minimum cover these stable codes:

```text
app.launch
app.warmup.decision
app.warmup.completed
runtime.start.requested
runtime.start.completed
runtime.start.failed
runtime.stop.requested
runtime.stop.completed
runtime.stop.failed
runtime.restart.requested
runtime.config.generate.started
runtime.config.generate.completed
runtime.config.generate.failed
runtime.config.validate.started
runtime.config.validate.completed
runtime.config.validate.failed
runtime.reload.requested
runtime.reload.completed
runtime.reload.failed
controller.request.completed
controller.request.failed
xpc.helper.requested
xpc.helper.completed
xpc.helper.failed
network.dns.check
network.route.check
task.cancelled
task.timed-out
task.stale-generation-rejected
```

For each configuration stage, assert `stage`, `outcome`, and elapsed milliseconds while paths/profile names are projected safely. For controller outcomes, assert an explicit safe request category, HTTP status on success, and error domain/code on failure; never retain URL, headers, query, secret, proxy/provider/node name, or request body. Force a cancelled task, a timeout fake, and a late result whose generation no longer matches, and assert each produces its own event instead of returning silently.

The rest of the confirmed matrix is assigned to explicit behavioral tests later in this plan: stream connect/disconnect/reconnect/final outcome and Mihomo decode failures in Task 8; Helper/NE/TUN coordination in Tasks 9–11; and `app.termination.requested`, cleanup outcome, and bounded flush outcome in Task 13. Task 14 reruns this coverage suite after deleting the legacy wrapper.

- [ ] **Step 3: Write safe controller-request telemetry tests**

Give concrete `MihomoAPIClient` requests an injected, optional `@Sendable` outcome sink. With `URLProtocolStub`, require exactly one callback for 2xx, non-2xx, cancellation, and timeout. The callback contains only a compile-time request category, status code when available, duration, outcome, and safe error domain/code. Assert the original URL, controller secret, Authorization header, query values, request body, and response body never enter the callback.

- [ ] **Step 4: Write App startup recovery tests**

Append an application event immediately, complete disk recovery afterward, and assert both old and current-session events remain. Require recovery, `app.launch`, and the warmup decision to occur once even if WindowGroup, MenuBarExtra, and Settings all appear.

- [ ] **Step 5: Run focused tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredApplicationEventCoverageTests \
  -only-testing:ClashMaxTests/MihomoAPIClientTests/testRequestTelemetryContainsOnlySafeStructuredOutcome \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testRuntimeOverridesMissingLogLevelDefaultsToDebug \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testStructuredApplicationLifecycleEventsStayInApplicationChannel \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testLogRecoveryMergesWithImmediateLaunchEvent
```

Expected: `FAIL` for the old `info` default and missing recorder integration.

- [ ] **Step 6: Create navigation state, then own stores and recorder in `AppModel`**

First implement the small `@MainActor @Observable LogNavigationState` so every later reference in this task compiles. It holds an optional request `{ id, channel }`, plus `open(_:)` and `consume(id:)`.

Add:

```swift
let applicationLogStore: ApplicationLogStore
let runtimeLogStore: RuntimeLogStore
let logNavigationState = LogNavigationState()
private let structuredLogRecorder: StructuredLogRecorder
```

Initialize both stores and fixed-path persistence from the injected `RuntimePaths`. Add an optional recorder factory only if tests need persistence fakes; do not introduce a global singleton.

- [ ] **Step 7: Replace `appendAppLog` and instrument the required outcomes**

Use:

```swift
private func appendAppLog(
  level: StructuredLogLevel,
  category: String,
  code: String,
  message: String,
  audience: LogAudience = .support,
  metadata: [String: String] = [:],
  operationID: UUID? = nil
)
```

Convert every call site exercised by the coverage matrix, including warmup, runtime lifecycle, config generation/validation/reload stages, Helper XPC coordination, DNS/route checks, cancellation, timeout, and stale-generation guard exits. Install the optional safe `MihomoAPIClient` outcome sink at every AppModel-owned concrete-client construction site and map it to `controller.request.completed`/`controller.request.failed`; the sink must use explicit request-category enum cases supplied by public API methods, never derive labels from raw URLs. Temporary unrelated legacy call sites may use one explicit wrapper with `code: "app.legacy-message"`; remove that wrapper in Task 14.

- [ ] **Step 8: Add one-time recovery and environment injection**

Add `performLaunchWarmupIfNeeded(allowed:)` and `startLogRecoveryIfNeeded()` to `AppModel`, call them from the existing repeated `.onAppear` paths, and guard both internally. Record both the warmup decision and its eventual outcome once. Inject `ApplicationLogStore` and `RuntimeLogStore` directly by their marker-distinct types, plus `LogNavigationState`; never erase them back to the same runtime type before `.environment(...)`.

Temporarily let existing `LogsView` read a merged compatibility snapshot so application logs remain visible before the runtime migration in Task 8.

- [ ] **Step 9: Run focused and regression tests**

Run the Step 5 command, then:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredApplicationEventCoverageTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests \
  -only-testing:ClashMaxTests/MihomoAPIClientTests \
  -only-testing:ClashMaxTests/AppActivationPolicyTests
```

Expected: `PASS`.

- [ ] **Step 10: Commit**

```bash
git add ClashMax/Models/CoreModels.swift \
  ClashMax/Services/MihomoAPIClient.swift \
  ClashMax/Stores/LogNavigationState.swift \
  ClashMax/Stores/AppModel.swift \
  ClashMax/App/ClashMaxApp.swift \
  ClashMax/Views/LogsView.swift \
  ClashMaxTests/StructuredApplicationEventCoverageTests.swift \
  ClashMaxTests/DashboardRuntimeStateTests.swift \
  ClashMaxTests/MihomoAPIClientTests.swift \
  ClashMaxTests/LocalizationTests.swift \
  ClashMaxTests/TestDoubles.swift
git commit -m "feat: record structured application diagnostics"
```

## Task 8: Mihomo structured logs, reconnect events, and process output

**Files:**
- Modify: `ClashMax/Services/MihomoAPIClient.swift`
- Modify: `ClashMax/Services/CoreProcessController.swift`
- Modify: `ClashMax/Stores/AppModel.swift`
- Modify: `ClashMax/Views/LogsView.swift`
- Create: `ClashMax/Views/Dashboard/RecentRuntimeLogsCard.swift`
- Modify: `ClashMax/Views/Dashboard/RunningDashboardView.swift`
- Modify: `ClashMaxTests/MihomoAPIClientTests.swift`
- Modify: `ClashMaxTests/CoreProcessControllerTests.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift`
- Modify: `ClashMaxTests/TestDoubles.swift`

- [ ] **Step 1: Write structured, legacy, and observable decode-failure tests**

Require a structured payload to preserve core time, level, message, and stringified fields:

```json
{"time":"2026-07-28T08:30:01.123Z","level":"debug","message":"DNS lookup","fields":{"network":"udp","attempt":2}}
```

Require the current `{"type":"warn","payload":"legacy"}` payload to continue decoding.

Feed a malformed frame followed by a valid frame. Require the stream to yield a typed decode-failure item, continue to the valid record, and never expose the raw malformed bytes. In AppModel, assert each failure increments the runtime channel's `decodeFailureCount` and produces a sampled Support warning with code `mihomo.log.payload-decode-failed`, safe error domain/code, and no payload text. Repeated malformed frames may aggregate, but the error path must remain visible and must not masquerade as a transport disconnect.

Decode an unknown structured and legacy level such as `notice`. Require normalization to `.info`, retention of `originalLevel == "notice"`, and eventual runtime-event metadata `mihomo.originalLevel: "notice"` in Developer projection. The Support projection may minimize that value but must remain credential-safe.

- [ ] **Step 2: Write request-query tests**

Expose an internal request builder if necessary. Assert `/logs` carries both `level=<effective>` and `format=structured`, with Bearer authentication unchanged.

- [ ] **Step 3: Write stream lifecycle tests**

Extend `ScriptedRuntimeStreamController` so a disconnect error contains a domain/code. Assert the application channel records connect, disconnect, scheduled reconnect, and recovered events with attempt count/duration; old generation and post-stop events are still rejected.

Also assert toggling Developer Mode never changes the effective Mihomo subscription level, an explicitly persisted level below Debug remains respected, and connect/reconnect final outcomes satisfy the Task 7 application-event coverage matrix.

- [ ] **Step 4: Write runtime-source tests**

Assert `/logs` events enter only `.runtime/.mihomo`; timestamps come from Mihomo while `receivedAt` comes from App. Assert structured fields and unknown `originalLevel` metadata survive Developer projection and Support projection minimizes network identity.

- [ ] **Step 5: Write stdout/stderr and dedup tests**

Yield sanitized `ProcessOutputLine` values before controller readiness and after a simulated crash. Assert source `.mihomo`, category `stdout`/`stderr`, no secret in the retained tail, and a matching `/logs` fingerprint does not create a duplicate event.

- [ ] **Step 6: Run focused tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/MihomoAPIClientTests \
  -only-testing:ClashMaxTests/CoreProcessControllerTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testRuntimeStreamsReconnectAndRecordStructuredLifecycle \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testMihomoEventsUseRuntimeChannelAndCoreTimestamp
```

Expected: `FAIL` because `/logs` still requests/decodes legacy data and stream errors are swallowed.

- [ ] **Step 7: Add transport records and a non-terminal decode-failure item**

Replace `LogEntry` at the API boundary with:

```swift
struct MihomoLogRecord: Equatable, Sendable {
  var timestamp: Date?
  var level: StructuredLogLevel
  var originalLevel: String?
  var message: String
  var fields: [String: String]
}

enum MihomoLogStreamItem: Equatable, Sendable {
  case record(MihomoLogRecord)
  case decodeFailure(MihomoLogDecodeFailure)
}
```

Change `MihomoAPIControlling.logStream(level:)` and all fakes to stream `MihomoLogStreamItem`. The log-specific decoder converts malformed frames to `.decodeFailure` and immediately receives the next frame; socket/transport failures still finish the throwing stream. `MihomoLogDecodeFailure` carries only stable classification and safe error domain/code, never payload bytes or decoded fragments.

- [ ] **Step 8: Record runtime, decode quality, and stream-lifecycle events**

Map core records to `ProducerLogEvent(source: .mihomo, ...)`. When `originalLevel` is non-nil, copy its bounded, redacted value to metadata key `mihomo.originalLevel` before recording; do not silently drop it. For decode-failure items, increment runtime quality and record the sampled Support warning described in Step 1 without including raw input. Record transport lifecycle in the application channel with sanitized `errorDomain`/`errorCode`; do not put the controller secret or WebSocket URL query into metadata.

- [ ] **Step 9: Route process output**

Pass the output callback from `FoundationProcessLauncher` through `CoreProcessController` to `AppModel`. Raw continuous lines default to Developer audience; startup/crash summaries may be Support after projection. Use sampler fingerprinting to deduplicate with `/logs`.

- [ ] **Step 10: Introduce the minimal real channel switch and extract the runtime card**

Change the current Logs page to choose application or runtime store with a segmented picker. Extract the existing private `RecentLogsRuntimeCard` from `RunningDashboardView.swift` into the new `Views/Dashboard/RecentRuntimeLogsCard.swift`, rename it `RecentRuntimeLogsCard`, and make its minimal implementation read runtime Support events only. When the effective runtime level is below Debug, expose a non-error hint that Mihomo Debug is limited by the saved Runtime Log Level. Full selection/presentation/search/scroll/actions arrive in Tasks 12–13.

- [ ] **Step 11: Run focused and stream regression tests**

Run the Step 6 command, then:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testRuntimeStreamReplacementRejectsOldGenerationAndStopPreventsReconnect
```

Expected: `PASS`.

- [ ] **Step 12: Commit**

```bash
git add ClashMax/Services/MihomoAPIClient.swift \
  ClashMax/Services/CoreProcessController.swift \
  ClashMax/Stores/AppModel.swift \
  ClashMax/Views/LogsView.swift \
  ClashMax/Views/Dashboard/RecentRuntimeLogsCard.swift \
  ClashMax/Views/Dashboard/RunningDashboardView.swift \
  ClashMaxTests/MihomoAPIClientTests.swift \
  ClashMaxTests/CoreProcessControllerTests.swift \
  ClashMaxTests/DashboardRuntimeStateTests.swift \
  ClashMaxTests/TestDoubles.swift
git commit -m "feat: ingest structured Mihomo runtime logs"
```

## Task 9: Helper structured ring and backward-compatible incremental import

**Files:**
- Modify: `Shared/HelperProtocol.swift`
- Modify: `ClashMaxHelper/main.swift`
- Modify: `ClashMax/Services/TunnelHelperClient.swift`
- Modify: `ClashMax/Stores/AppModel.swift`
- Modify: `ClashMaxTests/TunnelHelperValidationTests.swift`
- Modify: `ClashMaxTests/TunnelHelperClientTests.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift`

- [ ] **Step 1: Write Helper source-buffer privacy tests**

Feed chunked stdout/stderr containing a sentinel. Inspect `HelperService.recentLogs` payload directly and assert the sentinel never enters the 200-event ring, even before the App receives it.

- [ ] **Step 2: Write structured payload and v1 fallback tests**

Require protocol v2 Helper output to decode structured records. Keep the top-level payload as `[String]`: each v2 element is one versioned JSON record string, while a v1 element is plain text. Feed a v1 payload and require App wrapping with source `.helper`, code `helper.legacy-output`, and no crash.

- [ ] **Step 3: Write lifecycle and authorization tests**

Through fakes, require stable records for XPC accepted/rejected, protocol/build negotiation, path/signature validation stage, launch PID, exit code, SIGTERM, and SIGKILL. Store only a reason code/fingerprint result, never full paths/signature text.

- [ ] **Step 4: Write incremental polling tests**

Return overlapping v2 batches and assert App imports each event ID once. For v1 batches without IDs, require a longest-tail/longest-head overlap cursor so only the newly appended tail imports (including repeated identical text at different positions). On simulated XPC failure/Helper stop, assert one final pull is attempted and other runtime sources continue.

- [ ] **Step 5: Run Helper tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/TunnelHelperValidationTests \
  -only-testing:ClashMaxTests/TunnelHelperClientTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testHelperStructuredLogsImportIncrementally
```

Expected: `FAIL` because Helper stores unstructured chunks and App exposes only `[String]`.

- [ ] **Step 6: Upgrade the existing XPC payload without adding an interface**

Keep `recentLogs(withReply:) -> NSString` and its top-level JSON `[String]` shape. Encode each v2 producer record as one JSON string element, bump `ClashMaxHelperProtocolVersion.current` to `2`, and keep `minimumCompatible = 1`. This lets the new App parse v2 records and v1 text while an older App still receives strings rather than an incompatible object array.

Use:

```swift
enum HelperLogBatch: Equatable, Sendable {
  case structured([ProducerLogEvent])
  case legacy([String])
}
```

Decode each string as a versioned record first and fall back to legacy plaintext per element. Keep a dedicated legacy overlap cursor because plaintext has no stable ID.

- [ ] **Step 7: Separate Helper-owned Mihomo stdout/stderr**

Use separate pipes and `SanitizedLineAccumulator`. Helper lifecycle events use source `.helper`; Helper-launched Mihomo output uses source `.mihomo` with metadata `owner=tun-helper`. Never retain raw chunks.

- [ ] **Step 8: Record connection authorization safely**

Have `HelperListenerDelegate` tell `HelperService` only `accepted` or a sanitized rejection code. Do not weaken existing code-signing checks and do not log audit-token/signature blobs.

- [ ] **Step 9: Import into runtime store**

Poll only while TUN/Helper runtime is relevant, track v2 producer IDs with bounded pruning, track v1 tail overlap separately, and attempt a last pull on stop/failure. Convert transport failures into source `.helper` Support events. Record the App-initiated status/start/stop/restart XPC operation in the application channel with operation ID, duration, protocol/build result, and sanitized error domain/code; never record its arguments.

- [ ] **Step 10: Run focused tests**

Run the command from Step 5.

Expected: `PASS`.

- [ ] **Step 11: Commit**

```bash
git add Shared/HelperProtocol.swift \
  ClashMaxHelper/main.swift \
  ClashMax/Services/TunnelHelperClient.swift \
  ClashMax/Stores/AppModel.swift \
  ClashMaxTests/TunnelHelperValidationTests.swift \
  ClashMaxTests/TunnelHelperClientTests.swift \
  ClashMaxTests/DashboardRuntimeStateTests.swift
git commit -m "feat: ingest structured Helper runtime events"
```

## Task 10: Network Extension event ring with old-schema compatibility

**Files:**
- Modify: `Shared/NetworkExtensionRuntimeConstants.swift`
- Modify: `ClashMaxNetworkExtension/TransparentProxyProvider.swift`
- Modify: `ClashMaxNetworkExtension/main.swift`
- Modify: `ClashMax/Services/NetworkExtensionController.swift`
- Modify: `ClashMax/Stores/AppModel.swift`
- Modify: `ClashMaxTests/NetworkExtensionControllerTests.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift`
- Modify: `ClashMaxTests/NetworkExtensionProjectConfigurationTests.swift`

- [ ] **Step 1: Write old/new snapshot decoding tests**

Decode the current schema with no `schemaVersion`/`recentEvents` and require defaults. Decode a new schema with producer events and require IDs, categories, codes, levels, and timestamps to survive.

- [ ] **Step 2: Write NE source-buffer privacy tests**

Exercise a Shared `NetworkExtensionStructuredEventFactory` with an endpoint, signing identifier, and error containing a compound sentinel, encode the resulting snapshot fixture, and assert no credential sentinel or user path exists before App import. The hosted test target cannot `@testable import` the separate Network Extension product, so keep the redacting factory in Shared and require the NE recorder to call that tested factory.

- [ ] **Step 3: Write bounded/non-per-flow behavior tests**

Require provider start/stop, SOCKS handshake stage/failure, TCP/UDP/DNS aggregate changes, and persistence failure categories in the Shared event builder/retention policy. Generate many flow events and assert the ring stays bounded and does not persist payload/per-packet history. Add a source-contract test in `NetworkExtensionProjectConfigurationTests` that the NE target compiles the Shared producer/privacy/line files and routes recorder appends through the factory; do not pretend the App-hosted XCTest directly instantiated NE-private classes.

- [ ] **Step 4: Write App incremental import tests**

Poll the same snapshot twice and assert event IDs import once into `.runtime/.networkExtension`. Make the next file unreadable/corrupt and assert the last valid snapshot remains while one decode/permission event is recorded.

- [ ] **Step 5: Run focused tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/NetworkExtensionControllerTests \
  -only-testing:ClashMaxTests/NetworkExtensionProjectConfigurationTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testNetworkExtensionStructuredEventsImportOnce
```

Expected: `FAIL` because the shared snapshot has only bypass/error arrays and no general event ring.

- [ ] **Step 6: Extend the shared schema compatibly**

Add `schemaVersion`, `recentEvents: [ProducerLogEvent]`, and the Shared `NetworkExtensionStructuredEventFactory` with `decodeDefault`. Keep `recentBypasses` and `recentErrors` during migration so old App/NE combinations continue to work.

- [ ] **Step 7: Redact before NE memory and disk**

Every recorder entry point must construct a producer event only after applying `StructuredLogRedactor` to message and metadata. Persist the already-sanitized snapshot; never rely on App-side projection to protect the App Group file.

- [ ] **Step 8: Add lifecycle and aggregate events**

Record provider start/stop, VPN state, SOCKS handshake stage, and changes in TCP/UDP/DNS error counters. Keep per-flow `Logger` usage bounded and private; do not mirror every flow into `recentEvents`.

- [ ] **Step 9: Import new and legacy events**

Prefer `recentEvents`; wrap legacy bypass/error records when present. Bound seen IDs to the IDs in current/recent snapshots. Report file read/decode status distinctly from “no NE errors”.

- [ ] **Step 10: Run focused tests and build the NE target**

Run the Step 5 command, then:

```bash
bash script/guarded_xcodebuild.sh build -project ClashMax.xcodeproj \
  -target ClashMaxNetworkExtension \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `PASS` and `BUILD SUCCEEDED`.

- [ ] **Step 11: Commit**

```bash
git add Shared/NetworkExtensionRuntimeConstants.swift \
  ClashMaxNetworkExtension/TransparentProxyProvider.swift \
  ClashMaxNetworkExtension/main.swift \
  ClashMax/Services/NetworkExtensionController.swift \
  ClashMax/Stores/AppModel.swift \
  ClashMaxTests/NetworkExtensionControllerTests.swift \
  ClashMaxTests/DashboardRuntimeStateTests.swift \
  ClashMaxTests/NetworkExtensionProjectConfigurationTests.swift
git commit -m "feat: ingest structured Network Extension events"
```

## Task 11: TUN change events and diagnostic quality

**Files:**
- Modify: `ClashMax/Services/TunRuntimeInspector.swift`
- Create: `ClashMax/Services/TunDiagnosticsEventDiffer.swift`
- Modify: `ClashMax/Stores/AppModel.swift`
- Modify: `ClashMaxTests/TunRuntimeInspectorTests.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift`

- [ ] **Step 1: Write a pure TUN-diff test matrix**

For controller, Helper PID, utun, default route, route exclusions, DNS, and external checks, require:

- unchanged pass-to-pass emits nothing;
- status/error-code/summary changes emit one event;
- fail and recovery always emit;
- user refresh and repair emit even if unchanged;
- permission-denied records `EPERM/unavailable`, not “missing”.

- [ ] **Step 2: Write metadata privacy tests**

Require check ID, old/new status, exit/error code, duration, and count to remain. Require full command line, Bearer, complete route table, user path, endpoint, and DNS payload to be absent.

- [ ] **Step 3: Run focused tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/TunRuntimeInspectorTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testTunDiagnosticsRecordOnlyChangesFailuresRecoveryAndRepair
```

Expected: `FAIL` because snapshots are not converted into structured events.

- [ ] **Step 4: Add a pure differ**

Create `ClashMax/Services/TunDiagnosticsEventDiffer.swift` with:

```swift
enum TunDiagnosticsTrigger: Equatable, Sendable {
  case periodic
  case userRefresh
  case repair(action: String)
}

enum TunDiagnosticsEventDiffer {
  static func events(
    previous: TunDiagnosticsSnapshot,
    current: TunDiagnosticsSnapshot,
    trigger: TunDiagnosticsTrigger
  ) -> [ProducerLogEvent]
}
```

Use source `.tun`, stable `tun.check.<id>` codes, and Support audience for failures/recovery/repair. Routine unchanged details remain unlogged.

- [ ] **Step 5: Call the differ at every snapshot publication**

Route periodic, explicit refresh, and repair triggers correctly. Do not infer event identity from localized title/message; use `TunDiagnosticCheck.id` and status/error metadata. Convert current DNS apply/restore messages that include the full server list into safe stage/result/count events, and reuse existing repair UUIDs as operation IDs.

- [ ] **Step 6: Run focused tests**

Run the command from Step 3.

Expected: `PASS`.

- [ ] **Step 7: Commit**

```bash
git add ClashMax/Services/TunRuntimeInspector.swift \
  ClashMax/Services/TunDiagnosticsEventDiffer.swift \
  ClashMax/Stores/AppModel.swift \
  ClashMaxTests/TunRuntimeInspectorTests.swift \
  ClashMaxTests/DashboardRuntimeStateTests.swift
git commit -m "feat: record change-oriented TUN diagnostics"
```

## Task 12: Native SwiftUI log page, query policy, and viewport following

**Files:**
- Create: `ClashMax/Models/LogPresentation.swift`
- Modify: `ClashMax/Stores/LogNavigationState.swift`
- Create: `ClashMax/Views/Logs/LogChannelPane.swift`
- Create: `ClashMax/Views/Logs/StructuredLogRow.swift`
- Modify: `ClashMax/Views/Dashboard/RecentRuntimeLogsCard.swift`
- Modify: `ClashMax/Views/LogsView.swift`
- Modify: `ClashMax/Views/ContentView.swift`
- Modify: `Resources/Localizable.xcstrings`
- Create: `ClashMaxTests/LogPresentationTests.swift`
- Create: `ClashMaxTests/LogsViewLayoutTests.swift`
- Modify: `ClashMaxTests/MenuBarRuntimePresentationTests.swift`
- Modify: `ClashMaxTests/LocalizationTests.swift`

- [ ] **Step 1: Write query-composition tests**

Require channel, five-level mapping, runtime source, audience, and case/diacritic-insensitive search to compose. Search only projected text so ordinary users cannot discover hidden Developer fields.

- [ ] **Step 2: Write independent-tab-state tests**

Require default sidebar entry to choose application logs, a `LogNavigationState.open(.runtime)` request to choose runtime, and each tab to retain its own level/source/search/expanded-row/viewport state while switching. Give navigation requests an ID and consume each request once so a stale runtime request cannot override a later sidebar entry.

- [ ] **Step 3: Write viewport-policy tests**

Use a pure state machine:

```swift
struct LogViewportState: Equatable, Sendable {
  var followsLatest: Bool
  var pendingCount: Int
  mutating func didAppend(_ count: Int)
  mutating func didChangeBottomProximity(isNearBottom: Bool)
  mutating func jumpToLatest()
}
```

Assert append-at-bottom follows, append-after-upscroll increments pending without jumping, and Jump to Latest clears pending/restores follow. Historical events inserted by late recovery must not count as new; a query change resets the pending baseline to the new result set.

- [ ] **Step 4: Write runtime-card selector tests**

Require at most six newest runtime Support events, correct source labels, stable order, and zero application/Developer leakage.

- [ ] **Step 5: Write quality-diagnostics and pre-implementation UI tests**

Add pure presentation tests requiring the active channel's `LogQualitySnapshot` to expose all six confirmed diagnostics with stable labels and values:

- merged event count;
- capacity-dropped count;
- sampled-dropped count;
- decode-failure count;
- last successful event time or “Never”;
- latest typed writer issue rendered from operation/domain/code/time, or “None”.

Switch channels in the test and prove the values do not bleed between stores. Construct only a typed writer issue whose original test error contained a home-path sentinel; require presentation to use fixed localized copy plus allowlisted operation/domain/code and contain no raw error/path text.

Add `LogsViewLayoutTests` before changing the view: host the eventual `LogsView`/row fixtures in `NSHostingView` at narrow macOS window widths using translated English/Simplified Chinese controls, Chinese event content, long messages, and accessibility text sizes. Require adaptive column hiding without horizontal overflow, keyboard-focusable controls, VoiceOver labels/help, and stable accessibility identifiers for channel, level, source, actions, quality diagnostics, both lists, Jump to Latest, clear confirmation, and the runtime card. These tests should initially fail to compile or assert because the new UI/localizations are absent.

- [ ] **Step 6: Run presentation and UI tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/LogPresentationTests \
  -only-testing:ClashMaxTests/LogsViewLayoutTests \
  -only-testing:ClashMaxTests/MenuBarRuntimePresentationTests/LogLevelStyleTests \
  -only-testing:ClashMaxTests/LocalizationTests
```

Expected: `FAIL` because pure query/navigation/viewport policies do not exist.

- [ ] **Step 7: Implement pure presentation state**

Use `LogQuery` as `Equatable, Sendable`, containing channel, level filter, optional runtime source, search text, and developer-mode flag. Snapshot events and projection context before off-main work. Add a pure `LogQualityPresentation` that formats the six quality fields without inspecting message text.

- [ ] **Step 8: Build the native toolbar and active-channel quality surface**

Keep `LogsView` as the parent and place per-channel list/query/scroll work in `LogChannelPane`. In `LogsView`:

- segmented `Picker` for Application/Runtime;
- menu-style level `Picker`;
- menu-style source `Picker` only for Runtime;
- `.searchable(text:placement:prompt:)`;
- native `Menu` for actions (wired in Task 13).

Do not add a ViewModel. Keep page state in `@State`; consume the marker-distinct `ApplicationLogStore`, `RuntimeLogStore`, and `LogNavigationState` through `@Environment`.

Add a compact native status control for the active channel with a popover containing a labeled two-column `Grid` for all six quality diagnostics. Render the latest writer issue only through `LogQualityPresentation` fixed localized copy; never interpolate raw `Error` text. Keep it additionally visible as an actionable inline warning. Give the control, popover, and each metric stable accessibility labels/identifiers; switching tabs must immediately switch the quality snapshot.

- [ ] **Step 9: Build the lazy expandable list**

Use:

```swift
ScrollView {
  LazyVStack(spacing: 0) {
    ForEach(projectedEvents) { event in
      StructuredLogRow(event: event, isExpanded: ...)
        .id(event.id)
    }
  }
}
```

Each row shows millisecond time, text+SF Symbol+semantic color level, source, category/code, and message. Expanded content shows metadata, operation ID, repetition count, and receive delay. No per-event insertion animation.

- [ ] **Step 10: Add cancellable off-main filtering**

Use `.task(id: queryRevision)`; capture Sendable snapshots, run pure filtering in `Task.detached(priority: .userInitiated)`, call `try Task.checkCancellation()`, and publish only if both cancellation state and a request token still match. While a query is computing, retain the last published snapshot and disable copy/export so screen and output cannot disagree.

- [ ] **Step 11: Add macOS 15 scrolling behavior**

Use `ScrollPosition`, `ScrollViewReader`, `onScrollGeometryChange`, and `onScrollPhaseChange` (available at the deployment target). Scroll only when the active tab's policy says `followsLatest`; expose an accessible “Jump to Latest” button with pending count. Do not use macOS 26-only `ScrollPosition.x/y`. Do not gate macOS 15 APIs; gate only any API newer than the deployment target and provide a native fallback.

- [ ] **Step 12: Implement explicit states and satisfy the prewritten layout tests**

- short disk recovery: progress state;
- connecting/starting with no events: shared Shimmer primitives;
- stopped, empty, failed, security warning, and recovery: explicit non-skeleton states;
- narrow width: adaptive column visibility without horizontal clipping;
- VoiceOver labels/help and keyboard focus for rows and actions.
- stable accessibility identifiers for channel, level, source, actions, both lists, Jump to Latest, clear confirmation, and the runtime card.

Add the English and Simplified Chinese strings used by this task's channel/source/level/search controls, quality panel, list rows, Jump to Latest, and content states now, before rerunning `LogsViewLayoutTests`; Task 14 is only the final catalog audit and remaining later-workflow strings.

- [ ] **Step 13: Run focused tests and build**

Run the Step 6 command, then:

```bash
bash script/guarded_xcodebuild.sh build -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

Expected: `PASS` and `BUILD SUCCEEDED`.

- [ ] **Step 14: Commit**

```bash
git add ClashMax/Models/LogPresentation.swift \
  ClashMax/Stores/LogNavigationState.swift \
  ClashMax/Views/Logs/LogChannelPane.swift \
  ClashMax/Views/Logs/StructuredLogRow.swift \
  ClashMax/Views/Dashboard/RecentRuntimeLogsCard.swift \
  ClashMax/Views/LogsView.swift \
  ClashMax/Views/ContentView.swift \
  Resources/Localizable.xcstrings \
  ClashMaxTests/LogPresentationTests.swift \
  ClashMaxTests/LogsViewLayoutTests.swift \
  ClashMaxTests/MenuBarRuntimePresentationTests.swift \
  ClashMaxTests/LocalizationTests.swift
git commit -m "feat: build native structured log viewer"
```

## Task 13: Copy, export, clear, runtime-card navigation, and diagnostics

**Files:**
- Create: `ClashMax/Services/StructuredLogExport.swift`
- Modify: `ClashMax/Stores/AppModel.swift`
- Modify: `ClashMax/Views/LogsView.swift`
- Modify: `ClashMax/Views/Dashboard/RecentRuntimeLogsCard.swift`
- Modify: `ClashMax/Views/Dashboard/RunningDashboardView.swift`
- Modify: `ClashMax/App/ClashMaxApp.swift`
- Modify: `Resources/Localizable.xcstrings`
- Create: `ClashMaxTests/StructuredLogExportTests.swift`
- Create: `ClashMaxTests/AppTerminationLoggingTests.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift`
- Modify: `ClashMaxTests/LocalizationTests.swift`

- [ ] **Step 1: Write one end-to-end Support-output sentinel test**

Use the same event containing credential and identity sentinels. Assert clipboard text, exported UTF-8 text, application diagnostics tail, and runtime diagnostics tail are byte-for-byte derived from the same formatter and contain no forbidden sentinel.

- [ ] **Step 2: Write filter/header tests**

Require current channel/query only, App version, generated time, time range, channel, level/source/search criteria, and stable event order. Empty results must disable copy/export or produce an explicit empty-state response.

Add an injected folder-opener test. Selecting “Open Log Folder” must first present a confirmation explaining that raw JSONL is a local Developer record, may contain identity-level detail, and is not directly submit-safe; offer Copy/Export as the safe support workflow. Assert Cancel never calls the opener and only explicit confirmation opens the fixed logs directory. Require localized English and Simplified Chinese warning text and accessible confirmation controls.

- [ ] **Step 3: Write channel-clear tests**

Clear with pending publication/write and assert memory plus all rotated files for only the selected channel disappear. Capture the channel at the moment the confirmation request is created, switch tabs before confirming in the test, and assert the originally requested channel is cleared. Simulate a failure and require a visible recoverable error without clearing the other channel.

- [ ] **Step 4: Write navigation and runtime-card tests**

Invoke the card/open action and assert `selectedSection == .logs` plus a runtime navigation request. Assert the card renders only six runtime Support events and includes Mihomo/Helper/NE/TUN source text.

- [ ] **Step 5: Write diagnostics-section tests**

Require separate `Application Logs:` and `Runtime Logs:` tails. Remove the standalone raw Helper section once Helper events are in runtime. Require the whole report, including profile/node/probe fields, to use Support redaction.

- [ ] **Step 6: Write application-termination logging tests**

Exercise the termination coordinator with injected cleanup and persistence fakes; never ask `NSApplication` to terminate in a unit test. Cover no cleanup needed, cleanup success, cleanup failure, one hanging writer, and both writers completing. Require these stable application events and safe metadata:

```text
app.termination.requested
app.termination.cleanup.completed
app.termination.cleanup.failed
app.termination.flush.completed
app.termination.flush.timed-out
```

Assert the cleanup outcome is recorded before the first flush, the flush is attempted in a defer-like path even after cleanup failure, a hung channel never prevents the other from completing, and the whole termination path respects one fixed deadline. After the first flush result is known, record the final flush outcome and use only the remaining deadline for one best-effort application-channel flush; do not recursively report a failure of that final attempt.

Resolve the AppKit reply contract explicitly:

- if `appModel == nil`, preserve the existing immediate `.terminateNow` fallback because there is no recorder;
- otherwise the first request returns `.terminateLater` even when runtime cleanup is unnecessary, because recording `app.termination.requested` itself creates asynchronous persistence work;
- reentrant requests while coordination is in flight return `.terminateLater` without starting another task;
- the coordinator eventually calls `reply(toApplicationShouldTerminate:)` with the same final cleanup-success Boolean the existing `prepareForTermination()` path would have produced.

Tests must assert this intentional immediate-reply change instead of simultaneously expecting `.terminateNow` and an awaited flush.

- [ ] **Step 7: Run focused tests and confirm failure**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogExportTests \
  -only-testing:ClashMaxTests/AppTerminationLoggingTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testRuntimeDiagnosticsSeparatesApplicationAndRuntimeSupportLogs \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testRecentRuntimeLogCardOpensRuntimeTab \
  -only-testing:ClashMaxTests/LocalizationTests
```

Expected: `FAIL` because formatter/actions/sections are not implemented.

- [ ] **Step 8: Implement one formatter**

Use:

```swift
struct StructuredLogExportContext: Equatable, Sendable {
  var appVersion: String
  var generatedAt: Date
  var queryDescription: String
  var channel: LogChannel
}

enum StructuredLogSupportFormatter {
  static func text(
    events: [StructuredLogEvent],
    context: StructuredLogExportContext,
    projection: SupportProjectionContext
  ) -> String
}
```

Clipboard, `FileDocument`, and diagnostics must call this exact function. No action may format raw stored events.

- [ ] **Step 9: Add native actions**

- Copy: injectable `LogClipboardWriting` with an `NSPasteboard` implementation.
- Export: SwiftUI `.fileExporter` with a UTF-8 `FileDocument`; cancellation is not an error.
- Open folder: wrap fixed-directory `NSWorkspace` integration behind an injectable opener and the mandatory warning confirmation.
- Clear: destructive confirmation alert; await `structuredLogRecorder.clear(channel)`.

Copy/export must operate on the last published `LogQuerySnapshot`, not recompute from raw storage after the action is clicked. Disable them while the query task is in flight. Clear confirmation stores its requested channel independently of the currently selected tab.

Never call `NSWorkspace` directly from the menu action. Present the prewritten raw-JSONL warning first, and call the injected fixed-directory opener only from its explicit confirmation action.

- [ ] **Step 10: Make the runtime card an accessible navigation control**

Use a plain-style `Button` or explicit “Open Logs” button rather than a gesture-only card. Set the navigation request before changing `selectedSection`.

- [ ] **Step 11: Update diagnostics and implement the tested termination sequence**

Build separate Support tails from the two stores. In `applicationShouldTerminate`, record requested and cleanup outcome events, return `.terminateLater` for every request with a live `appModel`, and call the bounded two-phase recorder flush proven in Step 6 even when runtime cleanup fails or is unnecessary. Never block indefinitely on one channel. Preserve the existing final cleanup-success Boolean passed to `reply(toApplicationShouldTerminate:)`, not the old immediate `.terminateNow` path.

Add this task's English and Simplified Chinese copy/export/clear/raw-folder-warning/termination failure strings now and run localization tests; Task 14 remains the final catalog/migration audit.

- [ ] **Step 12: Run focused tests**

Run the command from Step 7.

Expected: `PASS`.

- [ ] **Step 13: Commit**

```bash
git add ClashMax/Services/StructuredLogExport.swift \
  ClashMax/Stores/AppModel.swift \
  ClashMax/Views/LogsView.swift \
  ClashMax/Views/Dashboard/RecentRuntimeLogsCard.swift \
  ClashMax/Views/Dashboard/RunningDashboardView.swift \
  ClashMax/App/ClashMaxApp.swift \
  Resources/Localizable.xcstrings \
  ClashMaxTests/StructuredLogExportTests.swift \
  ClashMaxTests/AppTerminationLoggingTests.swift \
  ClashMaxTests/DashboardRuntimeStateTests.swift \
  ClashMaxTests/LocalizationTests.swift
git commit -m "feat: add safe structured log workflows"
```

## Task 14: Remove the mixed buffer and complete migration/localization

**Files:**
- Modify: `ClashMax/Stores/RuntimeDataStore.swift`
- Modify: `ClashMax/Models/CoreModels.swift`
- Modify: `ClashMax/Stores/AppModel.swift`
- Modify: `ClashMax/Views/LogsView.swift`
- Modify: `ClashMax/Views/Dashboard/RunningDashboardView.swift`
- Modify: `ClashMax/Views/MenuBarView.swift` only if compilation shows a legacy log reference
- Modify: `Resources/Localizable.xcstrings`
- Modify: `ClashMaxTests/RuntimeDataStoreTests.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift`
- Modify: `ClashMaxTests/StructuredApplicationEventCoverageTests.swift` only if migration exposes a missing behavioral path
- Modify: `ClashMaxTests/LocalizationTests.swift`

- [ ] **Step 1: Add a static migration guard test**

Read the source tree in a test and fail if production code still contains:

```text
RuntimeDataStore.logs
runtimeData.appendLog
struct LogEntry
enum LogVisibility
helperLogs: [String]
```

Allow references only in migration comments scheduled for deletion in this same task.

- [ ] **Step 2: Convert remaining legacy App log call sites**

Search:

```bash
rg -n 'appendAppLog|LogEntry|LogVisibility|runtimeData\\.logs|runtimeData\\.appendLog|helperLogs' ClashMax Shared ClashMaxHelper ClashMaxNetworkExtension
```

Replace every generic legacy event with a stable category/code/audience. Do not use localized message text as an event identifier. This search is only a migration inventory, not coverage evidence: after conversion, re-exercise the behavioral matrix for launch/warmup, termination, runtime lifecycle, config generation/validation/reload, controller success/failure, stream reconnect, XPC, DNS/routes, cancellation, timeout, and stale-generation rejection.

- [ ] **Step 3: Remove old ownership**

Delete the log buffer, publish task, `logs`, append/flush methods, and visibility methods from `RuntimeDataStore`. Delete `LogEntry`/`LogVisibility` from `CoreModels`. Remove compatibility merged snapshots and raw Helper logs from `AppModel`.

- [ ] **Step 4: Update style tests**

Change `LogLevelStyle` to accept `StructuredLogLevel`; preserve red/orange/purple/secondary behavior and add a distinct Critical symbol/weight.

- [ ] **Step 5: Complete the English and Simplified Chinese catalog audit**

Tasks 12–13 add strings alongside their UI. Audit the completed feature and add only any remaining producer/migration copy. Require coverage for channel names, sources, filters, recovery/classified-writer warnings, log-level limitation hint, Jump to Latest/pending count, copy/export/clear confirmation/results, raw JSONL warning, empty/stopped/connecting states, expanded metadata labels, and pluralized counts. Fail if either locale falls back to the key.

- [ ] **Step 6: Run the migration and localization gates**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/RuntimeDataStoreTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testLegacyMixedLogBufferIsFullyRemoved \
  -only-testing:ClashMaxTests/StructuredApplicationEventCoverageTests \
  -only-testing:ClashMaxTests/AppTerminationLoggingTests \
  -only-testing:ClashMaxTests/MenuBarRuntimePresentationTests/LogLevelStyleTests \
  -only-testing:ClashMaxTests/LocalizationTests
```

Then:

```bash
CLASHMAX_XCODEBUILD_WRAPPER=script/guarded_xcodebuild.sh \
  ./script/localization_gate.sh
```

Expected: both commands `PASS`; `rg` from Step 2 returns no production legacy references.

- [ ] **Step 7: Verify project configuration did not drift**

Run:

```bash
bash script/guarded_xcodebuild.sh --verify-only --require-complete-allowlist
git diff --exit-code 6b7f114..HEAD -- Config '*.entitlements'
git diff 6b7f114..HEAD -- project.yml
git diff --exit-code HEAD -- Config project.yml '*.entitlements'
```

Expected: the generated-project semantic/security comparison and complete source allowlist pass; the Git exit-code guards are empty/successful. The complete committed `project.yml` diff contains only the three explicit Network Extension Shared-source entries added in Task 1; there are no target-setting, signing, entitlement, capability, embed, or identifier changes in tracked or ignored project state.

- [ ] **Step 8: Commit**

```bash
git add ClashMax/Stores/RuntimeDataStore.swift \
  ClashMax/Models/CoreModels.swift \
  ClashMax/Stores/AppModel.swift \
  ClashMax/Views/LogsView.swift \
  ClashMax/Views/Dashboard/RunningDashboardView.swift \
  ClashMax/Views/MenuBarView.swift \
  Resources/Localizable.xcstrings \
  ClashMaxTests/RuntimeDataStoreTests.swift \
  ClashMaxTests/DashboardRuntimeStateTests.swift \
  ClashMaxTests/StructuredApplicationEventCoverageTests.swift \
  ClashMaxTests/LocalizationTests.swift \
  ClashMaxTests/MenuBarRuntimePresentationTests.swift
git commit -m "refactor: remove legacy mixed log buffer"
```

## Task 15: Focused, full, and user-gated verification

**Files:**
- Modify only if a test exposes a defect in already-scoped implementation files.
- Evidence: `DerivedData/TestResults/StructuredLoggingFocused.xcresult`
- Evidence: `DerivedData/TestResults/StructuredLoggingFull.xcresult`

- [ ] **Step 1: Record the pre-test machine baseline**

Read-only checks:

```bash
pgrep -x ClashMax || true
pgrep -x ClashMaxHelper || true
pgrep -x mihomo || true
lsof -nP -iTCP:7890 -sTCP:LISTEN || true
lsof -nP -iTCP:9097 -sTCP:LISTEN || true
scutil --proxy
scutil --dns
route -n get default
```

Expected: no ClashMax/Helper/Mihomo test residue and no managed proxy/listener. Record actual DNS/route for exact post-test comparison.

- [ ] **Step 2: Run the focused logging matrix**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -resultBundlePath DerivedData/TestResults/StructuredLoggingFocused.xcresult \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/StructuredLogProducerTests \
  -only-testing:ClashMaxTests/StructuredLogEventTests \
  -only-testing:ClashMaxTests/StructuredLogProjectionTests \
  -only-testing:ClashMaxTests/StructuredLogPersistenceTests \
  -only-testing:ClashMaxTests/StructuredLogSamplerTests \
  -only-testing:ClashMaxTests/LogChannelStoreTests \
  -only-testing:ClashMaxTests/StructuredLogRecorderTests \
  -only-testing:ClashMaxTests/StructuredApplicationEventCoverageTests \
  -only-testing:ClashMaxTests/StructuredLogExportTests \
  -only-testing:ClashMaxTests/AppTerminationLoggingTests \
  -only-testing:ClashMaxTests/LogPresentationTests \
  -only-testing:ClashMaxTests/LogsViewLayoutTests \
  -only-testing:ClashMaxTests/SystemProxyControllerTests \
  -only-testing:ClashMaxTests/CoreProcessControllerTests \
  -only-testing:ClashMaxTests/MihomoAPIClientTests \
  -only-testing:ClashMaxTests/TunnelHelperClientTests \
  -only-testing:ClashMaxTests/TunnelHelperValidationTests \
  -only-testing:ClashMaxTests/NetworkExtensionControllerTests \
  -only-testing:ClashMaxTests/TunRuntimeInspectorTests \
  -only-testing:ClashMaxTests/DashboardRuntimeStateTests
```

Expected: `TEST SUCCEEDED`, zero failures.

- [ ] **Step 3: Run the full suite**

Run:

```bash
bash script/guarded_xcodebuild.sh test -project ClashMax.xcodeproj -scheme ClashMax \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  -resultBundlePath DerivedData/TestResults/StructuredLoggingFull.xcresult \
  CODE_SIGNING_ALLOWED=NO
```

Expected: all non-skipped tests pass. Report exact passed/skipped/failed counts from:

```bash
xcrun xcresulttool get test-results summary \
  --path DerivedData/TestResults/StructuredLoggingFull.xcresult
```

- [ ] **Step 4: Re-run localization and source guards**

Run:

```bash
CLASHMAX_XCODEBUILD_WRAPPER=script/guarded_xcodebuild.sh \
  ./script/localization_gate.sh
rg -n 'RuntimeDataStore\\.logs|runtimeData\\.appendLog|struct LogEntry|enum LogVisibility' ClashMax
git diff --check 6b7f114..HEAD
git diff --check
```

Expected: localization `PASS`, no legacy production matches, and no whitespace errors in committed or uncommitted changes.

- [ ] **Step 5: Compare the post-test machine baseline**

Repeat Step 1. Expected: exact process/port/proxy/DNS/route state matches the pre-test baseline. If not, report `FAIL` and diagnose without broadly killing processes or changing system settings.

- [ ] **Step 6: Inspect the final diff**

Run:

```bash
git status --short
git diff --stat 6b7f114..HEAD
bash script/guarded_xcodebuild.sh --verify-only --require-complete-allowlist
git diff --exit-code 6b7f114..HEAD -- Config '*.entitlements'
git diff 6b7f114..HEAD -- project.yml
git diff --exit-code HEAD -- Config project.yml '*.entitlements'
```

Expected: only scoped source/tests/docs/localization/guard-tooling changes; the ignored generated project matches the pre-change App/Helper/NE security/capability/embed snapshot and complete source allowlist; the full committed `project.yml` diff contains exactly the three explicit NE Shared-source entries; both Git exit-code guards are clean; and there is no signing/entitlement drift.

- [ ] **Step 7: Commit verification-only fixes if any**

If no fixes were required, do not create an empty commit. If scoped fixes were required:

Stage only the explicitly named files from the affected task's **Files** list (never `git add -A` or a broad directory), inspect the staged diff, then commit with `git commit -m "test: complete structured logging verification"`.

- [ ] **Step 8: Report real-system acceptance as user-gated**

Report:

- Automated source/fake integration: `PASS` or `FAIL` with exact evidence.
- Real signed Helper/NE/TUN/Mihomo runtime smoke: `NOT RUN — requires user approval and may change Helper/System Extension/System Proxy/DNS/routes`.
- Do not turn `NOT RUN` into `PASS` based on unit tests.
- Wait for explicit user instruction before running `./script/build_and_run.sh`, approving extensions, registering Helper, enabling TUN/NE, or changing network state.
