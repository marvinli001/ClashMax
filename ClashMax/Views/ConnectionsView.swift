import SwiftUI

struct ConnectionsView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    AdaptivePage(
      title: "Connections",
      subtitle: "\(appModel.connections.count) active"
    ) {
      EmptyView()
    } content: {
      if appModel.connections.isEmpty {
        CenteredUnavailableState(
          title: "No active connections",
          systemImage: "network.slash",
          message: "Connections will appear here after apps send traffic through ClashMax."
        )
      } else {
        Table(appModel.connections) {
          TableColumn("Host") { connection in
            Text(connection.host)
          }
          TableColumn("Network") { connection in
            Text(connection.network)
          }
          TableColumn("Rule") { connection in
            Text(connection.rule ?? "")
          }
          TableColumn("Chain") { connection in
            Text(connection.chain.joined(separator: " / "))
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
  }
}
