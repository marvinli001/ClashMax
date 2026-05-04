import SwiftUI

struct ProxiesView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    AdaptivePage(
      title: "Proxies",
      subtitle: appModel.proxyGroups.isEmpty ? "Proxy groups appear after a profile is running." : "\(appModel.proxyGroups.count) groups"
    ) {
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
          message: "Start ClashMax with an active profile, then refresh runtime data."
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
