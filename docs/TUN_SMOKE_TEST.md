# ClashMax Installed-Bundle TUN Smoke Test

This gate must be run against an installed, signed bundle at `/Applications/ClashMax.app`.
Unit tests can verify runtime YAML, helper protocol state, and repair semantics, but they
cannot prove macOS kernel routing, DNS service order, sleep/wake behavior, network
switching, UDP, or helper approval persistence.

## Read-Only Preflight

Run:

```sh
./script/tun_smoke_check.sh /Applications/ClashMax.app
```

The script is intentionally read-only. It checks the installed bundle, embedded helper,
LaunchDaemon plist, bundled Mihomo files, code signatures, current launchd helper state,
current route table hints, current DNS resolver hints, and visible Mihomo processes. It
does not register or unregister the helper, change DNS, change routes, start ClashMax, or
require `sudo`.

## Manual Installed-Bundle Matrix

1. Build a signed app, install it as `/Applications/ClashMax.app`, and launch that
   installed bundle rather than an Xcode-run bundle.
2. Select TUN mode and start ClashMax. On first run, approve the privileged helper in
   System Settings if macOS prompts for it, then retry start.
3. Quit and relaunch ClashMax. Confirm helper status is reused without another approval
   prompt. Status should report the helper as enabled, bootstrapped, protocol-compatible,
   fingerprint-matched, and either running or ready.
4. Start, stop, and restart TUN mode several times. Confirm Mihomo starts under the
   helper, Status reaches running state, stop clears TUN diagnostics, and System DNS
   restores to the pre-start snapshot.
5. Put the Mac to sleep, wake it, and verify ClashMax either remains connected or reports
   an actionable TUN/DNS repair state. Re-run Status diagnostics after wake.
6. Switch networks, for example Wi-Fi to Ethernet or hotspot and back. Confirm default
   route, route-exclude, DNS hijack, and System DNS diagnostics match the active service.
7. Verify browser traffic and non-browser traffic. Include a command-line request that
   does not rely on the macOS HTTP proxy, such as `curl --proxy "" https://example.com`.
8. Verify UDP and QUIC with an endpoint that actually uses UDP, such as HTTP/3/QUIC or a
   UDP DNS probe routed through Mihomo.
9. Verify DNS leak behavior. DNS queries should use the ClashMax/Mihomo DNS path, fake-ip
   answers should be returned when fake-ip is enabled, and external resolvers should not
   be used unexpectedly.
10. Verify route exclusions. Add a known CIDR to route-exclude, restart or apply TUN
    settings, and confirm traffic to that CIDR bypasses TUN while normal traffic remains
    captured.
11. Verify online TUN setting changes. Change DNS hijack, route-exclude, or MTU while TUN
    is running. ClashMax should reload config, inspect runtime facts, fall back to one
    helper restart if diagnostics still warn, and surface a clear error if runtime facts
    still do not match.
12. Verify repair-failure safety semantics. Simulate a repair failure where route
    diagnostics still warn after reload and helper restart. Repair Routing must stop TUN
    safely, clear live diagnostics, mark the runtime stopped, and preserve the failed
    diagnostic in the final user-facing error.

Record the app version, build number, macOS version, network type, helper status, DNS
result, route result, UDP result, and any repair action used. The real installed-bundle TUN smoke remains manual because it depends on macOS system approval and live data-plane state.
