import SwiftUI

enum DashboardPowerButtonAsset {
  static let fileName = "2773-5719-egg-radio-button-v2"
  static let fileExtension = "riv"
  static let bundleSubdirectory = "Animations"
  static let stateMachineName = "Radiobutton"
  static let hoverInputName = "isHover"
  static let pressedInputName = "Pressed"
  static let backInputName = "Back"

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
    colorScheme == .dark ? "dark-unframed-rive-visual" : "light-unframed-rive-visual"
  }
}

struct CoreVisualView: View {
  let state: DashboardRuntimeState
  let reduceMotion: Bool
  var activationTrigger = 0

  var body: some View {
    if state.isVisualActive {
      ActiveCorePowerSymbol(
        state: state,
        reduceMotion: reduceMotion,
        activationTrigger: activationTrigger
      )
      .transition(.opacity.combined(with: .scale(scale: 0.92)))
    } else {
      RestingCoreSymbol(state: state, reduceMotion: reduceMotion)
        .transition(.opacity)
    }
  }
}

private struct RestingCoreSymbol: View {
  @Environment(\.colorScheme) private var colorScheme
  let state: DashboardRuntimeState
  let reduceMotion: Bool

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)
      ZStack {
        Image(systemName: symbolName)
          .font(.system(size: side * 0.62, weight: .regular))
          .foregroundStyle(tint)
          .symbolRenderingMode(.hierarchical)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("ClashMax core"))
    .accessibilityValue(Text(state.displayTitle))
  }

  private var symbolName: String {
    switch state {
    case .blocked:
      return "exclamationmark.circle"
    case .crashed:
      return "exclamationmark.triangle.fill"
    default:
      return "power.circle"
    }
  }

  private var tint: SwiftUI.Color {
    switch state {
    case .blocked:
      return .secondary
    case .crashed:
      return .red
    default:
      return .accentColor
    }
  }
}

private struct ActiveCorePowerSymbol: View {
  @Environment(\.colorScheme) private var colorScheme
  let state: DashboardRuntimeState
  let reduceMotion: Bool
  let activationTrigger: Int

  @State private var pulsing = false
  @State private var pressDip = false

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)

      ZStack {
        Circle()
          .fill(tint.opacity(haloOpacity))
          .blur(radius: side * 0.20)
          .scaleEffect(pulsing ? 1.08 : 0.94)

        Circle()
          .stroke(tint.opacity(0.36), lineWidth: max(1.0, side * 0.012))
          .frame(width: side * 0.80, height: side * 0.80)
          .opacity(pulsing ? 0.95 : 0.65)

        Image(systemName: "power.circle.fill")
          .font(.system(size: side * 0.62, weight: .regular))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(tint)
          .shadow(color: tint.opacity(colorScheme == .dark ? 0.55 : 0.40), radius: side * 0.08)
          .scaleEffect(pressDip ? 0.92 : 1.0)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .aspectRatio(1, contentMode: .fit)
    .onAppear { syncPulse() }
    .onChange(of: state) { _, _ in syncPulse() }
    .onChange(of: reduceMotion) { _, _ in syncPulse() }
    .onChange(of: activationTrigger) { _, _ in flashPress() }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("ClashMax power button"))
    .accessibilityValue(Text(state.displayTitle))
  }

  private var tint: Color {
    state.isStarting ? .cyan : .green
  }

  private var haloOpacity: Double {
    state.isStarting ? 0.42 : 0.30
  }

  private func syncPulse() {
    Task { @MainActor in
      pulsing = false
      guard !reduceMotion else { return }
      try? await Task.sleep(nanoseconds: 16_000_000)
      withAnimation(
        .easeInOut(duration: state.isStarting ? 1.1 : 1.7)
          .repeatForever(autoreverses: true)
      ) {
        pulsing = true
      }
    }
  }

  private func flashPress() {
    guard !reduceMotion else { return }
    Task { @MainActor in
      withAnimation(.spring(response: 0.20, dampingFraction: 0.6)) {
        pressDip = true
      }
      try? await Task.sleep(nanoseconds: 140_000_000)
      withAnimation(.spring(response: 0.34, dampingFraction: 0.7)) {
        pressDip = false
      }
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
