import Pow
import SwiftUI

struct LaunchDashboardView: View {
  @Environment(AppModel.self) private var appModel
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableSize: CGSize

  var body: some View {
    let visualSide = DashboardLayoutMetrics.launchVisualSideLength(
      availableWidth: availableSize.width,
      availableHeight: availableSize.height,
      isVisualActive: state.isVisualActive
    )

    VStack(spacing: 0) {
      Spacer(minLength: 0)

      VStack(spacing: 22) {
        headerRow(visualSide: visualSide)

        LaunchControlDeck(
          state: state,
          namespace: namespace,
          reduceMotion: reduceMotion,
          availableWidth: availableSize.width,
          primaryActionDisabled: primaryActionDisabled,
          primaryAction: runRuntime
        )
        .frame(maxWidth: DashboardLayoutMetrics.launchControlsMaxWidth(availableWidth: availableSize.width))
        .frame(maxWidth: .infinity)
        .transition(.opacity)

        LaunchStatusMessage(state: state)
          .frame(maxWidth: DashboardLayoutMetrics.launchControlsMaxWidth(availableWidth: availableSize.width))
          .frame(maxWidth: .infinity)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func headerRow(visualSide: CGFloat) -> some View {
    HStack(alignment: .center, spacing: 18) {
      Button {
        runRuntime()
      } label: {
        CoreVisualView(state: state, reduceMotion: reduceMotion)
          .frame(width: visualSide, height: visualSide)
          .contentShape(Circle())
      }
      .buttonStyle(CorePowerButtonStyle(reduceMotion: reduceMotion))
      .disabled(primaryActionDisabled)
      .help(primaryActionDisabled ? launchTitle : (appModel.canStopRuntime ? String(localized: "Stop ClashMax") : String(localized: "Start ClashMax")))
      .dashboardMatchedGeometry(id: "core-visual", in: namespace, reduceMotion: reduceMotion)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          if showsStateSymbol {
            Image(systemName: stateSymbol)
              .foregroundStyle(stateTint)
              .font(.system(size: 22, weight: .semibold))
          }

          Text(launchTitle)
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
        }

        Text(appModel.profileStore.activeProfile?.name ?? String(localized: "Select a profile to start ClashMax"))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .dashboardMatchedGeometry(id: "profile-summary", in: namespace, reduceMotion: reduceMotion)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var primaryActionDisabled: Bool {
    if appModel.canStopRuntime { return false }
    if state.isStarting { return true }
    return appModel.readinessIssue != nil
  }

  /// The same call the toolbar button, ⌘R and the menu bar make. The page swap that follows is
  /// animated by `DashboardView`, keyed on the layout, not by a transaction opened here.
  private func runRuntime() {
    guard !primaryActionDisabled else { return }
    if appModel.canStopRuntime {
      appModel.stop()
    } else {
      appModel.start()
    }
  }

  private var launchTitle: String {
    NSLocalizedString(state.launchTitle, comment: "")
  }

  private var stateSymbol: String {
    switch state {
    case .blocked:
      return "exclamationmark.triangle.fill"
    case .crashed:
      return "xmark.octagon.fill"
    default:
      return "power.circle.fill"
    }
  }

  private var showsStateSymbol: Bool {
    switch state {
    case .stopped:
      return false
    default:
      return true
    }
  }

  private var stateTint: Color {
    switch state {
    case .blocked:
      return .secondary
    case .crashed:
      return .red
    default:
      return .cyan
    }
  }
}

/// The resting power symbol's press feedback: a slight dip while the pointer is down, released as soon
/// as it lifts. With Reduce Motion on it dims instead of moving.
private struct CorePowerButtonStyle: ButtonStyle {
  let reduceMotion: Bool

  func makeBody(configuration: Configuration) -> some View {
    let isPressed = configuration.isPressed
    configuration.label
      .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
      .opacity(isPressed && reduceMotion ? 0.8 : 1)
      .animation(.easeOut(duration: 0.12), value: isPressed)
  }
}

private struct LaunchControlDeck: View {
  @Environment(AppModel.self) private var appModel
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableWidth: CGFloat
  let primaryActionDisabled: Bool
  let primaryAction: () -> Void

  var body: some View {
    let compact = availableWidth < 620

    VStack(alignment: .leading, spacing: compact ? 12 : 14) {
      if compact {
        VStack(alignment: .leading, spacing: 12) {
          profileControl
          HStack(alignment: .bottom, spacing: 20) {
            modeControl
            mixedPortControl
          }
          routingControl(fillsWidth: true)
        }
      } else {
        HStack(alignment: .bottom, spacing: 30) {
          profileControl
          modeControl
          mixedPortControl
        }
      }

      Divider()
        .opacity(0.28)

      if compact {
        VStack(alignment: .leading, spacing: 12) {
          startButton
        }
      } else {
        HStack(spacing: 14) {
          routingControl(fillsWidth: true)
          startButton
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .dashboardCard()
  }

  private var profileControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Profile")
        .font(.caption2)
        .foregroundStyle(.secondary)

      Picker("Profile", selection: profilePickerBinding) {
        if appModel.profileStore.profiles.isEmpty {
          Text("No Profiles").tag(Profile.ID?.none)
        }
        ForEach(appModel.profileStore.profiles) { profile in
          Text(profile.name).tag(Optional(profile.id))
        }
      }
      .pickerStyle(.menu)
      .labelsHidden()
      .controlSize(.regular)
      .fixedSize()
      .disabled(appModel.profileStore.profiles.isEmpty)
      .frame(width: DashboardLayoutMetrics.launchProfileControlWidth, alignment: .leading)
      .dashboardMatchedGeometry(id: "profile-control", in: namespace, reduceMotion: reduceMotion)
    }
    .frame(width: DashboardLayoutMetrics.launchProfileControlWidth, alignment: .leading)
  }

  private var profilePickerBinding: Binding<Profile.ID?> {
    Binding(
      get: { appModel.profileStore.activeProfileID },
      set: { newID in
        guard let newID,
              newID != appModel.profileStore.activeProfileID,
              let profile = appModel.profileStore.profiles.first(where: { $0.id == newID })
        else { return }
        appModel.selectProfile(profile)
      }
    )
  }

  private var modeControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Mode")
        .font(.caption2)
        .foregroundStyle(.secondary)
      RunModePicker(selection: Binding(
        get: { appModel.overrides.mode },
        set: { appModel.requestMode($0) }
      ))
      .dashboardMatchedGeometry(id: "mode-control", in: namespace, reduceMotion: reduceMotion)
    }
    .frame(width: DashboardLayoutMetrics.runModePickerWidth, alignment: .leading)
  }

  @ViewBuilder
  private func routingControl(fillsWidth: Bool) -> some View {
    let content = VStack(alignment: .leading, spacing: 6) {
      Text("Proxy")
        .font(.caption2)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        routingModePicker
        ProxyRoutingSettingsButton()
      }
    }

    if fillsWidth {
      content.frame(maxWidth: .infinity, alignment: .leading)
    } else {
      content.frame(width: DashboardLayoutMetrics.proxyRoutingModePickerWidth, alignment: .leading)
    }
  }

  private var routingModePicker: some View {
    ProxyRoutingModePicker(selection: Binding(
      get: { appModel.proxyRoutingMode },
      set: { appModel.requestProxyRoutingMode($0) }
    ))
    .fixedSize(horizontal: true, vertical: false)
  }

  private var mixedPortControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Mixed Port")
        .font(.caption2)
        .foregroundStyle(.secondary)
      // A port is an identifier, not a quantity: an Int interpolated into a localized label picks up
      // the locale's grouping separator and reads "7,890".
      Stepper(
        value: Binding(
          get: { appModel.overrides.mixedPort },
          set: { appModel.setMixedPort($0) }
        ),
        in: 1024...65535
      ) {
        Text(verbatim: String(appModel.overrides.mixedPort))
      }
      .frame(width: DashboardLayoutMetrics.launchMixedPortControlWidth, alignment: .leading)
    }
    .frame(width: DashboardLayoutMetrics.launchMixedPortControlWidth, alignment: .leading)
  }

