# ObservableObject → @Observable Migration

Date: 2026-08-03
Status: Approved, ready for implementation planning

## Goal

Replace every remaining `ObservableObject`/`@Published` observation path in ClashMax with the
Observation framework (`@Observable`), and remove Combine from the app's state fan-out entirely.

`RuntimeDataStore` was migrated in an earlier pass and serves as the reference implementation for
the patterns below. Everything else still uses Combine.

## Current state

16 `ObservableObject` classes, 81 `@Published` properties, 57 `@EnvironmentObject` reads,
33 `.environmentObject(_:)` injections, 6 `@StateObject`, 5 `@ObservedObject`.

| Group | Types |
| --- | --- |
| Hub | `AppModel` (35 `@Published`) |
| Sub-stores | `PersistedSettingsStore` (20), `ProfileStore` (3), `ProfileCoordinator` (3), `ProxyPreviewStore` (3), `ProviderAnalyticsStore` (1), `PublicIPCoordinator` (1), `RuntimeSnippetLibraryStore` (2), `SystemProxyCoordinator` (1) |
| Services | `CoreProcessController` (3), `NetworkExtensionController` (4), `TunnelHelperClient` (1), `AppUpdateController` (2) |
| View-local | `ProxySearchCoordinator` (2), `ConnectionAppIconCache` (0), `RuleMatchSimulationDebouncer` (0) |

Every one of these types is already `@MainActor`, so the migration requires no concurrency rework.

`ConnectionAppIconCache` and `RuleMatchSimulationDebouncer` declare no `@Published` properties and
never call `objectWillChange.send()`. They are lifetime holders, not observable state, and should
drop the conformance rather than gain `@Observable`.

## Mechanism mapping

| Before | After |
| --- | --- |
| `final class X: ObservableObject` + `@Published var p` | `@Observable final class X` + `var p` (keep `private(set)`) |
| `@EnvironmentObject var x: X` | `@Environment(X.self) private var x` |
| `.environmentObject(x)` | `.environment(x)` |
| `@StateObject private var x = X()` | `@State private var x = X()` |
| `@ObservedObject var x: X` | `let x: X` |
| `$x.prop` binding from an environment/state object | `@Bindable var x = x` declared at the top of `body` |
| 9 `objectWillChange` relay sinks in `AppModel` | deleted; nested `@Observable` tracking replaces them |
| non-observable holder conforming to `ObservableObject` | plain class, held in `@State` |
| mutable buffers/caches inside an `@Observable` type | `@ObservationIgnored` |

### Why the cluster is atomic

`AppModel` exposes roughly 20 computed facades over `settings` (`overrides`, `tunSettings`,
`appTheme`, `proxyRoutingMode`, …). Today those invalidate views because
`settings.objectWillChange` is relayed into `AppModel.objectWillChange`.

An `@Observable` type has no `objectWillChange` to relay. If `AppModel` migrates while
`PersistedSettingsStore` does not, every view reading `appModel.overrides` silently stops
updating — with no compiler error and no test failure. The same argument applies to each
sub-store and service that `AppModel` relays from.

Therefore `AppModel` and all nine relayed types migrate in a single change.

### `@ObservationIgnored` rule

Observation invalidates on property *access* plus setter call. Any stored property that is mutated
as an implementation detail and is not meant to drive view updates must be
`@ObservationIgnored` — otherwise mutating it invalidates every view that touched the object.
This is the rule that made `RuntimeDataStore` correct (`logBuffer`, `connectionRecordBuffer`,
`logPublishTask`, `connectionStateGeneration`). Apply it to Combine cancellable bags, `Task`
handles, caches, generation counters, and the callback hooks introduced below.

## Replacing the five Combine pipelines

Nine of the fourteen `.sink` calls in `AppModel.setupBindings` are pure `objectWillChange` relays
and are deleted. Five carry real behavior and need explicit replacements:

| Source | Handler | Primed on subscribe today? |
| --- | --- | --- |
| `settings.$subscriptionFetchSettings` | `profileCoordinator.rescheduleSubscriptionAutoUpdates()` | No (`.dropFirst()`) |
| `settings.$globalShortcutSettings` | `installGlobalShortcuts(_:)` | **Yes** |
| `proxyPreview.$profilePreviewGroups` | `schedulePreviewRuntimeStartIfReady(profilePreviewGroups:)` | **Yes** |
| `profileStore.$profiles` | prune snippet bindings + provider analytics | No (`.dropFirst()`) |
| `coreController.$status` | `handleCoreStatusChange(_:)` | **Yes** |

Each owning store gains an `@ObservationIgnored` callback property fired from the `didSet` that
already exists on that property:

```swift
@ObservationIgnored var onGlobalShortcutSettingsChange: ((GlobalShortcutSettings) -> Void)?

var globalShortcutSettings = GlobalShortcutSettings.default {
    didSet {
        saveCodable(globalShortcutSettings, forKey: Self.globalShortcutSettingsDefaultsKey)
        onGlobalShortcutSettingsChange?(globalShortcutSettings)
    }
}
```

`AppModel.setupBindings` assigns these instead of subscribing. This matches the callback pattern
`AppModel` already uses for `profileCoordinator` (`restartRuntime`, `stopRuntime`,
`shouldSyncRuntimeAfterProfileChange`).

### Two semantics that must be reproduced deliberately

**Initial emission.** A `@Published` projected publisher emits its current value on subscribe.
`installGlobalShortcuts`, `schedulePreviewRuntimeStartIfReady`, and `handleCoreStatusChange`
therefore each run once during `setupBindings` today. `didSet` does not fire during
initialization, so `setupBindings` must call those three explicitly after assigning the hooks.
The two `.dropFirst()` pipelines must **not** receive a priming call.

