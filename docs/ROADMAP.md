# ClashMax Roadmap

**English** | [简体中文](ROADMAP.zh-CN.md)

**Status reviewed: 2026-11-17**, against source revision `9fe49fa`.
This is a source/documentation review; no app, tests or live network checks were run for it.
App and core versions belong in [project.yml](../project.yml) and the
[core manifest](../Resources/Core/mihomo-manifest.json), rather than a second version list here.

This roadmap separates implemented behavior, missing implementation and recorded manual
acceptance. **Implemented does not mean manually accepted or release-ready.** Existing IDs
are retained for source comments, tests and historical references.

Start with the [development guide](DEVELOPMENT.md) for setup and rules, the
[manual test plan](MANUAL_TEST_PLAN.md) for observations, and the
[release guide](RELEASE.md) for signed-bundle gates. Earlier implementation decisions and
measurements remain in the [archived roadmap](archive/ROADMAP-2026-11-17.md).

## 1. Positioning

ClashMax is a native macOS proxy client focused on explaining what Mihomo actually does:
which rule won, whether a configuration change took effect, and how to recover from a
specific proxy, DNS or routing failure. Add controls when they solve a user problem;
use the common runtime-snippet path for arbitrary Mihomo keys.

## 2. Design Principles — The Three Layers


This section is normative. It is the answer to the recurring question *"how do we stay
approachable while raising the ceiling for advanced users?"*

### 2.1 The pattern we reject: a Basic / Advanced toggle

Do not add a global "simple mode / advanced mode" switch, and do not add an "Advanced"
section that accumulates whatever did not fit elsewhere. Three reasons:

1. **It forces users to self-classify.** The moment someone is stuck is exactly the moment
   they do not know which tier their problem lives in.
2. **The advanced tier becomes a dumping ground.** Every surface we could not design well
   gets thrown in, and it ends up harder to use than the thing it was meant to escape.
3. **It is an unwinnable arms race.** Mihomo adds configuration keys faster than we can
   design toggles, and each toggle we add dilutes the first-run experience for everyone.

### 2.2 Layer by what the user is holding, not by difficulty

| Layer | What the user has in hand | Interface shape | Existing foundation |
| --- | --- | --- | --- |
| **L1 — Symptom** | *"It's broken / it's slow"* | A verdict plus a **single fix button**. No Mihomo vocabulary. | `ProxyEffectDiagnostics`, `TunRuntimeInspector`, `PublicIPInfoCard`, `ExternalControlHealthChecker` |
| **L2 — Intent** | *"I want X to go through Y"* | Scenario-shaped forms: an app, a site, a network. Still no Mihomo vocabulary. | [`QuickRule.swift`](../ClashMax/Models/QuickRule.swift), `NetworkPolicyRule`, Connections row menus |
| **L3 — Truth** | *"I know which key I need to change"* | The final YAML: visible, patchable, diffable, revertible. Full Mihomo vocabulary. | `RuntimeSnippet`, `EffectiveRuntimeConfigBuilder`, `RuntimeSnippetLibraryStore` |

### 2.3 Two invariants

**INV-1 — One truth, two entrances.**
An L1 fix button and an L2 intent form must both write into the *same* representation an L3
user edits by hand. There is exactly one rule model, one snippet store, one runtime YAML
builder. A feature that introduces a parallel storage format for "the easy version" is
rejected.

> This is already the stated design of quick rules. From
> [`QuickRule.swift`](../ClashMax/Models/QuickRule.swift): quick rules are *"stored in an
> ordinary runtime snippet and stay fully editable in Routing, so there is exactly one rule
> representation and one storage format in the app."* Generalize this; do not re-derive it
> per feature.

**INV-2 — The escape hatch is a first-class citizen, not a fallback.**
The ceiling for advanced users does not come from more UI switches. It comes from
**see it / override it / roll it back**:

- the fully resolved runtime YAML is always viewable;
- any key can be overridden by a user snippet, including keys ClashMax has no UI for;
- every apply shows a diff first;
- a failed apply reverts automatically and says why.