  private var startButton: some View {
    Button {
      primaryAction()
    } label: {
      Label(primaryActionTitle, systemImage: primaryActionSymbol)
        .font(.system(.headline, design: .rounded).weight(.semibold))
        .frame(width: DashboardLayoutMetrics.launchStartButtonWidth)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.regular)
    .disabled(primaryActionDisabled)
    .dashboardMatchedGeometry(id: "primary-run-control", in: namespace, reduceMotion: reduceMotion)
  }

  private var primaryActionTitle: String {
    appModel.canStopRuntime ? String(localized: "Stop") : String(localized: "Start")
  }

  private var primaryActionSymbol: String {
    appModel.canStopRuntime ? "stop.fill" : "play.fill"
  }
}

private struct LaunchStatusMessage: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let state: DashboardRuntimeState

  var body: some View {
    if let presentation {
      Label(presentation.message, systemImage: presentation.symbolName)
        .font(.callout)
        .foregroundStyle(presentation.color)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(presentation.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(presentation.color.opacity(0.22), lineWidth: 1)
        }
        // Pow does not check Reduce Motion itself.
        .changeEffect(.shake, value: presentation.shakesOnChange ? presentation.message : "", isEnabled: !reduceMotion)
    }
  }

  /// Only the standing conditions that block a start (setup needed, core crashed) live under the
  /// controls. A failed action is an alert and a passing remark is a toast; neither is repeated here.
  private var presentation: LaunchStatusPresentation? {
    guard let message = state.detailMessage else { return nil }
    if appModel.tunHelperPreparationState.isFailure {
      return LaunchStatusPresentation(message: message, symbolName: "xmark.octagon.fill", color: .red, shakesOnChange: true)
    }
    if case .blocked = state {
      return LaunchStatusPresentation(message: message, symbolName: "exclamationmark.triangle.fill", color: .secondary, shakesOnChange: false)
    }
    return LaunchStatusPresentation(message: message, symbolName: "xmark.octagon.fill", color: .red, shakesOnChange: true)
  }
}

private struct LaunchStatusPresentation {
  var message: String
  var symbolName: String
  var color: Color
  var shakesOnChange: Bool
}

extension View {
  /// Carries one control across the launch ↔ running swap. With Reduce Motion the two pages only
  /// cross-fade, so nothing travels across the window.
  @ViewBuilder
  func dashboardMatchedGeometry(id: String, in namespace: Namespace.ID, reduceMotion: Bool) -> some View {
    if reduceMotion {
      self
    } else {
      matchedGeometryEffect(id: id, in: namespace)
    }
  }
}
