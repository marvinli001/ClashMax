import Pow
import SwiftUI

enum DashboardLayoutMetrics {
  static let runModePickerWidth: CGFloat = 214
  static let proxyRoutingModePickerWidth: CGFloat = 232
  static let launchProfileControlWidth: CGFloat = 178
  static let launchMixedPortControlWidth: CGFloat = 104
  static let launchStartButtonWidth: CGFloat = 156
  static let dashboardGridSpacing: CGFloat = 12
  static let metricTileMinimumColumnWidth: CGFloat = 118
  static let metricTileSingleRowBreakpoint: CGFloat = 680
  static let metricTileTwoColumnBreakpoint: CGFloat = 420
  static let runningPairColumnsBreakpoint: CGFloat = 700

  static func pagePadding(for width: CGFloat) -> CGFloat {
    width < 760 ? 14 : 18
  }

  static func launchVisualSideLength(
    availableWidth: CGFloat,
    availableHeight: CGFloat,
    isVisualActive: Bool = false
  ) -> CGFloat {
    let width = max(0, availableWidth)
    let height = max(0, availableHeight)
    let candidate = min(width * 0.22, height * 0.26)
    let active = min(max(candidate, 112), 220)
    if isVisualActive { return active }
    let resting = min(active * 0.55, 96)
    return max(resting, 68)
  }

  static func launchControlsMaxWidth(availableWidth: CGFloat) -> CGFloat {
    min(max(availableWidth - 32, 360), 640)
  }

  static func dashboardMaxWidth(for width: CGFloat) -> CGFloat {
    width < 900 ? .infinity : 1180
  }
}

struct RunModePicker: View {
  let selection: Binding<RunMode>

  var body: some View {
    Picker("Mode", selection: selection) {
      ForEach(RunMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize(horizontal: true, vertical: false)
  }
}

struct ProxyRoutingModePicker: View {
  let selection: Binding<ProxyRoutingMode>

  var body: some View {
    Picker("Proxy Routing", selection: selection) {
      ForEach(ProxyRoutingMode.allCases) { mode in
        Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
    .fixedSize(horizontal: true, vertical: false)
  }
}

struct DashboardStatusPill: View {
  let title: String
  let value: String
  let symbolName: String
  let tint: Color

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.caption2)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(.caption, design: .rounded).weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(tint.opacity(0.20), lineWidth: 1)
    }
  }
}

struct DashboardMetricTile: View {
  let title: String
  let value: String
  let footnote: String?
  let symbolName: String
  let tint: Color

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Image(systemName: symbolName)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 28, height: 28)
          .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        Spacer()
      }

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(value)
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.62)
          .contentTransition(.numericText())
          .changeEffect(.pulse(shape: RoundedRectangle(cornerRadius: 8), style: tint.opacity(0.18), count: 1), value: value)

        if let footnote {
          Text(footnote)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
    .dashboardCard()
  }
}

struct DashboardSectionHeader: View {
  let title: String
  let symbolName: String
  var trailing: String?

  var body: some View {
    HStack(spacing: 8) {
      Label(title, systemImage: symbolName)
        .font(.headline)
      Spacer()
      if let trailing {
        Text(trailing)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}

struct DashboardEmptyRuntimeView: View {
  let title: String
  let symbolName: String
  var message: String?

  var body: some View {
    VStack(spacing: 10) {
      Image(systemName: symbolName)
        .font(.system(size: 24, weight: .semibold))
        .foregroundStyle(.tertiary)
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(.tertiary)
          .multilineTextAlignment(.center)
          .lineLimit(2)
      }
    }
    .frame(maxWidth: .infinity, minHeight: 128)
    .frame(maxHeight: .infinity, alignment: .center)
  }
}

enum DashboardCardSurfaceStyle {
  static func surfaceID(for colorScheme: ColorScheme) -> String {
    colorScheme == .dark ? "dark-material-dashboard-card" : "light-flat-dashboard-card"
  }

  static func shadowOpacity(for colorScheme: ColorScheme) -> Double {
    colorScheme == .dark ? 0.16 : 0.04
  }

  static func strokeOpacity(for colorScheme: ColorScheme) -> Double {
    colorScheme == .dark ? 0.30 : 0.55
  }
}

struct DashboardCardModifier: ViewModifier {
  @Environment(\.colorScheme) private var colorScheme
  var interactive = false

  func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
    let card = content
      .background {
        if colorScheme == .dark {
          ZStack {
            shape.fill(.regularMaterial)
            shape.fill(Color.primary.opacity(0.040))
          }
        } else {
          shape.fill(Color(nsColor: .windowBackgroundColor))
        }
      }
      .overlay {
        shape.stroke(
          Color(nsColor: .separatorColor).opacity(DashboardCardSurfaceStyle.strokeOpacity(for: colorScheme)),
          lineWidth: 1
        )
      }
      .shadow(color: .black.opacity(DashboardCardSurfaceStyle.shadowOpacity(for: colorScheme)), radius: colorScheme == .dark ? 16 : 10, x: 0, y: colorScheme == .dark ? 8 : 2)

    if colorScheme == .dark {
      card.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
    } else {
      card
    }
  }
}

extension View {
  func dashboardCard(interactive: Bool = false) -> some View {
    modifier(DashboardCardModifier(interactive: interactive))
  }
}

func dashboardDurationString(from start: Date?, now: Date = Date()) -> String {
  guard let start else { return "--" }
  let interval = max(0, Int(now.timeIntervalSince(start)))
  let hours = interval / 3600
  let minutes = (interval % 3600) / 60
  let seconds = interval % 60
  if hours > 0 {
    return String(format: "%d:%02d:%02d", hours, minutes, seconds)
  }
  return String(format: "%d:%02d", minutes, seconds)
}

struct DashboardTrafficSparkline: View {
  let samples: [TrafficSample]

  var body: some View {
    Canvas { context, size in
      let inset: CGFloat = 8
      let plot = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
      let maxValue = max(samples.map { max($0.upload, $0.download) }.max() ?? 1, 1)

      var baseline = Path()
      baseline.move(to: CGPoint(x: plot.minX, y: plot.maxY))
      baseline.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
      context.stroke(baseline, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

      context.stroke(path(for: samples.map(\.download), maxValue: maxValue, in: plot), with: .color(.cyan), lineWidth: 2.4)
      context.stroke(path(for: samples.map(\.upload), maxValue: maxValue, in: plot), with: .color(.indigo), lineWidth: 2)
    }
  }

  private func path(for values: [Int], maxValue: Int, in rect: CGRect) -> Path {
    var path = Path()
    guard !values.isEmpty else { return path }

    for (index, value) in values.enumerated() {
      let progress = values.count == 1 ? 0 : CGFloat(index) / CGFloat(values.count - 1)
      let x = rect.minX + rect.width * progress
      let y = rect.maxY - rect.height * (CGFloat(value) / CGFloat(maxValue))
      if index == 0 {
        path.move(to: CGPoint(x: x, y: y))
      } else {
        path.addLine(to: CGPoint(x: x, y: y))
      }
    }

    return path
  }
}
