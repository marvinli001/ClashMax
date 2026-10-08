# Mihomo v1.19.32 App adaptation

## Release notes draft

- TUN Settings now offers `cubic`, `reno`, `bbr`, and `bbr3` TCP congestion control
  when the Mips stack is selected. The picker has no free-text input. `Default (cubic)`
  preserves a profile's own `tun.congestion-controller`; without a profile value,
  Mihomo uses cubic. An explicit choice overrides the profile only while TUN is
  enabled with Mips. Other stacks ignore the key, and the app does not write its
  stored choice for those stacks. Raw YAML snippets retain the final override.
- The running TUN diagnostics display the value from the applied runtime YAML,
  including inherited profile values and raw snippet overrides.
- Mihomo's default TUN stack is now Mips. ClashMax continues to write its selected
  stack explicitly and keeps Mixed as its default. Mips is Mihomo's own userspace
  network stack; the name is unrelated to CPU architecture.
- `load-balance` now validates `hash-key`. Only `in-user` is supported, with
  `consistent-hashing` or `sticky-sessions`; `round-robin` with a hash key and
  unknown keys fail preflight. The core's original error remains available in
  subscription diagnostics. There is no new hash-key UI.
- Outbounds such as WireGuard and ZeroTier now use Mips for `ip-stack: auto`.
  ClashMax has no setting for that outbound option.

The xhttp share-link header conversion and the mieru, OpenVPN, anytls, sing-mux,
h2, MSS, and EasyTier fixes are internal core changes and need no App adapter.

## Default-stack decision pending

Recommendation: keep `.mixed` for new installations for this update. Mips first
appeared in v1.19.31 and became the upstream default in v1.19.32, but ClashMax has
not yet completed real helper-mode TUN acceptance on it. Passing `mihomo -t` proves
config parsing only. After the four-stack live matrix below passes, a separate
decision can change the new-install default to `.mips`. Existing stored choices
must be preserved in either case; this adaptation makes no default migration.

## Why preflight group indices are not replaced with names

For a normal full profile, ConfigNormalizer preserves `proxy-groups` array order;
selection overrides replace a group's `now` in place. Provider templates create
their own groups, and legacy merge YAML and raw snippets can replace or append
the array, so only the final runtime YAML could be considered as a mapping source.

Even that final order is insufficient. On v1.19.32, a synthetic YAML with two
independent select groups and a failing load-balance group emitted different
`proxy group[N]` indices on repeated `-t` runs. With the failing group first,
four runs reported `0, 0, 2, 0`; with it second, they reported `2, 0, 1, 1`;
with it third, they reported `0, 2, 0, 0`. There was no App normalization in
this control. Substituting the YAML's Nth group would misidentify the failure.
The formatter therefore preserves the core's index and full output. Regression
tests use the captured hash-key errors, with only temporary trailer paths replaced.

## Authorized live helper-mode TUN checklist

**Status: NOT RUN.** Ask Marvin to authorize live network changes before starting.
Marvin enters administrator passwords and performs macOS helper approval. Do not
change signing, entitlements, the App Group, or generated project settings.

Use an installed signed test bundle whose bundled core reports v1.19.32. Confirm
the bundle includes this App adaptation before testing the new picker. Follow
[the installed-bundle TUN smoke test](TUN_SMOKE_TEST.md) for signed-bundle checks.
Preparing/installing a replacement signed bundle is a separate authorized step
if one is not already available.

### Record the baseline before changing anything

1. Record App/core/macOS versions, active network service, active profile identity
   (without subscription URLs or secrets), runtime mode, whether the core is
   running, helper approval/status, system proxy state, and all TUN/DNS settings.
   Save the original stack and optional congestion-controller choice for restoration.
2. Record current processes/listeners, all existing `utun` interfaces, IPv4/IPv6
   routes/default gateways, and both resolver and per-service DNS settings. Existing
   VPN interfaces, routes, listeners, or DNS changes belong to the baseline. Do not
   stop another VPN or user setup. If there is a conflict, pause the live test.
