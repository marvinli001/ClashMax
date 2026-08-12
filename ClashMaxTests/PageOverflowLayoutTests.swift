import SwiftUI
import XCTest
@testable import ClashMax

/// Issue #27: sections whose height grew with their row count used to push a page past the window.
/// SwiftUI grows a flexible frame to fit an oversized child instead of clipping it, so the overflow
/// escaped the page entirely — it painted over the title bar and pushed the sidebar's rows off
/// screen, leaving a window that could only be recovered by quitting.
final class PageOverflowLayoutTests: XCTestCase {
  // MARK: - Secondary sections

  func testSecondarySectionTakesAShareOfThePage() {
    XCTAssertEqual(
      SecondarySectionHeight.maxHeight(pageHeight: 600),
      600 * SecondarySectionHeight.pageHeightShare,
      accuracy: 0.001
    )
  }

  func testSecondarySectionNeverClaimsMostOfThePage() {
    for pageHeight in stride(from: CGFloat(200), through: 2_000, by: 50) {
      let height = SecondarySectionHeight.maxHeight(pageHeight: pageHeight)
      XCTAssertLessThan(
        height,
        pageHeight,
        "A summary section must leave room for the list it summarizes at page height \(pageHeight)"
      )
    }
  }

  func testSecondarySectionStopsGrowingOnATallPage() {
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 4_000), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 100_000), SecondarySectionHeight.ceiling)
  }

  func testSecondarySectionKeepsAUsableFloorOnAShortPage() {
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 40), SecondarySectionHeight.floor)
  }

  /// The height is measured, so it is zero on the first layout pass and the section would otherwise
  /// vanish (or, worse, be treated as unbounded) before geometry reports anything.
  func testSecondarySectionFallsBackToTheCeilingBeforeTheFirstGeometryPass() {
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: 0), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: -120), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: .infinity), SecondarySectionHeight.ceiling)
    XCTAssertEqual(SecondarySectionHeight.maxHeight(pageHeight: .nan), SecondarySectionHeight.ceiling)
  }

  /// The page measures itself *after* the cap is applied, so capping shrinks the page, which shrinks
  /// the cap. That has to settle instead of oscillating: re-feeding the result must never grow it.
  func testSecondarySectionHeightConvergesWhenFedItsOwnPage() {
    var pageHeight: CGFloat = 4_000
    var previous = CGFloat.greatestFiniteMagnitude

    for _ in 0..<10 {
      let height = SecondarySectionHeight.maxHeight(pageHeight: pageHeight)
      XCTAssertLessThanOrEqual(height, previous)
      previous = height
      // A page that shrinks back towards the real window as the overflow is removed.
      pageHeight = max(600, pageHeight * 0.5)
    }

    XCTAssertEqual(previous, SecondarySectionHeight.maxHeight(pageHeight: 600), accuracy: 0.001)
  }

  // MARK: - Connections layout

  func testStackedConnectionsListShrinksWithAShortPage() {
    XCTAssertEqual(ConnectionsLayout.stackedListMinHeight(availableHeight: 400), 180, accuracy: 0.001)
    XCTAssertEqual(
      ConnectionsLayout.stackedListMinHeight(availableHeight: 1_200),
      ConnectionsLayout.stackedListMinHeight,
      accuracy: 0.001
    )
  }

  func testStackedConnectionsListKeepsAFloor() {
    XCTAssertEqual(ConnectionsLayout.stackedListMinHeight(availableHeight: 100), 120, accuracy: 0.001)
    XCTAssertEqual(
      ConnectionsLayout.stackedListMinHeight(availableHeight: 0),
      ConnectionsLayout.stackedListMinHeight
    )
  }

  /// The stacked layout has to fit the list, the detail card, the controls row and the spacing
  /// between them into one page. Anything more overflowed the window.
  func testStackedConnectionsBlocksFitTheirPage() {
    let controlsAndSpacing: CGFloat = 52

    for availableHeight in stride(from: CGFloat(360), through: 1_400, by: 20) {
      let list = ConnectionsLayout.stackedListMinHeight(availableHeight: availableHeight)
      let detail = ConnectionsLayout.detailMaxHeight(mode: .stackedDetail, availableHeight: availableHeight)
      XCTAssertLessThanOrEqual(
        list + detail + controlsAndSpacing,
        availableHeight,
        "Stacked connections overflow a \(availableHeight)pt page"
      )
    }
  }

  func testSplitConnectionsDetailOwnsItsColumn() {
    XCTAssertEqual(ConnectionsLayout.detailMaxHeight(mode: .splitDetail, availableHeight: 720), 720)
  }

  func testStackedConnectionsDetailStaysASliceOfThePage() {
    XCTAssertEqual(ConnectionsLayout.detailMaxHeight(mode: .stackedDetail, availableHeight: 700), 280, accuracy: 0.001)
    XCTAssertEqual(ConnectionsLayout.detailMaxHeight(mode: .stackedDetail, availableHeight: 4_000), 320)
    XCTAssertEqual(ConnectionsLayout.detailMaxHeight(mode: .stackedDetail, availableHeight: 120), 96, accuracy: 0.001)
  }

  func testConnectionsDetailHeightFallsBackBeforeTheFirstGeometryPass() {
    XCTAssertEqual(ConnectionsLayout.detailMaxHeight(mode: .stackedDetail, availableHeight: 0), 320)
    XCTAssertEqual(ConnectionsLayout.detailMaxHeight(mode: .splitDetail, availableHeight: .nan), 320)
  }

  // MARK: - Page chrome

  /// `AdaptivePage` publishes the page height so nested sections can bound themselves against the
  /// real window; a default of zero has to mean "not measured yet", not "no room".
  func testPageHeightEnvironmentDefaultsToUnmeasured() {
    XCTAssertEqual(EnvironmentValues().pageHeight, 0)
    XCTAssertEqual(
      SecondarySectionHeight.maxHeight(pageHeight: EnvironmentValues().pageHeight),
      SecondarySectionHeight.ceiling
    )
  }
}
