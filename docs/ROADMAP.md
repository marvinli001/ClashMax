# ClashMax Roadmap

**English** | [简体中文](ROADMAP.zh-CN.md)

**Status:** draft 2026-08-14, revised 2026-08-27, corrected 2026-08-29 · maintainer
[@marvinli001](https://github.com/marvinli001) · app 1.0.23, bundled Mihomo
[v1.19.30](../Resources/Core/mihomo-manifest.json)

This document records **where ClashMax is going and why**, in a form that can be checked
against the tree. It is not a wish list. Every gap named below was verified by reading the
repository on 2026-08-14, and every proposed issue carries acceptance criteria that can be
demonstrated with a command or a screenshot.

The 2026-08-27 revision closes **A3, A6 and B5** — the three coverage gaps that were either
already hurting users or getting worse on their own. Each endpoint contract quoted in those
sections was probed against the bundled core rather than read off the upstream docs; where a
probe contradicted the obvious assumption, the contradiction is written down next to the
criterion it constrains.

A review on 2026-08-29 found five defects in that first cut — a fallback that could turn one
failed group request back into a per-node storm, a setting that meant two different things
either side of the promotion floor, geo settings missing from backup and restore, geo
diagnostics reading the saved value instead of the one the core actually applied, and a
ClashX import whose winning value depended on directory-enumeration order. All five are
fixed, and each is written up under the criterion it belongs to rather than in a changelog,
because the criterion is what was wrong. **The A3/A6/B5 "shipped" claims below are about the
transport and the logic; the manual observations each section names as a gap are still
open.**

Bug fixes, filed issues, and Mihomo version bumps are ongoing maintenance and are
deliberately **not** in this document. This is about what ClashMax is *for*.

---

## 1. Positioning

Every other Mihomo client competes on **how many kernel switches it exposes**.

ClashMax should compete on **explaining what the kernel is actually doing**.

That is not aspirational — it is already the shape of the codebase. These subsystems have no
equivalent in ClashX, Clash Verge Rev, or mihomo-party:

| Capability | Where |
| --- | --- |
| Classifies *why* traffic is not going through the proxy, down to a `Cause` | [`ClashMax/Models/ProxyEffectDiagnostics.swift`](../ClashMax/Models/ProxyEffectDiagnostics.swift) |
| Simulates which rule a given host will match | `RuleMatchSimulator` in [`ClashMax/Models/CoreModels.swift`](../ClashMax/Models/CoreModels.swift) |
| Shows the exact runtime YAML a change will produce, as a diff, before applying | [`EffectiveRuntimeConfigBuilder.swift`](../ClashMax/Services/EffectiveRuntimeConfigBuilder.swift), Routing page |
| Reports whether the change the user just made actually took effect | [`RuntimeApplyOutcomeBanner.swift`](../ClashMax/Views/RuntimeApplyOutcomeBanner.swift) |
| Flags dangerous keys smuggled in by a subscription | `ProviderOptionsRisk` in [`CoreModels.swift`](../ClashMax/Models/CoreModels.swift) |
| Inspects live TUN routes / DNS state and system proxy state independently of the core | [`TunRuntimeInspector.swift`](../ClashMax/Services/TunRuntimeInspector.swift), [`SystemProxyController.swift`](../ClashMax/Services/SystemProxyController.swift) |

**The roadmap is: make this the product, not a side feature.**

---

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
`tun.*`, `dns.enable` and the geo keys always won over it, and it was reachable only from a
Developer Mode disclosure on subscription profiles. Only `mixed-port`, `external-controller` (and
its variants) and `secret` are refused, and refusing them **serves** INV-2 rather than capping it:
they are the channel the app applies, verifies and rolls back through, each already has an owning
control in Settings, and a patch that moved one would leave the app unable to roll back that very
patch.

With INV-2 satisfied, **ClashMax's ceiling equals Mihomo's ceiling** and the UI does not
grow. When Mihomo ships a new key tomorrow, advanced users have it the same day and we ship
nothing.

**Why this also serves beginners:** because of INV-1, a beginner who presses a fix button
can then *look at what that button wrote*. The app teaches its own configuration language
instead of hiding it behind a wall. Beginners graduate into advanced users in place.

### 2.4 Review checklist for any new configuration surface

Before adding a setting, a toggle, or a page, answer all five:

- [ ] **Which layer is this?** If the answer is "both L1 and L3", it is two features.
- [ ] **If L1: what is the single fix button, and which snippet does it write?**
- [ ] **If L2: does it reuse the existing rule/snippet model, or invent a new one?** (INV-1)
- [ ] **If L3: is it reachable through the generic override path already?** If yes, do not
      build bespoke UI for it. Since 2026-08-29 the honest answer for a plain Mihomo key is
      yes — a Raw YAML snippet reaches it.
- [ ] **Can the user see the resulting YAML diff, and revert it?** (INV-2)

A key that only advanced users need, and that the generic snippet override already reaches,
is **done** — shipping a dedicated toggle for it is a regression in L1 quality.

---

## 3. Where ClashMax Stands Today

### 3.1 Scale, as verified on 2026-08-14

| Claim | How to check |
| --- | --- |
| 89 source files, ~61.7k lines across app, helper, Network Extension, shared code | `find ClashMax Shared ClashMaxHelper ClashMaxNetworkExtension -name '*.swift' \| wc -l` |
| 44 test files, ~38k lines, 1131 XCTest cases + 5 Swift Testing cases | `grep -rhoE 'func test[A-Za-z0-9_]*' ClashMaxTests \| sort -u \| wc -l` |
| 1277 localized keys in `en` and `zh-Hans` | [`Resources/Localizable.xcstrings`](../Resources/Localizable.xcstrings) |
| Tests run in public CI | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) |

