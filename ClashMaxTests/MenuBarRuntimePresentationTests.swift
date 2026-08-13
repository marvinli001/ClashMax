import AppKit
@testable import ClashMax
import XCTest

final class MenuBarRuntimePresentationTests: XCTestCase {
  func testPresentationTitlesCoverMenuBarRuntimeStates() {
    assertPresentation(
      MenuBarRuntimePresentation(dashboardRuntimeState: .stopped, runtimeOwner: .stopped),
      title: String(localized: "Stopped"),
      detail: String(localized: "Profile and core are ready."),
      symbolName: "shield",
      showsTraffic: false
    )

    assertPresentation(
      MenuBarRuntimePresentation(dashboardRuntimeState: .starting, runtimeOwner: .stopped),
      title: String(localized: "Starting"),
      detail: String(localized: "Core is starting."),
      symbolName: "arrow.triangle.2.circlepath",
      showsTraffic: false
    )

    assertPresentation(
      MenuBarRuntimePresentation(dashboardRuntimeState: .running, runtimeOwner: .user),
      title: String(localized: "Running"),
      detail: String(localized: "User-mode core is running."),
      symbolName: "shield.lefthalf.filled",
      showsTraffic: true
    )

    assertPresentation(
      MenuBarRuntimePresentation(dashboardRuntimeState: .running, runtimeOwner: .tunnel),
      title: String(localized: "Running TUN"),
      detail: String(localized: "TUN helper owns VPN-style routing."),
      symbolName: "point.topleft.down.curvedto.point.bottomright.up",
      showsTraffic: true
    )

    assertPresentation(
      MenuBarRuntimePresentation(dashboardRuntimeState: .running, runtimeOwner: .networkExtension),
      title: String(localized: "Running NE"),
      detail: String(localized: "Network Extension owns transparent proxy routing."),
      symbolName: "network",
      showsTraffic: true
    )

    assertPresentation(
      MenuBarRuntimePresentation(
        previewRuntimeActive: true,
        dashboardRuntimeState: .stopped,
        runtimeOwner: .preview
      ),
      title: String(localized: "Preview"),
      detail: String(localized: "Preview runtime is active."),
      symbolName: "eye",
      showsTraffic: false
    )

    assertPresentation(
      MenuBarRuntimePresentation(
        dashboardRuntimeState: .crashed(message: "mihomo exited with code 2"),
        runtimeOwner: .networkExtension
      ),
      title: String(localized: "Crashed"),
      detail: "mihomo exited with code 2",
      symbolName: "xmark.octagon.fill",
      showsTraffic: false
    )

    assertPresentation(
      MenuBarRuntimePresentation(
        dashboardRuntimeState: .blocked(reason: "No active profile selected."),
        runtimeOwner: .stopped,
        hasActiveProfile: false
      ),
      title: String(localized: "No Profile"),
      detail: String(localized: "Select a profile to start ClashMax."),
      symbolName: "doc.badge.plus",
      showsTraffic: false
    )

    assertPresentation(
      MenuBarRuntimePresentation(
        dashboardRuntimeState: .blocked(reason: AppError.missingBundledCore.description),
        runtimeOwner: .stopped,
        missingBundledCore: true
      ),
      title: String(localized: "No Core"),
      detail: String(localized: "Bundled Mihomo core is unavailable."),
      symbolName: "externaldrive.badge.xmark",
      showsTraffic: false
    )

    assertPresentation(
      MenuBarRuntimePresentation(
        dashboardRuntimeState: .blocked(reason: "TUN helper requires approval."),
        runtimeOwner: .stopped,
        readinessIssue: "TUN helper requires approval."
      ),
      title: String(localized: "Needs Setup"),
      detail: "TUN helper requires approval.",
      symbolName: "exclamationmark.triangle.fill",
      showsTraffic: false
    )
  }

