import SwiftUI

/// The traffic chart's data, resolved away from SwiftUI so the parts that decide how the chart
/// *moves* can be tested without rendering a view.
///
/// Every retained sample keeps its sequence number, and the shape places a sample by that number
/// rather than by its position in the array. That is the whole trick behind a chart that scrolls:
/// the old chart interpolated each *slot* from its previous height to its next one, so on every
/// tick all 72 points morphed towards their right-hand neighbour at once. With steady traffic that
/// reads as a slide; with real, spiky traffic every point is busy going somewhere else and the
/// whole line shivers for the full second. Here nothing morphs. A sample's height is fixed the
/// moment it arrives, only the view's window (`head`) moves, and a new sample enters from the
/// right edge at the height it will keep.
///
/// The vertical scale is the other thing kept still: the ceiling snaps up to a 1/2/5-style rung
/// so ordinary fluctuation never rescales the plot, and a floor keeps an idle trickle flat.
struct TrafficChartGeometry: Equatable {
  /// Bytes per second, oldest first, one entry per retained sample.
  var download: [Double]
  var upload: [Double]
  /// Sequence number of the last entry; entry `i` is sample `newestSequence - (count - 1 - i)`.
  var newestSequence: Int
  /// Bytes per second represented by the top of the plot.
  var ceiling: Int

  /// An idle link still emits a trickle of keepalives. Never scale the plot to
  /// less than 1 KB/s, so that trickle stays visually flat.
  static let minimumCeiling = 1024

  /// - Parameter sampleCount: how many samples the store has appended in total; the retained
  ///   `samples` are the newest of them, so the last one carries sequence `sampleCount - 1`.
  init(samples: [TrafficSample], sampleCount: Int) {
    let peak = samples.reduce(0) { max($0, max($1.upload, $1.download)) }
    ceiling = Self.niceCeiling(atLeast: max(peak, Self.minimumCeiling))
    download = samples.map { Double($0.download) }
    upload = samples.map { Double($0.upload) }
    newestSequence = max(sampleCount, samples.count) - 1
  }

  /// The ladder the ceiling snaps to, in quarters of a power of ten: 1, 1.25,
  /// 1.5, 1.75, 2, 2.5, 3, 3.5, 4, 5, 6, 7, 8, 10.
  ///
  /// A coarse 1/2/5 ladder holds the scale still for longer, but it can park the
  /// ceiling at twice the peak and leave the curve crawling along the bottom half
  /// of the plot. No two rungs here are more than 25% apart, so the peak always
  /// reaches at least 80% of the plot height, and a rescale — eased in over half a
  /// second — is a small nudge rather than a jump.
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

/// One traffic series as a smoothed curve anchored to sample sequence numbers.
///
/// `head` is the sequence number currently sitting at the right edge and `scale` is `1 / ceiling`;
/// both are the animatable data. The sample values themselves never animate — see
/// `TrafficChartGeometry` for why that is the point. Points to the right of `head` (the sample
/// that is still sliding in) and left of the window are drawn and left to the view's clip.
///
/// Catmull-Rom through the samples rather than straight segments: the samples are
/// a 1 Hz reconstruction of a continuous signal, so a curve is not decoration,
/// it is closer to the thing being measured than the polyline was.
struct TrafficSeriesShape: Shape {
  var values: [Double]
  var newestSequence: Int
  /// Samples visible between the left and right edge of the plot.
  var slotCount: Int
  var head: Double
  var scale: Double
  var smoothing: CGFloat
  var isClosed: Bool
  /// Keeps the newest point's round cap inside the clip instead of cutting it in half.
  var edgeInset: CGFloat = 2

  var animatableData: AnimatablePair<Double, Double> {
    get { AnimatablePair(head, scale) }
    set {
      head = newValue.first
      scale = newValue.second
    }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path()
    guard values.count >= 2, slotCount >= 2, rect.width > 0, rect.height > 0 else { return path }

    let plotRight = rect.maxX - edgeInset
    let step = (rect.width - edgeInset * 2) / CGFloat(slotCount - 1)
    let points = values.enumerated().map { index, value in
      let sequence = Double(newestSequence - (values.count - 1 - index))
      return CGPoint(
        x: plotRight - CGFloat(head - sequence) * step,
        y: rect.maxY - rect.height * CGFloat(min(max(value * scale, 0), 1))
      )
    }

    path.move(to: points[0])
    for index in 0..<(points.count - 1) {
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
  /// Total samples appended this session (`RuntimeDataStore.trafficSampleCount`).
  let sampleCount: Int
  var inset: CGFloat = 8
  var downloadLineWidth: CGFloat = 2.4
  var uploadLineWidth: CGFloat = 2
  var baselineOpacity = 0.18
  /// Two fewer than `RuntimeDataStore` retains (72): the sample sliding in on the right and the one
  /// sliding out on the left are both still needed while they are half visible, so the window shows
  /// slightly less than the buffer and the curve never starts short of the left edge.
  var slotCount = 70
  var smoothing: CGFloat = 0.2
  /// mihomo's `/traffic` websocket emits one sample per second. Easing the window across that
  /// same second is what makes the chart scroll instead of step; linear, because a spring would
  /// overshoot and wobble on every tick.
  var sampleInterval: Double = 1

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var head: Double = 0
  @State private var scale: Double = 1 / Double(TrafficChartGeometry.minimumCeiling)

  var body: some View {
    let geometry = TrafficChartGeometry(samples: samples, sampleCount: sampleCount)

    ZStack {
      Rectangle()
        .fill(Color.secondary.opacity(baselineOpacity))
        .frame(height: 1)
        .frame(maxHeight: .infinity, alignment: .bottom)

      series(geometry.download, in: geometry, isClosed: true)
        .fill(
          LinearGradient(
            colors: [.cyan.opacity(0.26), .cyan.opacity(0.02)],
            startPoint: .top,
            endPoint: .bottom
          )
        )

      series(geometry.download, in: geometry)
        .stroke(.cyan, style: StrokeStyle(lineWidth: downloadLineWidth, lineCap: .round, lineJoin: .round))

      series(geometry.upload, in: geometry)
        .stroke(.indigo, style: StrokeStyle(lineWidth: uploadLineWidth, lineCap: .round, lineJoin: .round))
    }
    .clipped()
    .padding(inset)
    // Explicit animations rather than `.animation(value:)`: the window must never animate
    // *backwards*. A restart resets the sequence to zero, and easing the head from 500 back to 0
    // would sweep the whole plot sideways for a second.
    .onChange(of: geometry.newestSequence, initial: true) { previous, next in
      guard next > previous, !reduceMotion else {
        head = Double(next)
        return
      }
      withAnimation(.linear(duration: sampleInterval)) {
        head = Double(next)
      }
    }
    .onChange(of: geometry.ceiling, initial: true) { previous, next in
      let target = 1 / Double(next)
      guard previous != next, !reduceMotion else {
        scale = target
        return
      }
      withAnimation(.easeInOut(duration: 0.5)) {
        scale = target
      }
    }
  }

  private func series(_ values: [Double], in geometry: TrafficChartGeometry, isClosed: Bool = false) -> TrafficSeriesShape {
    TrafficSeriesShape(
      values: values,
      newestSequence: geometry.newestSequence,
      slotCount: slotCount,
      head: head,
      scale: scale,
      smoothing: smoothing,
      isClosed: isClosed
    )
  }
}

struct DashboardTrafficSparkline: View {
  let samples: [TrafficSample]
  let sampleCount: Int

  var body: some View {
    TrafficSparkline(samples: samples, sampleCount: sampleCount)
  }
}
