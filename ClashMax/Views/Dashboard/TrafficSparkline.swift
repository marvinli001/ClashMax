import SwiftUI

/// The traffic chart's geometry, resolved away from SwiftUI so the parts that
/// decide how the chart *moves* can be tested without rendering a view.
///
/// Three things made the old chart read as a redraw instead of a scroll, and all
/// three live here:
///
/// - **The window used to grow.** Points were spread across `samples.count`, so
///   for the first 72 seconds of a session every new sample re-spaced the whole
///   path and the shape visibly compressed horizontally. A fixed slot count with
///   zero padding on the left keeps the spacing constant: samples enter at the
///   right edge and leave at the left, one slot per tick.
/// - **The scale used to snap.** The plot was normalised against the raw maximum
///   of the visible window, so the entire chart jumped vertically whenever a
///   spike entered or fell out. Rounding the ceiling up to a 1/2/5 × 10ⁿ step
///   means small fluctuations don't rescale anything at all.
/// - **Idle noise filled the plot.** With a raw maximum, a single 40 B/s
///   keepalive on an otherwise idle link normalised to full height and looked
///   like saturation. A floor on the ceiling keeps idle traffic flat.
struct TrafficChartGeometry: Equatable {
  /// Normalised 0...1 heights, oldest first, always exactly `slotCount` entries.
  var download: [Double]
  var upload: [Double]
  /// Bytes per second represented by the top of the plot.
  var ceiling: Int

  /// An idle link still emits a trickle of keepalives. Never scale the plot to
  /// less than 1 KB/s, so that trickle stays visually flat.
  static let minimumCeiling = 1024

  init(samples: [TrafficSample], slotCount: Int) {
    let slots = max(slotCount, 2)
    let window = Self.window(samples, slots: slots)
    let peak = window.reduce(0) { max($0, max($1.upload, $1.download)) }
    let ceiling = Self.niceCeiling(atLeast: max(peak, Self.minimumCeiling))
    let divisor = Double(ceiling)
    self.ceiling = ceiling
    self.download = window.map { min(Double($0.download) / divisor, 1) }
    self.upload = window.map { min(Double($0.upload) / divisor, 1) }
  }

  private static func window(_ samples: [TrafficSample], slots: Int) -> [TrafficSample] {
    guard samples.count < slots else { return Array(samples.suffix(slots)) }
    return Array(repeating: .zero, count: slots - samples.count) + samples
  }

  /// The ladder the ceiling snaps to, in quarters of a power of ten: 1, 1.25,
  /// 1.5, 1.75, 2, 2.5, 3, 3.5, 4, 5, 6, 7, 8, 10.
  ///
  /// A coarse 1/2/5 ladder holds the scale still for longer, but it can park the
  /// ceiling at twice the peak and leave the curve crawling along the bottom half
  /// of the plot. No two rungs here are more than 25% apart, so the peak always
  /// reaches at least 80% of the plot height, and a rescale — now that it eases
  /// in with everything else — is a small nudge rather than a jump.
  private static let ceilingSteps = [4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32, 40]

  /// Rounds up to the next rung so the vertical scale only changes on a real
  /// change of magnitude, not on every sample.
  static func niceCeiling(atLeast value: Int) -> Int {
    guard value > minimumCeiling else { return minimumCeiling }
    var unit = 1
    // Divide rather than multiply in the comparison so a pathological value
    // can't overflow the unit on the way up.
    while unit <= value / 10 {
      unit *= 10
    }
    // `value` is past the 1 KB/s floor here, so `unit` is at least 1000 and the
    // quarter divides exactly.
    let quarter = max(unit / 4, 1)
    for step in ceilingSteps where quarter * step >= value {
      return quarter * step
    }
    return quarter * 40
  }
}

/// `VectorArithmetic` over an array, so a whole series can be `animatableData`.
///
/// This is what turns the 1 Hz sample into motion: interpolating every slot at
/// once means a new sample doesn't pop in at the right edge, it slides in while
/// the rest of the series slides left.
struct AnimatableVector: VectorArithmetic {
  var values: [Double]

  init(_ values: [Double] = []) {
    self.values = values
  }

  static var zero: AnimatableVector { AnimatableVector() }

  static func + (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
    combine(lhs, rhs, +)
  }

  static func - (lhs: AnimatableVector, rhs: AnimatableVector) -> AnimatableVector {
    combine(lhs, rhs, -)
  }

  mutating func scale(by rhs: Double) {
    for index in values.indices {
      values[index] *= rhs
    }
  }

  var magnitudeSquared: Double {
    values.reduce(0) { $0 + $1 * $1 }
  }

