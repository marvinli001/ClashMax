import AppKit
import Metal
import RiveRuntime
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
    if state.isVisualActive,
       let data = DashboardPowerButtonAsset.data(),
       let riveVisual = RivePowerButtonVisualView(
        data: data,
        state: state,
        reduceMotion: reduceMotion,
        activationTrigger: activationTrigger
       ) {
      riveVisual
        .transition(.opacity.combined(with: .scale(scale: 0.6)))
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

private struct RivePowerButtonVisualView: View {
  @StateObject private var viewModel: RiveViewModel
  @State private var isHovering = false
  let state: DashboardRuntimeState
  let reduceMotion: Bool
  let activationTrigger: Int

  init?(data: Data, state: DashboardRuntimeState, reduceMotion: Bool, activationTrigger: Int) {
    guard let file = try? RiveFile(data: data, loadCdn: false) else {
      return nil
    }
    let model = RiveModel(riveFile: file)
    _viewModel = StateObject(
      wrappedValue: RiveViewModel(
        model,
        stateMachineName: DashboardPowerButtonAsset.stateMachineName,
        fit: .contain,
        autoPlay: false
      )
    )
    self.state = state
    self.reduceMotion = reduceMotion
    self.activationTrigger = activationTrigger
  }

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)

      TransparentRiveView(viewModel: viewModel)
        .aspectRatio(1, contentMode: .fit)
        .frame(width: side, height: side)
        .clipShape(Circle())
        .scaleEffect(isHovering && !state.isVisualActive ? 1.04 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: isHovering)
        .allowsHitTesting(false)
        .frame(width: proxy.size.width, height: proxy.size.height)
    }
    .aspectRatio(1, contentMode: .fit)
    .onAppear {
      syncAnimation(previousRuntimeActive: state.isVisualActive ? false : nil)
    }
    .onHover { hovering in
      isHovering = hovering
      syncHoverInput()
    }
    .onChange(of: state) { oldState, _ in
      syncAnimation(previousRuntimeActive: oldState.isVisualActive)
    }
    .onChange(of: activationTrigger) { _, _ in
      triggerPressedAnimation()
    }
    .onChange(of: reduceMotion) { _, _ in
      syncAnimation(previousRuntimeActive: nil)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("ClashMax power button"))
    .accessibilityValue(Text(state.displayTitle))
  }

  private func syncAnimation(previousRuntimeActive: Bool?) {
    if reduceMotion {
      viewModel.reset()
      viewModel.pause()
      return
    }

    syncHoverInput()

    if let previousRuntimeActive, previousRuntimeActive != state.isVisualActive {
      state.isVisualActive ? triggerPressedAnimation() : triggerBackAnimation()
    }
  }

  private func syncHoverInput() {
    guard !reduceMotion else { return }
    viewModel.setInput(DashboardPowerButtonAsset.hoverInputName, value: isHovering)
  }

  private func triggerPressedAnimation() {
    guard !reduceMotion else { return }
    viewModel.triggerInput(DashboardPowerButtonAsset.pressedInputName)
  }

  private func triggerBackAnimation() {
    guard !reduceMotion else { return }
    viewModel.triggerInput(DashboardPowerButtonAsset.backInputName)
  }
}

private struct TransparentRiveView: NSViewRepresentable {
  let viewModel: RiveViewModel

  func makeNSView(context _: Context) -> RiveView {
    let view = viewModel.createRiveView()
    configureTransparency(on: view)
    return view
  }

  func updateNSView(_ view: RiveView, context _: Context) {
    viewModel.update(view: view)
    configureTransparency(on: view)
  }

  static func dismantleNSView(_: RiveView, coordinator: Coordinator) {
    coordinator.viewModel.stop()
    coordinator.viewModel.deregisterView()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(viewModel: viewModel)
  }

  final class Coordinator {
    let viewModel: RiveViewModel

    init(viewModel: RiveViewModel) {
      self.viewModel = viewModel
    }
  }

  private func configureTransparency(on view: RiveView) {
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.wantsLayer = true
    view.layer?.isOpaque = false
    view.layer?.backgroundColor = NSColor.clear.cgColor
    (view.layer as? CAMetalLayer)?.isOpaque = false
    view.layer?.filters = nil
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