  private func assertPresentation(
    _ presentation: MenuBarRuntimePresentation,
    title: String,
    detail: String,
    symbolName: String,
    showsTraffic: Bool,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(presentation.title, title, file: file, line: line)
    XCTAssertEqual(presentation.detail, detail, file: file, line: line)
    XCTAssertEqual(presentation.symbolName, symbolName, file: file, line: line)
    XCTAssertEqual(presentation.showsTraffic, showsTraffic, file: file, line: line)
  }
}

final class MenuBarTrafficStatusLabelTests: XCTestCase {
  func testShowsCompactUploadThenDownloadLinesWhileRunningWithData() {
    let lines = MenuBarTrafficStatusLabel.lines(
      showsTraffic: true,
      hasTrafficData: true,
      sample: TrafficSample(upload: 348, download: 2048)
    )

    XCTAssertEqual(lines?.upload, "↑348B/s")
    XCTAssertEqual(lines?.download, "↓2KB/s")
  }

  func testLabelStripsInternalUnitSpacingToStayNarrow() {
    let label = MenuBarTrafficStatusLabel.text(
      showsTraffic: true,
      hasTrafficData: true,
      sample: TrafficSample(upload: 48, download: 22 * 1024)
    )

    // Reuses TrafficSample.format units (KB/s, B/s) so the menu bar stays
    // consistent with the rest of the app, but drops the internal number/unit
    // spacing so each status item row stays narrow (Discussion #20).
    XCTAssertEqual(label, "↑48B/s\n↓22KB/s")
    guard let label else { return XCTFail("Expected a traffic label") }
    XCTAssertFalse(label.contains(" KB/s"))
    XCTAssertFalse(label.contains(" B/s"))
    XCTAssertTrue(label.contains("KB/s"))
  }

  func testLabelStaysCompactAndCarriesBothDirections() {
    let label = MenuBarTrafficStatusLabel.text(
      showsTraffic: true,
      hasTrafficData: true,
      sample: TrafficSample(upload: 5 * 1024 * 1024, download: 12 * 1024 * 1024)
    )

    guard let label else {
      return XCTFail("Expected a traffic label while running with live data")
    }
    XCTAssertTrue(label.contains("↓"))
    XCTAssertTrue(label.contains("↑"))
    // It must remain a short status label, never a full sentence or description.
    XCTAssertLessThan(label.count, 32)
    XCTAssertFalse(label.contains("Download"))
    XCTAssertFalse(label.contains("Upload"))
  }

  func testHiddenWhenNotRunning() {
    let label = MenuBarTrafficStatusLabel.text(
      showsTraffic: false,
      hasTrafficData: true,
      sample: TrafficSample(upload: 100, download: 200)
    )

    XCTAssertNil(label)
  }

  func testHiddenWhenRunningButNoSamplesYet() {
    let label = MenuBarTrafficStatusLabel.text(
      showsTraffic: true,
      hasTrafficData: false,
      sample: .zero
    )

    XCTAssertNil(label)
  }

  func testShownForIdleRunningSampleToAvoidFlicker() {
    // Running with at least one sample but currently idle keeps a stable
    // 0 B/s label instead of flickering the status item text in and out.
    let label = MenuBarTrafficStatusLabel.text(
      showsTraffic: true,
      hasTrafficData: true,
      sample: .zero
    )

    XCTAssertEqual(label, "↑0B/s\n↓0B/s")
  }
}

