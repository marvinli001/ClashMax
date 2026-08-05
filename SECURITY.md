# Security Policy

ClashMax runs a local Mihomo core, installs a privileged TUN helper, ships a Network
Extension, and stores subscription metadata on the user's machine. A bug in any of those
paths can expose traffic, credentials, or the machine itself, so security reports are
handled separately from normal issues.

**Report privately. Never open a public issue for a vulnerability.**

## Supported Versions

Security fixes target the latest public release and the current `master` branch. Older
release builds do not receive separate backports unless maintainers judge the impact to
require it.

## Reporting a Vulnerability

Use whichever of these is available to you, in order of preference:

1. **GitHub private vulnerability reporting** —
   [open a draft advisory](https://github.com/marvinli001/ClashMax/security/advisories/new).
   This keeps the report, the discussion, and the eventual advisory in one private place.
2. **Email** — `lizhuoyang0@gmail.com`, with `ClashMax security` in the subject line.
   Email is not end-to-end encrypted, so send only what is needed to understand the
   issue, and redact per the rules below.
3. If neither works, open a public issue that says only *which surface* is affected and
   asks for a private contact. No exploit steps, no logs, no secrets.

Please include:

- ClashMax version and build number (Settings shows both), macOS version, and CPU
  architecture.
- Which routing surface is involved: System Proxy, TUN (privileged helper), or
  `NE Proxy` (Network Extension), and whether the runtime was running at the time.
- Minimal reproduction steps, and a **redacted** profile or config fragment if the issue
  depends on profile content.
- Impact as you understand it: what an attacker gains, and what access they need first.

### What to expect

This is a small, single-maintainer project, so these are honest targets rather than a
contractual SLA:

| Stage | Target |
| --- | --- |
| Acknowledgement of your report | 5 days |
| Initial assessment (valid / not valid, severity, affected surfaces) | 14 days |
| Fix or documented mitigation for confirmed issues | depends on severity and release surface |
| Public disclosure | after a fix ships, or 90 days from the report, whichever comes first |

If you want credit in the advisory and release notes, say so in the report and give the
name or handle you want used. Nothing about your report is published before the fix
unless you ask for it.

## Never Post These In Public

This applies to issues, discussions, pull requests, screenshots, screen recordings,
attached logs, sample profiles, and CI logs:

- **Subscription URLs**, including short links and any URL carrying a `token`, `sub`,
  `uuid`, or similar query parameter. A subscription URL is a bearer credential: anyone
  who has it has your nodes.
- **Node credentials**: passwords, UUIDs, pre-shared keys, `password`, `auth`, `psk`,
  Shadowsocks/Trojan/VLESS secrets, certificates, and private keys.
- **The ClashMax controller secret** and any Bearer token from an external dashboard.
- **Private domains and hostnames**, internal DNS names, and rule entries that expose a
  private network's naming.
- **Personal network details**: public IPs, Wi-Fi SSIDs, MAC addresses, and account
  identifiers from your provider.

Replace them with placeholders (`https://example.com/sub?token=<redacted>`,
`internal.example`, `1.2.3.4`). A report with redactions is far more useful than a
report we have to ask you to delete. If you have already posted something sensitive,
tell us — the comment can be edited or hidden, but treat the value as compromised and
rotate it.

The repository's CI runs a check that fails the build if a private key block is committed,
but that check catches only the most obvious case. Redaction is still yours to do.

## How ClashMax Handles Sensitive Data

Reports are easier to write when you know where data lives:

- **Imported YAML profiles** are stored locally and are never modified. ClashMax
  generates a separate app-managed runtime YAML before launching Mihomo, and that
  generated file is what carries injected ports, controller, secret, DNS, TUN, and mode
  settings.
- **Subscription URLs** are stored in the macOS Keychain, keyed by profile ID, not in the
  profile manifest on disk.
- **Runtime configs** are written under a ClashMax-managed Application Support path.
- **The controller** binds to `127.0.0.1`. A new controller secret is generated for every
  launch, and control API access uses Bearer authentication.
- **Logs are redacted at the producer boundary** (`Shared/StructuredLogPrivacy.swift`),
  before a line reaches the in-memory ring, the on-disk JSONL, or a copied diagnostic
  report. Redaction covers auth headers, tokens, passwords, keys, and subscription URLs,
  and deliberately keeps schemes, hosts, ports, error domains, and error codes so logs
  stay useful. Treat a leak *through* this boundary as a security bug, not a papercut.
- **No telemetry.** ClashMax does not collect analytics or send profile data anywhere.
  Network requests it makes on its own are: subscription updates to the URL you supplied,
  the Sparkle appcast, and the optional public-IP probe.

## Security Scope

These surfaces are in scope, in rough order of severity:

### Privileged helper and XPC

The helper is a root LaunchDaemon that owns TUN mode.

- Any path by which an unauthorized process gets the helper to act on its behalf. The
  helper checks each incoming XPC connection against a code-signing requirement and a
  client policy (`ClashMaxHelper/main.swift`,
  `Shared/HelperProtocol.swift`); bypasses of that check are in scope.
- Argument or path injection through the XPC interface, including anything that escapes
  the helper's allowed roots for the core binary, runtime config, and work directory.
- Privilege escalation via helper installation, registration, or the LaunchDaemon plist.
- TOCTOU between validation and execution of the core binary.

### TUN mode

- Routes, DNS settings, or interfaces left behind after the runtime stops or crashes,
  in a state where traffic leaves unprotected or is silently redirected.
- DNS leaks and traffic that bypasses the tunnel when the profile says it should not.
- Failure to restore the system's previous network state.

### Network Extension (`NE Proxy`, experimental)

- Flaws in the transparent proxy provider: SOCKS5 CONNECT and UDP ASSOCIATE handling,
  the local DNS listener on `127.0.0.1:1053`, and port 53 capture.
- Snapshot/restore failures for macOS service DNS that leave a temporary DNS server
  configured after the extension stops.
- App Group, entitlement, or Mach service exposure that lets another process talk to the
  provider.

### Mihomo control API

- The controller reachable off `127.0.0.1`, or reachable without Bearer authentication.
- Secret reuse across launches, secret leakage into logs, generated config, diagnostics,
  or another app.
- External-dashboard integration handing the secret to an untrusted origin.

### Profiles, config generation, and storage

- Generated runtime YAML that mutates the original imported profile.
- Config generation that writes credentials somewhere unprotected, or that turns
  attacker-controlled profile content into command execution or path traversal.
- Keychain items stored with weaker protection than intended, or readable by other apps.
- Subscription fetching that follows redirects or handles TLS in a way that exposes the
  subscription URL.

### Updates, signing, and packaging

- Anything that could install untrusted code: appcast handling, Sparkle EdDSA signature
  verification, downgrade attacks, or update artifacts served over a channel the app
  does not verify.
- Entitlement, hardened runtime, or notarization regressions in release artifacts.
- The bundled core policy: ClashMax intentionally supports only the app-owned bundled
  Mihomo core. A way to make it run a different binary is in scope.

## Out Of Scope

- Reports that require an already-compromised local administrator, with no additional
  ClashMax-specific impact.
- Behavior of third-party subscription providers, node operators, or the Mihomo core
  itself. Report core bugs to [Mihomo](https://github.com/MetaCubeX/mihomo); if it
  affects how ClashMax drives the core, we still want to hear about it.
- Missing hardening with no demonstrated impact, and scanner output without a working
  scenario.
- Anything that requires the user to import a profile from an attacker while the profile
  behaves exactly as a legitimate profile would (a malicious profile can route your
  traffic — that is what profiles do).
- Public disclosure of exploit details before maintainers have had a reasonable chance to
  investigate.

## Testing Guidance

Test against your own machine and your own subscriptions only. Do not test against other
users, third-party subscription providers, or the update infrastructure. Denial-of-service
testing against project infrastructure is not authorized.

## Maintainer Response

Reports are triaged by reproducibility, impact, and affected release surface. A fix ships
as a source patch, a signed release build, and matching update metadata; the release path
is documented in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Changes that cross a
privilege or privacy boundary — helper, XPC, entitlements, path validation, Keychain, log
redaction, controller authentication — are expected to land with regression tests, which
CI runs on every pull request.
