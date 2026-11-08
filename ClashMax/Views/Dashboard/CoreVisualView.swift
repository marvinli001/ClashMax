import Pow
import SwiftUI

struct CoreVisualView: View {
  @Environment(\.scenePhase) private var scenePhase
  let state: DashboardRuntimeState
  let reduceMotion: Bool

  var body: some View {
    Group {
      if state.isVisualActive {
        ActiveCorePowerSymbol(state: state, reduceMotion: reduceMotion)
          .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
      } else {
        RestingCoreSymbol(state: state, reduceMotion: reduceMotion)
          .transition(.opacity)
      }
    }
    .changeEffect(.pulse(shape: Circle(), style: Color.accentColor.opacity(0.5), count: 1),
                  value: state.isRunning, isEnabled: state.isRunning && !reduceMotion && scenePhase != .background)
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

/// The power symbol while the core is starting or running.
///
/// Starting breathes; running is still. The breathing halo is its own view that exists only while
/// starting, rather than a `repeatForever` animation on a flag: writing that flag back to `false`
/// without an animation does not stop a repeating animation in SwiftUI, it keeps oscillating. Taking
/// the view out of the hierarchy is the one stop that always works. The halo is a radial gradient,
/// not a blurred circle, so nothing here needs an offscreen blur pass.
private struct ActiveCorePowerSymbol: View {
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.scenePhase) private var scenePhase
  let state: DashboardRuntimeState
  let reduceMotion: Bool

  var body: some View {
    GeometryReader { proxy in
      let side = min(proxy.size.width, proxy.size.height)

      ZStack {
        if breathes {
          BreathingCoreHalo(tint: tint, side: side)
            .transition(.opacity)
          StartingCoreRing(side: side)
            .transition(.opacity)
        } else {
          CoreHalo(tint: tint, side: side, intensity: 0.30)
        }

        Circle()
          .stroke(tint.opacity(0.36), lineWidth: max(1.0, side * 0.012))
          .frame(width: side * 0.80, height: side * 0.80)
          .opacity(0.8)

        Image(systemName: "power.circle.fill")
          .font(.system(size: side * 0.62, weight: .regular))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(tint)
          .shadow(color: tint.opacity(colorScheme == .dark ? 0.55 : 0.40), radius: side * 0.08)
      }
      .frame(width: proxy.size.width, height: proxy.size.height)
      // The busy ring settles into a still power mark only after the runtime actually starts.
      .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: state.isStarting)
    }
    .aspectRatio(1, contentMode: .fit)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text("ClashMax power button"))
    .accessibilityValue(Text(state.displayTitle))
  }

  private var breathes: Bool {
    state.isStarting && !reduceMotion && scenePhase != .background
  }

  private var tint: Color {
    .accentColor
  }
}

private struct StartingCoreRing: View {
  let side: CGFloat
  @State private var rotates = false

  var body: some View {
    Circle().trim(from: 0.05, to: 0.32)
      .stroke(Color.accentColor.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .frame(width: side * 0.94, height: side * 0.94)
      .rotationEffect(.degrees(rotates ? 360 : 0))
      .onAppear {
        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { rotates = true }
      }
      .accessibilityHidden(true)
  }
}

private struct CoreHalo: View {
  let tint: Color
  let side: CGFloat
  let intensity: Double

  var body: some View {
    Circle()
      .fill(
        RadialGradient(
          colors: [tint.opacity(intensity), tint.opacity(0)],
          center: .center,
          startRadius: 0,
          endRadius: side * 0.5
        )
      )
  }
}

/// Only ever on screen while the core is starting; see `ActiveCorePowerSymbol`.
private struct BreathingCoreHalo: View {
  let tint: Color
  let side: CGFloat
  @State private var expanded = false

  var body: some View {
    CoreHalo(tint: tint, side: side, intensity: 0.42)
      .scaleEffect(expanded ? 1.08 : 0.94)
      .opacity(expanded ? 1 : 0.7)
      .onAppear {
        withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
          expanded = true
        }
      }
  }
}
