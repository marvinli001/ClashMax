# Menu Bar Rich Panel QA

This note captures the first-pass design and verification contract for the
ClashMax menu bar rich panel.

## Product Scope

- Keep the menu bar item lightweight: status symbol only.
- Open a SwiftUI `MenuBarExtra` window-style panel for daily runtime control.
- Do not place full main-window workflows in the panel. Proxy groups,
  connections, rules, logs, and deep settings stay in the main window.
- Keep the app as a regular Dock app with the main window behavior unchanged.

## Layout Contract

- Panel width stays in the 300-330 px range. Current implementation is 312 px.
- Top area shows product identity, active profile, runtime owner, and current
  runtime state.
- Primary action is Start Core or Stop Core.
- Middle controls include Run Mode, Profile, Proxy Routing, System Proxy, and
  Traffic only while a real runtime is running.
- Footer actions include Update Subscription, Check Updates, Open Main Window,
  and Quit.
- Use native SwiftUI controls, SF Symbols, semantic status colors, and system
  materials.
- Avoid hero treatment, decorative gradients, one-hue themes, oversized type,
  nested cards, and skeleton placeholders for stopped, failed, or recovery
  states.

## Runtime State Matrix

Check these states in both English and Simplified Chinese:

- No Profile: communicates that a profile must be selected before starting.
- No Core: communicates that the bundled Mihomo core is unavailable.
- Stopped: profile and core are ready.
- Starting: the core is starting and the primary action is disabled unless a
  stop path is available.
- Running: user-mode core is active.
- Running TUN: TUN helper owns routing.
- Running NE: Network Extension owns transparent proxy routing.
- Preview: preview runtime is active.
- Crashed: crash message is visible and Stop remains available when runtime
  cleanup is possible.
- Needs Setup: helper, signing, approval, or routing prerequisites are explicit.

## Localization Contract

- `Resources/Localizable.xcstrings` is the only string source.
- Do not add temporary `Text` extensions or sidecar string tables.
- Menu bar display must not expose `runtimeOwner.rawValue` or raw English
  `statusSummary`.
- Keep representative static keys and dynamic format keys covered by
  `LocalizationTests`.
- Keep menu bar runtime state mapping covered by
  `MenuBarRuntimePresentationTests`.
- Keep the rich panel width and long-label layout guarded by
  `MenuBarPanelLayoutTests`.

## Verification Commands

Run these after changing menu bar UI strings or state mapping:

```sh
xcodegen generate
jq empty Resources/Localizable.xcstrings
tmpdir=$(mktemp -d)
xcrun xcstringstool compile Resources/Localizable.xcstrings --output-directory "$tmpdir" --dry-run
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:ClashMaxTests/MenuBarPanelLayoutTests
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:ClashMaxTests/MenuBarRuntimePresentationTests
xcodebuild test -project ClashMax.xcodeproj -scheme ClashMax -destination 'platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:ClashMaxTests/LocalizationTests
```

`ClashMax.xcodeproj` is generated from `project.yml` and ignored by git, so run
XcodeGen before relying on new test files or target membership.

Run this before claiming the app still builds and launches:

```sh
./script/build_and_run.sh --verify
```

## Manual Visual QA

Automated screen capture may fail for transient SwiftUI menu bar panels under
restricted desktop capture environments, so do this manually before release:

- Open the panel in light mode and dark mode.
- Check English and Simplified Chinese.
- Verify the panel does not truncate or overlap text in the header, status
  message, control rows, and footer buttons.
- Verify inactive controls still explain recovery through visible copy or help.
- Verify failure and security-sensitive states use explicit recovery text, not
  skeleton loading placeholders.
- Verify long profile names truncate to one line without resizing the panel.
- Verify the System Proxy toggle is disabled unless Proxy Routing is System
  Proxy, and that the disabled state explains the routing requirement.

## Reference Image Pass

For a second visual pass, provide 2-4 reference images and identify what should
be borrowed as inspiration:

- panel density and spacing
- glass or material feel
- shadow and corner treatment
- status color usage
- footer action grouping
- icon tone and size

Reference images are used for visual decomposition only. Do not copy
proprietary code, brand assets, icons, or exact layouts.
