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
      subtitle: groups.isEmpty
        ? "Proxy groups load from the active profile and runtime."
        : appModel.isShowingProxyPreview ? "\(groups.count) preview groups" : "\(groups.count) groups"
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
          if appModel.isShowingProxyPreview {
            ProxyPreviewNotice(message: appModel.proxyRuntimeActionMessage)
          }

          List {
            ForEach(groups) { group in
              Section(group.name) {
                ForEach(group.nodes) { node in
                  let canUseRuntimeAction = appModel.canControlRuntimeProxies && node.isSelectable

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
                    .disabled(!canUseRuntimeAction)
                    .help(canUseRuntimeAction ? "Select \(node.name)" : appModel.proxyRuntimeActionMessage)

                    Button {
                      appModel.testDelay(for: node)
                    } label: {
                      Image(systemName: "speedometer")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!canUseRuntimeAction)
                    .help(canUseRuntimeAction ? "Test delay" : appModel.proxyRuntimeActionMessage)
                    .accessibilityLabel("Test delay for \(node.name)")
                  }
                }
              }
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
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
  let message: String

  var body: some View {
    Label(message, systemImage: "info.circle")
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
