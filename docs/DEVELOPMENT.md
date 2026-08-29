# ClashMax Development Guide

This document contains project-level development rules that should travel with
the repository. Local agent files such as `AGENTS.md` may add workstation-
specific context, but they must not be the only place where stable project
discipline is recorded.

## Product Direction

- Build ClashMax as a native macOS 15+ SwiftUI app. Keep the UI aligned with
  the current Apple platform visual language, but gate newer platform APIs with
  availability checks and practical fallbacks when they are above the deployment
  target.
- Keep the first screen as the actual proxy client, not a marketing page.
- Prioritize a quiet operational interface for profiles, proxy groups,
  connections, rules, logs, runtime settings, and menu bar controls.
- Use native SwiftUI first, bridge to AppKit only for integration gaps, and use
  SF Symbols for controls where possible.

## MVP Scope

- Preserve imported YAML profiles unchanged.
- Generate a ClashMax-managed runtime YAML before launching Mihomo.
- Bind Mihomo's controller to `127.0.0.1`.
- Generate a per-run controller secret and always use Bearer authentication.
- Let the user-mode core own normal system proxy behavior.
- Let the privileged helper own TUN mode behavior.
- Do not add Linux-only `auto-redirect` to macOS TUN runtime config.
- Keep telemetry, accounts, node collection, subscription analytics, embedded
  Sub-Store, and Sparkle outside the MVP baseline unless the MVP scope is
  explicitly expanded.

## Security, Signing, And Licensing

- ClashMax is intended to stay GPL-3.0-compatible because it distributes or
  controls Mihomo.
- Do not copy code, assets, or UI from proprietary projects.
- Treat `666OS/ClashMac` as product inspiration only.
- Code from GPL projects such as Clash Verge Rev may be adapted only when
  license notices and attribution remain correct.
- Prefer reimplementing behavior in Swift instead of copying Rust or
  TypeScript from other projects.
- Helper and XPC code must validate app-provided paths.
- Helper and XPC code must not use shell interpolation for app-provided paths.
- Local test verification may disable signing with `CODE_SIGNING_ALLOWED=NO`.
  Packaging, helper, entitlement, or notarization changes still require the
  appropriate signed-release verification before shipping.
- The `NE Proxy` routing mode uses a macOS System Extension containing a
  transparent app-proxy provider and requires Developer ID signing with Network
  Extension, System Extension, and App Group capabilities before it can run on a
  real machine.
- The current Network Extension stage targets TCP and UDP transparent proxying:
  system TCP flows use SOCKS5 CONNECT and UDP flows, including UDP DNS flows,
  use SOCKS5 UDP ASSOCIATE through the local Mihomo SOCKS5/mixed port. NE mode
  also generates app-managed Mihomo DNS on `127.0.0.1:1053`, captures TCP/UDP
  port 53 flows to that listener, and can temporarily apply `114.114.114.114`
  as the active macOS service DNS with snapshot/restore protection.

## Build And Verification

The Xcode project is generated from `project.yml` with XcodeGen:

```bash
xcodegen generate
```

Main verification command:

```bash
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

### Code Formatting

Formatting is enforced by [SwiftFormat](https://github.com/nicklockwood/SwiftFormat).
The pinned version lives in one place — the `--minversion` line in
`.swiftformat` — and CI asserts that the version it installs matches it.

The gate requires that exact version, not merely a new enough one. `.swiftformat`
opts rules *out* with `--disable` instead of listing the set it wants with
`--rules`, so a rule a later release adds and enables by default would apply here
too: formatting with a newer build produces a diff that CI, pinned to the older
one, rejects. `brew install swiftformat` tracks latest, so once Homebrew moves
past the pin, install the pinned release directly or point `SWIFTFORMAT` at it —
the script's error message carries the download link. Moving the pin means
bumping `.swiftformat` and `.github/workflows/ci.yml` together and reformatting
the tree with the new build in that same commit.

```bash
brew install swiftformat
script/swiftformat_lint.sh          # check the files this change touches
script/swiftformat_lint.sh --fix    # format exactly that set
script/swiftformat_lint.sh --all --summary   # remaining debt, per rule
```

Adoption is deliberately two-step. The tree reached ~100k lines of Swift with no
formatter at all, so a repo-wide gate would have been red on arrival and a
single reformat commit would have collided with whatever was in flight.

- **Step 1 (in place).** The gate checks only files the change under review
  touches, so the tree converges as it is edited. A file nobody has touched is
  allowed to be unformatted. The `hygiene` CI job runs this on every push and
  pull request, and separately prints the whole-tree violation count without
  failing on it, so the remaining debt is visible as it shrinks.
- **Step 2 (later).** One mechanical commit that formats the remainder, taken at
  a quiet point with nothing else in flight, and skipped afterwards with
  `git blame --ignore-rev`. It is *not* a whitespace-only diff — `trailingCommas`,
  `hoistTry`, `redundantSelf` and `sortImports` move tokens, and `git diff -w`
  only shrinks it by a tenth — so review it by confirming the formatter is
  idempotent and the suite is green, not by reading every line:

  ```bash
  git status --porcelain          # must be empty; this commit carries nothing else
  script/swiftformat_lint.sh --all --fix
  xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
  script/localization_gate.sh     # multiline literals move; the keys must not
  git commit -am "Format the tree with SwiftFormat"
  git rev-parse HEAD >> .git-blame-ignore-revs
  git config blame.ignoreRevsFile .git-blame-ignore-revs
  ```

  Build it, do not just lint it. `--lint` clean does not mean it compiles:
  `redundantSelf` strips `self.` from inside `os.Logger` interpolations, where
  the compiler requires it because the interpolation appenders are `@escaping`
  autoclosures. That is what `--self-required` in `.swiftformat` is for, and it
  was found by building, not by linting.

  The localization gate is not optional either: `String(localized:)` multiline
  literals get re-indented, and a literal whose *value* changed would silently
  orphan its catalog key.

`.swiftformat` is not the SwiftFormat defaults. Two things shaped it:

- Options describe the style the codebase already had, measured rather than
  guessed — 2-space indent (298 offending lines, against 86,990 at 4), unspaced
  ranges (`0..<n`, 361 against 19), lowercase hex, and preserved digit grouping.
  Adopting the formatter is a normalization pass, not a restyle.
- Disabled rules follow one line: the formatter normalizes mechanical syntax
  (whitespace, indentation, ordering, redundant tokens, trailing commas) and
  does not restructure or delete code someone wrote deliberately. That rules out
  rewriting `if`/`else` assignments into `if` expressions, expanding one-line
  bodies such as `var id: String { rawValue }`, promoting explanatory comments to
  `///`, deleting hand-written memberwise initializers, removing SwiftUI `Group`
  wrappers (which changes view identity), and rewriting force-unwraps in tests.
  Each disabled rule carries its reason in the file.

