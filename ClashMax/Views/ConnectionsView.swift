import AppKit
import SwiftUI

enum ConnectionsLayoutMode {
  case stackedDetail
  case splitDetail
}

enum ConnectionsLayout {
  static let splitDetailBreakpoint: CGFloat = 1_080
  static let detailWidth: CGFloat = 320
  static let stackedListMinHeight: CGFloat = 280

  static func mode(forWidth width: CGFloat) -> ConnectionsLayoutMode {
    width >= splitDetailBreakpoint ? .splitDetail : .stackedDetail
  }

  /// Issue #27: the stacked layout puts the detail card *under* the list, so the two share one
  /// page. `stackedListMinHeight` alone outgrew a short window, and an oversized page does not
  /// clip — it stretches the whole window's layout. Both blocks therefore scale with the room
  /// they actually have.
  static func stackedListMinHeight(availableHeight: CGFloat) -> CGFloat {
    guard availableHeight.isFinite, availableHeight > 0 else { return stackedListMinHeight }
    return min(stackedListMinHeight, max(availableHeight * 0.45, 120))
  }

  /// How tall the detail card may grow before its contents scroll inside it. Beside the list it
  /// owns a full column; under the list it may claim only part of the page.
  static func detailMaxHeight(mode: ConnectionsLayoutMode, availableHeight: CGFloat) -> CGFloat {
    guard availableHeight.isFinite, availableHeight > 0 else { return 320 }
    switch mode {
    case .splitDetail:
      return availableHeight
    case .stackedDetail:
      return min(max(availableHeight * 0.4, 96), 320)
    }
  }
}

