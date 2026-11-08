import AppKit
@testable import ClashMax
import XCTest

final class AppActivationPolicyTests: XCTestCase {
  func testLaunchWarmupsAreSuppressedForXCTestEnvironment() {
    XCTAssertFalse(
      AppLaunchWarmupPolicy.shouldRun(
        environment: ["XCTestConfigurationFilePath": "/tmp/ClashMaxTests.xctestconfiguration"],
        isXCTestCaseAvailable: false,
        bundlePaths: []
      )
    )
  }

  func testLaunchWarmupsAreSuppressedWhenXCTestIsLoaded() {
    XCTAssertFalse(
      AppLaunchWarmupPolicy.shouldRun(
        environment: [:],
        isXCTestCaseAvailable: true,
        bundlePaths: []
      )
    )
  }

  func testLaunchWarmupsRunOutsideXCTest() {
    XCTAssertTrue(
      AppLaunchWarmupPolicy.shouldRun(
        environment: [:],
        isXCTestCaseAvailable: false,
        bundlePaths: ["/Applications/ClashMax.app"]
      )
    )
  }

  func testNoRegularWindowsUsesAccessoryPolicy() {
    XCTAssertEqual(AppActivationPolicyResolver.policy(for: []), .accessory)
  }

  func testVisibleMainWindowKeepsRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: true,
        isMiniaturized: false
      ),
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .regular)
  }

  func testVisibleSettingsWindowKeepsRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: true,
        isMiniaturized: false
      ),
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .regular)
  }

  func testMiniaturizedWindowKeepsRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: true
      ),
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .regular)
  }

  func testMenuBarPanelDoesNotKeepRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: false,
        isVisible: true,
        isMiniaturized: false,
        isPanel: true
      ),
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .accessory)
  }

  func testHiddenRegularWindowDoesNotKeepRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: false
      ),
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .accessory)
  }

  func testPanelThatCanBecomeMainDoesNotKeepRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: true,
        isMiniaturized: false,
        isPanel: true
      ),
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .accessory)
  }

  func testClosingRegularWindowSchedulesActivationPolicyRefresh() {
    let window = AppActivationPolicyWindowSnapshot(
      canBecomeMain: true,
      isVisible: true,
      isMiniaturized: false
    )

    XCTAssertTrue(AppActivationPolicyResolver.shouldRefreshAfterClosing(window))
  }

  func testClosingMenuBarPanelDoesNotScheduleActivationPolicyRefresh() {
    let window = AppActivationPolicyWindowSnapshot(
      canBecomeMain: true,
      isVisible: true,
      isMiniaturized: false,
      isPanel: true
    )

    XCTAssertFalse(AppActivationPolicyResolver.shouldRefreshAfterClosing(window))
  }

  func testNoWindowsNeedsNewMainWindow() {
    XCTAssertTrue(AppActivationPolicyResolver.shouldOpenMainWindow(for: []))
  }

  func testVisibleMainWindowDoesNotNeedNewMainWindow() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: true,
        isMiniaturized: false
      ),
    ]

    XCTAssertFalse(AppActivationPolicyResolver.shouldOpenMainWindow(for: windows))
  }

  func testMiniaturizedMainWindowDoesNotNeedNewMainWindow() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: true
      ),
    ]

    XCTAssertFalse(AppActivationPolicyResolver.shouldOpenMainWindow(for: windows))
  }

  func testHiddenMainWindowDoesNotNeedNewMainWindow() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: false
      ),
    ]

    XCTAssertFalse(AppActivationPolicyResolver.shouldOpenMainWindow(for: windows))
  }

  func testMenuBarPanelNeedsNewMainWindow() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: true,
        isMiniaturized: false,
        isPanel: true
      ),
    ]

    XCTAssertTrue(AppActivationPolicyResolver.shouldOpenMainWindow(for: windows))
  }

  func testLaunchPresentsMainWindowWithoutSilentStart() {
    XCTAssertTrue(
      MainWindowLaunchPolicy.shouldPresentMainWindowOnLaunch(
        silentStartEnabled: false,
        isLoginItemLaunch: false
      )
    )
    XCTAssertTrue(
      MainWindowLaunchPolicy.shouldPresentMainWindowOnLaunch(
        silentStartEnabled: false,
        isLoginItemLaunch: true
      )
    )
  }

  func testSilentStartOnlySuppressesLoginItemLaunches() {
    XCTAssertFalse(
      MainWindowLaunchPolicy.shouldPresentMainWindowOnLaunch(
        silentStartEnabled: true,
        isLoginItemLaunch: true
      )
    )
  }

  func testSilentStartStillPresentsMainWindowForManualLaunch() {
    XCTAssertTrue(
      MainWindowLaunchPolicy.shouldPresentMainWindowOnLaunch(
        silentStartEnabled: true,
        isLoginItemLaunch: false
      )
    )
  }

  func testMissingLaunchEventIsNotALoginItemLaunch() {
    XCTAssertFalse(AppLaunchSource.isLoginItemLaunch(nil))
  }

  func testManualOpenEventIsNotALoginItemLaunch() {
    // What Finder, Spotlight, the Dock and `open` actually send: 'aevt'/'oapp'
    // with no property data.
    XCTAssertFalse(AppLaunchSource.isLoginItemLaunch(Self.launchEvent()))
  }

  func testLoginItemLaunchEventIsDetected() {
    let event = Self.launchEvent()
    event.setParam(
      NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
      forKeyword: OSType(keyAEPropData)
    )

    XCTAssertTrue(AppLaunchSource.isLoginItemLaunch(event))
  }

  func testOtherLaunchPropertyIsNotALoginItemLaunch() {
    let event = Self.launchEvent()
    // 'othr': any launch property that is not the login-item marker.
    event.setParam(
      NSAppleEventDescriptor(enumCode: OSType(0x6f74_6872)),
      forKeyword: OSType(keyAEPropData)
    )

    XCTAssertFalse(AppLaunchSource.isLoginItemLaunch(event))
  }

  func testReopenEventIsNotALoginItemLaunch() {
    let event = Self.launchEvent(eventID: AEEventID(kAEReopenApplication))
    event.setParam(
      NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)),
      forKeyword: OSType(keyAEPropData)
    )

    XCTAssertFalse(AppLaunchSource.isLoginItemLaunch(event))
  }

  private static func launchEvent(
    eventClass: AEEventClass = AEEventClass(kCoreEventClass),
    eventID: AEEventID = AEEventID(kAEOpenApplication)
  ) -> NSAppleEventDescriptor {
    NSAppleEventDescriptor.appleEvent(
      withEventClass: eventClass,
      eventID: eventID,
      targetDescriptor: nil,
      returnID: AEReturnID(kAutoGenerateReturnID),
      transactionID: AETransactionID(kAnyTransactionID)
    )
  }
}