`project.yml` sets `indentWidth: 2` / `tabWidth: 2` / `usesTabs: false`, so the
generated project tells Xcode's editor the same thing `.swiftformat` tells the
formatter and code typed in Xcode is born formatted. Those land on the project's
main group rather than on any build setting, so they do not move the semantic
snapshot `script/guarded_xcodebuild.sh` compares against.

Localization release gate:

```bash
script/localization_gate.sh
```

Run this before shipping and after touching user-visible strings. The gate
validates `Resources/Localizable.xcstrings`, dry-runs catalog compilation, runs
the new-key translation check below, and runs `LocalizationTests`, including the
active-key stale check.

Run it again *after* the Xcode archive and before notarizing or publishing.
Archiving re-extracts the catalog, so it adds untranslated keys to a build that
was already green: 1.0.22 gained 49 that way, and 1.0.23 gained `"sniffer"` and
`"Sniffer Patch"` — late enough that the translations could only ride the next
release.

New keys must ship a Simplified Chinese translation:

```bash
script/localization_new_key_gate.sh
```

Every key without a `zh-Hans` value has to be listed in
`script/localization_untranslated_allowlist.txt`, which snapshots the debt that
already existed; anything else fails. This is the check that would have caught
1.0.22, where archiving in Xcode re-extracted the catalog and added 49
untranslated Quick Rules keys. Keys that get translated must leave the list —
prune it with `--write-allowlist`. It runs in the `hygiene` CI job, so it does
not need Xcode; `script/test_localization_new_key_gate.sh` covers the gate
itself.

Release smoke gate:

```bash
script/release_smoke_check.sh \
  --app /Applications/ClashMax.app \
  --appcast docs/appcast.xml \
  --sparkle-dir dist/sparkle \
  --dmg dist/dmg/ClashMax-X.Y.Z.dmg \
  --report-dir dist/release-smoke \
  --preflight-only
```

For RC builds, use `--live --soak-minutes 60` after installing the signed,
notarized app in `/Applications`. The script records app, helper, Network
Extension, DNS, route, non-proxy curl, subscription-pool, soak, and sleep/wake
evidence under `dist/release-smoke`.

Run command:

```bash
./script/build_and_run.sh
```

Delay-transport benchmark (roadmap A6 — group endpoint vs per-node fan-out):

```bash
script/bench_group_delay.py
```

Needs the bundled core (`script/install_mihomo_core.sh`) or `--core PATH`. It
generates its own configs, starts two cores on loopback, measures, and tears them
down; `--nodes`, `--concurrency`, `--timeout-ms` and `--keep` are available. The
recorded run is in `docs/ROADMAP.md` under A6.

Network Extension signed-build checks are covered by `script/release_smoke_check.sh`.
For local diagnosis, these commands remain useful:

```bash
codesign -dvvv --entitlements :- /path/to/ClashMax.app
codesign -dvvv --entitlements :- /path/to/ClashMax.app/Contents/Library/SystemExtensions/io.github.clashmax.ClashMax.NetworkExtension.systemextension
spctl --assess --type execute --verbose /path/to/ClashMax.app
systemextensionsctl list
```

