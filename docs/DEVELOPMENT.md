# ClashMax Development Guide

This document contains project-level development rules that should travel with
the repository. Local agent files such as `AGENTS.md` may add workstation-
specific context, but they must not be the only place where stable project
discipline is recorded.

## Product Direction

- Build ClashMax as a native macOS 26+ SwiftUI app.
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
- The `NE Transparent Proxy Experimental` routing mode is Developer Mode only.
  It uses a macOS System Extension containing a transparent app-proxy provider and requires
  Developer ID signing with Network Extension, System Extension, and App Group
  capabilities before it can run on a real machine.
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

Run command:

```bash
./script/build_and_run.sh
```

Network Extension signed-build checks:

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

Manual installed-bundle NE smoke test:

1. Build a signed app, copy it to `/Applications/ClashMax.app`, then approve the
   System Extension in System Settings.
2. Enable Developer Mode and select `Network Extension Experimental`.
3. Start ClashMax and confirm the dashboard shows NE connected, DNS capture
   enabled, DNS runtime as fake-ip, and System DNS as applied.
4. Verify TCP traffic through a browser or `curl`, then verify UDP traffic with a
   UDP-capable endpoint such as QUIC/HTTP3 or a DNS UDP probe.
5. Verify DNS capture by checking that DNS requests reach Mihomo DNS and fake-ip
   answers are returned for matching domains.
6. Stop ClashMax and confirm Transparent Proxy becomes inactive, Mihomo stops
   only after NE shutdown, and System DNS returns to the pre-start snapshot. Use
   the `Repair DNS` action if restore reports a failure.

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
