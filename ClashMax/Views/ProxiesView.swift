import SwiftUI

struct ProxiesView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    AdaptivePage(
      title: "Proxies",
      subtitle: appModel.proxyGroups.isEmpty ? "Runtime groups load after the active profile starts." : "\(appModel.proxyGroups.count) groups"
    ) {
      if !appModel.isRunning, appModel.profileStore.activeProfile != nil {
        Button {
          appModel.start()
        } label: {
          Label("Start", systemImage: "play.fill")
        }
      }
      Button {
        appModel.reloadRuntimeData()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
    } content: {
      if appModel.proxyGroups.isEmpty {
        CenteredUnavailableState(
          title: "No proxy groups",
          systemImage: "point.3.connected.trianglepath.dotted",
          message: appModel.proxyGroupsUnavailableMessage
        )
      } else {
        List {
          ForEach(appModel.proxyGroups) { group in
            Section(group.name) {
              ForEach(group.nodes) { node in
                HStack {
                  Image(systemName: group.selected == node.name ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(group.selected == node.name ? .green : .secondary)
                  VStack(alignment: .leading) {
                    Text(node.name)
                    Text(node.delay.map { "\($0) ms" } ?? "No delay")
                      .font(.caption)
                      .foregroundStyle(.secondary)
                  }
                  Spacer()
                  Button {
                    appModel.testDelay(for: node)
                  } label: {
                    Image(systemName: "speedometer")
                  }
                  .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                  appModel.selectProxy(group: group, node: node)
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