Real-device Network Extension validation must use an app bundle installed in
`/Applications`, then approve the System Extension in System Settings and
confirm `systemextensionsctl list` reports it as activated and enabled.
If `nesessionmanager` reports `The VPN app used by the VPN configuration is not
installed` or `Plugin was disabled` after installing a signed build, verify that
LaunchServices sees the installed bundle:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | rg -n "path: +/Applications/ClashMax.app" -C 20
```

ClashMax refreshes the `/Applications/ClashMax.app` LaunchServices registration
before installing or starting the NE transparent proxy, using:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R /Applications/ClashMax.app
```

Manual installed-bundle NE smoke test, recorded through `script/release_smoke_check.sh --live --soak-minutes 60`:

1. Build a signed app, copy it to `/Applications/ClashMax.app`, then approve the
   System Extension in System Settings.
2. Select `NE Proxy`.
3. Start ClashMax and confirm the dashboard shows NE connected, DNS capture
   enabled, DNS runtime as fake-ip, and System DNS as applied.
4. Verify TCP traffic through a browser or `curl`, then verify UDP traffic with a
   UDP-capable endpoint such as QUIC/HTTP3 or a DNS UDP probe.
5. Verify DNS capture by checking that DNS requests reach Mihomo DNS and fake-ip
   answers are returned for matching domains.
6. Stop ClashMax and confirm Transparent Proxy becomes inactive, Mihomo stops
   only after NE shutdown, and System DNS returns to the pre-start snapshot. Use
   the `Repair DNS` action if restore reports a failure.

Manual installed-bundle TUN validation matrix, recorded through `script/release_smoke_check.sh --live --soak-minutes 60`:

Use this matrix for real macOS data-plane validation. Unit tests can prove
runtime YAML, helper/XPC state, and repair semantics, but they cannot prove
kernel routing, DNS service order, sleep/wake behavior, or UDP behavior on a
real machine.

1. Build a signed app, install it as `/Applications/ClashMax.app`, and launch
   that installed bundle rather than an Xcode-run bundle.
2. Select TUN mode and start ClashMax. On first run, approve the privileged
   helper in System Settings if macOS prompts for it, then retry start.
3. Quit and relaunch ClashMax, keep the same installed app, and confirm helper
   status is reused without another approval prompt. The Settings helper detail
   should show the helper as enabled, bootstrapped, protocol-compatible, and
   fingerprint-matched.
4. Start, stop, and restart TUN mode several times. Confirm Mihomo starts under
   the helper, the dashboard reaches running state, stop clears TUN diagnostics,
   and System DNS restores to the pre-start snapshot.
5. Put the Mac to sleep, wake it, and verify ClashMax either remains connected
   or reports an actionable TUN/DNS repair state. Re-run diagnostics after wake.
6. Switch networks, for example Wi-Fi to Ethernet or hotspot and back. Confirm
   default-route, route-exclude, DNS hijack, and System DNS diagnostics still
   match the active service after the network change.
7. Verify browser traffic and non-browser traffic. Use both a browser request
   and a command-line request that does not rely on the macOS HTTP proxy, such
   as `curl --proxy "" https://example.com`.
8. Verify UDP and QUIC traffic with an endpoint that actually uses UDP, such as
   HTTP/3/QUIC or another UDP probe routed through Mihomo.
9. Verify DNS leak behavior. Check that DNS queries use the ClashMax/Mihomo DNS
   path, fake-ip answers are returned for matching domains when fake-ip is
   enabled, and external resolvers are not used unexpectedly.
10. Verify route exclusions. Add a known CIDR to route-exclude, restart or apply
    TUN settings, and confirm traffic to that CIDR bypasses TUN while normal
    traffic remains captured.
11. Verify online TUN setting changes. Change DNS hijack, route-exclude, or
    MTU while TUN is running; ClashMax should reload config, inspect runtime
    facts, fall back to helper restart if diagnostics still warn, and surface a
    clear error if the runtime state still does not match.
12. Verify repair-failure safety semantics. Simulate or force a repair failure
    where route diagnostics still warn after reload and helper restart. `Repair
    Routing` must stop TUN safely, clear diagnostics, mark the runtime stopped,
    and preserve the failed diagnostic in the final user-facing error.

Before claiming progress, run the narrowest command that proves the claim and
report the actual result. If new Swift files are added or project membership is
changed, regenerate the Xcode project before trusting build results.

## UI Constraints

- Keep dashboards dense, calm, and quick to scan.
- Avoid decorative hero sections, nested cards, oversized type inside compact
  panels, and one-hue palettes.
- Prefer tables, lists, split views, segmented controls, toggles, menus, and
  icon buttons for operational workflows.
- Make runtime state explicit: stopped, starting, running, crashed, TUN helper
  unavailable, no profile, no core binary, and validation failed.
- Do not hide security-sensitive details behind vague copy.
- Show actionable recovery messages when user action is required.
- Loading skeletons must use the shared SwiftUI-Shimmer primitives, not ad hoc
  shimmer calls. Use skeletons only for temporary async runtime/network loading;
  never replace stopped, empty, failed, security-sensitive, or recovery states
  with skeleton placeholders.
