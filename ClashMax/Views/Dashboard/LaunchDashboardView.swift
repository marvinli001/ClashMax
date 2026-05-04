import Pow
import SwiftUI

struct LaunchDashboardView: View {
  @EnvironmentObject private var appModel: AppModel
  let state: DashboardRuntimeState
  let namespace: Namespace.ID
  let reduceMotion: Bool
  let availableSize: CGSize

  var body: some View {
    let visualSide = DashboardLayoutMetrics.launchVisualSideLength(
      availableWidth: availableSize.width,
      availableHeight: availableSize.height
    )
    let compactHeight = availableSize.height < 620

    VStack(spacing: compactHeight ? 12 : 18) {
      VStack(spacing: compactHeight ? 10 : 14) {
        Button {
          startRuntime()
        } label: {
          CoreVisualView(state: state, reduceMotion: reduceMotion)
            .frame(width: visualSide, height: visualSide)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(startDisabled)
        .help(startDisabled ? launchTitle : "Start ClashMax")
        .matchedGeometryEffect(id: "core-visual", in: namespace)

        VStack(spacing: 6) {
          HStack(spacing: 8) {
            Image(systemName: stateSymbol)
              .foregroundStyle(stateTint)
            Text(launchTitle)
              .font(.system(size: 28, weight: .semibold, design: .rounded))
              .lineLimit(1)
              .minimumScaleFactor(0.72)
          }

          Text(appModel.profileStore.activeProfile?.name ?? "Select a profile to start ClashMax")
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .matchedGeometryEffect(id: "profile-summary", in: namespace)
        }
      }
      .padding(.top, compactHeight ? 2 : 12)

      LaunchControlDeck(
        state: state,
        namespace: namespace,
        reduceMotion: reduceMotion,
        availableWidth: availableSize.width,
        startDisabled: startDisabled,
        startAction: startRuntime
      )
        .frame(maxWidth: DashboardLayoutMetrics.launchControlsMaxWidth(availableWidth: availableSize.width))
        .transition(.movingParts.blur)

      LaunchStatusMessage(state: state)
        .frame(maxWidth: DashboardLayoutMetrics.launchControlsMaxWidth(availableWidth: availableSize.width))
    }
    .frame(maxWidth: .infinity)
    .frame(minHeight: max(420, availableSize.height - 36), alignment: .center)
  }

  private var startDisabled: Bool {
    if state.isStarting { return true }
    return appModel.readinessIssue != nil
  }

  private func startRuntime() {
    guard !startDisabled else { return }
    withAnimation(.spring(response: 0.52, dampingFraction: 0.82)) {
      appModel.start()
    }
  }

  private var launchTitle: String {
    switch state {
    case .blocked:
      return "ClashMax Needs Setup"
    case .crashed:
      return "Core Needs Attention"
    default:
      return "ClashMax Ready"
    }
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
    VStack(alignment: .leading, spacing: 14) {
      if availableWidth >= 720 {
        HStack(alignment: .top, spacing: 14) {
          profileControl
          modeControl
          Spacer(minLength: 0)
          mixedPortControl(alignment: .trailing)
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          profileControl
          HStack(alignment: .top, spacing: 12) {
            modeControl
            Spacer(minLength: 0)
            mixedPortControl(alignment: .trailing)
          }
        }
      }

      Divider()
        .opacity(0.28)

      if availableWidth >= 620 {
        HStack(spacing: 14) {
          toggleControls
          Spacer(minLength: 0)
          startButton
        }
      } else {
        VStack(alignment: .leading, spacing: 12) {
          toggleControls
          startButton
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
    .padding(18)
    .dashboardCard(interactive: true)
  }

  private var profileControl: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Profile")
        .font(.caption)
        .foregroundStyle(.secondary)
      Picker("Profile", selection: profileSelection) {
        Text("None").tag(Profile.ID?.none)
        ForEach(appModel.profileStore.profiles) { profile in
          Text(profile.name).tag(Optional(profile.id))
        }
      }
      .labelsHidden()
      .frame(minWidth: 160, idealWidth: 240, maxWidth: 300)
      .matchedGeometryEffect(id: "profile-control", in: namespace)
    }
  }

  private var modeControl: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Mode")
        .font(.caption)
        .foregroundStyle(.secondary)
      RunModePicker(selection: Binding(
        get: { appModel.overrides.mode },
        set: { appModel.setMode($0) }
      ))
      .matchedGeometryEffect(id: "mode-control", in: namespace)
    }
  }

  private func mixedPortControl(alignment: HorizontalAlignment) -> some View {
    VStack(alignment: alignment, spacing: 8) {
      Text("Mixed Port")
        .font(.caption)
        .foregroundStyle(.secondary)
      Stepper("\(appModel.overrides.mixedPort)", value: $appModel.overrides.mixedPort, in: 1024...65535)
        .frame(width: 146)
    }
  }

  private var toggleControls: some View {
    HStack(spacing: 16) {
      Toggle("System Proxy", isOn: Binding(
        get: { appModel.systemProxyEnabled },
        set: { appModel.setSystemProxyEnabled($0) }
      ))
      .toggleStyle(.switch)

      Toggle("TUN Mode", isOn: $appModel.tunEnabled)
        .toggleStyle(.switch)
    }
  }

  private var startButton: some View {
    Button {
      startAction()
    } label: {
      Label("Start", systemImage: "play.fill")
        .font(.system(.headline, design: .rounded).weight(.semibold))
        .frame(minWidth: 128)
    }
    .buttonStyle(.borderedProminent)
    .controlSize(.large)
    .disabled(startDisabled)
    .matchedGeometryEffect(id: "primary-run-control", in: namespace)
    .changeEffect(.shine(duration: reduceMotion ? 0.18 : 0.72), value: state)
  }

  private var profileSelection: Binding<Profile.ID?> {
    Binding(
      get: { appModel.profileStore.activeProfileID },
      set: { id in
        guard let id,
              let profile = appModel.profileStore.profiles.first(where: { $0.id == id })
        else {
          return
        }
        try? appModel.profileStore.select(profile)
      }
    )
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