  /// The two sides always have the same length in practice (the geometry pads to
  /// a fixed slot count), but `.zero` is empty and SwiftUI subtracts against it,
  /// so the shorter side reads as zeros rather than truncating the result.
  private static func combine(
    _ lhs: AnimatableVector,
    _ rhs: AnimatableVector,
    _ operation: (Double, Double) -> Double
  ) -> AnimatableVector {
    let count = max(lhs.values.count, rhs.values.count)
    var result = [Double]()
    result.reserveCapacity(count)
    for index in 0 ..< count {
      let left = index < lhs.values.count ? lhs.values[index] : 0
      let right = index < rhs.values.count ? rhs.values[index] : 0
      result.append(operation(left, right))
    }
    return AnimatableVector(result)
  }
}

/// One traffic series as a smoothed curve.
///
/// Catmull-Rom through the samples rather than straight segments: the samples are
/// a 1 Hz reconstruction of a continuous signal, so a curve is not decoration,
/// it is closer to the thing being measured than the polyline was.
struct TrafficSeriesShape: Shape {
  var values: AnimatableVector
  var smoothing: CGFloat
  var isClosed: Bool

  init(values: [Double], smoothing: CGFloat, isClosed: Bool = false) {
    self.values = AnimatableVector(values)
    self.smoothing = smoothing
    self.isClosed = isClosed
  }

  var animatableData: AnimatableVector {
    get { values }
    set { values = newValue }
  }

  func path(in rect: CGRect) -> Path {
    let heights = values.values
    var path = Path()
    guard heights.count >= 2, rect.width > 0, rect.height > 0 else { return path }

    let step = rect.width / CGFloat(heights.count - 1)
    let points = heights.enumerated().map { index, value in
      CGPoint(
        x: rect.minX + CGFloat(index) * step,
        y: rect.maxY - rect.height * CGFloat(min(max(value, 0), 1))
      )
    }

    path.move(to: points[0])
    for index in 0 ..< (points.count - 1) {
      let previous = points[max(index - 1, 0)]
      let start = points[index]
      let end = points[index + 1]
      let next = points[min(index + 2, points.count - 1)]
      // A control point may be pulled past the plot on a sharp spike, which would
      // bow the curve under the baseline and leak the area fill below it.
      let control1 = CGPoint(
        x: start.x + (end.x - previous.x) * smoothing,
        y: clamp(start.y + (end.y - previous.y) * smoothing, in: rect)
      )
      let control2 = CGPoint(
        x: end.x - (next.x - start.x) * smoothing,
        y: clamp(end.y - (next.y - start.y) * smoothing, in: rect)
      )
      path.addCurve(to: end, control1: control1, control2: control2)
    }

    if isClosed, let last = points.last {
      path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
      path.addLine(to: CGPoint(x: points[0].x, y: rect.maxY))
      path.closeSubpath()
    }

    return path
  }

  private func clamp(_ y: CGFloat, in rect: CGRect) -> CGFloat {
    min(max(y, rect.minY), rect.maxY)
  }
}

struct TrafficSparkline: View {
  let samples: [TrafficSample]
  var inset: CGFloat = 8
  var downloadLineWidth: CGFloat = 2.4
  var uploadLineWidth: CGFloat = 2
  var baselineOpacity = 0.18
  /// Matches `RuntimeDataStore`'s retained history, so a full buffer fills the
  /// plot exactly and nothing is dropped on the floor.
  var slotCount = 72
  var smoothing: CGFloat = 0.2
  /// mihomo's `/traffic` websocket emits one sample per second. Easing each
  /// update across that same second is what makes the chart scroll instead of
  /// step; a spring would overshoot and wobble on every tick, so this is linear.
  var sampleInterval: Double = 1

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let geometry = TrafficChartGeometry(samples: samples, slotCount: slotCount)

    ZStack {
      Rectangle()
        .fill(Color.secondary.opacity(baselineOpacity))
        .frame(height: 1)
        .frame(maxHeight: .infinity, alignment: .bottom)

      TrafficSeriesShape(values: geometry.download, smoothing: smoothing, isClosed: true)
        .fill(
          LinearGradient(
            colors: [.cyan.opacity(0.26), .cyan.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
          )
        )

      TrafficSeriesShape(values: geometry.download, smoothing: smoothing)
        .stroke(.cyan, style: StrokeStyle(lineWidth: downloadLineWidth, lineCap: .round, lineJoin: .round))

      TrafficSeriesShape(values: geometry.upload, smoothing: smoothing)
        .stroke(.indigo, style: StrokeStyle(lineWidth: uploadLineWidth, lineCap: .round, lineJoin: .round))
    }
    .padding(inset)
    .animation(reduceMotion ? nil : .linear(duration: sampleInterval), value: geometry)
  }
}

struct DashboardTrafficSparkline: View {
  let samples: [TrafficSample]

  var body: some View {
    TrafficSparkline(samples: samples)
  }
}
