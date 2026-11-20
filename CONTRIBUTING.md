# Contributing to ClashMax

Thanks for helping improve ClashMax. This project is a native macOS SwiftUI Mihomo client, so contributions should keep the app quiet, operational, and faithful to macOS workflows.

For Chinese users: issues and pull requests in Chinese are welcome. Please include enough concrete detail for someone else to reproduce or review the change.

## Where to Start

First time here? Start with a [**good first issue**](https://github.com/marvinli001/ClashMax/labels/good%20first%20issue). These are scoped small on purpose: each one names the files to change, points at existing code to copy, and states exactly how to verify it. Ask questions directly on the issue — you do not need a complete solution before asking.

- Use [Issues](https://github.com/marvinli001/ClashMax/issues) for reproducible bugs, actionable feedback, and implementation tasks that are specific enough to track.
- Use [Questions](https://github.com/marvinli001/ClashMax/discussions/new?category=questions) for installation, usage, setup help, and runtime troubleshooting.
- Use [Ideas](https://github.com/marvinli001/ClashMax/discussions/new?category=ideas) for early feature ideas, product direction, and workflow proposals.
- Use [Development](https://github.com/marvinli001/ClashMax/discussions/new?category=development) before starting larger contributions that need design alignment, ownership boundaries, or release-sensitive verification.
- Use a pull request when you already have a narrow code or documentation change ready for review.

If an idea is still open-ended, start in Discussions. If it has a concrete goal, scope, and acceptance criteria, open an Issue or pull request instead.

## Local Setup

Use the [development guide](docs/DEVELOPMENT.md) as the single source for prerequisites,
core installation, Xcode project generation, focused/full tests, exact-version formatting
and localization checks. On an existing checkout, preserve user-owned Xcode signing/profile
and capability state before regenerating. Inspect the formatter's file selection before
using `--fix` so unrelated working-tree changes are not reformatted.

Choose work from the [roadmap](docs/ROADMAP.md), which separates implementation from
manual acceptance. Signed Helper/NE validation and release gates live in the
[release guide](docs/RELEASE.md); observations go in the tracked
[manual test plan](docs/MANUAL_TEST_PLAN.md).

## Contribution Guidelines

- Keep changes scoped. Avoid broad rewrites when a focused patch solves the problem.
- Preserve imported YAML profiles unchanged; ClashMax should generate app-managed runtime YAML before launching Mihomo.
- Keep Mihomo controller access local to `127.0.0.1`, use per-run secrets, and preserve Bearer authentication.
- Do not copy code, assets, or UI from proprietary projects. GPL-compatible references must keep notices and attribution correct.
- Helper, XPC, and Network Extension code must validate app-provided paths and must not use shell interpolation for app-provided values.
- Treat signing, entitlements, helper registration, and Network Extension behavior as release-sensitive. Test those paths with an installed app in `/Applications` when the change touches them.
- Keep UI work native to macOS: dense, calm, explicit state, and clear recovery actions.

## Pull Request Checklist

Before opening a PR, please confirm:

- The PR explains the problem, the user-visible behavior, and the chosen fix.
- Relevant screenshots or screen recordings are included for visible UI changes.
- The narrowest useful verification command was run, and the result is included in the PR.
- `script/swiftformat_lint.sh` passes for the files the change touches.
- `script/localization_gate.sh` was run when the PR touches user-visible strings or release preparation.
- New user-visible strings have a `zh-Hans` translation in `Resources/Localizable.xcstrings`; `script/localization_new_key_gate.sh` passes. Growing `script/localization_untranslated_allowlist.txt` needs a reason in the PR.
- Documentation was updated when behavior, installation, release, or security expectations changed.
- Logs, screenshots, sample profiles, and test data do not include subscription URLs, credentials, private domains, or personal network details.