final class MenuBarStatusItemImageTests: XCTestCase {
  func testRenderCompositesLogoAndBothTrafficRowsIntoOneTemplateImage() {
    let lines = MenuBarTrafficStatusLabel.Lines(upload: "↑48B/s", download: "↓22KB/s")

    let image = MenuBarStatusItemImage.render(lines: lines, logo: solidLogo())

    // MenuBarExtra only renders a single-Image label through the status item's
    // native image slot, so everything must live in this one template image.
    XCTAssertTrue(image.isTemplate)
    XCTAssertEqual(image.size.height, MenuBarStatusItemImage.rowHeight * 2)
    XCTAssertGreaterThan(
      image.size.width,
      MenuBarStatusItemImage.logoPointSize + MenuBarStatusItemImage.logoTextGap
    )

    guard let rep = image.representations.first as? NSBitmapImageRep else {
      return XCTFail("Expected a pre-rasterized bitmap representation")
    }
    let logoRegionMaxX = Int(MenuBarStatusItemImage.logoPointSize * 2)
    XCTAssertGreaterThan(
      alphaPixels(in: rep, xRange: 0..<logoRegionMaxX),
      0,
      "Logo must be drawn into the composite image"
    )
    // Upload row occupies the top half, download row the bottom half. Both must
    // carry real pixels — the empty-image / clipped-second-row regressions both
    // fail here.
    XCTAssertGreaterThan(
      alphaPixels(in: rep, xRange: logoRegionMaxX..<rep.pixelsWide, yRange: 0..<rep.pixelsHigh / 2),
      0,
      "Upload row must be drawn"
    )
    XCTAssertGreaterThan(
      alphaPixels(in: rep, xRange: logoRegionMaxX..<rep.pixelsWide, yRange: rep.pixelsHigh / 2..<rep.pixelsHigh),
      0,
      "Download row must be drawn"
    )
  }

  func testRenderWithoutLogoStillDrawsBothRows() {
    let lines = MenuBarTrafficStatusLabel.Lines(upload: "↑0B/s", download: "↓0B/s")

    let image = MenuBarStatusItemImage.render(lines: lines, logo: nil)

    XCTAssertTrue(image.isTemplate)
    guard let rep = image.representations.first as? NSBitmapImageRep else {
      return XCTFail("Expected a pre-rasterized bitmap representation")
    }
    XCTAssertGreaterThan(alphaPixels(in: rep, yRange: 0..<rep.pixelsHigh / 2), 0)
    XCTAssertGreaterThan(alphaPixels(in: rep, yRange: rep.pixelsHigh / 2..<rep.pixelsHigh), 0)
  }

  private func solidLogo() -> NSImage {
    NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
      NSColor.black.setFill()
      rect.fill()
      return true
    }
  }

  private func alphaPixels(
    in rep: NSBitmapImageRep,
    xRange: Range<Int>? = nil,
    yRange: Range<Int>? = nil
  ) -> Int {
    var count = 0
    for x in xRange ?? 0..<rep.pixelsWide {
      for y in yRange ?? 0..<rep.pixelsHigh {
        if let color = rep.colorAt(x: x, y: y), color.alphaComponent > 0.1 {
          count += 1
        }
      }
    }
    return count
  }
}

final class LogLevelStyleTests: XCTestCase {
  func testLogLevelAliasesUseConsistentSeverityColors() {
    for level in ["error", "fatal", "panic"] {
      XCTAssertEqual(LogLevelStyle.color(for: level), .red)
    }
    for level in ["warn", "warning"] {
      XCTAssertEqual(LogLevelStyle.color(for: level), .orange)
    }
    for level in ["debug", "trace"] {
      XCTAssertEqual(LogLevelStyle.color(for: level), .purple)
    }
    for level in ["info", "information", "unknown"] {
      XCTAssertEqual(LogLevelStyle.color(for: level), .secondary)
    }
  }
}

final class MenuBarNodeSelectionTests: XCTestCase {
  func testSelectorGroupsKeepOnlyManualSelectorGroupsInProfileOrder() {
    let groups = [
      group(name: "Fallback", type: "Fallback"),
      group(name: "Auto", type: "URLTest"),
      group(name: "Elite", type: "Selector"),
      group(name: "Region", type: "select"),
    ]

    let result = MenuBarNodeSelection.selectorGroups(from: groups, runMode: .rule)

    XCTAssertEqual(result.map(\.name), ["Elite", "Region"])
  }

  func testGlobalGroupOnlyAppearsInGlobalMode() {
    let groups = [
      group(name: "Elite", type: "Selector"),
      group(name: "GLOBAL", type: "Selector"),
    ]

    XCTAssertEqual(
      MenuBarNodeSelection.selectorGroups(from: groups, runMode: .rule).map(\.name),
      ["Elite"]
    )
    XCTAssertEqual(
      MenuBarNodeSelection.selectorGroups(from: groups, runMode: .direct).map(\.name),
      ["Elite"]
    )
    XCTAssertEqual(
      MenuBarNodeSelection.selectorGroups(from: groups, runMode: .global).map(\.name),
      ["Elite", "GLOBAL"]
    )
  }

