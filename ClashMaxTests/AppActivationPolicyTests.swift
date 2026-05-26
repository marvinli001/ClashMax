import AppKit
import XCTest
@testable import ClashMax

final class AppActivationPolicyTests: XCTestCase {
  func testNoRegularWindowsUsesAccessoryPolicy() {
    XCTAssertEqual(AppActivationPolicyResolver.policy(for: []), .accessory)
  }

  func testVisibleMainWindowKeepsRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: true,
        isMiniaturized: false
      )
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .regular)
  }

  func testVisibleSettingsWindowKeepsRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: true,
        isMiniaturized: false
      )
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .regular)
  }

  func testMiniaturizedWindowKeepsRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: true
      )
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
      )
    ]

    XCTAssertEqual(AppActivationPolicyResolver.policy(for: windows), .accessory)
  }

  func testHiddenRegularWindowDoesNotKeepRegularPolicy() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: false
      )
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
      )
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
      )
    ]

    XCTAssertFalse(AppActivationPolicyResolver.shouldOpenMainWindow(for: windows))
  }

  func testMiniaturizedMainWindowDoesNotNeedNewMainWindow() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: true
      )
    ]

    XCTAssertFalse(AppActivationPolicyResolver.shouldOpenMainWindow(for: windows))
  }

  func testHiddenMainWindowDoesNotNeedNewMainWindow() {
    let windows = [
      AppActivationPolicyWindowSnapshot(
        canBecomeMain: true,
        isVisible: false,
        isMiniaturized: false
      )
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
      )
    ]

    XCTAssertTrue(AppActivationPolicyResolver.shouldOpenMainWindow(for: windows))
  }
}
