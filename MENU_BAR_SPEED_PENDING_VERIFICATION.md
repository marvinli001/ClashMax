# Menu Bar Speed Pending Verification

Created: 2026-07-05

Codex did not run Xcode, Swift build, or test commands for this change.

## Scope To Verify Later

- Menu bar status item shows upload above download while traffic data is live.
- Upload/download text keeps compact units without internal spaces, for example `↑26KB/s` above `↓34.7MB/s`.
- The two-line speed label does not overlap the ClashMax menu bar icon or adjacent macOS menu bar items.
- The menu bar rich panel still fits its planned compact width and height.

## Suggested Commands

Run these on a machine with the macOS/Xcode environment available:

```sh
xcodebuild test \
  -project ClashMax.xcodeproj \
  -scheme ClashMax \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:ClashMaxTests/MenuBarRuntimePresentationTests \
  -only-testing:ClashMaxTests/MenuBarPanelLayoutTests
```

After the narrow tests pass, run the full project verification:

```sh
xcodebuild test \
  -project ClashMax.xcodeproj \
  -scheme ClashMax \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  CODE_SIGNING_ALLOWED=NO
```

For a manual visual check:

```sh
./script/build_and_run.sh
```

Start ClashMax with a profile, generate live traffic, and inspect the menu bar item.