**`willSet` → `didSet` timing, and the bug it fixes.** `@Published` publishes from `willSet`, so a
sink that re-reads the property off the object observes the *pre-change* value.
`rescheduleSubscriptionAutoUpdates()` takes no parameter and re-reads
`settings.subscriptionFetchSettings` through the hook installed at `AppModel.swift:960`, meaning
it currently reschedules subscription auto-updates using the **old** settings. Moving to `didSet`
reads the new value.

This is a real behavior change and it is the correct behavior. Pin it with a regression test
asserting that changing `subscriptionFetchSettings` reschedules against the new interval; do not
preserve the stale read.

The other four handlers receive the new value as a parameter and are timing-neutral.

## Preserving the structural dedup guards

Observation fires on every setter call, not on inequality. Several hot paths depend on guards that
skip redundant writes, and issues #10 and #11 regress if they are touched:

- `RuntimeDataStore`: `if recordsChanged`, `if snapshotsChanged`, `guard logs != next`
- `ProxySearchCoordinator.publish`: `if snapshot != self.snapshot`
- `PersistedSettingsStore.refreshLaunchSettings`: `guard refreshed != launchSettings`
- `AppModel.applyDelayStates`: batch coalescing before writing `proxyGroups` /
  `proxyDelayBatchProgress`

These guards are load-bearing under Observation, not leftovers from Combine. Carry them forward
unchanged.

## Stages

Each stage ends with the full test suite green and is committed separately.

**Stage 1 — leaves and services.** `ProxySearchCoordinator`, `ConnectionAppIconCache`,
`RuleMatchSimulationDebouncer`, `AppUpdateController`, `PublicIPCoordinator`,
`TunnelHelperClient`. None of these are relayed into `AppModel`'s `objectWillChange`, so they
carry no nested-tracking dependency. `ConnectionAppIconCache` and `RuleMatchSimulationDebouncer`
drop the conformance without gaining `@Observable`.

**Stage 2 — the cluster, atomically.** `PersistedSettingsStore`, `ProfileStore`,
`ProfileCoordinator`, `ProxyPreviewStore`, `ProviderAnalyticsStore`, `RuntimeSnippetLibraryStore`,
`SystemProxyCoordinator`, `CoreProcessController`, `NetworkExtensionController`, and `AppModel`;
delete the 9 relays; rewire the 5 pipelines onto callbacks; add the three priming calls.

**Stage 3 — view call sites.** 57 `@EnvironmentObject` → `@Environment`, 33 `.environmentObject`
→ `.environment`, `@StateObject`/`@ObservedObject` conversions, and `@Bindable` where bindings are
taken (`ContentView.swift:8` for `$appModel.selectedSection`; `SettingsView` for its
`$settings.*` bindings). `.environmentObject` calls inside `ClashMaxTests` must be converted too.

**Stage 4 — test contracts.** The nine rewrites below.

## Test contract rewrites

Observation has no "did this object publish at all" signal, so tests asserting on
`objectWillChange` must become per-property assertions using the synchronous re-arming
`ObservationChangeCounter` already present in `DashboardRuntimeStateTests.swift`. Its re-arm is
synchronous inside `onChange` on purpose — an async re-arm undercounts and would mask an issue-#11
regression.

| Test | Tracked property after migration |
| --- | --- |
| `testSettingCurrentModeDoesNotPublishChanges` | `model.overrides` |
| `testRequestingModeDefersPublishedChangesUntilNextActorTurn` | `model.overrides` |
| `testRequestingProxyRoutingModeDefersPublishedChangesUntilNextActorTurn` | `model.proxyRoutingMode` |
| `testCoreControllerStatusChangesPublishAppModelChanges` | `model.statusSummary` |
| `ProfileStoreTests.testSelectingAlreadyActiveProfileDoesNotPublishChanges` | `store.activeProfileID` and `store.profiles` |
| 3 × `coordinator.$snapshot` in `ProxySearchPipelineTests` | `coordinator.snapshot` |
| `model.$proxyDelayBatchProgress` (`DashboardRuntimeStateTests.swift:6009`) | `model.proxyDelayBatchProgress` |

This narrows each assertion: it no longer catches incidental churn on an unrelated property. That
is an accepted trade — the narrower assertion states what it actually means to test.

New tests to add:

- `subscriptionFetchSettings` change reschedules against the **new** settings (the `didSet` fix).
- Each of the three primed hooks runs exactly once during `setupBindings`.

## Risks

**Silent invalidation loss is the dominant risk and the compiler cannot catch it.** A store missed
in stage 2 produces no error and no test failure — only a view that stops updating at runtime.
Mitigation: stage 2 is atomic, and before building, confirm `grep -rn "ObservableObject" ClashMax`
returns nothing for the cluster.

**Dedup guards.** Covered above; regressing one silently reverts the issue #10/#11 perf work.
Existing coalescing tests are the guard rail.

**Missing `.environment` injection** traps at runtime rather than failing to compile — the same
failure mode as `@EnvironmentObject` today, so this is not a new risk, but stage 3 touches all 27
injection sites and a dropped one surfaces only when that window is opened.

**Verification gap.** The test suite proves logic, not that the UI redraws. Past sessions in this
project have repeatedly ended without a manual app run. This migration changes the invalidation
mechanism for the entire UI, so the work is not complete until the app has been launched and the
main surfaces (Dashboard, Proxies, Profiles, Settings, Routing, Logs, Connections, menu bar) have
been observed updating live.

## Out of scope

- Extracting the `ProxyDelayBatch` subsystem out of `AppModel` (previously identified as the
  highest-value decomposition, but it is a subsystem move, not part of this migration).
- Any restructuring of `AppModel` beyond removing the Combine plumbing.