3. Save read-only snapshots locally in a private directory. Full network snapshots
   can contain private IPs or domains; keep them local and redact any shared report.

   ```sh
   umask 077
   tun_report_dir="$(mktemp -d "${TMPDIR:-/tmp}/clashmax-tun-1.19.32.XXXXXX")"
   snapshot_tun_state() {
     snapshot_dir="$tun_report_dir/$1"
     mkdir -p "$snapshot_dir"
     date -u > "$snapshot_dir/time.txt"
     sw_vers > "$snapshot_dir/macos.txt"
     ifconfig -l > "$snapshot_dir/interfaces.txt"
     ifconfig > "$snapshot_dir/ifconfig.txt"
     netstat -rn -f inet > "$snapshot_dir/routes-ipv4.txt"
     netstat -rn -f inet6 > "$snapshot_dir/routes-ipv6.txt"
     route -n get default > "$snapshot_dir/default-ipv4.txt" 2>&1
     route -n get -inet6 default > "$snapshot_dir/default-ipv6.txt" 2>&1
     scutil --dns > "$snapshot_dir/resolvers.txt"
     scutil --proxy > "$snapshot_dir/proxy.txt"
     networksetup -listnetworkserviceorder > "$snapshot_dir/service-order.txt"
     networksetup -listallnetworkservices > "$snapshot_dir/services.txt"
     networksetup -listallnetworkservices | sed '1d;s/^\*//' |
       while IFS= read -r network_service; do
         printf '\n%s\n' "$network_service"
         networksetup -getdnsservers "$network_service"
       done > "$snapshot_dir/service-dns.txt"
     ps -axo pid,ppid,comm > "$snapshot_dir/processes.txt"
     # With live-test authorization, Marvin enters the password for root visibility.
     sudo lsof -nP -iTCP -sTCP:LISTEN > "$snapshot_dir/tcp-listeners.txt"
     sudo lsof -nP -iUDP > "$snapshot_dir/udp-sockets.txt"
   }
   snapshot_tun_state baseline
   ```

   No full process arguments or controller secrets are recorded. Missing IPv6
   default routes and empty listener output are recorded as baseline facts.

### Run each stack once under the helper

| Stack | Congestion selection | Start/helper + interface | DNS hijack | Browser + direct curl | Stop and restore |
| --- | --- | --- | --- | --- | --- |
| Mixed | Hidden; stored choice must not be injected | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Mips | `bbr`; also check Default inherits profile or cubic | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| System | Hidden; stored choice must not be injected | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| GVisor | Hidden; stored choice must not be injected | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

For each row:

1. With the test core stopped, select the stack and keep the same profile, network,
   MTU, DNS hijack and route settings. Use a DNS-capable profile with a known test
   domain and a rule that routes the browser test through the intended outbound.
   Enable TUN through the helper; approve prompts personally if needed. Never use
   an unsigned XCTest host to claim this acceptance.
2. Confirm Starting reaches Running, the helper owns the intended Mihomo process,
   the new utun/interface and routes match diagnostics, and no bind/stack errors
   appear. For Mips + bbr, confirm the generated YAML and running diagnostics show
   bbr. `-t` cannot prove its TCP behavior. For the other stacks, a remembered bbr
   choice must not be injected by the App.
3. Confirm DNS hijack with a fresh test-domain query, for example
   `dig @1.1.1.1 example.com A +time=3 +tries=1`. With fake-ip enabled and this domain
   not excluded, expect an address in the configured fake-ip range. Correlate the
   request with Mihomo DNS/diagnostics; an answer alone does not prove hijack.
   Check system resolution as well, and confirm resolver/service DNS matches the
   configured override. Record failures and recovery messages.
4. Browse a fresh page and confirm its connection uses the intended rule/outbound.
   Run `curl --proxy "" --max-time 20 https://example.com` to check traffic that
   does not rely on system HTTP proxy. Check UDP DNS and, when the test endpoint
   supports it, QUIC. Record routing and content evidence without private URLs.
5. Save `snapshot_tun_state "<stack>-running"`, then stop TUN through the App.
   Confirm the test Mihomo process exits, controller/mixed/DNS listeners disappear,
   system proxy and per-service DNS return to baseline, and no test-created utun
   or routes remain. Save `snapshot_tun_state "<stack>-stopped"` and compare to the
   baseline. Existing utuns remain; unrelated network changes are recorded rather
   than deleted. Wait for normal teardown and record any delay or stuck process.
6. A second start/stop is useful for shutdown regressions if a row fails. Do not
   broadly kill processes or delete routes/interfaces to conceal the failure.
   Pause with the specific leftover state and use only an authorized App recovery.

For Mips, also check that switching between Default and bbr preserves the choice
across relaunch; Default should show the profile's value if present, or cubic
otherwise. Changing algorithms requires the stack to be rebuilt; record any App
reload/restart outcome. Additional live checks of reno/bbr3 are optional coverage.

### Restore and record the result

Restore the original stack, congestion choice, TUN/DNS settings, active profile,
runtime mode, and original running/stopped state. Confirm DNS, proxy, routes,
interfaces, helper state, test processes and listeners against the original
baseline again. Record any remaining difference with its owner and reason. Keep
macOS-approved helper registration if it pre-existed; undo any new registration
only with authorization for that exact action.

Record PASS/FAIL/NOT RUN for every cell, logs with secrets redacted, baseline and
after-state comparisons, and whether startup, DNS, browsing, shutdown and full
restoration succeeded. sing-tun v0.4.24 → v0.4.27 raised darwin utun `SO_RCVBUF`
to 8 MB and derives `UTUN_OPT_MAX_PENDING_PACKETS` from it; tunFd writes are now
serialized, and shutdown maps `ENOTSOCK`/`EBADF` to `os.ErrClosed`. It also changes
system-stack NAT checksum updates and timeout scanning, and fixes gVisor endpoint
release. Source tests and `-t` cannot establish acceptance of these runtime changes.
