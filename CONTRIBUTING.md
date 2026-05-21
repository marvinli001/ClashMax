# Contributing to ClashMax

Thanks for helping improve ClashMax. This project is a native macOS SwiftUI Mihomo client, so contributions should keep the app quiet, operational, and faithful to macOS workflows.

For Chinese users: issues and pull requests in Chinese are welcome. Please include enough concrete detail for someone else to reproduce or review the change.

## Where to Start

- Use [Issues](https://github.com/marvinli001/ClashMax/issues) for actionable feedback, reproducible bugs, and trackable implementation tasks.
- Use [Discussions](https://github.com/marvinli001/ClashMax/discussions) for questions, announcements, setup help, and broader project conversations.
- Use a pull request when you already have a narrow code or documentation change ready for review.

## Local Setup

ClashMax uses XcodeGen as the source of truth for the generated Xcode project.

```bash
xcodegen generate
```

Open the generated `ClashMax.xcodeproj`, or run the main verification command:

```bash
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO
```

For local app runs:

```bash
./script/build_and_run.sh
```

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for project direction, security boundaries, Network Extension notes, and release-sensitive verification.

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
- Documentation was updated when behavior, installation, release, or security expectations changed.
- Logs, screenshots, sample profiles, and test data do not include subscription URLs, credentials, private domains, or personal network details.
