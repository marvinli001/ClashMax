import SwiftUI

struct ContentView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    NavigationSplitView {
      SidebarView(selection: $appModel.selectedSection)
    } detail: {
      VStack(spacing: 0) {
        StatusStrip()
        Divider()
        detail
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
        .toolbar {
          ToolbarItemGroup {
            RunModePicker(selection: Binding(
              get: { appModel.overrides.mode },
              set: { appModel.requestMode($0) }
            ))

            Button {
              if appModel.canStopRuntime {
                appModel.stop()
              } else {
                appModel.start()
              }
            } label: {
              Label(toolbarRunTitle, systemImage: toolbarRunSymbol)
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(!appModel.canStopRuntime && appModel.readinessIssue != nil)
          }
        }
    }
    .sheet(isPresented: initialTunHelperPromptPresented) {
      if let prompt = appModel.initialTunHelperPrompt {
        InitialTunHelperPromptSheet(
          prompt: prompt,
          actionInFlight: appModel.initialTunHelperPromptActionInFlight,
          onPrimaryAction: {
            appModel.installInitialTunHelper()
          },
          onLater: {
            appModel.dismissInitialTunHelperPrompt()
          }
        )
      }
    }
    .onAppear {
      appModel.evaluateInitialTunHelperPromptOnLaunch()
    }
  }

  private var initialTunHelperPromptPresented: Binding<Bool> {
    Binding(
      get: { appModel.initialTunHelperPrompt != nil },
      set: { isPresented in
        if !isPresented {
          appModel.dismissInitialTunHelperPrompt()
        }
      }
    )
  }

  private var toolbarRunTitle: String {
    appModel.canStopRuntime ? "Stop" : "Start"
  }

  private var toolbarRunSymbol: String {
    appModel.canStopRuntime ? "stop.fill" : "play.fill"
  }

  @ViewBuilder
  private var detail: some View {
    switch appModel.selectedSection {
    case .home:
      DashboardView()
    case .status:
      StatusView()
    case .profiles:
      ProfilesView()
    case .proxies:
      ProxiesView()
    case .connections:
      ConnectionsView()
    case .routing:
      RoutingView()
    case .rules:
      RulesView()
    case .logs:
      LogsView()
    case .settings:
      SettingsView()
    }
  }
}

private struct InitialTunHelperPromptSheet: View {
  let prompt: InitialTunHelperPrompt
  let actionInFlight: Bool
  let onPrimaryAction: () -> Void
  let onLater: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top, spacing: 14) {
        Image(systemName: "checkmark.shield")
          .font(.system(size: 36, weight: .semibold))
          .foregroundStyle(.blue)
          .frame(width: 44, height: 44)

        VStack(alignment: .leading, spacing: 8) {
          Text("Install ClashMax Helper")
            .font(.title3.weight(.semibold))
          Text("ClashMax uses a privileged helper to enable TUN routing.")
            .foregroundStyle(.primary)
          Text("macOS will ask you to approve ClashMax in System Settings > General > Login Items & Extensions before TUN routing can start.")
            .foregroundStyle(.secondary)
          Text("System Proxy and Network Extension routing continue to work without this helper.")
            .foregroundStyle(.secondary)
          if prompt.primaryAction == .openSettings {
            Text("Helper approval is pending.")
              .font(.callout.weight(.medium))
              .foregroundStyle(.orange)
          }
        }
        .fixedSize(horizontal: false, vertical: true)
      }

      Text(prompt.statusMessage)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      HStack {
        Spacer()
        Button("Later", action: onLater)
          .keyboardShortcut(.cancelAction)

        Button {
          onPrimaryAction()
        } label: {
          if actionInFlight {
            ProgressView()
              .controlSize(.small)
          } else {
            Text(prompt.primaryButtonTitle)
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(actionInFlight)
      }
    }
    .padding(24)
    .frame(width: 520, alignment: .topLeading)
  }
}

private struct StatusStrip: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    HStack(spacing: 14) {
      Label(appModel.statusSummary, systemImage: statusSymbol)
        .foregroundStyle(statusStyle)
        .lineLimit(1)
        .minimumScaleFactor(0.78)

      Divider()
        .frame(height: 16)

      Text(appModel.profileStore.activeProfile?.name ?? "No Profile")
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.78)

      Text(proxyRoutingStatus)
        .foregroundStyle(.secondary)

      Spacer()

      if let issue = appModel.readinessIssue {
        Text(issue)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else if let error = appModel.lastError {
        Text(error)
          .foregroundStyle(.red)
          .lineLimit(1)
      } else if let notice = appModel.appNotice {
        Label(notice.message, systemImage: notice.symbolName)
          .foregroundStyle(noticeColor(for: notice.tone))
          .lineLimit(1)
      }
    }
    .font(.callout)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity)
  }

  private var statusSymbol: String {
    if appModel.isRunning {
      return "checkmark.circle.fill"
    }
    switch appModel.coreController.status {
    case .running:
      return "checkmark.circle.fill"
    case .starting, .restarting:
      return "clock.arrow.circlepath"
    case .crashed:
      return "exclamationmark.triangle.fill"
    case .stopped:
      return "stop.circle"
    }
  }

  private var statusStyle: Color {
    if appModel.isRunning {
      return .green
    }
    switch appModel.coreController.status {
    case .running:
      return .green
    case .crashed:
      return .red
    case .starting, .restarting:
      return .orange
    case .stopped:
      return .secondary
    }
  }

  private var proxyRoutingStatus: String {
    let isActive = appModel.systemProxyEnabled || appModel.tunEnabled || appModel.networkExtensionEnabled
    return "\(appModel.proxyRoutingMode.displayName) \(isActive ? "On" : "Ready")"
  }

  private func noticeColor(for tone: AppNotice.Tone) -> Color {
    switch tone {
    case .info:
      return .blue
    case .success:
      return .green
    }
  }
}
