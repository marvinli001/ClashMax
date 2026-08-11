# Mihomo Core

ClashMax expects a single universal Mihomo sidecar binary here:

- `mihomo` (`x86_64 arm64`)

Run `script/install_mihomo_core.sh` to produce it: the script downloads the
per-architecture upstream release assets, verifies them against
`mihomo-manifest.json`, and merges them with `lipo`.

Do not ship the per-architecture assets separately. macOS 26.4 and later warn
users that "Intel app support is ending soon" whenever an app bundle contains a
Mach-O without an arm64 slice, and it blames the containing app even if that
binary is never executed. A merged universal core keeps Intel Macs supported
without putting an Intel-only component in the bundle.

The project is GPL-3.0-compatible because the official Mihomo core is GPL-3.0.
Before distributing a release, refresh the pinned binary here, verify checksums
against `mihomo-manifest.json`, and make the source/license notices available.