The second bullet became true on 2026-08-29. It is carried by the **Raw YAML** snippet payload
([`RawYAMLPatch.swift`](../ClashMax/Models/RawYAMLPatch.swift)) — an ordinary snippet kind on the
Routing page, alongside rules, DNS and sniffer, using the same save, preflight, diff and rollback
path as any other snippet. It is applied **after** every app-managed key
([`ConfigNormalizer.swift`](../ClashMax/Services/ConfigNormalizer.swift)), which is what the legacy
per-profile "Runtime Merge YAML" field never did: that one merges *before* those writes, so `mode`,
`tun.*`, `dns.enable` and the geo keys always won over it, and its editor has since been removed
from the profile sheet along with the developer-mode switch that gated it (the field is still
honoured for profiles that carry it). Only `mixed-port`, `external-controller` (and
its variants) and `secret` are refused, and refusing them **serves** INV-2 rather than capping it:
they are the channel the app applies, verifies and rolls back through, each already has an owning
control in Settings, and a patch that moved one would leave the app unable to roll back that very
patch. The profile's own inbound listener keys (`port`, `socks-port`, `redir-port`, `tproxy-port`)
are not refused but dropped from every layer, raw patches included, and the drop is written to the
app log (issue #33): Mihomo opens those listeners before the mixed one, so a subscription that also
declared `port: 7890` took the app's port first and `mixed-port` never came up. The profile's
other controller listeners (`external-controller-tls`, `-unix`, `-pipe`) are dropped from the
profile layer the same way, with a log line (2026-10-01, see [C1](archive/ROADMAP-2026-11-17.md#c1--import-time-subscription-audit-report)):
the unix socket answers without the secret, so a subscription that shipped one handed the core to
every process on the Mac.

With INV-2 satisfied, **ClashMax's ceiling equals Mihomo's ceiling** and the UI does not
grow. When Mihomo ships a new key tomorrow, advanced users have it the same day and we ship
nothing.

**Why this also serves beginners:** because of INV-1, a beginner who presses a fix button
can then *look at what that button wrote*. The app teaches its own configuration language
instead of hiding it behind a wall. Beginners graduate into advanced users in place.

### 2.4 Review checklist for any new configuration surface

Before adding a setting, a toggle, or a page, answer all five:

- **Which layer is this?** If the answer is "both L1 and L3", it is two features.
- **If L1: what is the single fix button, and which snippet does it write?**
- **If L2: does it reuse the existing rule/snippet model, or invent a new one?** (INV-1)
- **If L3: is it reachable through the generic override path already?** If yes, do not
      build bespoke UI for it. Since 2026-08-29 the honest answer for a plain Mihomo key is
      yes — a Raw YAML snippet reaches it.
- **Can the user see the resulting YAML diff, and revert it?** (INV-2)

A key that only advanced users need, and that the generic snippet override already reaches,
is **done** — shipping a dedicated toggle for it is a regression in L1 quality.

## 3. Implemented Behavior

These items have source implementations. Remaining manual observations are tracked in §5,
not as missing feature code. The archive retains the original probes and acceptance rationale.

| ID | Implemented behavior | Current source |
| --- | --- | --- |
| [A1](archive/ROADMAP-2026-11-17.md#a1--sniffer-recover-the-domain-the-kernel-never-saw) | Sniffer configuration, domain-origin decoding and one-click domain visibility repair; A1e sign-off remains open | [SnifferDiagnostics](../ClashMax/Models/SnifferDiagnostics.swift), [SnifferSettings](../ClashMax/Models/SnifferSettings.swift) |
| [A2](archive/ROADMAP-2026-11-17.md#a2--wire-dnsquery-into-a-dns-resolution-panel) | Core DNS queries, answer/TTL/negative-result display and rule simulation; the API does not report the answering nameserver | [DNSResolutionDiagnostics](../ClashMax/Models/DNSResolutionDiagnostics.swift), [MihomoAPIClient](../ClashMax/Services/MihomoAPIClient.swift) |
| [A3](archive/ROADMAP-2026-11-17.md#a3--flush-fake-ip-cache-as-an-l1-fix-action) | Fake-IP diagnosis and cache flush action | [FakeIPDiagnostics](../ClashMax/Models/FakeIPDiagnostics.swift) |
| [A5](archive/ROADMAP-2026-11-17.md#a5--one-click-redacted-diagnostic-bundle) | Redacted diagnostic-bundle preview, copy and file export | [DiagnosticBundle](../ClashMax/Models/DiagnosticBundle.swift), [DiagnosticBundleSheet](../ClashMax/Views/DiagnosticBundleSheet.swift) |
| [A6](archive/ROADMAP-2026-11-17.md#a6--batch-delay-testing-via-groupnamedelay) | Whole-group delay testing with bounded scheduling, cancellation and per-node fallback | [ProxyDelayTestCoordinator](../ClashMax/Stores/ProxyDelayTestCoordinator.swift) |
| [A7](archive/ROADMAP-2026-11-17.md#a7--tun-dns-mode-mihomo-v11933) | TUN `dns-mode` validation, app ownership and reporting | [ConfigNormalizer](../ClashMax/Services/ConfigNormalizer.swift), [RuntimeDiagnosticsStore](../ClashMax/Stores/RuntimeDiagnosticsStore.swift) |
| [B1](archive/ROADMAP-2026-11-17.md#b1--per-app-routing-with-a-real-app-picker) | Installed-app picker and bundle-wide process rules, including creation from a connection | [AppProcessRule](../ClashMax/Models/AppProcessRule.swift), [ConnectionsView](../ClashMax/Views/ConnectionsView.swift) |
| [B3](archive/ROADMAP-2026-11-17.md#b3--app-intents-and-shortcuts) | Ten App Intent actions; nine App Shortcuts leave a slot for the future scenario action | [ClashMaxAppIntents](../ClashMax/App/ClashMaxAppIntents.swift), [ClashMaxIntentExecutor](../ClashMax/App/ClashMaxIntentExecutor.swift) |
| [B5](archive/ROADMAP-2026-11-17.md#b5--geo-database-maintenance) | Geo database settings, inventory, age diagnosis and update action | [GeoDatabaseStore](../ClashMax/Stores/GeoDatabaseStore.swift) |
| [C1](archive/ROADMAP-2026-11-17.md#c1--import-time-subscription-audit-report) / [C3](archive/ROADMAP-2026-11-17.md#c3--decide-the-listeners-question) | Import/update audit reports, profile entry points, inherited-listener consent and live exposure diagnosis | [SubscriptionAudit](../ClashMax/Models/SubscriptionAudit.swift), [ListenerExposure](../ClashMax/Models/ListenerExposure.swift) |
| [D2](archive/ROADMAP-2026-11-17.md#d2--automate-mihomo-upgrade-regression) | Bundled-core preflight matrix and architecture checks wired into CI; CI installs and requires the pinned core | [CI](../.github/workflows/ci.yml), [CoreRuntimePreflightTests](../ClashMaxTests/CoreRuntimePreflightTests.swift), [BundledCoreArchitectureTests](../ClashMaxTests/BundledCoreArchitectureTests.swift) |
| UI refresh | Native workspace, nine pages, inspectors/sheets, SwiftUIX input adapters and 320 pt menu bar content | [ContentView](../ClashMax/Views/ContentView.swift), [NativeInputs](../ClashMax/Views/NativeInputs.swift), [historical design](UI_REFRESH_PLAN.md) |
| Observation migration | `@Observable` stores/services and typed environment access replace the former Combine observation fan-out | [AppModel](../ClashMax/Stores/AppModel.swift), [archived design](superpowers/specs/2026-08-03-observable-migration-design.md) |

### Retained Runtime Decisions

- Keep **Mixed** as the new-install TUN stack default and preserve existing selections. The
  [v1.19.32 note](MIHOMO_1_19_32.md) records why the upstream default did not change the app default.
- Keep the app-managed System DNS override. While it is on, ClashMax pins TUN `dns-mode` to
  `disabled`; raw snippets retain their documented override path. The maintainer's
  [2026-10-25 decision](archive/ROADMAP-2026-11-17.md#a7--tun-dns-mode-mihomo-v11933)
  remains in force; this cleanup does not reopen it.
- Support the app-owned bundled Mihomo channel. Other channels need a manifest, integrity
  verification, helper allowlisting, UI state and rollback before they can be offered.

## 4. Remaining Work

The four feature groups below remain open: A4, B2 with the dependent B3 action, B4, and C2.
D1/D3 are engineering and acceptance work. The logging design is listed separately because
its foundations exist but the proposed product is not implemented end to end.

### A4 — Connection Route Replay

Existing pieces: connection history, reported rule/chain, rule explanation, DNS queries and
public-IP diagnostics. They do not yet form one connection-specific ordered replay.

- [ ] Show DNS answer → matched rule → selected group → actual node → exit IP for a selected connection.
- [ ] Label each fact as core-reported, live-probed or simulated, including its time and missing data.
- [ ] Support retained closed connections. A current DNS/IP probe must not be presented as a
      measurement made when an old connection was open.

### B2 — Scenarios: Generalize `NetworkPolicyRule`

[NetworkPolicyRule](../ClashMax/Models/CoreModels.swift) still matches SSID and controls
routing mode, system proxy and runtime auto-start. It cannot select a profile, snippet or node.

- [ ] Add interface type, specified network, VPN presence and an explicit unmatched fallback as triggers.
- [ ] Add profile selection, named-snippet enable/disable and proxy-group node selection as actions.
- [ ] Have exactly one active scenario, deterministic precedence and a visible matching reason.
- [ ] Decode persisted SSID policies without changing their behavior, with migration fixtures.
- [ ] Surface switches in the menu bar or a notification.

### B3 — App Intents and Shortcuts: Scenario Action

- [ ] Add **Activate Scenario** after B2 supplies a scenario model, using the reserved App Shortcut slot.

The other ten actions are implemented. Shortcuts.app and cold background-launch observations
remain manual acceptance under §5, not ten new implementation tasks.

### B4 — Control Center Widget

No widget target or Control Center implementation is present in the current project.

- [ ] Switch routing mode and show live state outside the app.
- [ ] Gate newer macOS APIs and keep a practical fallback for the macOS 15 deployment target.
- [ ] Consume the same application state rather than create a second source of truth.

### C2 — Subscription Update Diff

[ProfileStore](../ClashMax/Stores/ProfileStore.swift) replaces a subscription after preflight;
[ProfileCoordinator](../ClashMax/Stores/ProfileOperationsStore.swift) audits it afterwards.
The previous source is held for write rollback, not a retained user-visible diff or risk-approval gate.

- [ ] Retain enough bounded, redacted information to compare with the previous fetch.
- [ ] Summarize node additions/removals/renames separately from configuration changes.
- [ ] Stop silent application of newly introduced danger keys and request a decision.
- [ ] Keep diff storage bounded and redacted. Preserve C1/C3 protections already in place.

### D1 — Decompose `AppModel`

**In progress.** Profiles, system proxy, diagnostics, Geo databases, outbound endpoints,
network policy and delay testing already have stores/coordinators. The old all-in-one
line counts are obsolete; inspect the current ownership before extracting more.

- [ ] Continue extracting runtime and routing responsibilities where the current work needs it,
      preserving the public interfaces consumed by views.
- [ ] Keep each domain change independently revertible; compare the full suite against a baseline
      without new skips when doing a cross-cutting extraction.
- [ ] Preserve initialization priming (`didSet` does not run in `init`), structural deduplication
      and intentional `@ObservationIgnored` hot-path state.

### D3 — Close the Manual-Verification Gap

The [tracked per-release checklist](MANUAL_TEST_PLAN.md#per-release-checklist) now exists.
The missing work is executing it and recording observations for the version under test.

- [ ] Complete the outstanding feature and signed-bundle observations in §5.
- [ ] Record date, app/core build, macOS/architecture, observed behavior and evidence before
      calling an item manually accepted.
- [ ] Treat an unrun or blocked release gate as such; tests and fixture screenshots do not close it.

### Related Design — Structured Logging Split

**Partially implemented foundation; end-to-end implementation still open.** The shared
producer/redactor/line accumulator and project guards exist. The app still uses
`RuntimeDataStore.logs`; the planned recorder, independent application/runtime stores,
rotating JSONL persistence and split-channel viewer are absent.

Keep the [approved design](superpowers/specs/2026-07-28-structured-logging-design.md) and
[implementation plan](superpowers/plans/2026-07-28-structured-logging.md) as a separate work item.
Recheck the remaining steps and establish a fresh baseline before resuming; old checkboxes,
line numbers and test counts do not establish present status.

## 5. Manual Acceptance Still Open in the Repository

This table reports missing recorded sign-off, not a claim that nobody has ever used a feature.
No new manual acceptance was performed during the 2026-11-17 document cleanup.

| Scope | Observation still needed | Procedure |
| --- | --- | --- |
| A1e | Real domainless connection → diagnosed cause → fix → a new connection matches the domain rule | [A1](MANUAL_TEST_PLAN.md#a1--a-domainless-connection-is-diagnosed-and-repaired-end-to-end) |
| A2 / A3 / B5 | Real DNS results and negative/failure states; fake-IP fix applicability; Geo file/update outcomes | [Manual plan](MANUAL_TEST_PLAN.md) |
| A5 / B1 / B3 / C1 / C3 | Exact export preview, app/helper-process routing, Shortcuts outcomes/cold launch, audit entry points and listener consent | [Per-release checklist](MANUAL_TEST_PLAN.md#per-release-checklist) and feature cases |
| A6 | Large-group scrolling, cancel behavior, every node reaching a final state, diagnostic counts | [A6](MANUAL_TEST_PLAN.md#a6--whole-group-delay-testing-on-a-group-of-1000-nodes); transport-only measurement is already recorded |
| Native UI | macOS 15 appearance, real MenuBarExtra panel, keyboard focus, IME, VoiceOver and system accessibility settings | [UI acceptance](MANUAL_TEST_PLAN.md#native-ui-acceptance) |
| Signed integration | Installed Helper/NE, TUN/DNS/routing restoration, network changes, sleep/wake and UDP/QUIC | [Release guide](RELEASE.md), [TUN matrix](TUN_SMOKE_TEST.md) |

Keep the sniffer A1 closure gate: A1a–A1d are implemented, but **A1 is not accepted until A1e
is signed off**. Measured group-delay transport, source tests and signed data-plane acceptance
are separate evidence.

## 6. Non-Goals

- Feature-count parity with other Mihomo clients or a dedicated toggle for every Mihomo key.
- Telemetry, accounts, node collection/sales, subscription analytics or embedded Sub-Store.
- Runtime AI features; [the maintenance proposal](CODEX_OSS_PLAN.md) concerns repository work.
- Windows or Linux ports.

Existing Sparkle updates remain supported maintenance; the historical MVP exclusion is not
a request to remove them.

## 7. Updating This Roadmap

- Keep §2 normative. Record the reason for a principle change here.
- Link current symbols/files instead of volatile line counts. Date source reviews and keep
  app/core version pins in their existing source files.
- Track implementation and acceptance separately. Only tick manual observations with recorded evidence.
- Keep IDs when moving an item. Reordering is allowed; dropping an item requires a reason in §6.
- Preserve the earlier sequencing: close A1e, then A4; B2/C2 follow the diagnostic foundations;
  the B3 scenario action depends on B2, and B4 follows. D1/D3 accompany the affected work.
- Keep probe contracts, security decisions and dated results in the
  [English archive](archive/ROADMAP-2026-11-17.md) /
  [Chinese archive](archive/ROADMAP-2026-11-17.zh-CN.md). Their old unchecked boxes are historical,
  not another active queue.
