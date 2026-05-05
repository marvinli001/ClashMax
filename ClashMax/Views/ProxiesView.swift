import SwiftUI

struct ProxiesView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    let groups = appModel.visibleProxyGroups
    let isStarting = appModel.dashboardRuntimeState.isStarting
    let canStart = ProxiesPageActionState.canStart(
      isRunning: appModel.isRunning,
      hasActiveProfile: appModel.profileStore.activeProfile != nil,
      isStarting: isStarting,
      readinessIssue: appModel.readinessIssue
    )

    AdaptivePage(
      title: "Proxies",
      subtitle: subtitle(for: groups)
    ) {
      if !appModel.isRunning, appModel.profileStore.activeProfile != nil {
        Button {
          appModel.start()
        } label: {
          Label(isStarting ? "Starting" : "Start", systemImage: isStarting ? "clock.arrow.circlepath" : "play.fill")
        }
        .disabled(!canStart)
      }
      Button {
        appModel.reloadRuntimeData()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(!ProxiesPageActionState.canRefresh(isStarting: isStarting))
    } content: {
      if groups.isEmpty {
        CenteredUnavailableState(
          title: "No proxy groups",
          systemImage: "point.3.connected.trianglepath.dotted",
          message: appModel.proxyGroupsUnavailableMessage
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          if appModel.previewRuntimeActive {
            ProxyPreviewNotice(
              icon: "wand.and.stars",
              message: "Preview core is running on loopback for delay testing. Hit Start on Home to redirect traffic."
            )
          } else if appModel.isShowingProxyPreview {
            ProxyPreviewNotice(
              icon: "info.circle",
              message: "Pick a node and we'll remember it. Tests start a quiet preview core automatically."
            )
          }

          List {
            ForEach(groups) { group in
              Section(group.name) {
                ForEach(group.nodes) { node in
                  ProxyNodeRow(group: group, node: node)
                }
              }
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
    }
    .onAppear {
      appModel.enterPreviewRuntime()
    }
    .onDisappear {
      Task { @MainActor in
        await appModel.leavePreviewRuntime()
      }
    }
  }

  private func subtitle(for groups: [ProxyGroup]) -> String {
    if groups.isEmpty {
      return "Proxy groups load from the active profile and runtime."
    }
    if appModel.previewRuntimeActive {
      return "\(groups.count) groups · preview core"
    }
    if appModel.isShowingProxyPreview {
      return "\(groups.count) preview groups"
    }
    return "\(groups.count) groups"
  }
}

private struct ProxyNodeRow: View {
  @EnvironmentObject private var appModel: AppModel
  let group: ProxyGroup
  let node: ProxyNode

  var body: some View {
    let canSelect = node.isSelectable && (appModel.canControlRuntimeProxies || appModel.canSelectProxyOffline)
    let canTest = node.isSelectable && appModel.canControlRuntimeProxies

    HStack(spacing: 10) {
      Button {
        appModel.selectProxy(group: group, node: node)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: group.selected == node.name ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(group.selected == node.name ? .green : .secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(node.name)
              .foregroundStyle(node.isSelectable ? .primary : .secondary)
            Text(node.delay.map { "\($0) ms" } ?? "No delay")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canSelect)
      .help(canSelect ? "Select \(node.name)" : appModel.proxyRuntimeActionMessage)

      Button {
        appModel.testDelay(for: node)
      } label: {
        Image(systemName: "speedometer")
      }
      .buttonStyle(.borderless)
      .disabled(!canTest)
      .help(canTest ? "Test delay" : "Preview core needs a moment to come up before delay testing.")
      .accessibilityLabel("Test delay for \(node.name)")
    }
  }
}

enum ProxiesPageActionState {
  static func canStart(isRunning: Bool, hasActiveProfile: Bool, isStarting: Bool, readinessIssue: String?) -> Bool {
    !isRunning && hasActiveProfile && !isStarting && readinessIssue == nil
  }

  static func canRefresh(isStarting: Bool) -> Bool {
    !isStarting
  }
}

private struct ProxyPreviewNotice: View {
  let icon: String
  let message: String

  var body: some View {
    Label(message, systemImage: icon)
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}