final class SidebarWidthResetTests: XCTestCase {
  func testForgetsSavedSidebarWidthsOnceAndKeepsLaterOnes() throws {
    let suite = "SidebarWidthResetTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let mainKey = "NSSplitView Subview Frames main-AppWindow-1, SidebarNavigationSplitView"
    let otherKey = "NSSplitView Subview Frames main-AppWindow-1, SomeOtherSplitView"
    let frames = ["0.000000, 0.000000, 208.000000, 712.000000, NO, NO"]
    defaults.set(frames, forKey: mainKey)
    defaults.set(frames, forKey: otherKey)
    defaults.set("keep", forKey: "NSWindow Frame main-AppWindow-1")

    SidebarWidthReset.applyOnce(defaults: defaults)

    XCTAssertNil(defaults.object(forKey: mainKey))
    XCTAssertNotNil(defaults.object(forKey: otherKey), "only the sidebar split view is reset")
    XCTAssertEqual(defaults.string(forKey: "NSWindow Frame main-AppWindow-1"), "keep")
    XCTAssertTrue(defaults.bool(forKey: SidebarWidthReset.completedKey))

    // A width the user sets after the reset is theirs: a later launch leaves it alone.
    defaults.set(frames, forKey: mainKey)
    SidebarWidthReset.applyOnce(defaults: defaults)
    XCTAssertNotNil(defaults.object(forKey: mainKey))
  }
}