  func testSelectorGroupsSkipGroupsWithoutSelectableNodes() {
    let groups = [
      group(name: "Elite", type: "Selector"),
      ProxyGroup(
        name: "Empty",
        type: "Selector",
        selected: nil,
        nodes: [node("Locked", selectable: false)]
      ),
    ]

    XCTAssertEqual(
      MenuBarNodeSelection.selectorGroups(from: groups, runMode: .rule).map(\.name),
      ["Elite"]
    )
  }

  func testSelectorGroupsExcludePinnedGroupsToAvoidDuplicateRows() {
    let groups = [
      group(name: "Elite", type: "Selector"),
      group(name: "Region", type: "select"),
      group(name: "Backup", type: "Selector"),
    ]

    // Pinned groups already render as their own flat rows, so the node-selection
    // section must drop them (case-insensitively) to avoid duplicate rows.
    XCTAssertEqual(
      MenuBarNodeSelection.selectorGroups(
        from: groups,
        runMode: .rule,
        excludingPinned: ["region"]
      ).map(\.name),
      ["Elite", "Backup"]
    )

    // Back-compatible default keeps every selector group when nothing is pinned.
    XCTAssertEqual(
      MenuBarNodeSelection.selectorGroups(from: groups, runMode: .rule).map(\.name),
      ["Elite", "Region", "Backup"]
    )
  }

  func testCurrentSelectionLabelPrefersConfiguredSelectionThenFirstSelectable() {
    let configured = ProxyGroup(
      name: "Elite",
      type: "Selector",
      selected: "JP",
      nodes: [node("JP"), node("US")]
    )
    XCTAssertEqual(MenuBarNodeSelection.currentSelectionLabel(for: configured), "JP")

    let unset = ProxyGroup(
      name: "Region",
      type: "Selector",
      selected: nil,
      nodes: [node("Locked", selectable: false), node("HK")]
    )
    XCTAssertEqual(MenuBarNodeSelection.currentSelectionLabel(for: unset), "HK")

    let empty = ProxyGroup(
      name: "Empty",
      type: "Selector",
      selected: nil,
      nodes: [node("Locked", selectable: false)]
    )
    XCTAssertEqual(
      MenuBarNodeSelection.currentSelectionLabel(for: empty),
      String(localized: "Select")
    )
  }

  func testNodeMenuTitleAppendsDelayExceptWhenUnknown() {
    XCTAssertEqual(
      MenuBarNodeSelection.nodeMenuTitle(for: node("JP", delayState: .measured(73))),
      "JP · 73 ms"
    )
    XCTAssertEqual(
      MenuBarNodeSelection.nodeMenuTitle(for: node("JP", delayState: .testing)),
      "JP · Testing"
    )
    XCTAssertEqual(
      MenuBarNodeSelection.nodeMenuTitle(for: node("JP", delayState: .timeout)),
      "JP · Timeout"
    )
    XCTAssertEqual(
      MenuBarNodeSelection.nodeMenuTitle(for: node("JP", delayState: .error("x"))),
      "JP · No result"
    )
    // Unknown is omitted so large node menus stay readable.
    XCTAssertEqual(
      MenuBarNodeSelection.nodeMenuTitle(for: node("JP", delayState: .unknown)),
      "JP"
    )
  }

  private func group(name: String, type: String, selected: String? = nil) -> ProxyGroup {
    ProxyGroup(
      name: name,
      type: type,
      selected: selected,
      nodes: [node("[vless]JP Nano"), node("[vless]US LAS")]
    )
  }

  private func node(
    _ name: String,
    selectable: Bool = true,
    delayState: ProxyDelayState = .unknown
  ) -> ProxyNode {
    ProxyNode(name: name, type: "vless", delay: nil, isSelectable: selectable, delayState: delayState)
  }
}
