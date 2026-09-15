@testable import ClashMax
import SwiftUI
import XCTest

@MainActor
final class TrafficChartGeometryTests: XCTestCase {
  private func samples(_ downloads: [Int]) -> [TrafficSample] {
    downloads.map { TrafficSample(upload: 0, download: $0) }
  }

  private func shape(
    values: [Double],
    newestSequence: Int,
    slotCount: Int = 4,
    head: Double,
    scale: Double = 1,
    isClosed: Bool = false
  ) -> TrafficSeriesShape {
    TrafficSeriesShape(
      values: values,
      newestSequence: newestSequence,
      slotCount: slotCount,
      head: head,
      scale: scale,
      smoothing: 0,
      isClosed: isClosed,
      edgeInset: 0
    )
  }

  // MARK: - Sequence anchoring

  func testSamplesKeepTheirSequenceNumbersAcrossTheRetainedWindow() {
    // Ten samples have arrived, the store kept the last three: they are samples 7, 8 and 9.
    let geometry = TrafficChartGeometry(samples: samples([3, 4, 5]), sampleCount: 10)

    XCTAssertEqual(geometry.newestSequence, 9)
    XCTAssertEqual(geometry.download, [3, 4, 5])
    XCTAssertEqual(geometry.ceiling, TrafficChartGeometry.minimumCeiling)
  }

  func testSequenceNeverFallsBehindTheSamplesActuallyHeld() {
    // A store that has not been told a count still gets a consistent sequence.
    XCTAssertEqual(TrafficChartGeometry(samples: samples([1, 2]), sampleCount: 0).newestSequence, 1)
    XCTAssertEqual(TrafficChartGeometry(samples: [], sampleCount: 0).newestSequence, -1)
  }

