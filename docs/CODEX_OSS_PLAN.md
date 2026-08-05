# Codex Open-Source Maintenance Plan

**Status:** published 2026-08-05 · six-month window 2026-08-05 → 2027-02-05 · maintainer
[@marvinli001](https://github.com/marvinli001)

This is the public, checkable version of ClashMax's plan for using OpenAI API credits. It
describes an **open-source, human-reviewed maintenance and security workflow built around
Codex CLI and OpenAI models — not an end-user chatbot**. Nothing in ClashMax calls an
OpenAI API at runtime, and nothing in this plan adds an AI feature to the shipped app.
The credits fund maintenance of the repository itself.

## How To Verify This Document

Everything below is written against things you can open right now:

| Claim | Where to check |
| --- | --- |
| The project is real and actively maintained | `git log`, [releases](https://github.com/marvinli001/ClashMax/releases) |
| It has a substantial test suite | `ClashMaxTests/` — 36 files, ~35k lines, **986 XCTest cases** |
| Tests actually run in public CI | [`.github/workflows/ci.yml`](../.github/workflows/ci.yml), Actions tab |
| Release gates already exist | [`script/localization_gate.sh`](../script/localization_gate.sh), [`script/release_smoke_check.sh`](../script/release_smoke_check.sh), [`script/tun_smoke_check.sh`](../script/tun_smoke_check.sh) |
| Redaction is a real code boundary, not a promise | [`Shared/StructuredLogPrivacy.swift`](../Shared/StructuredLogPrivacy.swift) |
| Privilege boundaries exist and are tested | `ClashMaxHelper/main.swift`, `Shared/HelperProtocol.swift`, `ClashMaxTests/TunnelHelperValidationTests.swift` |
| Security reporting rules match this plan | [`SECURITY.md`](../SECURITY.md) |

Scale of the codebase the workflow has to reason about, as of 2026-08-05: 81 Swift source
files and ~58k lines across the app, the privileged helper, the Network Extension, and
shared code; 986 tests; 1,173 localized string keys in `en` and `zh-Hans`.

## Why This Codebase Is A Useful Testbed

ClashMax is a native macOS SwiftUI Mihomo proxy client. It is unusually rich in the
failure classes that are hard for automation and hard for a solo maintainer:

- SwiftUI state management (`@Observable`, snapshot lifetimes, main-actor isolation)
- YAML profile normalization and app-managed runtime config generation
- Mihomo REST and WebSocket control APIs
- A root LaunchDaemon helper reached over XPC
- TUN mode: routes, interfaces, teardown, restoration
- A Network Extension transparent proxy: SOCKS5 CONNECT / UDP ASSOCIATE, DNS capture
- DNS snapshot and restore
- Developer ID signing, entitlements, notarization, Sparkle updates
- Sleep/wake and network-change behavior

Every one of those crosses a privilege, privacy, or release boundary, which is exactly
where "the model wrote a plausible patch" is not good enough and a gated, human-reviewed
workflow earns its keep.

## Workstream 1 — Issue To Regression Pipeline

**Allocation: 45% of credits.**

A pipeline that turns a report into a failing test before it turns it into a patch.

1. **Intake.** Accepts only two kinds of input: (a) synthetic reports and fixtures written
   by the maintainer, and (b) GitHub reports and diagnostic bundles that a user explicitly
   submitted, already redacted. Nothing is scraped, and no private data is ingested — see
   [Privacy Red Lines](#privacy-red-lines).
2. **Classification.** Label the failure against the surfaces listed above (SwiftUI state,
   YAML normalization, Mihomo REST/WebSocket, XPC helper, TUN, Network Extension, DNS,
   signing, updates, sleep/wake), with a confidence score and the evidence used.
3. **Localization of the fault.** Identify likely code paths and name the specific files
   and functions, with reasons.
4. **Failing test first.** Draft a minimal XCTest that fails for the reported reason. If
   no failing test can be produced, the issue does not proceed to a patch; it goes back to
   triage as "not reproduced", which is itself a useful, recorded outcome.
5. **Narrow patch.** Propose the smallest change that turns the test green, plus a written
   rationale of what it deliberately does not change.
6. **Gates.** The full test suite, the localization gate, and — for release-sensitive
   surfaces — the release smoke gate must pass. A maintainer reads the diff and the
   reasoning before anything merges.

## Workstream 2 — Security And Privacy Review

**Allocation: 30% of credits.**

OpenAI models assist review of changes that cross a privilege or privacy boundary. The
review targets are concrete, not generic "look for bugs":

| Boundary | What the review looks for |
| --- | --- |
| Command invocation | Argument construction, no shell interpolation of app-provided values, timeouts, output handling |
| Path validation | Allowed roots for core binary, runtime config, and work directory; symlink and TOCTOU handling |
| XPC message handling | Client code-signing requirement and policy checks, interface surface, input validation |
| Keychain storage | Item classes, accessibility, scoping of subscription credentials |
| Controller authentication | `127.0.0.1` binding, per-launch secret, Bearer handling, secret leakage paths |
| Log redaction | New log sites that bypass `StructuredLogPrivacy`, and rules that under-redact |
| Entitlements | Diffs to app, helper, and Network Extension entitlements and hardened runtime |
| Helper packaging | LaunchDaemon plist, registration, embedded helper location and permissions |
| Release artifacts | Signing, notarization, appcast and Sparkle signature handling |

Model output here is advisory. It is accepted only after a human review and only after the
repository's tests, localization checks, and release-smoke gates pass.

## Workstream 3 — Maintainer Automation

**Allocation: 15% of credits.**

- Pull-request risk summaries: which boundaries a diff touches and what verification it
  therefore needs.
- Missing-test detection: changed behavior with no corresponding test.
- Issue triage: duplicate detection, missing-information prompts, surface labeling.
- Bilingual (English / 简体中文) issue and pull-request summaries — the user base is
  substantially Chinese-speaking and the repository is bilingual.
- Release notes, migration documentation, and contributor guidance.

**Allocation: 10% of credits** covers documentation and localization upkeep, including the
1,173-key string catalog and the two READMEs.

## Human Review Is Not Optional

- No model output merges without a maintainer reading the diff and the reasoning.
- Every change goes through public CI: `xcodebuild test`, the localization gate, and an
  unsigned Release build with a bundle-layout check.
- Release-sensitive changes (signing, entitlements, helper packaging, Network Extension,
  update metadata) additionally require the release smoke gate on a signed, notarized
  build installed in `/Applications`. That gate runs on the maintainer's machine because
  it needs Developer ID assets, and its report is what authorizes a release.
- Model-assisted commits are marked as such in the commit trailer, so the public history
  shows what was assisted and what was not.

## Privacy Red Lines

These are absolute. Credits will **never** be used to upload, and the workflow will never
ingest:

- Private or personal profile files
- Subscription URLs, including short links and any token-bearing URL
- Credentials of any kind: node passwords, UUIDs, pre-shared keys, API keys, controller
  secrets, signing keys
- Private domains, internal hostnames, or rule sets that expose a private network
- Personal network details: public IPs, Wi-Fi SSIDs, MAC addresses, provider account
  identifiers
- User traffic, connection contents, or connection metadata from real users

Operating rules that back those lines:

1. **Synthetic by default.** Evaluation fixtures are generated, not collected. Where a real
   report is needed, it is used only with the reporter's explicit submission, already
   redacted, and it is redacted again before use.
2. **Redaction reuses shipped code.** Fixture sanitization runs through the same rules as
   `Shared/StructuredLogPrivacy.swift`, so the sanitizer and the app's log boundary cannot
   drift apart. Redaction is idempotent by design and is itself under test.
3. **Leak testing is a metric, not a hope.** Every published fixture is scanned for
   credential and URL patterns before publication, and the leak rate is reported (see
   [Metrics](#metrics)). The target is zero, and a non-zero result is published rather
   than quietly fixed.
4. **CI enforces part of it mechanically.** The `hygiene` job in
   [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) fails the build if a private
   key block is committed.
5. **The same rules bind reporters.** [`SECURITY.md`](../SECURITY.md) states what must
   never appear in a public issue: subscription URLs, credentials, private domains, and
   personal network details.

## What Gets Published

The work product is public, not just the outcome. Planned paths in this repository:

| Path | Contents |
| --- | --- |
| `docs/codex/prompts/` | The prompts used for triage, test drafting, and security review |
| `docs/codex/acceptance/` | Acceptance criteria each generated artifact must meet before a human spends time on it |
| `docs/codex/redaction/` | Redaction rules and the sanitizer used on fixtures |
| `docs/codex/fixtures/` | Sanitized evaluation fixtures — synthetic reports, diagnostic bundles, config fragments |
| `docs/codex/eval/` | Evaluation scripts that score triage and patch runs against the fixtures |
| `docs/codex/metrics/` | Periodic metric reports, including API cost |
| `docs/codex/workflows/` | Reusable Codex CLI workflows other Swift/macOS maintainers can adopt |

Everything published stays under the repository's GPL-3.0 license.

## Metrics

Reported monthly under `docs/codex/metrics/`, with the raw evaluation output alongside the
summary. Definitions are fixed up front so the numbers cannot be redefined into looking
good:

| Metric | Definition | Target |
| --- | --- | --- |
| Triage accuracy | Share of classified reports whose surface label and named code paths the maintainer confirms, over the fixture set and over real issues | ≥ 80% surface label, ≥ 60% code path |
| Privacy leakage | Credential, subscription-URL, private-domain, or personal-network patterns found by the scanner in any published fixture or prompt | 0, always |
| Test reproducibility | Share of generated failing tests that fail before the patch and pass after, and stay deterministic over 50 consecutive runs | ≥ 90% |
| Patch acceptance | Share of proposed patches merged with no more than minor edits | ≥ 50% |
| Regression rate | Share of merged model-assisted patches later reverted or followed by a fix for the same behavior, within 60 days | ≤ 10% |
| Median triage time | Wall-clock median from issue opened to a labeled, reproduced, actionable state | −50% vs. the month-1 baseline |
| API cost | Spend per accepted patch and per triaged issue, by workstream | published, no target |

The median-triage-time baseline is measured during month 1 and published before any
reduction is claimed. A target that is missed gets reported as missed.

## Six-Month Targets

| Milestone | By | Deliverable |
| --- | --- | --- |
| M1 | 2026-09 | Public CI green on every PR; triage-time baseline measured; redaction rules and first synthetic fixture set published |
| M2 | 2026-10 | Issue-to-failing-test pipeline running end to end on fixtures; first metrics report |
| M3 | 2026-11 | Security-review workflow applied to every boundary-crossing PR; acceptance criteria published |
| M4 | 2026-12 | PR risk summaries, missing-test detection, and bilingual summaries in routine use |
| M5 | 2027-01 | Reusable Codex workflows published for other Swift/macOS maintainers |
| M6 | 2027-02 | Final metrics report against every target below |

Window targets:

- **20–30 confirmed issues resolved** through the pipeline.
- **At least 100 regression tests added**, on top of the 986 that exist today.
- **Median maintainer triage time reduced by 50%** against the published month-1 baseline.
- **Reusable Codex workflows published** for other Swift and macOS open-source
  maintainers.

## Budget Allocation

| Share | Workstream |
| --- | --- |
| 45% | Issue-to-test and patch workflows |
| 30% | Security review and evaluations |
| 15% | Pull-request and release automation |
| 10% | Documentation and localization |

Actual spend is reported against this split in the monthly metrics, including where it
diverged and why.

## Non-Goals

- No AI features in the shipped app. ClashMax does not call an OpenAI API at runtime.
- No end-user chatbot, and no support bot answering users on the maintainer's behalf.
- No automatic merging. Every change is read by a human.
- No ingestion of user traffic, private profiles, or telemetry — ClashMax collects none,
  and this work does not create a reason to start.
- No use of credits to generate marketing content or inflate contribution counts.

## Current Status

Honest baseline as of 2026-08-05, so progress can be measured rather than asserted:

| Item | State |
| --- | --- |
| Public CI (tests, localization gate, Release build) | **Added 2026-08-05** — first public CI in the repository |
| Security policy with reporting channel and scope | **Added 2026-08-05** |
| Log redaction boundary in shipped code | **Exists** — `Shared/StructuredLogPrivacy.swift` |
| Localization, TUN, and release smoke gates | **Exist** — under `script/` |
| Issue-to-regression pipeline | **Not started** — Workstream 1 |
| Published prompts, fixtures, eval scripts, metrics | **Not started** — `docs/codex/` is empty until M1 |

If this plan is funded, this table is what gets updated first.
