import SwiftUI

struct ConnectionsView: View {
  @EnvironmentObject private var appModel: AppModel

  var body: some View {
    AdaptivePage(
      title: "Connections",
      subtitle: "\(appModel.connections.count) active"
    ) {
      Button {
        appModel.closeAllRuntimeConnections()
      } label: {
        if appModel.closingAllConnections {
          Label("Closing", systemImage: "clock.arrow.circlepath")
        } else {
          Label("Close All", systemImage: "xmark.circle")
        }
      }
      .disabled(appModel.connections.isEmpty || appModel.closingAllConnections || !appModel.canControlRuntimeProxies)
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
          .width(min: 70, ideal: 84, max: 100)

          TableColumn("Rule") { connection in
            Text(connection.rule ?? "")
          }
          TableColumn("Chain") { connection in
            Text(connection.chain.joined(separator: " / "))
          }
          TableColumn("Traffic") { connection in
            Text(TrafficSample.format(connection.download + connection.upload))
              .font(.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
          .width(min: 84, ideal: 100, max: 120)

          TableColumn("Actions") { connection in
            Button {
              appModel.closeConnection(connection)
            } label: {
              if appModel.closingConnectionIDs.contains(connection.id) {
                Image(systemName: "clock.arrow.circlepath")
              } else {
                Image(systemName: "xmark.circle")
              }
            }
            .buttonStyle(.borderless)
            .disabled(appModel.closingConnectionIDs.contains(connection.id) || !appModel.canControlRuntimeProxies)
            .help("Close connection")
            .accessibilityLabel("Close connection to \(connection.host)")
          }
          .width(min: 64, ideal: 72, max: 82)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
    }
  }
}
