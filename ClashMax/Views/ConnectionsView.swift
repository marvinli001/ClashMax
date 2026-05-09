import SwiftUI

struct ConnectionsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore

  var body: some View {
    AdaptivePage(
      title: "Connections",
      subtitle: "\(runtimeData.connections.count) active"
    ) {
      Button {
        appModel.closeAllRuntimeConnections()
      } label: {
        if runtimeData.closingAllConnections {
          Label("Closing", systemImage: "clock.arrow.circlepath")
        } else {
          Label("Close All", systemImage: "xmark.circle")
        }
      }
      .disabled(runtimeData.connections.isEmpty || runtimeData.closingAllConnections || !appModel.canControlRuntimeProxies)
    } content: {
      if runtimeData.connections.isEmpty {
        CenteredUnavailableState(
          title: "No active connections",
          systemImage: "network.slash",
          message: "Connections will appear here after apps send traffic through ClashMax."
        )
      } else {
        Table(runtimeData.connections) {
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
              if runtimeData.closingConnectionIDs.contains(connection.id) {
                Image(systemName: "clock.arrow.circlepath")
              } else {
                Image(systemName: "xmark.circle")
              }
            }
            .buttonStyle(.borderless)
            .disabled(runtimeData.closingConnectionIDs.contains(connection.id) || !appModel.canControlRuntimeProxies)
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
