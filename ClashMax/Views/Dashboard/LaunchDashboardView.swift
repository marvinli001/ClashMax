import Pow
import SwiftUI

struct LaunchDashboardView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var coreActivationTrigger = 0
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
          startDisabled: startDisabled,
          startAction: startRuntime
        )
          .frame(maxWidth: DashboardLayoutMetrics.launchControlsMaxWidth(availableWidth: availableSize.width))
          .frame(maxWidth: .infinity)
          .transition(.movingParts.blur)

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
        startRuntime()
      } label: {
        CoreVisualView(
          state: state,
          reduceMotion: reduceMotion,
          activationTrigger: coreActivationTrigger
        )
          .frame(width: visualSide, height: visualSide)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .disabled(startDisabled)
      .help(startDisabled ? launchTitle : "Start ClashMax")
      .matchedGeometryEffect(id: "core-visual", in: namespace)

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

        Text(appModel.profileStore.activeProfile?.name ?? "Select a profile to start ClashMax")
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
          .matchedGeometryEffect(id: "profile-summary", in: namespace)
      }
    }
    .frame(maxWidth: .infinity)
  }

  private var startDisabled: Bool {
    if state.isStarting { return true }
    return appModel.readinessIssue != nil
  }

  private func startRuntime() {
    guard !startDisabled else { return }
    coreActivationTrigger += 1
    withAnimation(.spring(response: 0.52, dampingFraction: 0.82)) {
      appModel.start()
    }
  }

  private var launchTitle: String {
    state.launchTitle
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

private struct LaunchControlDeck: View {
  @EnvironmentObject private var appModel: AppModel
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableWidth: CGFloat
  let startDisabled: Bool
  let startAction: () -> Void

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
          routingControl
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
          routingControl
          Spacer(minLength: 0)
          startButton
        }
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .dashboardCard(interactive: true)
  }

  private var profileControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Profile")
        .font(.caption2)
        .foregroundStyle(.secondary)

      Picker("Profile", selection: profilePickerBinding) {
        if appModel.profileStore.profiles.isEmpty {
          Text("No Profiles").tag(Optional<Profile.ID>.none)
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
      .matchedGeometryEffect(id: "profile-control", in: namespace)
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
      .matchedGeometryEffect(id: "mode-control", in: namespace)
    }
    .frame(width: DashboardLayoutMetrics.runModePickerWidth, alignment: .leading)
  }

  private var routingControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Proxy")
        .font(.caption2)
        .foregroundStyle(.secondary)
      HStack(spacing: 6) {
        ProxyRoutingModePicker(selection: Binding(
          get: { appModel.proxyRoutingMode },
          set: { appModel.requestProxyRoutingMode($0) }
        ))
        ProxyRoutingSettingsButton()
      }
    }
    .frame(width: DashboardLayoutMetrics.proxyRoutingModePickerWidth, alignment: .leading)
  }

  private var mixedPortControl: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Mixed Port")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Stepper("\(appModel.overrides.mixedPort)", value: $appModel.overrides.mixedPort, in: 1024...65535)
        .frame(width: DashboardLayoutMetrics.launchMixedPortControlWidth, alignment: .leading)
    }
    .frame(width: DashboardLayoutMetrics.launchMixedPortControlWidth, alignment: .leading)
  }

  private var startButton: some View {
    Button {
      startAction()
    } label: {
      Label("Start", systemImage: "play.fill")
        .font(.system(.headline, design: .rounded).weight(.semibold))
        .frame(width: DashboardLayoutMetrics.launchStartButtonWidth)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.regular)
    .disabled(startDisabled)
    .matchedGeometryEffect(id: "primary-run-control", in: namespace)
    .changeEffect(.shine(duration: reduceMotion ? 0.18 : 0.72), value: state)
  }
}

private struct LaunchStatusMessage: View {
  @EnvironmentObject private var appModel: AppModel
  let state: DashboardRuntimeState

  var body: some View {
    if let message = state.detailMessage ?? appModel.lastError {
      Label(message, systemImage: messageSymbol)
        .font(.callout)
        .foregroundStyle(messageColor)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(messageColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .stroke(messageColor.opacity(0.22), lineWidth: 1)
        }
        .changeEffect(.shake, value: message)
    }
  }

  private var messageSymbol: String {
    if case .blocked = state { return "exclamationmark.triangle.fill" }
    return "xmark.octagon.fill"
  }

  private var messageColor: Color {
    if case .blocked = state { return .secondary }
    return .red
  }
}
