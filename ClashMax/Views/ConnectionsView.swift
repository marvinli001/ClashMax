import AppKit
import SwiftUI

struct ConnectionsView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @State private var searchText = ""
  @State private var mode = ConnectionViewMode.active
  @State private var groupsByApp = false
  @State private var selectedConnectionIDs = Set<ConnectionSnapshot.ID>()

  var body: some View {
    AdaptivePage(
      title: "Connections",
      subtitle: subtitle
    ) {
      Button {
        closeSelected()
      } label: {
        Label("Close Selected", systemImage: "xmark.circle")
      }
      .disabled(selectedActiveConnections.isEmpty || !appModel.canControlRuntimeProxies)

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
      if showsLoadingSkeleton {
        ClashMaxSkeletonTable(rows: 7)
      } else if visibleConnections.isEmpty {
        CenteredUnavailableState(
          title: emptyTitle,
          systemImage: "network.slash",
          message: emptyMessage
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          controls
          HStack(alignment: .top, spacing: 12) {
            connectionList
            connectionDetail
              .frame(width: 320)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .onChange(of: visibleConnections.map(\.id)) { _, ids in
      selectedConnectionIDs = selectedConnectionIDs.intersection(Set(ids))
    }
  }

  private var subtitle: String {
    String.localizedStringWithFormat(
      NSLocalizedString("%lld active, %lld retained", comment: ""),
      Int64(runtimeData.connections.count),
      Int64(runtimeData.connectionRecords.count)
    )
  }

  private var controls: some View {
    HStack(spacing: 10) {
      TextField("Search app, host, IP, rule, chain", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 240, idealWidth: 360, maxWidth: 460)

      Picker("Mode", selection: $mode) {
        ForEach(ConnectionViewMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 170)

      Toggle("Group by App", isOn: $groupsByApp)
        .toggleStyle(.checkbox)

      Spacer()
    }
  }

  @ViewBuilder
  private var connectionList: some View {
    if groupsByApp {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          ForEach(groupedConnections, id: \.app) { group in
            VStack(alignment: .leading, spacing: 6) {
              Text(group.app)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
              ForEach(group.connections) { connection in
                let canClose = canCloseConnection(connection)
                ConnectionRow(
                  connection: connection,
                  isSelected: selectedConnectionIDs.contains(connection.id),
                  isClosing: runtimeData.closingConnectionIDs.contains(connection.id),
                  canClose: canClose
                ) {
                  toggleSelection(connection)
                } closeAction: {
                  guard canClose else { return }
                  appModel.closeConnection(connection)
                }
              }
            }
          }
        }
        .padding(.vertical, 2)
      }
    } else {
      Table(visibleConnections, selection: $selectedConnectionIDs) {
        TableColumn("App") { connection in
          ConnectionAppLabel(connection: connection)
        }
        .width(min: 130, ideal: 180)

        TableColumn("Host") { connection in
          Text(connection.host)
            .lineLimit(1)
        }

        TableColumn("Source") { connection in
          Text(connection.sourceAddress)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .width(min: 120, ideal: 150)

        TableColumn("Destination") { connection in
          Text(connection.destinationAddress)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .width(min: 120, ideal: 160)

        TableColumn("Rule") { connection in
          Text(connection.ruleSummary)
            .lineLimit(1)
        }
        .width(min: 110, ideal: 150)

        TableColumn("Chain") { connection in
          Text(connection.chain.joined(separator: " / "))
            .lineLimit(1)
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
          .disabled(mode == .history || runtimeData.closingConnectionIDs.contains(connection.id) || !appModel.canControlRuntimeProxies)
          .help("Close connection")
          .accessibilityLabel("Close connection to \(connection.host)")
        }
        .width(min: 64, ideal: 72, max: 82)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }

  private var connectionDetail: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Connection Detail", systemImage: "info.circle")
        .font(.headline)

      if let connection = selectedConnection {
        detailRow("App", connection.appDisplayName)
        detailRow("Process", connection.processPath ?? "-")
        detailRow("Network", connection.network.isEmpty ? "-" : connection.network)
        detailRow("Source", connection.sourceAddress)
        detailRow("Destination", connection.destinationAddress)
        detailRow("Rule", connection.ruleSummary.isEmpty ? "-" : connection.ruleSummary)
        detailRow("Chain", connection.chain.isEmpty ? "-" : connection.chain.joined(separator: " / "))
        detailRow("Traffic", TrafficSample.formatBytes(connection.download + connection.upload))
        whyThisRule(connection)
      } else {
        Text("Select a connection to inspect the process, rule, and chain.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func whyThisRule(_ connection: ConnectionSnapshot) -> some View {
    let explanation = RuleExplanationBuilder().explanation(for: connection, rules: runtimeData.rules)
    return VStack(alignment: .leading, spacing: 8) {
      Divider()
      Label("Why This Rule", systemImage: "scope")
        .font(.caption.weight(.semibold))
      detailRow("Mihomo Reported", explanation.reportedRuleSummary.isEmpty ? "-" : explanation.reportedRuleSummary)
      detailRow("Chosen Target", explanation.target.isEmpty ? "-" : explanation.target)
      detailRow("Local Simulation", explanation.localSummary)
      Button {
        appModel.openRoutingExplanation(for: connection)
      } label: {
        Label("Open in Routing", systemImage: "arrow.triangle.branch")
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
    }
  }

  private func detailRow(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(LocalizedStringKey(title))
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption)
        .lineLimit(2)
        .textSelection(.enabled)
    }
  }

  private var visibleConnections: [ConnectionSnapshot] {
    let base: [ConnectionSnapshot]
    switch mode {
    case .active:
      base = runtimeData.connections
    case .history:
      base = runtimeData.connectionRecords.map(\.snapshot)
    }
    let query = ConnectionSearchQuery(rawValue: searchText)
    guard !query.isEmpty else { return base }
    return base.filter(query.matches)
  }

  private var groupedConnections: [(app: String, connections: [ConnectionSnapshot])] {
    Dictionary(grouping: visibleConnections, by: \.appDisplayName)
      .map { (app: $0.key, connections: $0.value) }
      .sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
  }

  private var selectedConnection: ConnectionSnapshot? {
    guard let id = selectedConnectionIDs.first else { return nil }
    return visibleConnections.first { $0.id == id }
  }

  private var selectedActiveConnections: [ConnectionSnapshot] {
    let activeIDs = Set(runtimeData.connections.map(\.id))
    return visibleConnections.filter {
      selectedConnectionIDs.contains($0.id)
        && activeIDs.contains($0.id)
        && !runtimeData.closingConnectionIDs.contains($0.id)
    }
  }

  private var showsLoadingSkeleton: Bool {
    runtimeData.connections.isEmpty
      && runtimeData.connectionRecords.isEmpty
      && appModel.profileStore.activeProfile != nil
      && (appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting)
  }

  private var emptyTitle: String {
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return String(localized: "No matching connections")
    }
    return mode == .active
      ? String(localized: "No active connections")
      : String(localized: "No retained connections")
  }

  private var emptyMessage: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? String(localized: "Connections will appear here after apps send traffic through ClashMax.")
      : String(localized: "No app, host, rule, or chain matches the current search.")
  }

  private func toggleSelection(_ connection: ConnectionSnapshot) {
    if selectedConnectionIDs.contains(connection.id) {
      selectedConnectionIDs.remove(connection.id)
    } else {
      selectedConnectionIDs.insert(connection.id)
    }
  }

  private func closeSelected() {
    for connection in selectedActiveConnections {
      appModel.closeConnection(connection)
    }
  }

  private func canCloseConnection(_ connection: ConnectionSnapshot) -> Bool {
    mode == .active
      && appModel.canControlRuntimeProxies
      && runtimeData.connections.contains { $0.id == connection.id }
      && !runtimeData.closingConnectionIDs.contains(connection.id)
  }
}

private enum ConnectionViewMode: String, CaseIterable, Identifiable {
  case active
  case history

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .active: String(localized: "Active")
    case .history: String(localized: "History")
    }
  }
}

private struct ConnectionSearchQuery {
  let terms: [String]

  init(rawValue: String) {
    terms = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  var isEmpty: Bool { terms.isEmpty }

  func matches(_ connection: ConnectionSnapshot) -> Bool {
    let haystack = [
      connection.appDisplayName,
      connection.host,
      connection.sourceAddress,
      connection.destinationAddress,
      connection.network,
      connection.rule,
      connection.rulePayload,
      connection.chain.joined(separator: " ")
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
  }
}

private struct ConnectionAppLabel: View {
  let connection: ConnectionSnapshot

  var body: some View {
    HStack(spacing: 6) {
      if let image = appIcon {
        Image(nsImage: image)
          .resizable()
          .frame(width: 16, height: 16)
          .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      } else {
        Image(systemName: "app")
          .foregroundStyle(.secondary)
          .frame(width: 16)
      }
      Text(connection.appDisplayName)
        .lineLimit(1)
    }
  }

  private var appIcon: NSImage? {
    guard let path = connection.processPath else { return nil }
    return NSWorkspace.shared.icon(forFile: path)
  }
}

private struct ConnectionRow: View {
  let connection: ConnectionSnapshot
  let isSelected: Bool
  let isClosing: Bool
  let canClose: Bool
  let selectAction: () -> Void
  let closeAction: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Button(action: selectAction) {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .frame(width: 18, height: 18)
      }
      .buttonStyle(.borderless)

      ConnectionAppLabel(connection: connection)
        .frame(width: 160, alignment: .leading)
      Text(connection.host)
        .lineLimit(1)
      Spacer()
      Text(connection.ruleSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Button(action: closeAction) {
        Image(systemName: isClosing ? "clock.arrow.circlepath" : "xmark.circle")
      }
      .buttonStyle(.borderless)
      .disabled(!canClose || isClosing)
      .help("Close connection")
      .accessibilityLabel("Close connection to \(connection.host)")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
  }
}
