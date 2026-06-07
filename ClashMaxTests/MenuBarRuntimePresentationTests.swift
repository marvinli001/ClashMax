import XCTest
@testable import ClashMax

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
  func testShowsCompactUpDownLabelWhileRunningWithData() {
    let label = MenuBarTrafficStatusLabel.text(
      showsTraffic: true,
      hasTrafficData: true,
      sample: TrafficSample(upload: 348, download: 2048)
    )

    XCTAssertEqual(label, "↓ 2 KB/s ↑ 348 B/s")
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

    XCTAssertEqual(label, "↓ 0 B/s ↑ 0 B/s")
  }
}