### 3.2 Mihomo coverage gaps

Mihomo control API endpoints ClashMax already speaks, from
[`MihomoAPIClient.swift`](../ClashMax/Services/MihomoAPIClient.swift): `/`, `/configs`,
`/connections`, `/logs`, `/providers/proxies`, `/providers/rules`, `/proxies`, `/restart`,
`/rules`, `/traffic`, `/version`.

Gaps, in priority order:

| Gap | Verified state | Consequence |
| --- | --- | --- |
| **`sniffer`** | **Zero occurrences repo-wide.** Worse: the connections decoder backfills a missing domain with the destination IP ([`MihomoAPIClient.swift:448`](../ClashMax/Services/MihomoAPIClient.swift#L448)), so nothing downstream can tell a domainless connection from a named one | Connections opened straight to an IP (hardcoded-IP apps, some CDNs, QUIC) carry no domain, so `DOMAIN-SUFFIX` rules cannot match them. Users experience this as *"my rules don't work"* — and our diagnostics cannot say why, because the fact is destroyed before diagnosis. See [A1](#a1--sniffer-recover-the-domain-the-kernel-never-saw) |
| **`/dns/query`** | Not implemented | Cannot answer "which nameserver answered this domain, and with what address". Leaves a hole in the middle of the routing story we otherwise tell end to end. |
| **`/cache/fakeip/flush`** | **Closed 2026-08-27** — `flushFakeIPCache()`, surfaced through `FakeIPDiagnosticsBuilder` as an L1 fix action. See [A3](#a3--flush-fake-ip-cache-as-an-l1-fix-action) | *(was: a stale fake-ip mapping can only be cleared by restarting the core)* |
| **`/group/{name}/delay`** | **Closed 2026-08-27** — whole-group units replace per-node fan-out above 8 members. Measured 2026-08-29 on 1200 nodes by [`script/bench_group_delay.py`](../script/bench_group_delay.py): **5.00 s vs 350.88 s, 70x**. A group in flight costs the whole concurrency budget and only a 404 degrades to per-node, so the fallback cannot become a larger storm than the one it replaced. See [A6](#a6--batch-delay-testing-via-groupnamedelay) | *(was: batch delay testing is issued per node; the kernel has a whole-group endpoint)* |
| **`geox-url`, `geo-auto-update`, `geodata-mode`** | **Closed 2026-08-27** — `GeoDatabaseSettings` is app-managed and generated into the runtime YAML by `ConfigNormalizer`. **ClashX import closed 2026-08-29** — the migration parser reads the keys instead of allow-listing them, from the main config only. Backup/restore carry the settings and the diagnostics read the applied ones. See [B5](#b5--geo-database-maintenance) | *(was: GeoIP/GeoSite databases cannot be updated, so geo-based rules silently drift out of date — measured on the maintainer's own machine on 2026-08-27: `GeoSite.dat` last written Jun 20, `geoip.metadb` May 4)* |
| **`/configs/geo`** | **Closed 2026-08-27** — `updateGeoDatabases(timeout:)` behind an Update Now action | *(was: no in-app geo database refresh)* |
| **`/memory`** | Not implemented | No core memory telemetry. |
| **`tcp-concurrent`, `global-client-fingerprint`, `find-process-mode`, `keep-alive-interval`, `ntp`, `experimental`, `global-ua`, `interface-name`** | **Closed 2026-08-29** — still zero occurrences by name, and deliberately so: the **Raw YAML** snippet payload ([`RawYAMLPatch.swift`](../ClashMax/Models/RawYAMLPatch.swift)) reaches all of them, and every key Mihomo ships tomorrow, without the app growing a switch. See [INV-2](#23-two-invariants) | *(was: advanced users hit a hard ceiling; per INV-2 the fix is the generic override path, not eight new toggles)* |
| **`listeners`** | Recognized only as a subscription risk key to strip | Inbound listeners (serving other devices on the LAN) are unavailable. Needs a deliberate decision, not a default. |

### 3.3 Native macOS leverage already half-built

| Asset | State | Missing piece |
| --- | --- | --- |
| `PROCESS-NAME` / `PROCESS-PATH` rule kinds | Present in the rule enum ([`CoreModels.swift:2492`](../ClashMax/Models/CoreModels.swift#L2492)) | No app picker. Users must type a process name from memory. |
| Process path + icon for live connections | Working ([`ConnectionsView.swift:578`](../ClashMax/Views/ConnectionsView.swift#L578)) | Not wired to rule creation. |
| `NetworkPolicyRule` — per-SSID policy | Switches routing mode, system proxy, auto-start ([`CoreModels.swift:5580`](../ClashMax/Models/CoreModels.swift#L5580)) | Cannot switch **profile** or **rule set**. Trigger is SSID only. |
| `NetworkEnvironmentMonitor`, `WiFiNetworkInfo` | Live SSID and path monitoring | Only consumed for policy matching and diagnostics. |

---

## 4. Tracks

Four tracks. A, B, C deliver product value; D is the tax that makes A, B, C affordable.

Issue IDs are stable slugs, not GitHub numbers, so they can be filed in any order.

---

### Track A — Diagnosis As The Product

**Goal:** answer one question end to end, in one screen: *"for this connection, from domain
to exit IP, what happened at every step?"*

This is the moat. Everything here is L1, and each fix button writes an L3-visible snippet.

#### A1 — `sniffer`: recover the domain the kernel never saw

**Priority: highest. Everything else in Track A waits behind it.**

Every other item in Track A explains a decision the kernel *made*. This one is about a
decision the kernel *could not make*. A connection opened straight to an IP carries no
domain, so every `DOMAIN`, `DOMAIN-SUFFIX`, `DOMAIN-KEYWORD` and `GEOSITE` rule is
structurally unreachable for it. The user writes a correct rule, and it never fires. No
surface in ClashMax can currently say why — which makes this simultaneously the largest
kernel gap and the largest hole in the diagnostic story the product is built on.

##### A1.0 — What was verified, and against what

Bundled Mihomo v1.19.29 (`Resources/Core/mihomo`), checked on 2026-08-14:

| Claim | Evidence |
| --- | --- |
| The core accepts the whole sniffer schema | `mihomo -t -f` over a config carrying `enable`, `override-destination`, `force-dns-mapping`, `parse-pure-ip`, `sniff.{TLS,HTTP,QUIC}` (with `ports` and per-protocol `override-destination`), `skip-domain` and `force-domain` → *test is successful* |
| Sniffing does **not** require a `dns:` block | The same config with no `dns:` key at all validates and runs. Unlike the DNS trap behind issue #16, there is no inert-by-omission failure mode to guard against here |
| An unknown protocol fails legibly | `sniff: {BOGUS: {}}` → `level=error msg="not find the sniffer[BOGUS]"`, so preflight can report the real cause rather than the generic trailer |
| The sniffer hot-reloads | `PUT /configs?force=true` with a sniffer-off config flipped `/configs.sniffing` from `true` to `false` on a running core, with no restart |
| **`GET /configs` does not return the sniffer block** | The response exposes exactly one boolean, `sniffing`. There is no `sniffer` key anywhere in it |
| Connection metadata carries `sniffHost` | `json:"sniffHost"` is present in the core binary, alongside `dnsMode`, `remoteDestination`, `specialProxy` and `inboundName` — **none** of which ClashMax decodes today |

Two consequences bind the design before any code is written:

1. Because the core reports only `sniffing: true|false`, the **generated runtime YAML is the
   single source of truth** for *what* is being sniffed. Do not build a read-back path for
   the details; per INV-2 the YAML already is the honest answer, and inventing a second
   answer would be a new source of truth to keep in sync.
2. Because the sniffer hot-reloads, a sniffer edit belongs in `.hotReload` in
   [`RuntimeChangeApplyMode.swift`](../ClashMax/Models/RuntimeChangeApplyMode.swift)
   alongside `.rules` and `.dns`. It must not promise a restart it does not need.

##### A1.1 — The blocking defect this uncovered

[`MihomoAPIClient.swift:448`](../ClashMax/Services/MihomoAPIClient.swift#L448) decodes a
connection's host as:

```swift
host: metadata["host"] as? String ?? metadata["destinationIP"] as? String ?? "",
```

A connection carrying **no domain** is therefore recorded with its destination IP sitting in
the `host` field, and `ConnectionSnapshot` keeps no flag separating the two cases.
[`ConnectionsView.swift:137`](../ClashMax/Views/ConnectionsView.swift#L137) documents the
fallback at the point where it prefills a quick rule — but the collapse happens one layer
below it, in the decoder, so **no consumer downstream can distinguish "the domain is
example.com" from "there is no domain"**.

This is why the gap has stayed invisible for so long: the Host column always had something
plausible to show. It is also a hard prerequisite. The diagnosis this item promises cannot
be computed at all until the decoder stops discarding the distinction, so A1a below ships
first and on its own.

##### A1a — Stop discarding the fact (prerequisite, no user-visible change)

- **Scope:** `MihomoAPIClient.decodeConnections`, `ConnectionSnapshot`. No UI work.
- **Acceptance criteria:**
  - [ ] `ConnectionSnapshot` distinguishes, as typed state rather than by string inspection:
        a natively reported domain, a domain recovered by sniffing (`sniffHost`), and no
        domain at all. The raw destination IP stays available in every case.
  - [ ] `sniffHost`, `dnsMode`, `remoteDestination` and `specialProxy` are decoded, with the
        same multi-spelling tolerance `stringValue(for:in:)` already applies elsewhere.
  - [ ] The Connections table renders exactly as it does today — the IP fallback stays a
        *presentation* choice made above the model, not a fact destroyed inside the decoder.
  - [ ] `connectionRuleHost` in `ConnectionsView` reads the new typed state instead of
        re-deriving it from an empty string, and the comment at line 137 moves with it.
  - [ ] Decoder tests over fixtures for: domain present, domain absent, `sniffHost` present
        with `host` absent, `sniffHost` present with `host` also present, and both absent.

##### A1b — Generate and own the `sniffer` block (L3)

- **Scope:** [`ConfigNormalizer.swift`](../ClashMax/Services/ConfigNormalizer.swift),
  `RuntimeOverrides`, [`RuntimeSnippet.swift`](../ClashMax/Models/RuntimeSnippet.swift),
  `EffectiveRuntimeConfigBuilder`.
- **Shape:** a `SnifferSettings` value type modeled on `TunDNSSettings` — `validationError`,
  `hasRuntimeOverlay`, `summary`, `Codable` with defaulted decoding — so it drops into the
  layer/diff/preflight machinery that already exists rather than beside it.
- **Acceptance criteria:**
  - [ ] `sniffer` is generated into the runtime YAML and survives `mihomo -t` for every
        template × routing mode × DNS-override combination, including the provider-backed
        template path in `providerBackedConfig`.
  - [ ] A new `RuntimeSnippetPayloadKind.sniffer` carries user edits, so a sniffer change is
        an ordinary snippet in the ordinary store, editable in Routing, orderable with the
        others, and diffable — no parallel storage (INV-1).
  - [ ] `RuntimeChangeKind.sniffer` resolves to `.hotReload` when the runtime serves user
        traffic, and to `.appliesOnNextStart` otherwise, matching the verified core behavior.
  - [ ] Validation rejects an unknown protocol, a malformed port range, and an empty `sniff`
        map with a specific message *before* the core sees it; when the core rejects a
        config anyway, the surfaced text is the `level=error msg=` line.
  - [ ] The Routing diff preview shows the `sniffer` block as a labeled layer, the way
        `dns-override` is shown today.
  - [ ] A subscription-supplied `sniffer` block merges through the existing runtime-merge
        path with a deliberate, visible keep-or-override decision — never a silent overwrite
        in either direction.
  - [ ] Tests cover: off, on with defaults, on with per-protocol ports, subscription
        conflict, invalid input, and the apply-mode resolution.

##### A1c — The diagnosis this exists for (L1)

The roadmap previously said *"`ProxyEffectDiagnostics` gains a cause"*. That is the wrong
home and the plan corrects it: `ProxyEffectDiagnosticsBuilder` produces **one global verdict
from one GeoIP probe host** and has no connection input at all. A per-connection cause
folded into it would conflate two different scopes.

- **Scope:** a new pure classifier — `SnifferDiagnostics` in `ClashMax/Models/` — shaped
  exactly like `ProxyEffectDiagnosticsBuilder` (`Input` struct → `Snapshot` carrying
  `Status`, a stable `Cause` enum, `Fact` rows, `recoveryActions`, `plainTextLines`), so it
  inherits the existing testing and copyable-report conventions for free.
- **Causes to classify:**

  | Cause | Meaning | Status |
  | --- | --- | --- |
  | `domainReported` | The connection carried a domain natively; sniffing is not in play | pass |
  | `domainRecoveredBySniffing` | `sniffHost` supplied the domain the rules matched on | pass |
  | `domainlessSnifferDisabled` | No domain, sniffing off — **the headline case** | fail |
  | `domainlessProtocolNotCovered` | No domain, sniffing on, but this port/protocol is not in the `sniff` map | warn |
  | `domainlessNotSniffable` | No domain, sniffing on and covering it, nothing recovered | info |
  | `sniffedButNotOverridden` | A domain was sniffed, but `override-destination` is off | warn |

- **Acceptance criteria:**
  - [ ] The `sniffedButNotOverridden` case is confirmed against the running core before it
        ships — whether `override-destination: false` leaves `sniffHost` populated while
        rules still match on the IP. Encode whichever behavior the core actually has; do not
        ship a cause that describes documentation rather than observation.
  - [ ] For a domainless connection, the verdict names the concrete consequence by reusing
        `RuleMatchSimulator`: *which domain rule would have matched had the domain been
        present*. A cause without that sentence is a fact, not a diagnosis.
  - [ ] Every non-pass cause carries a fix action that writes the A1b snippet — enable
        sniffing, extend it to this port, or turn on `override-destination` — and nothing
        else. No bare toggle in Settings (§2.4).
  - [ ] After the fix applies, the existing `RuntimeApplyOutcomeBanner` reports it, and
        re-running the diagnosis on a fresh connection to the same destination returns a
        pass. The loop closes visibly.
  - [ ] Reachable from a Connections row and from the Routing explanation for that
        connection — the two places the user is already standing when they notice.
  - [ ] The classifier is pure and fully covered: one test per cause, plus the
        rule-would-have-matched sentence.

##### A1d — Subscription trust for `sniffer` (folds into C1)

`sniffer` is **absent** from the danger-key set at
[`CoreModels.swift:805`](../ClashMax/Models/CoreModels.swift#L805). A subscription can
therefore ship `skip-domain`, `force-domain`, or `override-destination: false` today and
change which rules match the user's traffic, with nothing surfaced.

- **Acceptance criteria:**
  - [ ] `sniffer` joins the scanned key set at `warning` severity — it changes traffic
        identification, not LAN exposure — with a message naming the consequence, in the
        same register as the existing `dns` and `tun` entries.
  - [ ] The import-time report (C1) states what the subscription's sniffer block would
        change and what ClashMax kept.

##### A1e — Regression and manual proof

- **Acceptance criteria:**
  - [ ] The D2 script adds sniffer-on and sniffer-off to its template × mode matrix, so a
        future core bump that changes the schema fails the build.
  - [ ] `MANUAL_TEST_PLAN.md` gains the end-to-end line item, and it is signed off before
        A1 is called done: an app that connects by hardcoded IP → a `DOMAIN-SUFFIX` rule for
        it does not fire → the diagnosis names the missing domain and the rule that would
        have matched → the fix button → the rule now fires, confirmed in the Connections
        row's chain.

##### Definition of done for A1

All five phases, with A1e signed off by hand. Per the recurring failure mode named in D3,
*"tests pass, never seen by eye"* does not close this item — this one is specifically about
believing the user when they say their rules do not work.

#### A2 — Wire `/dns/query` into a DNS resolution panel

- **Problem:** the routing story has a hole in the middle. We can show rules and we can show
  the exit IP, but not what DNS actually returned.
- **Acceptance criteria:**
  - [ ] `MihomoAPIClient` gains `dnsQuery(name:type:)`.
  - [ ] A panel takes a domain and reports: which nameserver answered, the addresses, and
        whether the answer came from fake-ip.
  - [ ] The result feeds `RuleMatchSimulator` so the panel shows *domain → address → matched
        rule → group → node* in one place.
  - [ ] Reachable from a Connections row for the domain of that connection.
  - [ ] Failure states are explicit (core not running, DNS disabled, query timeout).

#### A3 — Flush fake-ip cache as an L1 fix action

**Status: shipped 2026-08-27.** Not yet exercised by hand — see the gap below.

- **Problem:** a stale fake-ip mapping currently requires a core restart.
- **What the endpoint actually does**, probed against the bundled core v1.19.30: `POST
  /cache/fakeip/flush` answers `204` with an empty body **whether or not the core is in
  fake-ip mode**, and `GET` answers `405`. The reply therefore cannot be used to decide
  whether the action meant anything — that decision has to be made *before* the call. It is,
  and not from `GET /configs`, which carries **no `dns` key at all**;
  [`ActiveDNSConfigReader`](../ClashMax/Services/ActiveDNSConfigReader.swift) reads the
  `dns:` block back off the runtime YAML the core was actually handed, the same way A1a's
  reader does for `sniffer`.
- **Acceptance criteria:**
  - [x] `MihomoAPIClient` gains `flushFakeIPCache()`.
  - [x] Surfaced as a fix action on the relevant diagnosis, not as a bare button.
        [`FakeIPDiagnosticsBuilder`](../ClashMax/Models/FakeIPDiagnostics.swift) only reaches
        `warn` when something *invalidating* happened after the table was last known empty —
        the profile reloaded, or the network changed. Absent that it is `pass`, and the panel
        says so rather than inviting a pointless flush.
  - [x] Disabled with an explanation when `enhanced-mode` is not `fake-ip`. `canFlush` is
        false for every cause where the core holds no table (core down, config not read back,
        DNS off, not fake-ip mode) and the control is rendered **disabled with `reason`
        showing**, not hidden — a hidden control cannot explain why it is not there.
- **Baseline:** the known-good moment is the later of "the core started with an empty table"
  and "we emptied it ourselves". That is sound here only because `profile.store-fake-ip` is
  never written by ClashMax and defaults to `false`, so the table genuinely is empty at core
  start.
- **Two false positives, fixed 2026-08-29:**
  - The profile signal was `Profile.updatedAt`, a manifest timestamp that also moves for a
    rename, an update-policy edit or an upstream-endpoint change — none of which can
    invalidate a single mapping. Renaming a profile reported a stale fake-ip table. The input
    is now `profileContentFetchedAt`, fed from `SubscriptionMetadata.lastFetchedAt`, which is
    written only when a fetch actually brought bytes back. A local profile has no fetch
    timestamp and contributes nothing, which is the honest answer: ClashMax does not observe
    in-place edits to a local config either way.
  - When both the profile and the network were invalidating, the builder always named the
    profile, because that branch was written first. It now compares the two timestamps and
    reports whichever happened **later** — the state the table is actually in, rather than a
    cause the user has already moved past.
- **Gap:** never run by hand against a real captive portal or a real subscription update.

#### A4 — Connection route replay

- **Problem:** diagnostics are per-subsystem. Nobody can see one connection's whole path.
- **Acceptance criteria:**
  - [ ] For a selected connection: DNS answer (A2) → matched rule → selected group → actual
        node → exit IP, as a single ordered view.
  - [ ] Each step shows where the value came from (core API, live probe, simulation) so a
        simulated step is never mistaken for an observed one.
  - [ ] Works for a closed connection from the recent-connections buffer, not only live ones.

#### A5 — One-click redacted diagnostic bundle

- **Problem:** issue reports arrive as *"it doesn't work"*. This is a maintenance cost paid
  on every issue.
- **Foundation:** [`StructuredLogPrivacy.swift`](../Shared/StructuredLogPrivacy.swift),
  `SanitizedLineAccumulator` — redaction is already a code boundary.
- **Acceptance criteria:**
  - [ ] Exports: app/core versions, effective runtime YAML, all diagnosis verdicts, recent
        logs, helper/TUN/system-proxy state, network environment.
  - [ ] Every secret, subscription URL, credential, and SSID is redacted **before** anything
        is written to disk, enforced by tests over the writer, not the UI.
  - [ ] The user sees the exact contents before the file is written.
  - [ ] Referenced from `SECURITY.md` and the issue template.

#### A6 — Batch delay testing via `/group/{name}/delay`

**Status: shipped 2026-08-27. Transport measured 2026-08-29; the UI observations are still open.**

- **What the endpoint actually does**, probed against the bundled core v1.19.30: `GET
  /group/{name}/delay?url=&timeout=` returns a flat `[String: Int]` on 200, an unknown group
  is `404`, and — the load-bearing detail — **a node that failed its probe is silently
  omitted from the response rather than reported**. Absence is the failure signal, which is
  why the mapping back into per-node state has to be explicit rather than a dictionary
  lookup with a shrug.
- **Acceptance criteria:**
  - [x] Whole-group testing uses the group endpoint; per-node stays for single tests.
        `AppModel.proxyDelayBatchUnits(items:settings:)` promotes a group to one request only
        when it has a name, at least 8 members (one concurrency wave of 6 plus a margin), and
        every member shares one test URL; `.nativePing` never promotes, because that mode does
        not go through the core at all.
  - [x] **A group in flight costs the whole concurrency budget, and only a 404 degrades.**
        Both were wrong in the first cut, and both made A6 capable of producing a *larger*
        burst than the fan-out it replaced:
        - A group unit was charged one slot, like a node. But one group request makes the
          core probe every member at once — the measurement below resolves 1200 members
          inside a single timeout window, so there is no internal wave limit to hide behind.
          Six such units against a six-slot budget is several thousand simultaneous probes.
          `ProxyDelayBatchUnit.concurrencyCost(budget:)` now charges a group the entire
          budget, so at most one group's worth of probes is ever in flight, and the scheduler
          returns exactly what it charged rather than assuming every unit cost one.
        - *Any* error on the group request used to be read as "this core does not support the
          endpoint" and re-expanded into one request per member. A 500, a dropped connection
          or a client-side timeout would therefore answer one failed request with hundreds,
          at the moment the core is least able to serve them. Only
          `ClientError.unknownProxyGroup` — which the API client raises for the 404 that both
          "the group was renamed" and "this core is too old to route the endpoint" produce —
          degrades now. Everything else fails the unit and says why.
  - [x] **Unified Delay means one thing on both sides of the promotion floor.** It used to
        mean two: the per-node path sampled twice from this process and reported the second
        result, while a promoted group called the endpoint once, so the same switch changed
        the measurement at 7 nodes and did nothing at 8. Mihomo's own `unified-delay` is a
        config key, so ClashMax now writes it into the runtime YAML *and* applies it to a
        running core, and `DelayTestSettings.clientSideProbeAttempts` repeats the probe only
        in `.nativePing`, where the core is not involved at all. The Settings copy was
        rewritten to describe that split instead of promising a second sample everywhere; the
        old wording is the reason the divergence went unnoticed. As a side effect a failing
        node in `.mihomoURL` no longer waits out two timeouts.
  - [x] The batch status semantics established for issue #18 (running / completed / partial /
        failed / cancelled) are preserved exactly — a member the core omitted is recorded as
        `.failure(.timeout, …)`, so it counts as tested-and-failed, not as missing.
  - [x] **Measured on a group of 1000+ nodes, reproducibly.** Done 2026-08-29, against the
        bundled core v1.19.30 directly, by
        [`script/bench_group_delay.py`](../script/bench_group_delay.py) — committed, so the
        numbers below can be re-derived from a clone rather than taken on trust. The rig
        writes its own configs, starts two cores on loopback (nothing leaves the machine),
        measures, and tears them down. A 1200-member group (400 reachable, 400 instantly
        refused, 400 black-holed, 5000 ms timeout) takes **5.00 s** through
        `/group/{name}/delay` and **350.88 s** through the per-node fan-out at concurrency 6 —
        **70x, 346 seconds saved**. The group call
        collapses to exactly one timeout window, so the core imposes no smaller internal wave;
        that assumption is now measured rather than hoped for. It also reproduces the omission
        behaviour at scale: **800 of 1200 members came back missing rather than failed**,
        which is precisely why absence is mapped to `.failure(.timeout, …)` explicitly.
  - **Still unmeasured:** the same run *through the app's UI* — scroll smoothness during the
    batch, cancel semantics, every node ending with a state on screen, and the Copy
    Diagnostics counts. The transport is where the time goes and it is now a known quantity;
    the four UI observations still need a person at the keyboard.

---

### Track B — Native macOS Leverage

**Goal:** ship the things a native macOS client can do that a cross-platform Electron client
cannot copy cheaply.

#### B1 — Per-app routing with a real app picker

- **Problem:** the rule kinds exist; the affordance does not. This is the single largest
  gap between ClashMax and Surge.
- **Acceptance criteria:**
  - [ ] Picker lists installed applications with name, icon, and bundle identifier, and
        emits a correct `PROCESS-NAME` or `PROCESS-PATH` rule.
  - [ ] Reachable from two places: the Routing editor, and *"route this app through…"* on a
        Connections row (the icon and path are already there).
  - [ ] Emits an ordinary quick rule into an ordinary snippet (INV-1) — no new storage.
  - [ ] After applying, the existing post-apply verdict says which rule now wins.
  - [ ] Helper text states plainly when process rules cannot match (e.g. traffic arriving
        via the system proxy from a process the core cannot attribute).

#### B2 — Scenarios: generalize `NetworkPolicyRule`

- **Problem:** per-SSID policy can switch mode and system proxy, but not the profile or the
  active rule set — which is what "at home / at work / on a hotspot / travelling" actually
  needs. The trigger is also SSID-only, so Ethernet and cellular tethering are invisible.
- **Acceptance criteria:**
  - [ ] Triggers extend beyond SSID: interface type (Wi-Fi / Ethernet / cellular), a
        specific network, VPN present, and "no match" as an explicit fallback.
  - [ ] Actions extend to: select profile, enable/disable named snippets, select a proxy
        group node.
  - [ ] Exactly one scenario is active at a time, with deterministic precedence and a
        visible reason for the current match.
  - [ ] Migrating existing `NetworkPolicyRule` values preserves behavior, covered by
        decode tests over persisted fixtures.
  - [ ] Scenario switches are surfaced (menu bar / notification); a silent reconfiguration
        of someone's network is not acceptable.

#### B3 — App Intents and Shortcuts

- **Acceptance criteria:**
  - [ ] Intents for: set routing mode, select profile, select node in group, toggle system
        proxy, toggle TUN, activate scenario.
  - [ ] Each intent reports success or a specific failure; none silently no-op.
  - [ ] Intents that require the privileged helper fail with the same actionable guidance the
        UI gives, reusing `HelperSetupGuidance`.
  - [ ] Verified from Shortcuts.app by hand and recorded in `MANUAL_TEST_PLAN.md`.

#### B4 — Control Center widget

- **Acceptance criteria:**
  - [ ] Toggles routing mode and shows live state from outside the app.
  - [ ] Gated on the macOS version with a practical fallback below it, per the availability
        discipline in [`DEVELOPMENT.md`](DEVELOPMENT.md).
  - [ ] Does not become a second source of truth: state comes from the same store the app
        reads.

#### B5 — Geo database maintenance

**Status: shipped 2026-08-27.** Never seen by eye — see the gap below.

- **Problem:** `geox-url` / `geo-auto-update` / `geodata-mode` are recognized but
  unsupported, so geo rules drift. This is the only gap on the 3.2 list that **keeps getting
  worse while nothing happens**, and it was already happening: on the maintainer's own
  machine on 2026-08-27, `~/Library/Application Support/ClashMax/Runtime/` held a
  `GeoSite.dat` last written **Jun 20** and a `geoip.metadb` last written **May 4** — roughly
  two and four months of drift, with no surface anywhere in the app that said so.
- **Traps found while implementing this**, both verified against the bundled core v1.19.30:
  - A config **file** must spell the `geox-url` sub-keys `geoip` / `geosite` / `mmdb` / `asn`.
    `GET /configs` echoes them back as `geo-ip` / `geo-site`, and writing *those* spellings
    into the file is **silently ignored** — the core keeps its built-in URLs and nothing
    reports a problem.
  - `geodata-mode` decides which GeoIP file is even on disk: off means `geoip.metadb` from the
    `mmdb` source, on means `GeoIP.dat` from the `geoip` source. Staleness has to be measured
    against the file the current mode actually uses.
- **Acceptance criteria:**
  - [x] The three keys are app-managed and generated into the runtime YAML —
        `GeoDatabaseSettings` in [`CoreModels.swift`](../ClashMax/Models/CoreModels.swift),
        written by [`ConfigNormalizer`](../ClashMax/Services/ConfigNormalizer.swift).
  - [x] Manual refresh via `/configs/geo`, with the last-update time visible. The panel
        reports the age of the **oldest database the running rules actually reference**, not a
        remembered "last clicked" timestamp, so it stays honest across app restarts.
  - [x] A failed or partial download never leaves a broken database in place. This one is the
        core's doing, not ours, and it was checked rather than assumed: a failed refresh
        answers **`500` with a `{"message": …}` body** and leaves the existing files
        byte-identical. The message is surfaced verbatim — `ClientError.coreMessage` exists
        precisely so the core's own explanation is not flattened into "HTTP 500".
  - [x] Default URLs are documented and overridable at L3 (four MetaCubeX URLs, each
        replaceable, validated for scheme and emptiness before they can be saved).
  - [x] **Backup and restore carry them.** They persist under their own defaults key, and the
        first cut stopped there: `BackupSettingsSnapshot` had no geo field, so restoring a
        settings backup silently reset custom mirrors, the auto-update flag and the interval
        to ClashMax's defaults — the failure mode is a *quiet* one, which is the kind this
        project is supposed to be least tolerant of. The snapshot now carries
        `geoDatabaseSettings` and restore mirrors it back onto `overrides.geoDatabase`, the
        way the store already does on every other write. An older backup with no geo key
        decodes to the defaults instead of failing.
  - [x] **The diagnostics describe the settings the core applied, not the ones on disk.**
        When a runtime reload fails, ClashMax deliberately keeps the saved settings and says
        "saved, but could not be applied" — but the inventory read, the staleness verdict and
        the manual refresh all still read `geoDatabaseSettings`. Since `geodata-mode` decides
        whether the live GeoIP file is `GeoIP.dat` or `geoip.metadb`, that combination checked
        a file the core was not using and reported the age of the wrong one. All three now go
        through `runtimeGeoDatabaseSettings`, which is the applied snapshot while the core is
        running and the saved value otherwise.
- **The silent-no-op guard:** `/configs/geo` answers `204` for "downloaded four files" *and*
  for "did nothing at all", so the status code alone must never be reported as success. The
  working directory is stat'ed either side of the call and the outcome is described from what
  changed on disk: rewritten, already current (the core sends `If-None-Match`, so an unchanged
  remote produces a 304 and no write), or *refreshed nothing while a referenced database is
  still missing* — which is the real no-op, and is reported as one.
- **ClashX import — closed 2026-08-29.** The parser used to allow-list `geo-auto-update`,
  `geodata-mode` and `geox-url` and read none of them, so a migrating user kept their geo
  settings on paper and got ClashMax's defaults in practice. It now reads all four keys into
  `ClientMigrationReport.geoDatabase`, which the apply step hands to
  `updateGeoDatabaseSettings`. `geo-update-interval` was not even on the allow-list, so it was
  additionally reported as an unknown key; it is read now too.
  - Each field is validated **as it is read**, because `updateGeoDatabaseSettings` refuses an
    invalid struct *whole*: one bad `geox-url` entry would otherwise turn the entire import
    into a silent no-op sitting behind a report that said "imported". A rejected field keeps
    ClashMax's default and says why in the report warnings.
  - A config that names only some of the keys keeps ClashMax's defaults for the rest, rather
    than restating them as if the user had chosen them.
  - **Only the main config contributes** — `config.yaml`, or whichever of ClashX's known
    primary file names is present. The scan also sweeps `profiles/` and `providers/`, and
    `FileManager.enumerator` promises no order, so reading geo keys from every file and
    keeping the last one let an arbitrary inactive fragment decide which mirror ClashMax
    downloads from, non-deterministically, and then applied it without asking. A fragment that
    names the keys is now reported in the warnings — named, not silently obeyed and not
    silently dropped.
  - The `geo-ip` / `geo-site` spellings — what `GET /configs` echoes back, and what the core
    ignores without a word when a *file* uses them — are named as the mistake they are instead
    of being passed along.
- **Gap:** never seen by eye. The whole feature is a claim about what is on disk, and nobody
  has watched it make that claim in a running app.

---

### Track C — Subscription Trust

**Goal:** treat a subscription for what it is — **an executable configuration handed to you
by someone else** — and make that legible.

A subscription can change your DNS, open listeners, and rebind the external controller.
`ProviderOptionsRisk` already knows this; no client has taken it seriously as a feature.

#### C1 — Import-time subscription audit report

- **Foundation:** `ProviderOptionsRisk` in [`CoreModels.swift:805`](../ClashMax/Models/CoreModels.swift#L805).
- **Acceptance criteria:**
  - [ ] On import and on update, a plain-language report: what this subscription tried to
        change, what ClashMax overrode, and what it let through.
  - [ ] Severity is actionable — every `danger` item names the concrete consequence.
  - [ ] The report is reachable later from the profile, not only at import time.
  - [ ] Covers at minimum the existing danger key set plus `sniffer` (A1d).

#### C2 — Subscription update diff

- **Problem:** a subscription that was safe last week can quietly add a dangerous key on its
  next update. Nothing surfaces that today.
- **Acceptance criteria:**
  - [ ] Each update stores enough to diff against the previous fetch.
  - [ ] Node churn (added/removed/renamed) is summarized separately from **configuration**
        changes; only the latter can raise a risk.
  - [ ] A newly introduced danger key blocks silent auto-application and asks.
  - [ ] Diff storage is bounded and redacted like everything else.

#### C3 — Decide the `listeners` question

- **Problem:** `listeners` is currently stripped as a risk with no path forward, which is
  the right default and the wrong endpoint.
- **Acceptance criteria:**
  - [ ] A written decision in this document: supported at L3 with explicit user consent, or
        permanently unsupported with the reason stated.
  - [ ] If supported: LAN exposure is opt-in per listener, shown in the runtime diff, and
        never inherited from a subscription without a prompt.

---

### Track D — Engineering Sustainability

**Goal:** stop paying interest on every feature above. Not a standalone milestone — do this
interleaved with A/B/C, touching only what the current feature touches.

#### D1 — Decompose `AppModel`

- **Problem:** [`AppModel.swift`](../ClashMax/Stores/AppModel.swift) is **8845 lines**;
  [`SettingsView.swift`](../ClashMax/Views/SettingsView.swift) is **3085 lines**. Every
  feature in this roadmap pays a tax to land there.
- **Timing:** the Observation migration just completed, so the invalidation boundaries are
  currently well understood. That understanding decays.
- **Acceptance criteria:**
  - [ ] Split by domain — runtime, routing, profiles, diagnostics — behind the same public
        surface views already consume.
  - [ ] No behavior change: the full suite passes at the current baseline with no new
        skips.
  - [ ] Done incrementally, one domain per change, each independently revertible.
  - [ ] The Observation-migration hazards stay respected: `didSet` does not fire in `init`
        (priming hooks must move with their properties), and structural dedup guards are
        load-bearing.

#### D2 — Automate Mihomo upgrade regression

- **Problem:** validating a core bump across templates and modes is manual today.
- **Acceptance criteria:**
  - [ ] A script runs `mihomo -t` over every generated template × routing mode ×
        DNS-override combination and fails with the `level=error msg=` line, not the
        generic trailer.
  - [ ] Runs in CI against the bundled core.
  - [ ] A new core version that breaks any combination fails the build rather than shipping.

#### D3 — Close the manual-verification gap

- **Problem:** a recurring pattern in this project's history is *"tests pass, never seen by
  eye"*. Several completed features carry that note.
- **Acceptance criteria:**
  - [ ] `MANUAL_TEST_PLAN.md` gains a per-release checklist for the flows automation cannot
        reach: menu bar panel, TUN approval, scenario switching, Shortcuts, the app picker.
  - [ ] Each roadmap item above is marked done only when its manual line item is signed off.

---

## 5. Sequencing

Deliberately conservative — one track at a time, with D interleaved.

| Horizon | Content | Why this order |
| --- | --- | --- |
| **First** | **A1a** | A decoder fix with no UI, and a hard prerequisite: until the connections decoder stops collapsing "no domain" into "the destination IP", the diagnosis in A1c is not computable. Ships on its own, in a day. |
| **Then** | **A1b + A1c + A1d** | The highest-priority item in this document, and the smallest closed loop that validates the whole thesis: a real kernel gap, a real diagnostic gap, one fix button, no new UI paradigm. If the three-layer model is wrong, this is where it shows cheaply. |
| **Then** | A2 | The other half of the routing story. Do it after A1 so the domain shown in the DNS panel and the domain the rules actually matched on are known to be the same value. |
| **Then** | ~~A3~~, A5, C1 | Low-risk, high-leverage. A5 and C1 both reduce maintainer load directly; C1 absorbs A1d. **A3 shipped 2026-08-27** alongside B5. |
| **Then** | B1, A4 | B1 is the headline user-facing feature; A4 is the screen that makes the moat obvious. Do B1 after A1 so process rules are not the second thing to fail on domainless connections. |
| **Then** | B2, C2 | Both are stateful and need the earlier work to be trustworthy first. |
| **Later** | B3, B4, ~~B5~~, ~~A6~~, C3 | Valuable, not load-bearing. **B5 and A6 were pulled forward and shipped 2026-08-27.** B5 because it was the one item on this list that degrades while nothing happens — and it had already been degrading for four months on the maintainer's own machine, which "not load-bearing" failed to predict. A6 because the #10 / #11 / #18 jank series all originate in the per-node fan-out it removes. |
| **Throughout** | D1, D2, D3 | Never a milestone of its own. |

---

## 6. Non-Goals

Stated so they do not get relitigated:

- **Feature parity with Clash Verge Rev / mihomo-party.** Switch count is not the axis
  ClashMax competes on.
- **A toggle for every Mihomo key.** Per INV-2, generic override is the answer.
- **Telemetry or accounts.** Unchanged from the MVP scope in
  [`DEVELOPMENT.md`](DEVELOPMENT.md).
- **Node collection, node sales, or an embedded Sub-Store.**
- **Any runtime AI feature.** Consistent with
  [`CODEX_OSS_PLAN.md`](CODEX_OSS_PLAN.md): tooling for maintaining the repository, never a
  feature in the shipped app.
- **Windows or Linux.** The entire Track B thesis is that being native to one platform is
  the advantage.

---

## 7. Changing This Document

- The **principles in §2 are normative.** Changing them requires a written reason here, not
  a one-off exception in a pull request.
- The **gaps in §3 are dated claims.** Re-verify before citing them; they are true as of
  2026-08-14.
- The **tracks in §4 are a queue, not a contract.** Reorder freely; do not silently drop an
  item — move it to §6 with a reason.
