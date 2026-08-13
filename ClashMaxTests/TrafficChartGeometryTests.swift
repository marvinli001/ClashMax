import SwiftUI
import XCTest
@testable import ClashMax

@MainActor
final class TrafficChartGeometryTests: XCTestCase {
  private func samples(_ downloads: [Int]) -> [TrafficSample] {
    downloads.map { TrafficSample(upload: 0, download: $0) }
  }

  // MARK: - Fixed window

  func testShortHistoryPadsOnTheLeftSoNewSamplesEnterFromTheRight() {
    let geometry = TrafficChartGeometry(samples: samples([0, 4096]), slotCount: 8)

    XCTAssertEqual(geometry.download.count, 8)
    // The plot spacing is what has to stay constant; the two real samples own the
    // two rightmost slots instead of being stretched across the whole width.
    XCTAssertEqual(Array(geometry.download.prefix(6)), Array(repeating: 0, count: 6))
    XCTAssertGreaterThan(geometry.download[7], 0)
  }

  func testLongHistoryKeepsTheNewestSlots() {
    let geometry = TrafficChartGeometry(samples: samples([1, 2, 3, 4, 5]), slotCount: 3)

    XCTAssertEqual(geometry.download.count, 3)
    XCTAssertEqual(geometry.ceiling, TrafficChartGeometry.minimumCeiling)
    // 3, 4, 5 — the oldest two are dropped, not resampled.
    XCTAssertEqual(geometry.download.map { $0 * Double(geometry.ceiling) }, [3, 4, 5])
  }

  func testSlotCountIsNeverLessThanTwoSoAPathCanBeDrawn() {
    XCTAssertEqual(TrafficChartGeometry(samples: [], slotCount: 0).download.count, 2)
    XCTAssertEqual(TrafficChartGeometry(samples: [], slotCount: 1).upload.count, 2)
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
    // The old chart re-normalised against the raw maximum, so this drift alone
    // moved every point in the plot. Inside a rung, nothing moves but the tip.
    let quiet = TrafficChartGeometry(samples: samples([120_000, 131_000]), slotCount: 4)
    let busier = TrafficChartGeometry(samples: samples([120_000, 148_000]), slotCount: 4)

    XCTAssertEqual(quiet.ceiling, busier.ceiling)
    XCTAssertEqual(quiet.download[2], busier.download[2], accuracy: 0.0001)
  }

  func testIdleTrickleStaysFlatInsteadOfFillingThePlot() {
    let geometry = TrafficChartGeometry(samples: samples([40, 12, 40]), slotCount: 3)

    XCTAssertEqual(geometry.ceiling, TrafficChartGeometry.minimumCeiling)
    // A 40 B/s keepalive used to normalise to full height on an idle link.
    XCTAssertLessThan(geometry.download.max() ?? 1, 0.05)
  }

  func testHeightsAreNormalisedAgainstTheSharedCeilingAndClamped() {
    let geometry = TrafficChartGeometry(
      samples: [TrafficSample(upload: 5000, download: 10000)],
      slotCount: 2
    )

    XCTAssertEqual(geometry.ceiling, 10000)
    XCTAssertEqual(geometry.download[1], 1, accuracy: 0.0001)
    // Upload and download share one scale, so the two lines stay comparable.
    XCTAssertEqual(geometry.upload[1], 0.5, accuracy: 0.0001)
    XCTAssertTrue(geometry.download.allSatisfy { $0 >= 0 && $0 <= 1 })
  }

  func testEmptyHistoryDrawsAFlatLineRatherThanDividingByZero() {
    let geometry = TrafficChartGeometry(samples: [], slotCount: 6)

    XCTAssertEqual(geometry.download, Array(repeating: 0, count: 6))
    XCTAssertEqual(geometry.upload, Array(repeating: 0, count: 6))
    XCTAssertGreaterThan(geometry.ceiling, 0)
  }

  // MARK: - Animation vector

  func testAnimatableVectorInterpolatesEverySlotAtOnce() {
    let start = AnimatableVector([0, 0.5, 1])
    let end = AnimatableVector([1, 0.5, 0])

    var delta = end - start
    delta.scale(by: 0.5)
    let midpoint = start + delta

    XCTAssertEqual(midpoint.values, [0.5, 0.5, 0.5])
  }

  func testAnimatableVectorTreatsTheEmptyZeroAsAllZeroes() {
    // SwiftUI subtracts against `.zero` when an animation starts, and `.zero` has
    // no length. Truncating there would collapse the first animated frame.
    let vector = AnimatableVector([0.25, 0.75])

    XCTAssertEqual((vector - .zero).values, [0.25, 0.75])
    XCTAssertEqual((AnimatableVector.zero + vector).values, [0.25, 0.75])
    XCTAssertEqual(vector.magnitudeSquared, 0.25 * 0.25 + 0.75 * 0.75, accuracy: 0.0001)
  }

  // MARK: - Curve

  func testCurveStaysInsideThePlotOnASpike() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 40)
    let shape = TrafficSeriesShape(values: [0, 0, 1, 0, 0], smoothing: 0.2, isClosed: true)

    let bounds = shape.path(in: rect).boundingRect

    // Catmull-Rom control points overshoot on a spike; unclamped they bow the
    // curve under the baseline and leak the area fill below the chart.
    XCTAssertGreaterThanOrEqual(bounds.minY, rect.minY - 0.001)
    XCTAssertLessThanOrEqual(bounds.maxY, rect.maxY + 0.001)
    XCTAssertGreaterThanOrEqual(bounds.minX, rect.minX - 0.001)
    XCTAssertLessThanOrEqual(bounds.maxX, rect.maxX + 0.001)
  }

  func testDegenerateInputsProduceAnEmptyPathInsteadOfCrashing() {
    let rect = CGRect(x: 0, y: 0, width: 100, height: 40)

    XCTAssertTrue(TrafficSeriesShape(values: [], smoothing: 0.2).path(in: rect).isEmpty)
    XCTAssertTrue(TrafficSeriesShape(values: [0.5], smoothing: 0.2).path(in: rect).isEmpty)
    XCTAssertTrue(
      TrafficSeriesShape(values: [0, 1], smoothing: 0.2)
        .path(in: CGRect(x: 0, y: 0, width: 0, height: 40))
        .isEmpty
    )
  }
}
