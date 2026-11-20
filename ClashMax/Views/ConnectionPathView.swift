import SwiftUI

struct ConnectionPathView: View {
  let connection: ConnectionSnapshot
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @State private var exit = PublicIPInfoState.idle
  @State private var probeID: UUID?

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Divider()
      Label("Path", systemImage: "point.topleft.down.to.point.bottomright.curvepath").font(.caption.bold())
      ForEach(ConnectionPath.facts(connection, rules: runtimeData.rules, exit: exit)) { fact in
        VStack(alignment: .leading, spacing: 2) {
          Text(fact.title).font(.caption.weight(.medium))
          Text(fact.value).font(.caption).textSelection(.enabled)
          if fact.mismatch {
            Label("Differs from core report", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
          Text([fact.source.title, fact.date?.formatted(date: .abbreviated, time: .standard) ?? String(localized: "Time unavailable")].joined(separator: " · "))
            .foregroundStyle(.secondary)
        }.font(.caption2)
      }
      Text("Current probe, not the exit at the time of this connection.").font(.caption2).foregroundStyle(.secondary)
      Button("Probe current exit") { probeID = UUID() }.disabled(exit.isLoading || !appModel.isCoreRunning)
      Button("Open in Routing") { appModel.openRoutingExplanation(for: connection) }
    }
    .controlSize(.small)
    .task(id: probeID) {
      guard probeID != nil else { return }
      exit = .loading(previous: nil, startedAt: Date())
      do {
        let config = try PublicIPInfoClient.loopbackConfiguration(port: appModel.currentRuntimeOverrides.mixedPort)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let info = try await PublicIPInfoClient(session: session).fetchPublicIPInfo()
        try Task.checkCancellation()
        exit = .loaded(info)
      } catch {
        guard !Task.isCancelled else { return }
        exit = .failed(message: String(localized: "Unavailable — the exit probe failed"), previous: nil, failedAt: Date())
      }
    }
  }
}
