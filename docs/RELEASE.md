# ClashMax Release Verification

Use this guide for signed-bundle and release acceptance. Source setup/checks live in the
[development guide](DEVELOPMENT.md); feature observations and per-version sign-off live in
[the manual plan](MANUAL_TEST_PLAN.md). A source-test pass alone does not establish release readiness.

Publication, remote pushes, signed-app replacement and live system changes each need
authorization covering the action and target. The steps below document the workflow;
reading or editing this guide does not authorize running it. The user performs macOS
administrator and System Extension approvals. Preserve their signing/profile/capability setup.

## Source And Artifact Preparation

1. Run the checks appropriate to the source change. Use the full suite for the release gate,
   plus the bundled-core matrix and architecture checks. Preserve logs and `.xcresult`.
2. Archive/export with the existing authorized signing setup. Run the localization gate
   again after archive, before notarization/publication; archive may extract new strings.
3. Verify the exported app, nested Mihomo core, Helper, Sparkle components and NE signatures,
   notarization and bundle layout. The bundle must not carry Intel-only Mach-O components;
   see the [core packaging policy](../Resources/Core/README.md).
4. Package the exported app:

   ```bash
   script/package_sparkle_update.sh /path/to/ClashMax.app dist/sparkle
   script/package_dmg.sh /path/to/ClashMax.app dist/dmg
   ```

   The DMG is the installer. The zip and optional deltas are Sparkle update assets;
   do not put the DMG in the appcast input directory.
5. Verify the app extracted from the zip. For live acceptance, install that same signed,
   notarized bundle as `/Applications/ClashMax.app` when installation is authorized.
   A DerivedData/Xcode-run or ad-hoc-signed bundle cannot prove installed Helper/NE behavior.

## Scripted Release Entry Point

```bash
script/release_smoke_check.sh \
  --app /Applications/ClashMax.app \
  --appcast docs/appcast.xml \
  --sparkle-dir dist/sparkle \
  --dmg dist/dmg/ClashMax-X.Y.Z.dmg \
  --report-dir dist/release-smoke \
  --preflight-only
```

Preflight checks artifacts, signatures/notarization, core, zip, DMG and appcast. It also
inspects the installed app's subscription pool and fetches subscriptions using locally
stored secrets; it is not just a file-layout check. Keep URLs/tokens and private profile
contents out of shared output. An empty or failing real subscription pool is a release
blocker; `--allow-empty-subscriptions` is for non-RC checks only.

For an authorized live RC run, use the same arguments with `--live --soak-minutes 60` in
place of `--preflight-only`. The script records app, Helper, Network Extension, DNS, routes,
non-system-proxy traffic, subscription-pool, soak and sleep/wake evidence under
`dist/release-smoke`. Inspect the generated summary rather than treating script invocation
as a pass. A skipped sleep/wake gate remains a release-blocking gap.

If the next appcast item has not yet been prepared, its latest-item check can be temporarily
unmatched during preparation. Re-run preflight against the final staged appcast and
artifacts before publication; no unmatched latest item is a final pass.

## Live Baseline And Cleanup

Before changing the installed app, runtime or network, record:

- Existing ClashMax/Mihomo/Helper/NE processes and listeners, including their owners.
- Active network services, system proxies, DNS and default route.
- Helper/NE approval state, selected profile, routing mode and whether the runtime was running.

Run only the authorized live matrix. Restore changes made by the test, including test
rules, profiles, app preferences and network settings. Compare against the baseline and
check for the test's leftover processes/listeners. A pre-existing user runtime or network
setup is not a test leftover; do not disable it or use broad process killing as cleanup.

## Installed TUN

Use the [TUN smoke test](TUN_SMOKE_TEST.md) for the complete matrix: initial/reused approval,
start/stop/restart, sleep/wake, network switching, browser and non-browser traffic, UDP/QUIC,
DNS leaks, route exclusions, online settings, repair-failure safety and DNS restoration.

A read-only installed-bundle diagnostic is available separately:

```bash
script/tun_smoke_check.sh --strict --json dist/release-smoke/tun-summary.json /Applications/ClashMax.app
```

The [v1.19.32 adaptation note](MIHOMO_1_19_32.md) preserves the four-stack
congestion-control matrix and its historical `NOT RUN` result. For a new release,
record the actual app/core version and a fresh baseline; do not turn that old result
into acceptance for today's core or silently change the retained Mixed default.

## Installed Network Extension

NE Proxy is a System Extension containing a transparent app-proxy provider. A real run
requires Developer ID signing with Network Extension, System Extension and App Group
capabilities. Current routing supports TCP through SOCKS5 CONNECT and UDP through SOCKS5
UDP ASSOCIATE to the local Mihomo SOCKS5/mixed port, including UDP DNS.
NE mode generates Mihomo DNS on `127.0.0.1:1053`, captures TCP/UDP port 53 and can temporarily
apply `114.114.114.114` as the active service DNS with snapshot/restore protection.

Useful read-only diagnosis:

```bash
codesign -dvvv --entitlements :- /Applications/ClashMax.app
codesign -dvvv --entitlements :- /Applications/ClashMax.app/Contents/Library/SystemExtensions/io.github.clashmax.ClashMax.NetworkExtension.systemextension
spctl --assess --type execute --verbose /Applications/ClashMax.app
systemextensionsctl list
```

For an authorized installed-bundle run:

1. Launch the installed app and approve the extension in System Settings. Confirm it is
   activated and enabled in `systemextensionsctl list`.
2. Select NE Proxy, start and confirm NE connected, DNS capture on, runtime DNS fake-IP and
   System DNS applied.
3. Verify TCP, UDP/QUIC and DNS capture with endpoints that actually use the relevant transport.
4. Stop and confirm the transparent proxy becomes inactive before Mihomo stops and System DNS
   returns to the baseline. Use Repair DNS if restoration reports a failure.

If macOS reports the VPN app is not installed or the plugin is disabled, inspect the installed
bundle's LaunchServices registration:

```bash
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump | rg -n "path: +/Applications/ClashMax.app" -C 20
```

The app refreshes its installed bundle registration before installing/starting NE.
Registration repair and another live start remain part of the authorized integration task.

## Manual Acceptance And Publication

Complete the [per-release checklist](MANUAL_TEST_PLAN.md#per-release-checklist) and the full
feature cases for changed behavior. Record `PASS`, `FAIL`, `BLOCKED` or `NOT RUN`, date,
app/core build, macOS/architecture, observations and artifact/log paths. An outstanding gate
blocks a release unless explicitly documented as a known issue in release notes and sign-off.

When publication is authorized:

1. Prepare the new appcast item without rewriting existing items or removing the final
   universal item needed by older clients. An arm64-only update uses the `apple-silicon`
   channel; universal updates stay on the default channel.
2. Upload the complete release assets before publishing their appcast references. A `docs/**`
   push can deploy Pages immediately; the feed must not advertise assets that are still absent.
3. Verify the final appcast, release assets and preflight result, then the published feed and
   update path. The DMG remains separate from the Sparkle feed.

Workstation-only `docs/APP_UPDATES.md` may hold operator setup details. It is ignored by git;
this tracked guide and the manual plan remain the release-verification entry points.
