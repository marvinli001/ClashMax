# ObservableObject → @Observable Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace every remaining `ObservableObject`/`@Published` observation path in ClashMax with the Observation framework (`@Observable`), removing Combine from the app's state fan-out.

**Architecture:** Sixteen `ObservableObject` types migrate in four staged commits. `AppModel` and the nine types it relays `objectWillChange` from must migrate in a single atomic commit, because `AppModel`'s ~20 computed facades over `settings` lose invalidation silently if the relay disappears before the sub-store becomes `@Observable`. Five Combine pipelines that carry real behavior become `didSet` callbacks. Nine tests asserting on `objectWillChange` become per-property assertions.

**Tech Stack:** Swift 6 (Swift 6 language mode), SwiftUI, Observation framework, macOS 15.0 deployment target, xcodegen (`project.yml`), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-03-observable-migration-design.md`

---

## Conventions used throughout this plan

**Build/test command** (whole suite):

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | tail -30
```

**Single test:**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testSettingCurrentModeDoesNotPublishChanges 2>&1 | tail -30
```

Expected pass output contains `** TEST SUCCEEDED **`. Expected failure output contains `** TEST FAILED **` plus the specific assertion.

**Baseline:** before starting, record the current pass count. Any later count below baseline minus the tests this plan intentionally rewrites is a regression, not noise. This project has a documented history of blaming pre-existing failures on new changes — always baseline-diff first.

### The three annotation rules

These govern every migration task. Read them before Task 1.

**R1 — Former `@Published` becomes a plain stored property.** Drop the attribute, keep everything else including `private(set)`:

```swift
// Before
@Published private(set) var status: CoreStatus = .stopped
// After
private(set) var status: CoreStatus = .stopped
```

**R2 — `@ObservationIgnored` for non-state stored properties.** Apply to `Task` handles, caches, generation counters, buffers, and the new callback hooks. Do **not** blanket-apply it to every private property: `@Observable` only invalidates a view when that view actually read the property, so a private property no view can reach costs nothing.

**R3 — Audit private properties reachable from view-visible computed properties.** This is the one case where behavior genuinely changes. Under `ObservableObject`, a computed property reading a non-`@Published` stored property never invalidated. Under `@Observable` it does. Example already in the code — `canRepairTunRouting` (`AppModel.swift:631`) reads `private var tunHelperStopUnconfirmed` (`AppModel.swift:789`):

```swift
var canRepairTunRouting: Bool {
    runtimeOwner == .tunnel
      || tunEnabled
      || tunnelCoreRunning
      || tunHelperStopUnconfirmed   // private, was never observable
      || tunDiagnostics.primaryIssue != nil
      || systemProxyController.hasManagedSystemDNSState
}
```

For each such property decide deliberately:
- The extra invalidation is **correct and cheap** (a button's enabled state now updates when it should) → leave it observable, and note it in the commit message.
- The property is mutated on a **hot path** (per-node delay results, log appends, per-frame counters) → mark `@ObservationIgnored`, or the issue #10/#11 perf work regresses.

Task 12 is the dedicated audit step and spells out the procedure.

---

## File Structure

**Created:**

| File | Responsibility |
| --- | --- |
| `ClashMaxTests/Support/ObservationChangeCounter.swift` | Shared test helper. Currently `private` inside `DashboardRuntimeStateTests.swift:12750`, so `ProfileStoreTests` and `ProxySearchPipelineTests` cannot reach it. |

**Modified — Stage 1 (leaves + services):** `ClashMax/Views/ProxySearchCoordinator.swift`, `ClashMax/Views/ConnectionsView.swift`, `ClashMax/Views/RoutingView.swift`, `ClashMax/Services/AppUpdateController.swift`, `ClashMax/Stores/PublicIPCoordinator.swift`, `ClashMax/Services/TunnelHelperClient.swift`

**Modified — Stage 2 (atomic cluster):** `ClashMax/Stores/PersistedSettingsStore.swift`, `ClashMax/Stores/ProfileStore.swift`, `ClashMax/Stores/ProfileOperationsStore.swift`, `ClashMax/Stores/ProxyPreviewStore.swift`, `ClashMax/Stores/ProviderAnalyticsStore.swift`, `ClashMax/Stores/RuntimeSnippetLibraryStore.swift`, `ClashMax/Stores/SystemProxyCoordinator.swift`, `ClashMax/Services/CoreProcessController.swift`, `ClashMax/Services/NetworkExtensionController.swift`, `ClashMax/Stores/AppModel.swift`

**Modified — Stage 3 (view call sites):** `ClashMax/App/ClashMaxApp.swift` and the 17 view files holding the 57 `@EnvironmentObject` declarations.

**Counts** (verified against the working tree, not HEAD): 57 `@EnvironmentObject`, 33 `.environmentObject(`, 5 `@StateObject`, 7 `@ObservedObject`, 81 `@Published`.

**Modified — Stage 4 (tests):** `ClashMaxTests/DashboardRuntimeStateTests.swift`, `ClashMaxTests/ProfileStoreTests.swift`, `ClashMaxTests/ProxySearchPipelineTests.swift`, `ClashMaxTests/MenuBarPanelLayoutTests.swift`

---

# Stage 0: Baseline

### Task 0: Record the baseline and pin the priming behavior

**Files:**
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift` (append near the other global-shortcut tests at `:8204-8274`)

- [ ] **Step 1: Confirm you are on the migration branch**

```bash
git branch --show-current
```

Expected: `observable-migration`. If not, run `git checkout observable-migration`.

- [ ] **Step 2: Run the full suite and record the count**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Write the resulting "Executed N tests, with M failures" line into your notes. This is the baseline every later task compares against.

- [ ] **Step 3: Pin the priming behavior with a characterization test**

Of the three handlers that `@Published` primes on subscribe, only `installGlobalShortcuts` has an observable effect at init: `handleCoreStatusChange` early-returns unless the status is `.crashed` (`AppModel.swift:1559`) and status is `.stopped` at construction, and `schedulePreviewRuntimeStartIfReady` requires non-empty preview groups (`AppModel.swift:6663`) which do not exist yet. The other two priming calls are cheap insurance, not load-bearing — this test covers the one that matters.

Write it **now**, against the un-migrated code, so you can prove it is meaningful before it becomes a regression guard. The three existing global-shortcut tests at `:8204`, `:8225`, `:8251` all assign `model.globalShortcutSettings` after construction and therefore exercise the `didSet`/publish path, not priming. This one deliberately assigns nothing after construction.

Append to `ClashMaxTests/DashboardRuntimeStateTests.swift`:

```swift
  func testGlobalShortcutsAreRegisteredFromPersistedSettingsAtLaunch() throws {
    let paths = try Self.makeRuntimePaths()
    let defaults = try Self.makeIsolatedDefaults()
    let shortcut = try XCTUnwrap(KeyboardShortcutDescriptor(string: "cmd+shift+p"))

    // Seed the suite the way a previous launch would have left it. Assigning through a throwaway
    // store persists via its didSet, so this needs no knowledge of the defaults keys or encoding.
    let seed = PersistedSettingsStore(defaults: defaults)
    seed.developerMode = true
    seed.globalShortcutSettings = GlobalShortcutSettings(bindings: [
      GlobalShortcutBinding(action: .startStop, shortcut: shortcut, enabled: true)
    ])

    let registrar = RecordingAppGlobalShortcutRegistrar()
    let model = AppModel(
      paths: paths,
      profileStore: ProfileStore(paths: paths, keychain: InMemorySecretStore()),
      defaults: defaults,
      globalShortcutRegistrar: registrar
    )

    // Nothing is assigned to model.globalShortcutSettings here on purpose. @Published emits its
    // current value on subscribe, so installGlobalShortcuts runs once during setupBindings today.
    // `didSet` does not fire during init, so after the migration setupBindings must prime this
    // explicitly — otherwise shortcuts a user already configured are never registered at launch.
    XCTAssertEqual(registrar.registrations.map(\.action), [.startStop])
    XCTAssertEqual(model.shortcutRegistrationStatus?.registeredCount, 1)
  }
```

- [ ] **Step 4: Run it and confirm it passes on the un-migrated code**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testGlobalShortcutsAreRegisteredFromPersistedSettingsAtLaunch 2>&1 | tail -20
```

Expected: PASS. If it fails, the seeding is wrong (wrong defaults suite, or `GlobalShortcutSettings` needs a different initializer) — fix the test until it passes, because a characterization test that fails on the old code pins nothing.

- [ ] **Step 5: Commit**

```bash
git add ClashMaxTests/DashboardRuntimeStateTests.swift
git commit -m "test: pin launch-time global shortcut registration

@Published primes installGlobalShortcuts on subscribe; didSet will not.
This test fails if the @Observable migration drops the priming call.
The existing shortcut tests all assign after construction and so cover
the publish path rather than priming."
```

There are uncommitted work-in-progress changes in the tree (launch-at-login repair, menu bar work) that are **not** part of this migration. Do not commit them, do not revert them, and do not include them in any `git add`. Every commit in this plan lists explicit paths for exactly this reason.

---

# Stage 1: Leaves and services

None of these six types are relayed into `AppModel.objectWillChange`, so they carry no nested-tracking dependency and can migrate independently.

### Task 1: `ConnectionAppIconCache` — drop the conformance

`ConnectionAppIconCache` declares no `@Published` properties and never calls `objectWillChange.send()`. It publishes nothing. It should not become `@Observable`; it should stop being an `ObservableObject`.

**Files:**
- Modify: `ClashMax/Views/ConnectionsView.swift:420` (declaration), `:26` (`@StateObject`), `:481`, `:503` (`@ObservedObject`)

- [ ] **Step 1: Drop the conformance**

At `ClashMax/Views/ConnectionsView.swift:419-420`, change:

```swift
@MainActor
final class ConnectionAppIconCache: ObservableObject {
```

to:

```swift
@MainActor
final class ConnectionAppIconCache {
```

- [ ] **Step 2: Convert the owner to `@State`**

At `ClashMax/Views/ConnectionsView.swift:26`, change:

```swift
@StateObject private var appIconCache = ConnectionAppIconCache()
```

to:

```swift
@State private var appIconCache = ConnectionAppIconCache()
```

`@State` holds the reference for the view's lifetime exactly as `@StateObject` did. The initializer is cheap (it stores two values and allocates two empty collections), so re-evaluating the expression on view-struct init is free.

- [ ] **Step 3: Convert the two consumers to plain lets**

At `ClashMax/Views/ConnectionsView.swift:481` and `:503`, change both:

```swift
@ObservedObject var iconCache: ConnectionAppIconCache
```

to:

```swift
let iconCache: ConnectionAppIconCache
```

- [ ] **Step 4: Build and run the suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: same count as baseline, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClashMax/Views/ConnectionsView.swift
git commit -m "refactor: drop ObservableObject from ConnectionAppIconCache

It declares no @Published properties and never sends objectWillChange,
so the conformance bought nothing. Held by @State for lifetime instead."
```

### Task 2: `RuleMatchSimulationDebouncer` — drop the conformance

Same situation: a `Task` handle and a delay constant, no observable state.

**Files:**
- Modify: `ClashMax/Views/RoutingView.swift:47` (declaration), `:100` (`@StateObject`)

- [ ] **Step 1: Drop the conformance**

At `ClashMax/Views/RoutingView.swift:46-47`, change:

```swift
@MainActor
final class RuleMatchSimulationDebouncer: ObservableObject {
```

to:

```swift
@MainActor
final class RuleMatchSimulationDebouncer {
```

- [ ] **Step 2: Convert the owner to `@State`**

At `ClashMax/Views/RoutingView.swift:100`, change:

```swift
@StateObject private var simulationDebouncer = RuleMatchSimulationDebouncer()
```

to:

```swift
@State private var simulationDebouncer = RuleMatchSimulationDebouncer()
```

- [ ] **Step 3: Run the suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count, `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClashMax/Views/RoutingView.swift
git commit -m "refactor: drop ObservableObject from RuleMatchSimulationDebouncer

Holds only a Task handle and a delay constant; nothing observable."
```

### Task 3: `PublicIPCoordinator` → `@Observable`

**Files:**
- Modify: `ClashMax/Stores/PublicIPCoordinator.swift:4-5`
- Consumer (converted in Stage 3): `ClashMax/Views/Dashboard/PublicIPInfoCard.swift:5`

- [ ] **Step 1: Migrate the class**

At `ClashMax/Stores/PublicIPCoordinator.swift:3-5`, change:

```swift
@MainActor
final class PublicIPCoordinator: ObservableObject {
  @Published private(set) var state: PublicIPInfoState = .idle
```

to:

```swift
@MainActor
@Observable
final class PublicIPCoordinator {
  private(set) var state: PublicIPInfoState = .idle
```

- [ ] **Step 2: Annotate the Task handle**

The type holds `private var task: Task<...>` (see `PublicIPCoordinator.swift:36` where it is assigned). Mark it per rule R2:

```swift
@ObservationIgnored private var task: Task<Void, Never>?
```

- [ ] **Step 3: Remove the Combine import if now unused**

```bash
grep -n "Combine\|AnyCancellable\|Publisher" ClashMax/Stores/PublicIPCoordinator.swift
```

If the only hit is `import Combine`, delete that line. If there are no hits at all, nothing to do.

- [ ] **Step 4: Run the suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count, `** TEST SUCCEEDED **`.

`PublicIPInfoCard` still reads it via `@EnvironmentObject`, which keeps compiling only if the type is still `ObservableObject` — it is not. **If the build fails here with "does not conform to ObservableObject" at `PublicIPInfoCard.swift:5`, that is expected**; fix it now by applying the Stage 3 conversion to that one line:

```swift
// PublicIPInfoCard.swift:5
@Environment(PublicIPCoordinator.self) private var publicIP
```

and change its injection at `ClashMax/App/ClashMaxApp.swift:23`, `:121`, `:151` from `.environmentObject(appModel.publicIP)` to `.environment(appModel.publicIP)`. Then re-run the suite.

- [ ] **Step 5: Commit**

```bash
git add ClashMax/Stores/PublicIPCoordinator.swift ClashMax/Views/Dashboard/PublicIPInfoCard.swift ClashMax/App/ClashMaxApp.swift
git commit -m "refactor: migrate PublicIPCoordinator to @Observable"
```

### Task 4: `TunnelHelperClient` → `@Observable`

**Files:**
- Modify: `ClashMax/Services/TunnelHelperClient.swift:253-254`

- [ ] **Step 1: Migrate the class**

At `ClashMax/Services/TunnelHelperClient.swift:252-254`, change:

```swift
@MainActor
final class TunnelHelperClient: ObservableObject {
  @Published var statusMessage: String = "Not registered"
```

to:

```swift
@MainActor
@Observable
final class TunnelHelperClient {
  var statusMessage: String = "Not registered"
```

- [ ] **Step 2: Apply rule R2 to its non-state members**

```bash
grep -nE '^  private (var|let) ' ClashMax/Services/TunnelHelperClient.swift
```

Mark every `Task<...>`, cache dictionary, and generation counter in that output with `@ObservationIgnored`. Leave plain configuration `let`s alone — immutable properties are never mutated, so they never invalidate.

- [ ] **Step 3: Run the suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count, `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add ClashMax/Services/TunnelHelperClient.swift
git commit -m "refactor: migrate TunnelHelperClient to @Observable"
```

### Task 5: `AppUpdateController` → `@Observable`

This one is an `NSObject` subclass driving Sparkle. `@Observable` works on `NSObject` subclasses; the generated observation registrar has a default value so it satisfies Swift's "initialize all stored properties before `super.init()`" rule automatically. The existing KVO (`observe(\.canCheckForUpdates)`) observes the *Sparkle updater*, not `self`, so it is unaffected.

**Files:**
- Modify: `ClashMax/Services/AppUpdateController.swift:5-7`
- Consumer (`@ObservedObject`): `ClashMax/Views/AppUpdateControls.swift:4`

- [ ] **Step 1: Migrate the class**

At `ClashMax/Services/AppUpdateController.swift:4-7`, change:

```swift
@MainActor
final class AppUpdateController: NSObject, ObservableObject {
  @Published private(set) var canCheckForUpdates = false
  @Published private(set) var statusMessage = String(localized: "Checking for updates is not configured for this build.")
```

to:

```swift
@MainActor
@Observable
final class AppUpdateController: NSObject {
  private(set) var canCheckForUpdates = false
  private(set) var statusMessage = String(localized: "Checking for updates is not configured for this build.")
```

- [ ] **Step 2: Annotate the Sparkle members**

At `ClashMax/Services/AppUpdateController.swift:9-10`:

```swift
@ObservationIgnored private let updaterController: SPUStandardUpdaterController?
@ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
```

- [ ] **Step 3: Convert the `@ObservedObject` consumer**

At `ClashMax/Views/AppUpdateControls.swift:4`, change:

```swift
@ObservedObject var updateController: AppUpdateController
```

to:

```swift
let updateController: AppUpdateController
```

- [ ] **Step 4: Fix the two `@EnvironmentObject` reads and the injections**

`AppUpdateController` is read at `ClashMax/Views/MenuBarView.swift:97` and `ClashMax/Views/SettingsView.swift:8`. Change both:

```swift
@Environment(AppUpdateController.self) private var appUpdateController
```

Change the owner at `ClashMax/App/ClashMaxApp.swift:8`:

```swift
@State private var appUpdateController = AppUpdateController()
```

and the three injections at `ClashMax/App/ClashMaxApp.swift:24`, `:122`, `:152` from `.environmentObject(appUpdateController)` to `.environment(appUpdateController)`.

Also `ClashMaxTests/MenuBarPanelLayoutTests.swift:290`, from `.environmentObject(AppUpdateController())` to `.environment(AppUpdateController())`.

- [ ] **Step 5: Run the suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count, `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add ClashMax/Services/AppUpdateController.swift ClashMax/Views/AppUpdateControls.swift ClashMax/Views/MenuBarView.swift ClashMax/Views/SettingsView.swift ClashMax/App/ClashMaxApp.swift ClashMaxTests/MenuBarPanelLayoutTests.swift
git commit -m "refactor: migrate AppUpdateController to @Observable"
```

### Task 6: Extract `ObservationChangeCounter` into a shared test helper

`ProxySearchCoordinator`'s tests (Task 7) need this helper, but it is `private` inside `DashboardRuntimeStateTests.swift`. Extract before it is needed.

Its re-arm is synchronous inside `onChange` **on purpose**: `withObservationTracking`'s `onChange` is one-shot, and an async re-arm drops mutations that land between the callback and the re-arm — which would undercount and mask an issue-#11 regression. Do not "improve" this into a `Task { }`.

**Files:**
- Create: `ClashMaxTests/Support/ObservationChangeCounter.swift`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift:12750-12767` (delete the private copy)

- [ ] **Step 1: Create the shared helper**

Create `ClashMaxTests/Support/ObservationChangeCounter.swift`:

```swift
import Foundation

/// Counts Observation invalidations for a specific property access.
///
/// `withObservationTracking`'s `onChange` fires once and then stops, so this re-arms itself
/// *synchronously* inside the callback. An async re-arm (`Task { arm() }`) would miss mutations
/// that land between the callback and the re-arm, undercounting publishes and hiding coalescing
/// regressions (issue #11). Keep the re-arm synchronous.
///
/// Usage:
/// ```swift
/// let counter = ObservationChangeCounter { _ = model.overrides }
/// model.setMode(model.overrides.mode)
/// XCTAssertEqual(counter.count, 0)
/// ```
@MainActor
final class ObservationChangeCounter {
  private(set) var count = 0
  private let access: () -> Void

  init(_ access: @escaping () -> Void) {
    self.access = access
    arm()
  }

  private func arm() {
    withObservationTracking(access) { [self] in
      MainActor.assumeIsolated {
        count += 1
        arm()
      }
    }
  }
}
```

The `sources: - path: ClashMaxTests` entry in `project.yml:297-298` is a directory glob, so the new `Support/` subdirectory is picked up with no project file change.

- [ ] **Step 2: Delete the private copy**

Delete lines 12750-12767 of `ClashMaxTests/DashboardRuntimeStateTests.swift` — the whole `private final class ObservationChangeCounter { … }` declaration.

- [ ] **Step 3: Regenerate the project and run the suite**

```bash
xcodegen generate && xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count, `** TEST SUCCEEDED **`. The existing `RuntimeDataStoreTests` and `DashboardRuntimeStateTests` call sites now resolve to the shared type.

- [ ] **Step 4: Commit**

```bash
git add ClashMaxTests/Support/ObservationChangeCounter.swift ClashMaxTests/DashboardRuntimeStateTests.swift ClashMax.xcodeproj/project.pbxproj
git commit -m "test: extract ObservationChangeCounter into a shared helper

ProfileStoreTests and ProxySearchPipelineTests need it in the migration;
it was private to DashboardRuntimeStateTests."
```

### Task 7: `ProxySearchCoordinator` → `@Observable` (+ its 3 emission tests)

This type guards the issue #10/#11 perf work. The `if snapshot != self.snapshot` dedup guard at `ProxySearchCoordinator.swift:99` is **load-bearing under Observation** — Observation fires on every setter call, not on inequality, so removing the guard reintroduces the redundant-republish that issue #11 fixed. Leave it exactly as it is.

**Files:**
- Modify: `ClashMax/Views/ProxySearchCoordinator.swift:13`, `:25`, `:27`
- Modify: `ClashMaxTests/ProxySearchPipelineTests.swift:280`, `:308`, `:350`
- Modify: `ClashMax/Views/ProxiesView.swift:8`, `ClashMax/Views/Dashboard/RunningDashboardView.swift:7` (`@ObservedObject` consumers — the coordinators are owned by `AppModel`, not these views)

- [ ] **Step 1: Rewrite the three emission tests against Observation first**

These tests currently assert on the Combine publisher. Rewrite them before touching the class so they fail for the right reason.

At `ClashMaxTests/ProxySearchPipelineTests.swift:280`, replace:

```swift
let cancellable = coordinator.$snapshot.dropFirst().sink { _ in snapshotEmissions += 1 }
```

with:

```swift
let counter = ObservationChangeCounter { _ = coordinator.snapshot }
```

and replace the later `XCTAssertEqual(snapshotEmissions, 1, ...)` assertion with `XCTAssertEqual(counter.count, 1, ...)`. Delete the matching `cancellable.cancel()` / `defer` line. Apply the same three-line change at `:308` and `:350`, keeping each test's own expected count and message.

`ObservationChangeCounter` needs no `.dropFirst()`: it arms on the current value and counts only subsequent invalidations, which is what `.dropFirst()` was emulating.

- [ ] **Step 2: Run the three tests to verify they fail**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' -only-testing:ClashMaxTests/ProxySearchPipelineTests 2>&1 | tail -30
```

Expected: FAIL. The counter reads `coordinator.snapshot`, which is still `@Published` and therefore not Observation-tracked, so `counter.count` stays 0 while the tests expect 1.

- [ ] **Step 3: Migrate the class**

At `ClashMax/Views/ProxySearchCoordinator.swift:12-13`, change:

```swift
@MainActor
final class ProxySearchCoordinator: ObservableObject {
```

to:

```swift
@MainActor
@Observable
final class ProxySearchCoordinator {
```

At `:25` and `:27` drop the attributes:

```swift
private(set) var snapshot: ProxySearchSnapshot = .empty
/// True while a request is scheduled or computing and has not yet published.
private(set) var isComputing: Bool = false
```

Apply rule R2 to the internals at `:38-44` — none of these should invalidate a view:

```swift
@ObservationIgnored private let run: @Sendable (ProxySearchPipeline.Input) -> ProxySearchSnapshot
@ObservationIgnored private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ProxySearch")
@ObservationIgnored private let signposter: OSSignposter
@ObservationIgnored private var gate = ProxySearchGenerationGate()
@ObservationIgnored private var pending: [Int: Task<Void, Never>] = [:]
```

`staleResultsDropped` at `:30` is `private(set)` and read only by tests, never by a view body — leave it observable, it costs nothing.

Delete `import Combine` at `:1`.

- [ ] **Step 4: Convert the two consumers to plain lets**

**Do not reintroduce per-view ownership.** Uncommitted work in the tree moved both coordinators onto `AppModel` (`let proxiesSearchCoordinator` / `let dashboardCurrentNodeCoordinator`, `AppModel.swift:808-809`) precisely because view-owned `@StateObject` instances were torn down on every tab switch, so returning to the page repainted from an empty snapshot. The views now receive the coordinator through an `init` and hold it as `@ObservedObject`. Converting these back to `@State` would revert that fix.

`ClashMax/Views/ProxiesView.swift:8`:

```swift
let searchCoordinator: ProxySearchCoordinator
```

`ClashMax/Views/Dashboard/RunningDashboardView.swift:7`:

```swift
let currentNodeCoordinator: ProxySearchCoordinator
```

Leave both `init`s and the `ContentView.swift:91` / dashboard call sites exactly as they are. Observation tracks reads through a plain reference, so no property wrapper is needed.

`AppModel` holds both as `let`, so once it becomes `@Observable` in Stage 2, nested tracking covers any view that reaches a coordinator *through* the model. The views here hold it directly, which already works as soon as `ProxySearchCoordinator` is `@Observable`.

- [ ] **Step 5: Run the tests to verify they pass**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' -only-testing:ClashMaxTests/ProxySearchPipelineTests 2>&1 | tail -30
```

Expected: PASS. In particular the `identical snapshot must not emit a redundant objectWillChange` case must still pass — that is the issue #11 contract, now expressed against Observation.

- [ ] **Step 6: Run the full suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count, `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add ClashMax/Views/ProxySearchCoordinator.swift ClashMax/Views/ProxiesView.swift ClashMax/Views/Dashboard/RunningDashboardView.swift ClashMaxTests/ProxySearchPipelineTests.swift
git commit -m "refactor: migrate ProxySearchCoordinator to @Observable

The 'if snapshot != self.snapshot' dedup guard stays load-bearing:
Observation fires on every setter call, not on inequality. The three
emission tests now assert via ObservationChangeCounter."
```

---

# Stage 2: The atomic cluster

Everything from here to Task 13 lands in **one commit**. Partial application leaves the app compiling but silently not updating. Do not run `git commit` until Task 13.

The build will be broken between Task 8 and Task 13. That is expected — do not try to fix intermediate compile errors by reverting; work forward through the tasks.

### Task 8: Migrate the seven simple sub-stores

**Files:**
- Modify: `ClashMax/Stores/ProfileStore.swift:230`, `:236-238`
- Modify: `ClashMax/Stores/ProfileOperationsStore.swift:5-8`
- Modify: `ClashMax/Stores/ProviderAnalyticsStore.swift:4`, `:15`
- Modify: `ClashMax/Stores/RuntimeSnippetLibraryStore.swift:42-44`
- Modify: `ClashMax/Stores/SystemProxyCoordinator.swift:4-5`
- Modify: `ClashMax/Stores/ProxyPreviewStore.swift:4-7`
- Modify: `ClashMax/Stores/PersistedSettingsStore.swift:5` and its 20 `@Published` lines

- [ ] **Step 1: `ProfileStore`**

`ClashMax/Stores/ProfileStore.swift:229-238`:

```swift
@MainActor
@Observable
final class ProfileStore {
  // (existing members between the declaration and these properties stay unchanged)
  private(set) var profiles: [Profile] = []
  private(set) var activeProfileID: Profile.ID?
  private(set) var subscriptionURLCache: [Profile.ID: String] = [:]
```

Mark `manifestLoadTask` (assigned at `:255`) `@ObservationIgnored`.

- [ ] **Step 2: `ProfileCoordinator`**

`ClashMax/Stores/ProfileOperationsStore.swift:4-8`:

```swift
@MainActor
@Observable
final class ProfileCoordinator {
  private(set) var isAddingSubscription = false
  private(set) var updatingProfileIDs: Set<Profile.ID> = []
  private(set) var message: String?
```

Mark the `hooks` struct and any `Task` handles `@ObservationIgnored`.

- [ ] **Step 3: `ProviderAnalyticsStore`**

`ClashMax/Stores/ProviderAnalyticsStore.swift:3-15`:

```swift
@MainActor
@Observable
final class ProviderAnalyticsStore {
  // (existing members between the declaration and these properties stay unchanged)
  private(set) var records: [ProviderAnalyticsRecord] = []
```

- [ ] **Step 4: `RuntimeSnippetLibraryStore`**

`ClashMax/Stores/RuntimeSnippetLibraryStore.swift:41-44`:

```swift
@MainActor
@Observable
final class RuntimeSnippetLibraryStore {
  private(set) var snippets: [RuntimeSnippet] = []
  private(set) var loadError: String?
```

- [ ] **Step 5: `SystemProxyCoordinator`**

`ClashMax/Stores/SystemProxyCoordinator.swift:3-5`:

```swift
@MainActor
@Observable
final class SystemProxyCoordinator {
  var enabled = false
```

Mark `guardTask` (assigned at `:127`) `@ObservationIgnored`.

- [ ] **Step 6: `ProxyPreviewStore`**

`ClashMax/Stores/ProxyPreviewStore.swift:3-14`:

```swift
@MainActor
@Observable
final class ProxyPreviewStore {
  var profilePreviewGroups: [ProxyGroup] = []
  var previewRuntimeActive = false
  var previewSelections: [String: String] = [:]

  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let previewMaterializer: ProfilePreviewMaterializer
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var refreshGeneration = 0
```

`refreshGeneration` in particular must be ignored — it increments on every refresh.

- [ ] **Step 7: `PersistedSettingsStore`**

`ClashMax/Stores/PersistedSettingsStore.swift:4-5`:

```swift
@MainActor
@Observable
final class PersistedSettingsStore {
```

Then delete the `@Published` attribute from all 20 properties, leaving each `didSet` body untouched. For example `:6-10` becomes:

```swift
var overrides: RuntimeOverrides {
    didSet {
      saveRuntimeSettings(overrides)
    }
}
```

Mark `defaults` and `loginItemService` (`:100-101`) `@ObservationIgnored`.

Preserve the `guard refreshed != launchSettings else { return }` in `refreshLaunchSettings` — `applicationDidBecomeActive` calls it repeatedly and without the guard every activation would invalidate every view reading `launchSettings`.

- [ ] **Step 8: Verify no `@Published` remains in these seven files**

```bash
grep -rn "@Published\|ObservableObject" ClashMax/Stores/ProfileStore.swift ClashMax/Stores/ProfileOperationsStore.swift ClashMax/Stores/ProviderAnalyticsStore.swift ClashMax/Stores/RuntimeSnippetLibraryStore.swift ClashMax/Stores/SystemProxyCoordinator.swift ClashMax/Stores/ProxyPreviewStore.swift ClashMax/Stores/PersistedSettingsStore.swift
```

Expected: no output.

Do not build yet — `AppModel` still relays from these types and will not compile until Task 11.

### Task 9: Migrate `CoreProcessController` and `NetworkExtensionController`

**Files:**
- Modify: `ClashMax/Services/CoreProcessController.swift:83-86`
- Modify: `ClashMax/Services/NetworkExtensionController.swift:334-341`

- [ ] **Step 1: `CoreProcessController`**

`ClashMax/Services/CoreProcessController.swift:82-86`:

```swift
@MainActor
@Observable
final class CoreProcessController {
  private(set) var status: CoreStatus = .stopped
  private(set) var recentCoreLog: String = ""
  private(set) var startupDiagnostics: [String] = []
```

`recentCoreLog` and `startupDiagnostics` accumulate core output. If either is appended to on a per-log-line basis, check whether a view reads it; the `RuntimeDataStore` log buffer precedent is that a hot append path reaching a view body must be coalesced or ignored. Run:

```bash
grep -rn "recentCoreLog\|startupDiagnostics" ClashMax/Views/
```

If a view reads it and the write path is per-line, note it for the Task 12 audit rather than fixing it here.

Apply rule R2 to `CoreProcessController`'s `Task` handles and process-management members:

```bash
grep -nE '^  private var .*(Task|Timer|Continuation|\[)' ClashMax/Services/CoreProcessController.swift
```

Mark each hit `@ObservationIgnored`.

- [ ] **Step 2: `NetworkExtensionController`**

`ClashMax/Services/NetworkExtensionController.swift:333-341`:

```swift
@MainActor
@Observable
final class NetworkExtensionController {
  // (existing members between the declaration and these properties stay unchanged)
  private(set) var systemExtensionState: NetworkExtensionInstallState = .notInstalled
  private(set) var vpnStatus: NetworkExtensionTunnelStatus = .disconnected
  private(set) var recentError: String?
  private(set) var diagnostics: NetworkExtensionDiagnosticsSnapshot = .empty
```

Mark its status-observation token and `Task` handles `@ObservationIgnored`:

```bash
grep -nE '^  private var .*(Task|Observation|Continuation)' ClashMax/Services/NetworkExtensionController.swift
```

- [ ] **Step 3: Verify**

```bash
grep -rn "@Published\|ObservableObject" ClashMax/Services/CoreProcessController.swift ClashMax/Services/NetworkExtensionController.swift
```

Expected: no output. Still do not build.

### Task 10: Add the five `didSet` callback hooks

This replaces the five behavioral Combine pipelines. Each hook is `@ObservationIgnored` (rule R2) — a stored closure is not view state.

**Files:**
- Modify: `ClashMax/Stores/PersistedSettingsStore.swift` (2 hooks)
- Modify: `ClashMax/Stores/ProxyPreviewStore.swift` (1 hook)
- Modify: `ClashMax/Stores/ProfileStore.swift` (1 hook)
- Modify: `ClashMax/Services/CoreProcessController.swift` (1 hook)

- [ ] **Step 1: `PersistedSettingsStore` — two hooks**

Add near the other stored members (after `loginItemService` at `:101`):

```swift
/// Fired after `subscriptionFetchSettings` changes. Assigned by `AppModel.setupBindings`.
/// Unlike the `@Published` publisher this replaces, this runs *after* the property is
/// updated, so a handler that re-reads the store observes the new value.
@ObservationIgnored var onSubscriptionFetchSettingsChange: (() -> Void)?
/// Fired after `globalShortcutSettings` changes. Assigned by `AppModel.setupBindings`.
@ObservationIgnored var onGlobalShortcutSettingsChange: ((GlobalShortcutSettings) -> Void)?
```

Extend the two existing `didSet` bodies. `:50-54` becomes:

```swift
var subscriptionFetchSettings = SubscriptionFetchSettings.default {
    didSet {
      saveCodable(subscriptionFetchSettings, forKey: Self.subscriptionFetchSettingsDefaultsKey)
      onSubscriptionFetchSettingsChange?()
    }
}
```

`:65-69` becomes:

```swift
var globalShortcutSettings = GlobalShortcutSettings.default {
    didSet {
      saveCodable(globalShortcutSettings, forKey: Self.globalShortcutSettingsDefaultsKey)
      onGlobalShortcutSettingsChange?(globalShortcutSettings)
    }
}
```

Both hooks are `nil` while the store loads persisted values in `init` (`:179`, `:194`) because `AppModel` assigns them later in `setupBindings` — matching today's behavior, where no subscriber existed yet.

- [ ] **Step 2: `ProxyPreviewStore` — add a `didSet` and a hook**

`profilePreviewGroups` currently has no `didSet`. Add one:

```swift
/// Fired after `profilePreviewGroups` changes. Assigned by `AppModel.setupBindings`.
@ObservationIgnored var onProfilePreviewGroupsChange: (([ProxyGroup]) -> Void)?

var profilePreviewGroups: [ProxyGroup] = [] {
    didSet {
      onProfilePreviewGroupsChange?(profilePreviewGroups)
    }
}
```

- [ ] **Step 3: `ProfileStore` — add a `didSet` and a hook**

```swift
/// Fired after `profiles` changes. Assigned by `AppModel.setupBindings`.
@ObservationIgnored var onProfilesChange: (([Profile]) -> Void)?

private(set) var profiles: [Profile] = [] {
    didSet {
      onProfilesChange?(profiles)
    }
}
```

- [ ] **Step 4: `CoreProcessController` — add a `didSet` and a hook**

`status` is assigned at twelve sites (`:121`, `:167`, `:175`, `:197`, `:212`, `:217`, `:228`, `:230`, `:238`, `:251`, `:301`, `:572`). Add the hook to the declaration rather than editing twelve call sites:

```swift
/// Fired after `status` changes. Assigned by `AppModel.setupBindings`.
@ObservationIgnored var onStatusChange: ((CoreStatus) -> Void)?

private(set) var status: CoreStatus = .stopped {
    didSet {
      onStatusChange?(status)
    }
}
```

- [ ] **Step 5: Verify all five hooks exist**

```bash
grep -rn "onSubscriptionFetchSettingsChange\|onGlobalShortcutSettingsChange\|onProfilePreviewGroupsChange\|onProfilesChange\|onStatusChange" ClashMax/Stores ClashMax/Services
```

Expected: 10 lines — one declaration and one `didSet` invocation per hook.

### Task 11: Migrate `AppModel` and rewire `setupBindings`

**Files:**
- Modify: `ClashMax/Stores/AppModel.swift:543` (declaration), the 35 `@Published` lines, `:853` (`storeCancellables`), `:998-1057` (the bindings block)

- [ ] **Step 1: Migrate the declaration and the 35 properties**

`ClashMax/Stores/AppModel.swift:542-544`:

```swift
@MainActor
@Observable
final class AppModel {
  var selectedSection: AppSection = .home
```

Delete the `@Published` attribute from all 35 properties (`:544` through `:735`), preserving `private(set)`, `private`, and the `didSet` on `lastError` at `:698-707`.

- [ ] **Step 2: Delete the nine relay sinks**

Delete these blocks entirely from `ClashMax/Stores/AppModel.swift:998-1057` — nested `@Observable` tracking replaces every one of them:

- `settings.objectWillChange` (`:998-1000`)
- `profileCoordinator.objectWillChange` (`:1012-1014`)
- `proxyPreview.objectWillChange` (`:1015-1017`)
- `profileStore.objectWillChange` (`:1023-1025`)
- `providerAnalyticsStore.objectWillChange` (`:1038-1040`)
- `runtimeSnippetLibrary.objectWillChange` (`:1041-1043`)
- `systemProxy.objectWillChange` (`:1044-1046`)
- `coreController.objectWillChange` (`:1047-1049`)
- `networkExtensionController.objectWillChange` (`:1055-1057`)

- [ ] **Step 3: Replace the five behavioral pipelines with hook assignments**

Replace the five `.sink` blocks with this. Note the three priming calls at the end — `@Published` publishers emit on subscribe, so `installGlobalShortcuts`, `schedulePreviewRuntimeStartIfReady`, and `handleCoreStatusChange` each ran once at setup today, and `didSet` does not fire during init:

```swift
    // The five hooks below replace Combine pipelines. `didSet` fires *after* the property is
    // updated, unlike @Published which published from `willSet` — see the priming calls and the
    // subscriptionFetchSettings note below.
    settings.onSubscriptionFetchSettingsChange = { [weak self] in
      self?.profileCoordinator.rescheduleSubscriptionAutoUpdates()
    }
    settings.onGlobalShortcutSettingsChange = { [weak self] settings in
      self?.installGlobalShortcuts(settings)
    }
    proxyPreview.onProfilePreviewGroupsChange = { [weak self] groups in
      self?.schedulePreviewRuntimeStartIfReady(profilePreviewGroups: groups)
    }
    self.profileStore.onProfilesChange = { [weak self] profiles in
      Task { [weak self] in
        await self?.pruneRuntimeSnippetProfileBindings(validProfileIDs: Set(profiles.map(\.id)))
        await MainActor.run {
          self?.providerAnalytics.prune(validProfileIDs: Set(profiles.map(\.id)))
        }
      }
    }
    coreController.onStatusChange = { [weak self] status in
      self?.handleCoreStatusChange(status)
    }

    // @Published publishers emitted their current value on subscribe, so these three handlers each
    // ran once during setup. `didSet` does not fire during init, so prime them explicitly.
    // Only the first has an observable effect at init — it registers shortcuts restored from
    // defaults, and dropping it means a user's configured shortcuts are dead until they edit one
    // (pinned by testGlobalShortcutsAreRegisteredFromPersistedSettingsAtLaunch). The other two are
    // no-ops here (status is .stopped, preview groups are empty) and are kept for symmetry so the
    // set of primed handlers matches the set that was primed by subscription.
    // `onSubscriptionFetchSettingsChange` and `onProfilesChange` replaced `.dropFirst()` pipelines
    // and must NOT be primed.
    installGlobalShortcuts(settings.globalShortcutSettings)
    schedulePreviewRuntimeStartIfReady(profilePreviewGroups: proxyPreview.profilePreviewGroups)
    handleCoreStatusChange(coreController.status)
```

`rescheduleSubscriptionAutoUpdates()` takes no parameter and re-reads `settings.subscriptionFetchSettings` through the hook at `AppModel.swift:960`. Under `@Published`/`willSet` it read the **pre-change** value; under `didSet` it reads the new one. That is a deliberate bug fix, pinned by a test in Task 15.

- [ ] **Step 4: Remove the Combine plumbing**

Delete `private var storeCancellables: Set<AnyCancellable> = []` at `:853`, then:

```bash
grep -n "AnyCancellable\|storeCancellables\|\.sink\|\.store(in:" ClashMax/Stores/AppModel.swift
```

If that returns nothing, delete `import Combine` at `:2`. If it returns hits, they are pipelines this plan did not account for — stop and read them before deleting anything.

- [ ] **Step 5: Apply rule R2 to `AppModel`'s Task handles**

```bash
grep -nE '^  private var .*Task<' ClashMax/Stores/AppModel.swift
```

Mark every hit `@ObservationIgnored` (`startTask`, `lifecycleStopTask`, `previewTask`, `stopTask`, `pendingModeTask`, `pendingRoutingModeTask`, `tunHelperPreparationTask`, `modeUpdateTask`, `runtimeReloadTask`, `outboundProxyEndpointLoadTask`, and the rest of that output).

Also mark the delay-state cache and any batch coalescing buffers `@ObservationIgnored` — they are mutated per node during a 1600-node batch test and must not invalidate views:

```bash
grep -nE '^  private var .*(delayStateCache|Buffer|pending|Generation)' ClashMax/Stores/AppModel.swift
```

- [ ] **Step 6: Verify no `ObservableObject` remains anywhere**

```bash
grep -rn "ObservableObject\|@Published" ClashMax/
```

Expected: only the comment at `ClashMax/App/ClashMaxApp.swift:171-172` (removed in Task 14) and any doc comments mentioning `@Published` historically (`ClashMax/Views/ProxySearchPipeline.swift:80`, `AppModel.swift:868`, `:7131`, `:7208`). Reword those comments to say "observable state" instead of `@Published`. No live declarations.

### Task 12: Audit private properties reachable from view-visible computed properties

This is rule R3, and it is the step that catches silent perf regressions. Do it before the first build — a compile success proves nothing here.

**Files:** `ClashMax/Stores/AppModel.swift` and the nine cluster types

- [ ] **Step 1: List the view-visible computed properties on `AppModel`**

```bash
grep -nE '^  (private\(set\) )?var [a-zA-Z]+: .*\{$' ClashMax/Stores/AppModel.swift | grep -v "private var"
```

- [ ] **Step 2: For each, check which private stored properties it reads**

The known instance is `canRepairTunRouting` (`:631-638`), which reads `private var tunHelperStopUnconfirmed` (`:789`). Others in the same family are `canRepairTunDNS` (`:625`) and `canRepairNetworkExtensionDNS` (`:620`).

- [ ] **Step 3: Classify each hit**

For every private stored property reached from a view-visible computed property:

- **Low-frequency state whose change should update the UI** (`tunHelperStopUnconfirmed`, `lifecycleStopInFlight`, `tunLaunchInFlight`) → leave observable. It flips a handful of times per runtime transition, and the newly-correct invalidation is the point: today the repair button's enabled state can go stale.
- **Hot-path state** (per-node delay results, per-line log appends, generation counters, caches) → `@ObservationIgnored`.

- [ ] **Step 4: Write down the classification**

Record each decision in the Task 13 commit message. A future reader needs to know these were chosen, not missed.

### Task 13: Build, verify, and commit the cluster

- [ ] **Step 1: Build**

```bash
xcodebuild build -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "error:|warning: .*Observable|BUILD" | head -40
```

Expected: `** BUILD SUCCEEDED **`.

Stage 3 has not run yet, so the 57 `@EnvironmentObject` declarations still reference now-non-`ObservableObject` types. **Expect this build to fail with "does not conform to 'ObservableObject'" errors** — that is the signal to proceed to Stage 3, not a defect. If it fails with anything else, fix that first.

- [ ] **Step 2: Do not commit yet**

The cluster is not verifiable until the views compile. Continue to Task 14, then return here.

- [ ] **Step 3: After Stage 3 completes, run the full suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count minus nothing; the nine test rewrites happen in Stage 4 and those tests still pass in their current form only if they were already converted. If `testSettingCurrentModeDoesNotPublishChanges` and the three sibling tests fail to **compile** (`value of type 'AppModel' has no member 'objectWillChange'`), that is expected — jump to Stage 4, then return.

- [ ] **Step 4: Commit the cluster together with Stage 3**

See Task 17.

---

# Stage 3: View call sites

### Task 14: Convert `ClashMaxApp.swift`

**Files:**
- Modify: `ClashMax/App/ClashMaxApp.swift`

- [ ] **Step 1: Convert the two owners**

`:7-8`:

```swift
@State private var appModel = AppModel.bootstrap()
@State private var appUpdateController = AppUpdateController()
```

(`appUpdateController` was already converted in Task 5; confirm rather than duplicate.)

An `App` struct is instantiated once, so the `AppModel.bootstrap()` expression is not re-evaluated per render.

- [ ] **Step 2: Convert all `.environmentObject(...)` to `.environment(...)`**

There are 33 call sites across the app and tests. Apply mechanically:

```bash
grep -rl "\.environmentObject(" ClashMax ClashMaxTests --include="*.swift" | xargs sed -i '' 's/\.environmentObject(/.environment(/g'
```

Then confirm none remain:

```bash
grep -rn "\.environmentObject(" ClashMax ClashMaxTests --include="*.swift"
```

Expected: no output.

- [ ] **Step 3: Convert the `@ObservedObject` on `MenuBarStatusLabel`**

`ClashMax/App/ClashMaxApp.swift:168`:

```swift
let appModel: AppModel
```

Delete the now-wrong comment at `:171-172` ("ObservableObject migration is out of scope for this change") and replace it with a one-line note that Observation tracks reads off a plain reference, so no property wrapper is needed.

### Task 15: Convert the 57 `@EnvironmentObject` declarations

**Files:** the 17 view files listed by the grep below

- [ ] **Step 1: Apply the mechanical conversion**

`@EnvironmentObject private var x: T` becomes `@Environment(T.self) private var x`. Run:

```bash
grep -rl "@EnvironmentObject" ClashMax --include="*.swift" | xargs sed -i '' -E 's/@EnvironmentObject (private )?var ([a-zA-Z]+): ([A-Za-z]+)/@Environment(\3.self) \1var \2/g'
```

Then verify none remain and spot-check the result:

```bash
grep -rn "@EnvironmentObject" ClashMax --include="*.swift"
grep -rn "@Environment(" ClashMax --include="*.swift" | head -20
```

Expected: first command silent; second shows declarations like `@Environment(AppModel.self) private var appModel`.

- [ ] **Step 2: Add `@Bindable` where bindings are taken**

`@Environment` does not vend bindings. Two places take them.

`ClashMax/Views/ContentView.swift:8` uses `$appModel.selectedSection`. At the top of that view's `body`, add:

```swift
@Bindable var appModel = appModel
```

`ClashMax/Views/SettingsView.swift` takes ~20 bindings off `settings` (`$settings.appTheme` at `:41`, `$settings.subscriptionFetchSettings` at `:259`/`:264`/`:269`/`:274`/`:321`, `$settings.delayTestSettings` at `:188`/`:200`, `$settings.ruleOverlaySettings` at `:333`, `$settings.networkPolicySettings` at `:364`, `$settings.globalShortcutSettings` at `:136`). At the top of `SettingsView.body`, add:

```swift
@Bindable var settings = settings
```

Do **not** touch `$settings.dns`, `$settings.stack`, `$settings.mtu` and friends in `DashboardComponents.swift` — those are `@Binding var settings: TunSettings` / `SystemProxySettings` / `NetworkExtensionRoutingSettings` locals (declared at `DashboardComponents.swift:199`, `:378`, `:432`), not the store. Same for `$settings.*` inside `SettingsView` subviews declaring `@Binding var settings:` at `:902`, `:937`, `:1023`, `:1312`, `:1320`.

- [ ] **Step 3: Build**

```bash
xcodebuild build -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" | head -40
```

Expected: `** BUILD SUCCEEDED **`. Any remaining error naming a specific view is a missed `@Bindable` — fix it where reported.

### Task 16: Fix the test-target injections

**Files:**
- Modify: `ClashMaxTests/MenuBarPanelLayoutTests.swift:288`, `:290`

- [ ] **Step 1: Confirm the sed from Task 14 caught them**

```bash
grep -n "environment" ClashMaxTests/MenuBarPanelLayoutTests.swift
```

Expected: `.environment(model)` and `.environment(AppUpdateController())`.

- [ ] **Step 2: Build the test target**

```bash
xcodebuild build-for-testing -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD" | head -40
```

Expected: `** BUILD SUCCEEDED **`, or compile errors only in the four `objectWillChange` tests handled in Stage 4.

### Task 17: Commit Stages 2 and 3 together

- [ ] **Step 1: Confirm the whole cluster migrated**

```bash
grep -rn "ObservableObject\|@Published\|@EnvironmentObject\|@StateObject\|@ObservedObject\|\.environmentObject(" ClashMax --include="*.swift"
```

Expected: no output. Any hit is a missed site that will silently stop updating.

- [ ] **Step 2: Commit**

```bash
git add ClashMax/
git commit -m "refactor: migrate AppModel cluster and views to @Observable

AppModel plus the 9 types it relayed objectWillChange from migrate
atomically: a partial migration silently drops invalidation for
AppModel's ~20 computed facades over `settings` with no compile error.

- deletes the 9 objectWillChange relay sinks; nested @Observable
  tracking replaces them
- replaces the 5 behavioural Combine pipelines with didSet callbacks,
  priming the 3 that @Published emitted on subscribe
- fixes rescheduleSubscriptionAutoUpdates, which read the pre-change
  subscription settings under @Published/willSet
- removes Combine from AppModel entirely
- 57 @EnvironmentObject -> @Environment, 33 .environmentObject ->
  .environment, @Bindable in ContentView and SettingsView

R3 audit (private state now reachable from view-visible computed
properties): tunHelperStopUnconfirmed, lifecycleStopInFlight and
tunLaunchInFlight are left observable on purpose — they flip a few times
per runtime transition and the repair buttons' enabled state was
previously able to go stale. Hot-path state is @ObservationIgnored."
```

---

# Stage 4: Test contracts

Observation has no "did this object publish at all" signal, so each `objectWillChange` assertion becomes a per-property assertion. This narrows every one of them — they no longer catch incidental churn on an unrelated property. That is the accepted trade recorded in the spec.

### Task 18: Rewrite the four `AppModel` publish tests

**Files:**
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift:9545-9645`

- [ ] **Step 1: `testSettingCurrentModeDoesNotPublishChanges`**

Replace:

```swift
    var changeCount = 0
    let cancellable = model.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    model.setMode(model.overrides.mode)

    XCTAssertEqual(changeCount, 0)
```

with:

```swift
    let counter = ObservationChangeCounter { _ = model.overrides }

    model.setMode(model.overrides.mode)

    XCTAssertEqual(counter.count, 0, "setting the current mode to its existing value must not invalidate `overrides`")
```

- [ ] **Step 2: `testRequestingModeDefersPublishedChangesUntilNextActorTurn`**

Replace the same three-line counter setup with:

```swift
    let counter = ObservationChangeCounter { _ = model.overrides }
```

and both assertions with `XCTAssertEqual(counter.count, 0)` and `XCTAssertGreaterThan(counter.count, 0)` in their existing positions. Leave the `for _ in 0..<20 where model.overrides.mode != .global { await Task.yield() }` loop untouched — it is what makes the test deterministic.

- [ ] **Step 3: `testRequestingProxyRoutingModeDefersPublishedChangesUntilNextActorTurn`**

Same shape, tracking the routing mode:

```swift
    let counter = ObservationChangeCounter { _ = model.proxyRoutingMode }
```

with `XCTAssertEqual(counter.count, 0)` before the yield loop and `XCTAssertGreaterThan(counter.count, 0)` after.

- [ ] **Step 4: `testCoreControllerStatusChangesPublishAppModelChanges`**

This one asserts that a change inside `CoreProcessController` reaches `AppModel` — exactly the nested-tracking behavior that replaced the relay, so it is the most valuable test in this group. Track the derived summary:

```swift
    let counter = ObservationChangeCounter { _ = model.statusSummary }
```

Replace `changeCount = 0` after the successful start with nothing (the counter cannot be reset; instead capture a floor):

```swift
    let baseline = counter.count

    launcher.process.finish(exitCode: 2)

    for _ in 0..<20 where counter.count == baseline {
      await Task.yield()
    }

    XCTAssertEqual(model.statusSummary, "Crashed: mihomo exited with code 2")
    XCTAssertGreaterThan(counter.count, baseline)
```

- [ ] **Step 5: Run the four tests**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' -only-testing:ClashMaxTests/DashboardRuntimeStateTests 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: PASS.

### Task 19: Rewrite the remaining publisher tests

**Files:**
- Modify: `ClashMaxTests/ProfileStoreTests.swift:145-156`
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift:6009`

- [ ] **Step 1: `testSelectingAlreadyActiveProfileDoesNotPublishChanges`**

At `ClashMaxTests/ProfileStoreTests.swift:149-155`, replace:

```swift
    var changeCount = 0
    let cancellable = store.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    try await store.select(profile)

    XCTAssertEqual(changeCount, 0)
```

with:

```swift
    let counter = ObservationChangeCounter {
      _ = store.activeProfileID
      _ = store.profiles
    }

    try await store.select(profile)

    XCTAssertEqual(counter.count, 0, "re-selecting the already-active profile must not invalidate activeProfileID or profiles")
```

Reading both properties inside the access block tracks both, so the test keeps its original breadth.

- [ ] **Step 2: The `proxyDelayBatchProgress` counter**

At `ClashMaxTests/DashboardRuntimeStateTests.swift:6009`, replace the `model.$proxyDelayBatchProgress` Combine subscription with:

```swift
    let progressCounter = ObservationChangeCounter { _ = model.proxyDelayBatchProgress }
```

and update that test's assertions to read `progressCounter.count`. Keep the expected counts exactly as they are — they encode the issue #11 coalescing contract, and changing them to make the test pass would silently revert that work.

- [ ] **Step 3: Confirm Combine is gone from the test target**

```bash
grep -rn "objectWillChange\|import Combine\|AnyCancellable" ClashMaxTests/
```

Expected: only comments/doc text referring to the old mechanism. Reword any that read as current fact. Delete `import Combine` from files with no remaining Combine use.

### Task 20: Add the `willSet` → `didSet` regression test

The priming behavior is already pinned by the characterization test from Task 0, so only one new test is needed here.

**Files:**
- Modify: `ClashMaxTests/DashboardRuntimeStateTests.swift` (there is no `PersistedSettingsStoreTests.swift`; the only settings-adjacent file is `GlobalShortcutSettingsTests.swift`, which is about shortcut parsing)

- [ ] **Step 1: Write the test for the `didSet` timing fix**

`rescheduleSubscriptionAutoUpdates` takes no new value; it re-reads the store through `hooks.subscriptionUpdateSettings()` (`ProfileOperationsStore.swift:353`), which is wired to `self?.settings.subscriptionFetchSettings` (`AppModel.swift:973`). Under `@Published`/`willSet` that read returned the **pre-change** settings. The cleanest way to pin the fix is at the store boundary, where the semantics actually live:

```swift
  func testSubscriptionFetchSettingsHookObservesTheNewValue() throws {
    let store = PersistedSettingsStore(defaults: try Self.makeIsolatedDefaults())

    // The real handler takes no parameter and re-reads the store, exactly like
    // ProfileCoordinator.rescheduleSubscriptionAutoUpdates does.
    var observed: SubscriptionFetchSettings?
    store.onSubscriptionFetchSettingsChange = { [weak store] in
      observed = store?.subscriptionFetchSettings
    }

    var updated = store.subscriptionFetchSettings
    updated.automaticUpdatesEnabled = true
    updated.defaultUpdateIntervalMinutes = 90
    store.subscriptionFetchSettings = updated

    // @Published published from willSet, so this read returned the OLD interval and subscription
    // auto-updates were rescheduled against stale settings. didSet fires after the write.
    XCTAssertEqual(observed?.defaultUpdateIntervalMinutes, 90)
    XCTAssertEqual(observed?.automaticUpdatesEnabled, true)
  }
```

`SubscriptionFetchSettings` is defined at `ClashMax/Models/CoreModels.swift:6145`; the interval field is `defaultUpdateIntervalMinutes`, not an hours-based one.

- [ ] **Step 2: Run it**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testSubscriptionFetchSettingsHookObservesTheNewValue 2>&1 | tail -20
```

Expected: PASS. This test cannot be written against the pre-migration code — `onSubscriptionFetchSettingsChange` does not exist there — so unlike Task 0's test it has no un-migrated baseline. Sanity-check it by temporarily moving the hook call from `didSet` to a `willSet`, confirming the assertion fails, then restoring it.

- [ ] **Step 3: Confirm Task 0's characterization test still passes**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' -only-testing:ClashMaxTests/DashboardRuntimeStateTests/testGlobalShortcutsAreRegisteredFromPersistedSettingsAtLaunch 2>&1 | tail -20
```

Expected: PASS. If it fails, `setupBindings` is missing the `installGlobalShortcuts(settings.globalShortcutSettings)` priming call from Task 11 Step 3.

- [ ] **Step 4: Run the full suite**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count plus the new tests, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add ClashMaxTests/
git commit -m "test: move observation contracts off objectWillChange

The four AppModel publish tests, the ProfileStore selection test, the
three ProxySearchCoordinator emission tests and the delay-batch progress
counter now assert per-property via ObservationChangeCounter. Observation
has no 'did this object publish at all' signal, so each assertion is
narrower and names the property it means.

Adds regression cover for the willSet->didSet fix in
rescheduleSubscriptionAutoUpdates. Launch-time priming is covered by the
characterization test added before the migration started."
```

---

# Stage 5: Verification

### Task 21: Manual app run

The suite proves logic, not that the UI redraws. This migration changes the invalidation mechanism for the entire UI, so **the work is not done until the app has been run**. This project has a documented pattern of sessions ending here with the box unticked; do not repeat it.

- [ ] **Step 1: Full suite green**

```bash
xcodebuild test -scheme ClashMax -destination 'platform=macOS' 2>&1 | grep -E "Executed .* tests|TEST SUCCEEDED|TEST FAILED" | tail -5
```

Expected: baseline count plus the new tests, zero failures.

- [ ] **Step 2: Confirm the observation surface is fully migrated**

```bash
grep -rn "ObservableObject\|@Published\|@EnvironmentObject\|@StateObject\|@ObservedObject\|\.environmentObject(" ClashMax ClashMaxTests --include="*.swift"
```

Expected: no output.

```bash
grep -rn "import Combine" ClashMax --include="*.swift"
```

Expected: no output, or only files with a genuine remaining Combine use (which this plan does not create).

- [ ] **Step 3: Launch and exercise every surface**

Use the `run` skill to launch the app. Then confirm live updating on each surface, because each is fed by a different store that was migrated:

| Surface | What must update live | Store behind it |
| --- | --- | --- |
| Dashboard | traffic counters, current node, public IP card | `RuntimeDataStore`, `PublicIPCoordinator` |
| Proxies | search field filtering, delay batch results, group selection | `ProxySearchCoordinator`, `AppModel` |
| Profiles | subscription update spinner, profile list after import | `ProfileStore`, `ProfileCoordinator` |
| Settings | every toggle round-trips and persists (`@Bindable` path) | `PersistedSettingsStore` |
| Routing | rule match simulation results | `RuntimeSnippetLibraryStore` |
| Logs | log lines streaming | `RuntimeDataStore` |
| Connections | connection rows appearing/closing, app icons | `RuntimeDataStore` |
| Menu bar | traffic label, group selection rows | `AppModel`, `RuntimeDataStore` |

A surface that renders but never updates is the exact failure mode this migration risks, and no test in the suite can catch it.

- [ ] **Step 4: Check for runtime traps**

A missing `.environment(...)` injection traps rather than failing to compile. Open every window — main window, Settings scene, and the menu bar panel — since they have separate injection lists (`ClashMaxApp.swift:15-24`, `:113-122`, `:143-152`).

- [ ] **Step 5: Record the result**

Report honestly which surfaces were confirmed by eye and which were not. If a surface could not be exercised (needs a live subscription, a running core, a real VPN profile), say so explicitly rather than implying it passed.

---

## Self-Review

**Spec coverage:**

| Spec section | Tasks |
| --- | --- |
| Mechanism mapping table | 1-5, 7-9, 11, 14-16 |
| Why the cluster is atomic | Stage 2 preamble, Tasks 11, 13, 17 |
| `@ObservationIgnored` rule (R1/R2/R3) | Conventions, Tasks 3, 4, 6, 8-11; audit in Task 12 |
| Five Combine pipelines → callbacks | Task 10 (hooks), Task 11 Step 3 (wiring) |
| Initial emission / priming | Task 0 Step 3 (characterization test), Task 11 Step 3, Task 20 Step 3 |
| `willSet` → `didSet` bug fix | Task 10 Step 1, Task 11 Step 3, Task 20 Step 1 |
| Structural dedup guards | Task 7 preamble, Task 8 Step 7, Task 19 Step 2 |
| Stage 1-4 breakdown | Stages 1-4 |
| Nine test contract rewrites | Tasks 18-19 (4 + 1 + 1); the 3 `$snapshot` rewrites are in Task 7 because they gate that migration |
| Risks: silent invalidation loss | Task 17 Step 1, Task 21 Step 2 |
| Risks: verification gap | Task 21 |
| Out of scope: ProxyDelayBatch extraction | not planned — correct |

All spec requirements map to a task.

**Known soft spots, stated rather than hidden:**

- Tasks 4, 8, 9, 11, 12 use `grep` to enumerate the properties needing `@ObservationIgnored` instead of listing every one literally. `AppModel` alone has ~170 instance stored properties across 8115 lines, and enumerating them here would encode a snapshot that drifts. The grep patterns are exact and the classification rule (R2/R3) is explicit, but the executing engineer does make per-property judgment calls in those steps.
- The spec called for "each of the three primed hooks runs exactly once during `setupBindings`". Reading the handlers showed two of the three are no-ops at init (`handleCoreStatusChange` early-returns unless `.crashed`; `schedulePreviewRuntimeStartIfReady` needs non-empty preview groups), so a test asserting on them would pass vacuously and pin nothing. Task 0 Step 3 covers the one handler with a real launch-time effect instead, and Task 11 Step 3 documents why the other two calls are still made. This is a deliberate narrowing of the spec, not an omission.

**Type consistency:** the five hook names (`onSubscriptionFetchSettingsChange`, `onGlobalShortcutSettingsChange`, `onProfilePreviewGroupsChange`, `onProfilesChange`, `onStatusChange`) are declared in Task 10 and used with identical spelling and signatures in Task 11 Step 3. `ObservationChangeCounter(_ access:)` is defined in Task 6 and called with the same single-closure form in Tasks 7, 18, 19.
