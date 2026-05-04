import RiveRuntime
import SwiftUI

enum DashboardPowerButtonAsset {
  static let fileName = "410-767-power-button"
  static let fileExtension = "riv"
  static let bundleSubdirectory = "Animations"

  static func bundleURL(in bundle: Bundle = .main) -> URL? {
    bundle.url(
      forResource: fileName,
      withExtension: fileExtension,
      subdirectory: bundleSubdirectory
    )
  }

  static func data(in bundle: Bundle = .main) -> Data? {
    guard let url = bundleURL(in: bundle) else { return nil }
    return try? Data(contentsOf: url)
  }
}

enum DashboardPowerButtonSurfaceStyle {
  static func surfaceID(for colorScheme: SwiftUI.ColorScheme) -> String {
    colorScheme == .dark ? "dark-elevated-power-surface" : "light-elevated-power-surface"
  }

  static func outerFill(for colorScheme: SwiftUI.ColorScheme) -> SwiftUI.Color {
    colorScheme == .dark
      ? SwiftUI.Color(nsColor: .controlBackgroundColor).opacity(0.22)
      : SwiftUI.Color(nsColor: .controlBackgroundColor)
  }

  static func innerFill(for colorScheme: SwiftUI.ColorScheme) -> SwiftUI.Color {
    colorScheme == .dark
      ? SwiftUI.Color(red: 0.055, green: 0.070, blue: 0.072)
      : SwiftUI.Color(red: 0.100, green: 0.115, blue: 0.112)
  }

  static func stroke(for colorScheme: SwiftUI.ColorScheme) -> SwiftUI.Color {
    colorScheme == .dark
      ? SwiftUI.Color.white.opacity(0.10)
      : SwiftUI.Color.black.opacity(0.10)
  }

  static func shadow(for colorScheme: SwiftUI.ColorScheme) -> SwiftUI.Color {
    colorScheme == .dark
      ? SwiftUI.Color.black.opacity(0.22)
      : SwiftUI.Color.black.opacity(0.08)
  }
}

struct CoreVisualView: View {
  let state: DashboardRuntimeState
  let reduceMotion: Bool

  var body: some View {
    if let data = DashboardPowerButtonAsset.data(),
       let riveVisual = RivePowerButtonVisualView(data: data, state: state, reduceMotion: reduceMotion) {
      riveVisual
    } else {
      FallbackCoreVisualView(state: state, reduceMotion: reduceMotion)
    }
  }
}

private struct RivePowerButtonVisualView: View {
  @Environment(\.colorScheme) private var colorScheme
  @StateObject private var viewModel: RiveViewModel
  let state: DashboardRuntimeState
  let reduceMotion: Bool

  init?(data: Data, state: DashboardRuntimeState, reduceMotion: Bool) {
    guard let file = try? RiveFile(data: data, loadCdn: false) else {
      return nil
    }
    let model = RiveModel(riveFile: file)
    _viewModel = StateObject(
      wrappedValue: RiveViewModel(
        model,
        fit: .contain,
        autoPlay: false
      )
    )
    self.state = state
    self.reduceMotion = reduceMotion
  }

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let outerCorner = max(22, side * 0.20)
      let innerCorner = max(18, side * 0.17)
      let innerSide = side * 0.86
      let shellShape = RoundedRectangle(cornerRadius: outerCorner, style: .continuous)
      let riveShape = RoundedRectangle(cornerRadius: innerCorner, style: .continuous)

      ZStack {
        shellShape
          .fill(DashboardPowerButtonSurfaceStyle.outerFill(for: colorScheme))
          .overlay {
            shellShape.stroke(DashboardPowerButtonSurfaceStyle.stroke(for: colorScheme), lineWidth: 1)
          }
          .shadow(color: DashboardPowerButtonSurfaceStyle.shadow(for: colorScheme), radius: 18, x: 0, y: 10)

        riveShape
          .fill(DashboardPowerButtonSurfaceStyle.innerFill(for: colorScheme))
          .frame(width: innerSide, height: innerSide)
          .overlay {
            viewModel.view()
              .aspectRatio(1, contentMode: .fit)
              .clipShape(riveShape)
          }
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .aspectRatio(1, contentMode: .fit)
    .onAppear {
      syncAnimation()
    }
    .onChange(of: state) { _, _ in
      syncAnimation()
    }
    .onChange(of: reduceMotion) { _, _ in
      syncAnimation()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("ClashMax power button"))
    .accessibilityValue(Text(state.displayTitle))
  }

  private func syncAnimation() {
    if reduceMotion {
      viewModel.reset()
      viewModel.pause()
      return
    }

    if state.isStarting || state.isRunning {
      viewModel.reset()
      viewModel.play(loop: .oneShot)
    } else {
      viewModel.reset()
      viewModel.pause()
    }
  }
}

private struct FallbackCoreVisualView: View {
  @Environment(\.colorScheme) private var colorScheme
  let state: DashboardRuntimeState
  let reduceMotion: Bool
  @State private var isAnimating = false

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      let chipSide = side * 0.42
      let orbitRadius = side * 0.34

