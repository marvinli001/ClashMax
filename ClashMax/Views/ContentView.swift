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
              appModel.isRunning ? appModel.stop() : appModel.start()
            } label: {
              Label(toolbarRunTitle, systemImage: toolbarRunSymbol)
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(appModel.dashboardRuntimeState.isStarting || (!appModel.isRunning && appModel.readinessIssue != nil))
          }
        }
    }
  }

  private var toolbarRunTitle: String {
    if appModel.dashboardRuntimeState.isStarting {
      return "Starting"
    }
    return appModel.isRunning ? "Stop" : "Start"
  }

  private var toolbarRunSymbol: String {
    if appModel.dashboardRuntimeState.isStarting {
      return "clock.arrow.circlepath"
    }
    return appModel.isRunning ? "stop.fill" : "play.fill"
  }

  @ViewBuilder
  private var detail: some View {
    switch appModel.selectedSection {
    case .home:
      DashboardView()
    case .profiles:
      ProfilesView()
    case .proxies:
      ProxiesView()
    case .connections:
      ConnectionsView()
    case .rules:
      RulesView()
    case .logs:
      LogsView()
    case .settings:
      SettingsView()
    }
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
    let isActive = appModel.systemProxyEnabled || appModel.tunEnabled
    return "\(appModel.proxyRoutingMode.displayName) \(isActive ? "On" : "Ready")"
  }
}