  func testTheNewestSampleSitsAtTheRightEdgeWhenTheHeadHasCaughtUp() {
    let rect = CGRect(x: 0, y: 0, width: 300, height: 40)
    // Four slots span the width, so one step is 100 points.
    let path = shape(values: [0, 0, 0, 0], newestSequence: 9, head: 9).path(in: rect)

    XCTAssertEqual(path.boundingRect.maxX, 300, accuracy: 0.001)
    XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.001)
  }

  func testAdvancingTheHeadSlidesEverySampleLeftByTheSameDistance() {
    // This is what the old chart could not do: a sample's position moves, its height does not.
    let rect = CGRect(x: 0, y: 0, width: 300, height: 40)
    let atRest = shape(values: [0, 1, 0, 0], newestSequence: 9, head: 9).path(in: rect).boundingRect
    let halfWay = shape(values: [0, 1, 0, 0], newestSequence: 9, head: 9.5).path(in: rect).boundingRect

    XCTAssertEqual(atRest.minX - halfWay.minX, 50, accuracy: 0.001)
    XCTAssertEqual(atRest.maxX - halfWay.maxX, 50, accuracy: 0.001)
    XCTAssertEqual(atRest.minY, halfWay.minY, accuracy: 0.001)
  }

  func testASampleStillSlidingInIsDrawnPastTheRightEdgeForTheClipToHandle() {
    let rect = CGRect(x: 0, y: 0, width: 300, height: 40)
    // Sample 10 just arrived; the head is still easing from 9 towards it.
    let path = shape(values: [0, 0, 0, 0], newestSequence: 10, head: 9.25).path(in: rect)

    XCTAssertEqual(path.boundingRect.maxX, 375, accuracy: 0.001)
  }

  // MARK: - Stable vertical scale

  func testCeilingSnapsUpToTheNextRung() {
    XCTAssertEqual(TrafficChartGeometry.niceCeiling(atLeast: 1500), 1500)
    XCTAssertEqual(TrafficChartGeometry.niceCeiling(atLeast: 2000), 2000)
    XCTAssertEqual(TrafficChartGeometry.niceCeiling(atLeast: 2001), 2500)
    XCTAssertEqual(TrafficChartGeometry.niceCeiling(atLeast: 5_000_001), 6_000_000)
  }

  func testCeilingAlwaysLeavesThePeakAtFourFifthsOfThePlot() {
    // A ceiling that holds still is only worth having if the curve still fills
    // the plot; a coarser ladder can park the peak at half height.
    for peak in stride(from: 1100, through: 40_000_000, by: 3137) {
      let ceiling = TrafficChartGeometry.niceCeiling(atLeast: peak)
      XCTAssertGreaterThanOrEqual(ceiling, peak, "ceiling clipped the peak at \(peak)")
      // The infimum is exactly 0.8, approached but never reached; the slack is
      // only there so the assertion can't turn on a floating-point last bit.
      XCTAssertGreaterThan(
        Double(peak) / Double(ceiling),
        0.799,
        "peak \(peak) only reached \(Double(peak) / Double(ceiling)) of the plot"
      )
    }
  }

  func testCeilingHoldsStillWhileTheSamplesWanderInsideOneStep() {
    let quiet = TrafficChartGeometry(samples: samples([120_000, 131_000]), sampleCount: 2)
    let busier = TrafficChartGeometry(samples: samples([120_000, 148_000]), sampleCount: 2)

    XCTAssertEqual(quiet.ceiling, busier.ceiling)
  }

  func testIdleTrickleStaysFlatInsteadOfFillingThePlot() {
    let geometry = TrafficChartGeometry(samples: samples([40, 12, 40]), sampleCount: 3)

    XCTAssertEqual(geometry.ceiling, TrafficChartGeometry.minimumCeiling)
    // A 40 B/s keepalive used to normalise to full height on an idle link.
    let tallest = (geometry.download.max() ?? 0) / Double(geometry.ceiling)
    XCTAssertLessThan(tallest, 0.05)
  }

  func testUploadAndDownloadShareOneCeiling() {
    let geometry = TrafficChartGeometry(
      samples: [TrafficSample(upload: 5000, download: 10000)],
      sampleCount: 1
    )

    XCTAssertEqual(geometry.ceiling, 10000)
    XCTAssertEqual(geometry.download, [10000])
    XCTAssertEqual(geometry.upload, [5000])
  }

  func testHeightsAreScaledAndClampedInsideThePlot() {
    let rect = CGRect(x: 0, y: 0, width: 300, height: 40)
    // A value past the ceiling is pinned to the top rather than escaping the plot.
    let path = shape(values: [0, 20000, 10000, 0], newestSequence: 3, head: 3, scale: 1 / 10000).path(in: rect)

    XCTAssertEqual(path.boundingRect.minY, 0, accuracy: 0.001)
    XCTAssertEqual(path.boundingRect.maxY, 40, accuracy: 0.001)
  }

  func testEmptyHistoryDrawsNothingRatherThanDividingByZero() {
    let geometry = TrafficChartGeometry(samples: [], sampleCount: 0)

    XCTAssertEqual(geometry.download, [])
    XCTAssertEqual(geometry.upload, [])
    XCTAssertGreaterThan(geometry.ceiling, 0)
  }

  // MARK: - Curve

  func testCurveStaysInsideThePlotVerticallyOnASpike() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
    let spike = TrafficSeriesShape(
      values: [0, 0, 1, 0, 0],
      newestSequence: 4,
      slotCount: 5,
      head: 4,
      scale: 1,
      smoothing: 0.2,
      isClosed: true,
      edgeInset: 0
    )

    let bounds = spike.path(in: rect).boundingRect

    // Catmull-Rom control points overshoot on a spike; unclamped they bow the
    // curve under the baseline and leak the area fill below the chart.
    XCTAssertGreaterThanOrEqual(bounds.minY, rect.minY - 0.001)
    XCTAssertLessThanOrEqual(bounds.maxY, rect.maxY + 0.001)
  }

  func testDegenerateInputsProduceAnEmptyPathInsteadOfCrashing() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 40)

    XCTAssertTrue(shape(values: [], newestSequence: -1, head: 0).path(in: rect).isEmpty)
    XCTAssertTrue(shape(values: [0.5], newestSequence: 0, head: 0).path(in: rect).isEmpty)
    XCTAssertTrue(shape(values: [0, 1], newestSequence: 1, slotCount: 1, head: 1).path(in: rect).isEmpty)
    XCTAssertTrue(
      shape(values: [0, 1], newestSequence: 1, head: 1)
        .path(in: CGRect(x: 0, y: 0, width: 0, height: 40))
        .isEmpty
    )
  }
}