      ZStack {
        CoreVisualBackdrop(accent: accent, side: side, isActive: state.isStarting || state.isRunning)

        ForEach(0..<3, id: \.self) { index in
          CoreVisualOrbit(
            index: index,
            side: side,
            radius: orbitRadius,
            accent: accent,
            isAnimating: isAnimating && !reduceMotion
          )
        }

        RoundedRectangle(cornerRadius: max(16, chipSide * 0.22), style: .continuous)
          .fill(.regularMaterial)
          .background(accent.opacity(colorScheme == .dark ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: max(16, chipSide * 0.22), style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: max(16, chipSide * 0.22), style: .continuous)
              .stroke(accent.opacity(0.24), lineWidth: 1)
          }
          .shadow(color: accent.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: side * 0.08, y: side * 0.04)
          .frame(width: chipSide, height: chipSide)

        Image(systemName: symbolName)
          .font(.system(size: max(28, chipSide * 0.34), weight: .semibold))
          .foregroundStyle(accent)
          .symbolEffect(.pulse, options: !reduceMotion && state.isStarting ? .repeating : .default, value: state.isStarting)

        CoreVisualStatusDots(side: side, accent: accent, state: state)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .aspectRatio(1, contentMode: .fit)
    .onAppear {
      guard !reduceMotion else { return }
      isAnimating = true
    }
    .onChange(of: reduceMotion) { _, reduceMotion in
      isAnimating = !reduceMotion
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("ClashMax core visual"))
    .accessibilityValue(Text(state.displayTitle))
  }

  private var symbolName: String {
    switch state {
    case .running:
      return "shield.lefthalf.filled"
    case .starting:
      return "dot.radiowaves.left.and.right"
    case .crashed:
      return "exclamationmark.triangle.fill"
    case .blocked:
      return "powerplug.fill"
    case .stopped:
      return "power"
    }
  }

  private var accent: SwiftUI.Color {
    switch state {
    case .running:
      return .green
    case .starting:
      return .cyan
    case .crashed:
      return .red
    case .blocked:
      return .secondary
    case .stopped:
      return .accentColor
    }
  }
}

private struct CoreVisualBackdrop: View {
  @Environment(\.colorScheme) private var colorScheme
  let accent: SwiftUI.Color
  let side: CGFloat
  let isActive: Bool

  var body: some View {
    ZStack {
      Circle()
        .fill(accent.opacity(colorScheme == .dark ? 0.12 : 0.08))
        .blur(radius: max(16, side * 0.10))
        .scaleEffect(isActive ? 0.84 : 0.72)

      Circle()
        .stroke(accent.opacity(0.18), lineWidth: 1)
        .frame(width: side * 0.72, height: side * 0.72)

      Circle()
        .stroke(.secondary.opacity(colorScheme == .dark ? 0.18 : 0.13), lineWidth: 1)
        .frame(width: side * 0.50, height: side * 0.50)
    }
  }
}

private struct CoreVisualOrbit: View {
  let index: Int
  let side: CGFloat
  let radius: CGFloat
  let accent: SwiftUI.Color
  let isAnimating: Bool

  var body: some View {
    let start = 0.08 + CGFloat(index) * 0.15
    let end = start + 0.18

    Circle()
      .trim(from: start, to: end)
      .stroke(
        LinearGradient(
          colors: [accent.opacity(0.0), accent.opacity(0.58), accent.opacity(0.0)],
          startPoint: .leading,
          endPoint: .trailing
        ),
        style: StrokeStyle(lineWidth: max(1.4, side * 0.008), lineCap: .round)
      )
      .frame(width: radius * 2, height: radius * 2)
      .rotationEffect(.degrees(isAnimating ? 360 + Double(index * 18) : Double(index * 36)))
      .animation(
        isAnimating
          ? .linear(duration: 5.2 + Double(index) * 0.6).repeatForever(autoreverses: false)
          : .easeOut(duration: 0.2),
        value: isAnimating
      )
  }
}

private struct CoreVisualStatusDots: View {
  let side: CGFloat
  let accent: SwiftUI.Color
  let state: DashboardRuntimeState

  var body: some View {
    let dotSide = max(7, side * 0.045)
    let radius = side * 0.33

    ForEach(0..<3, id: \.self) { index in
      Circle()
        .fill(index == activeIndex ? accent : SwiftUI.Color.secondary.opacity(0.34))
        .overlay {
          Circle()
            .stroke(.background.opacity(0.55), lineWidth: 1)
        }
        .frame(width: dotSide, height: dotSide)
        .offset(
          x: cos(angle(for: index)) * radius,
          y: sin(angle(for: index)) * radius
        )
    }
  }

  private var activeIndex: Int {
    switch state {
    case .blocked, .crashed:
      return 0
    case .stopped:
      return 1
    case .starting, .running:
      return 2
    }
  }

  private func angle(for index: Int) -> CGFloat {
    CGFloat(Double(index) * (2 * .pi / 3) - .pi / 2)
  }
}
