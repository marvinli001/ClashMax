# Security Policy

ClashMax controls a local Mihomo runtime, stores subscription metadata, and integrates with macOS helper, proxy, and Network Extension paths. Please treat security reports carefully and avoid posting sensitive details publicly.

## Supported Versions

Security fixes target the latest public release and the current `main` branch. Older release builds may not receive separate backports unless maintainers decide the impact requires it.

## Reporting a Vulnerability

- Prefer GitHub private vulnerability reporting if it is enabled for this repository.
- If private reporting is unavailable, open a minimal public issue that only states the affected area and asks for maintainer contact. Do not include exploit steps, secrets, subscription URLs, or private infrastructure details in a public issue.
- Include the ClashMax version, macOS version, CPU architecture, and whether the issue involves System Proxy, TUN helper, or `NE Transparent Proxy Experimental`.
- Redact profile content before sharing logs or screenshots. Subscription URLs, proxy credentials, private domains, and node addresses can be sensitive.

## Scope

Useful security reports include:

- Local controller exposure or missing Bearer authentication.
- Runtime config generation that leaks secrets or mutates original imported YAML profiles.
- Helper, XPC, or Network Extension path validation issues.
- Incorrect system proxy, DNS, or TUN cleanup that leaves sensitive traffic in an unintended state.
- Update, signing, notarization, or appcast behavior that could install untrusted code.

Out of scope:

- Reports requiring already-compromised local administrator access without a new ClashMax-specific impact.
- Third-party subscription provider behavior that ClashMax cannot control.
- Public disclosure of working exploit details before maintainers have had time to investigate.

## Maintainer Response

Maintainers will triage reports based on reproducibility, impact, and affected release surface. When a fix is needed, the expected path is a source patch, release build, and update metadata aligned with [docs/APP_UPDATES.md](docs/APP_UPDATES.md).