struct ConnectionsView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @State private var searchText = ""
  @State private var mode = ConnectionViewMode.active
  @State private var groupsByApp = false
  @State private var selectedConnectionIDs = Set<ConnectionSnapshot.ID>()
  @State private var appIconCache = ConnectionAppIconCache()
  @State private var quickRuleContext: QuickRuleSheetContext?

  var body: some View {
    AdaptivePage(title: "Connections") {
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
        VStack(spacing: 8) {
          GeometryReader { proxy in
            connectionsWorkspace(
              mode: ConnectionsLayout.mode(forWidth: proxy.size.width),
              availableHeight: proxy.size.height
            )
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

          PageStatusFooter(text: String.localizedStringWithFormat(
            NSLocalizedString("%lld active, %lld retained", comment: ""),
            Int64(runtimeData.connections.count),
            Int64(runtimeData.connectionRecords.count)
          ))
        }
      }
    }
    .onChange(of: visibleConnections.map(\.id)) { _, ids in
      selectedConnectionIDs = selectedConnectionIDs.intersection(Set(ids))
    }
    .quickRuleSheet($quickRuleContext)
  }

  /// Issue #15 phase B2: a connection going the wrong way is where the user notices the problem,
  /// so the rule that fixes it is written from here, prefilled with the host in front of them.
  @ViewBuilder
  private func connectionMenu(for selection: [ConnectionSnapshot]) -> some View {
    if let connection = selection.first, selection.count == 1 {
      Button(String(format: String(localized: "Add Rule for %@…"), connectionRuleHost(connection))) {
        let host = connectionRuleHost(connection)
        quickRuleContext = QuickRuleSheetContext(
          title: "Add Rule for This Connection",
          subtitle: String(
            format: String(localized: "%@ currently matches %@ and routes through %@."),
            host,
            connection.ruleSummary.isEmpty ? String(localized: "no reported rule") : connection.ruleSummary,
            connection.chain.first ?? String(localized: "-")
          ),
          draft: .targeting(host: host)
        )
      }
      .disabled(connectionRuleHost(connection).isEmpty)

      Button("Open in Routing") {
        appModel.openRoutingExplanation(for: connection)
      }

      Divider()

      Button("Copy Host") { copy(connectionRuleHost(connection)) }
      Button("Copy Destination") { copy(connection.destinationAddress) }
    } else if !selection.isEmpty {
      Button("Copy Hosts") {
        copy(selection.map(connectionRuleHost).filter { !$0.isEmpty }.joined(separator: "\n"))
      }
    }
  }

  /// Mihomo reports the destination IP as the host for connections opened without a hostname, and a
  /// domain rule keyed on an IP would never match, so the address is used as-is and the draft turns
  /// it into a CIDR rule.
  private func connectionRuleHost(_ connection: ConnectionSnapshot) -> String {
    let host = connection.host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard host.isEmpty else { return host }
    let destination = connection.destinationAddress.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = destination.lastIndex(of: ":") else { return destination }
    return String(destination[destination.startIndex..<separator])
  }

  private func copy(_ text: String) {
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private var controls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        searchField

        modePicker

        groupByAppToggle

        Spacer()
      }

      VStack(alignment: .leading, spacing: 8) {
        searchField
        HStack(spacing: 10) {
          modePicker
          groupByAppToggle
          Spacer()
        }
      }
    }
  }

  @ViewBuilder
  private func connectionsWorkspace(mode layoutMode: ConnectionsLayoutMode, availableHeight: CGFloat) -> some View {
    let detailMaxHeight = ConnectionsLayout.detailMaxHeight(
      mode: layoutMode,
      availableHeight: availableHeight
    )

    VStack(alignment: .leading, spacing: 10) {
      controls

      switch layoutMode {
      case .splitDetail:
        HStack(alignment: .top, spacing: 12) {
          connectionList
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          connectionDetail(maxHeight: detailMaxHeight)
            .frame(width: ConnectionsLayout.detailWidth, alignment: .topLeading)
        }
      case .stackedDetail:
        VStack(alignment: .leading, spacing: 12) {
          connectionList
            .frame(minHeight: ConnectionsLayout.stackedListMinHeight(availableHeight: availableHeight))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          connectionDetail(maxHeight: detailMaxHeight)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var searchField: some View {
    TextField("Search app, host, IP, rule, chain", text: $searchText)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 240, idealWidth: 360, maxWidth: 460)
  }

  private var modePicker: some View {
    Picker("Mode", selection: $mode) {
      ForEach(ConnectionViewMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 170)
  }

  private var groupByAppToggle: some View {
    Toggle("Group by App", isOn: $groupsByApp)
      .toggleStyle(.checkbox)
      .fixedSize(horizontal: true, vertical: false)
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
                  iconCache: appIconCache,
                  isSelected: selectedConnectionIDs.contains(connection.id),
                  isClosing: runtimeData.closingConnectionIDs.contains(connection.id),
                  canClose: canClose
                ) {
                  toggleSelection(connection)
                } closeAction: {
                  guard canClose else { return }
                  appModel.closeConnection(connection)
                }
                .contextMenu {
                  connectionMenu(for: [connection])
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
          ConnectionAppLabel(connection: connection, iconCache: appIconCache)
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
      .contextMenu(forSelectionType: ConnectionSnapshot.ID.self) { ids in
        connectionMenu(for: visibleConnections.filter { ids.contains($0.id) })
      }
    }
  }

  /// The card scrolls its own rows rather than growing past `maxHeight`, so a long chain or process
  /// path can never push the connection list out of the page (issue #27).
  private func connectionDetail(maxHeight: CGFloat) -> some View {
    BoundedHeightSection(maxHeight: maxHeight) {
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

  private func detailRow(_ title: LocalizedStringResource, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
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
      connection.chain.joined(separator: " "),
    ]
    .compactMap(\.self)
    .joined(separator: " ")
    return terms.allSatisfy { haystack.localizedCaseInsensitiveContains($0) }
  }
}

@MainActor
final class ConnectionAppIconCache {
  private let maximumCount: Int
  private let loader: (String) -> NSImage?
  private var images: [String: NSImage] = [:]
  private var missingPaths = Set<String>()
  private var insertionOrder: [String] = []

  init(maximumCount: Int = 256, loader: @escaping (String) -> NSImage? = { NSWorkspace.shared.icon(forFile: $0) }) {
    self.maximumCount = maximumCount
    self.loader = loader
  }

  func icon(for rawPath: String?) -> NSImage? {
    guard let path = normalizedPath(rawPath) else {
      return nil
    }
    if let image = images[path] {
      return image
    }
    if missingPaths.contains(path) {
      return nil
    }
    let image = loader(path)
    store(image, for: path)
    return image
  }

  private func store(_ image: NSImage?, for path: String) {
    if images[path] == nil, !missingPaths.contains(path) {
      insertionOrder.append(path)
    }
    if let image {
      images[path] = image
      missingPaths.remove(path)
    } else {
      images.removeValue(forKey: path)
      missingPaths.insert(path)
    }
    trimIfNeeded()
  }

  private func normalizedPath(_ rawPath: String?) -> String? {
    guard let path = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
          !path.isEmpty
    else {
      return nil
    }
    return path
  }

  private func trimIfNeeded() {
    while insertionOrder.count > maximumCount, let removed = insertionOrder.first {
      insertionOrder.removeFirst()
      images.removeValue(forKey: removed)
      missingPaths.remove(removed)
    }
  }
}

private struct ConnectionAppLabel: View {
  let connection: ConnectionSnapshot
  let iconCache: ConnectionAppIconCache

  var body: some View {
    HStack(spacing: 6) {
      if let image = iconCache.icon(for: connection.processPath) {
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
}

private struct ConnectionRow: View {
  let connection: ConnectionSnapshot
  let iconCache: ConnectionAppIconCache
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

      ConnectionAppLabel(connection: connection, iconCache: iconCache)
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
    .background(isSelected ? Color.accentColor.opacity(0.12) : Color.clear, in: SurfaceRadius.shape(SurfaceRadius.chip))
  }
}
