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

  /// Issue #27: the stacked layout puts the detail *under* the list, so the two share one page.
  /// `stackedListMinHeight` alone outgrew a short window, and an oversized page does not clip — it
  /// stretches the whole window's layout. Both blocks therefore scale with the room they have.
  static func stackedListMinHeight(availableHeight: CGFloat) -> CGFloat {
    guard availableHeight.isFinite, availableHeight > 0 else { return stackedListMinHeight }
    return min(stackedListMinHeight, max(availableHeight * 0.45, 120))
  }

  /// How tall the detail may grow before its contents scroll inside it. Beside the list it owns a
  /// full column; under the list it may claim only part of the page.
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
  /// Details are opt-in: the table alone answers most questions, and a permanent detail block used
  /// to take a third of every page even with nothing selected.
  @State private var showsDetail = false
  @State private var selectedConnectionIDs = Set<ConnectionSnapshot.ID>()
  @State private var appIconCache = ConnectionAppIconCache()
  @State private var quickRuleContext: QuickRuleSheetContext?
  @State private var snifferFixPhase = SnifferFixPhase.idle

  /// The one-click sniffer repair offered by the domain verdict. Local to the panel because it is
  /// about the button the user just pressed, not about the runtime as a whole.
  private enum SnifferFixPhase: Equatable {
    case idle
    case applying
    case applied
    case failed(String)
  }

  init() {}

  /// Seeds the page's view state for previews and fixture renders; the app starts from the defaults.
  init(
    initialMode: ConnectionViewMode,
    initialGroupsByApp: Bool = false,
    initialShowsDetail: Bool = false,
    initialSelection: Set<ConnectionSnapshot.ID> = []
  ) {
    _mode = State(initialValue: initialMode)
    _groupsByApp = State(initialValue: initialGroupsByApp)
    _showsDetail = State(initialValue: initialShowsDetail)
    _selectedConnectionIDs = State(initialValue: initialSelection)
  }

  var body: some View {
    let visibleConnections = visibleConnections
    // Only visible rows count as selected — a row hidden by the search is not — and only the ones
    // still open and not already being closed may be the target of a Close action.
    let selection = visibleConnections.filter { selectedConnectionIDs.contains($0.id) }
    let selectedActive = selection.filter(canCloseConnection)

    AdaptivePage(title: "Connections") {
      EmptyView()
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        // Always rendered, whatever the list holds: a search with no result, or an Active view with
        // zero connections while History still has some, must keep its way back.
        controls(selection: selection, selectedActive: selectedActive)

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
                visibleConnections: visibleConnections,
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
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .onChange(of: visibleConnections.map(\.id)) { _, ids in
      // Rows that left the list leave the selection too, so a closed connection can never stay the
      // target of Close Selected; rows that stay keep their highlight through every refresh.
      let retained = selectedConnectionIDs.intersection(Set(ids))
      if retained != selectedConnectionIDs {
        selectedConnectionIDs = retained
      }
    }
    .onChange(of: selectedConnectionIDs) { _, _ in
      snifferFixPhase = .idle
    }
    .quickRuleSheet($quickRuleContext)
  }

  // MARK: - Controls

  private func controls(selection: [ConnectionSnapshot], selectedActive: [ConnectionSnapshot]) -> some View {
    HStack(spacing: 10) {
      TextField("Search app, host, IP, rule, chain", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 200, idealWidth: 320, maxWidth: 400)

      Picker("Mode", selection: $mode) {
        ForEach(ConnectionViewMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .frame(width: 150)
      .help("Active shows live connections; History keeps recently closed ones")

      Spacer(minLength: 8)

      if !selectedActive.isEmpty {
        Button {
          closeSelected(selectedActive)
        } label: {
          Label(
            String.localizedStringWithFormat(NSLocalizedString("Close Selected (%lld)", comment: ""), Int64(selectedActive.count)),
            systemImage: "xmark.circle"
          )
        }
        .disabled(!appModel.canControlRuntimeProxies)
        .help("Close the selected active connections")
      }

      Toggle(isOn: $showsDetail) {
        Label("Show Details", systemImage: "info.circle")
          .labelStyle(.iconOnly)
      }
      .toggleStyle(.button)
      .keyboardShortcut("i", modifiers: [.command, .option])
      .help("Show details for the selected connection (⌥⌘I)")
      .accessibilityLabel("Show Details")

      moreMenu(selection: selection)
    }
  }

  /// The selected rows' actions come first — the same ones the row's context menu offers, from the
  /// same code — so a keyboard or VoiceOver user has a discoverable path to "Add Rule" and "Resolve
  /// DNS" without a right-click. With nothing selected the section says so instead of vanishing.
  private func moreMenu(selection: [ConnectionSnapshot]) -> some View {
    Menu {
      if selection.isEmpty {
        Text("Select a connection")
      } else {
        Section(ConnectionMenuPolicy.selectionTitle(for: selection)) {
          connectionMenu(for: selection, includesShowDetails: false)
        }
      }

      Divider()

      Button {
        appModel.closeAllRuntimeConnections()
      } label: {
        if runtimeData.closingAllConnections {
          Label("Closing", systemImage: "clock.arrow.circlepath")
        } else {
          Label("Close All Connections", systemImage: "xmark.circle")
        }
      }
      .disabled(runtimeData.connections.isEmpty || runtimeData.closingAllConnections || !appModel.canControlRuntimeProxies)

      Divider()

      Toggle("Group by App", isOn: $groupsByApp)
      Toggle("Show Details", isOn: $showsDetail)
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .help("Actions for the selected connections, Close All, and view options")
  }

  // MARK: - Workspace

  @ViewBuilder
  private func connectionsWorkspace(
    visibleConnections: [ConnectionSnapshot],
    mode layoutMode: ConnectionsLayoutMode,
    availableHeight: CGFloat
  ) -> some View {
    let detailMaxHeight = ConnectionsLayout.detailMaxHeight(
      mode: layoutMode,
      availableHeight: availableHeight
    )
    let list = connectionList(visibleConnections)

    if showsDetail {
      switch layoutMode {
      case .splitDetail:
        HStack(alignment: .top, spacing: 12) {
          list
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          connectionDetail(visibleConnections: visibleConnections, maxHeight: detailMaxHeight)
            .frame(width: ConnectionsLayout.detailWidth, alignment: .topLeading)
        }
      case .stackedDetail:
        VStack(alignment: .leading, spacing: 12) {
          list
            .frame(minHeight: ConnectionsLayout.stackedListMinHeight(availableHeight: availableHeight))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          connectionDetail(visibleConnections: visibleConnections, maxHeight: detailMaxHeight)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    } else {
      list
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
  }

  @ViewBuilder
  private func connectionList(_ visibleConnections: [ConnectionSnapshot]) -> some View {
    if groupsByApp {
      List(selection: $selectedConnectionIDs) {
        ForEach(groupedConnections(visibleConnections), id: \.app) { group in
          Section(group.app) {
            ForEach(group.connections) { connection in
              HStack(spacing: 10) {
                ConnectionAppLabel(connection: connection, iconCache: appIconCache)
                  .frame(width: 150, alignment: .leading)
                Text(connection.host)
                  .lineLimit(1)
                  .truncationMode(.middle)
                Spacer(minLength: 12)
                Text(connection.ruleSummary)
                  .font(.callout)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
                Text(TrafficSample.formatBytes(connection.download + connection.upload))
                  .font(.callout.monospacedDigit())
                  .foregroundStyle(.secondary)
                  .frame(width: 84, alignment: .trailing)
              }
              .tag(connection.id)
            }
          }
        }
      }
      .listStyle(.inset)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contextMenu(forSelectionType: ConnectionSnapshot.ID.self) { ids in
        connectionMenu(for: visibleConnections.filter { ids.contains($0.id) })
      } primaryAction: { _ in
        showsDetail = true
      }
    } else {
      Table(visibleConnections, selection: $selectedConnectionIDs) {
        TableColumn("App") { connection in
          ConnectionAppLabel(connection: connection, iconCache: appIconCache)
        }
        .width(min: 110, ideal: 150)

        TableColumn("Destination") { connection in
          Text(connection.host)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(connection.destinationAddress)
        }

        TableColumn("Rule") { connection in
          Text(connection.ruleSummary.isEmpty ? "-" : connection.ruleSummary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(connection.ruleSummary)
        }
        .width(min: 100, ideal: 150)

        TableColumn("Policy") { connection in
          Text(connection.chain.first ?? "-")
            .lineLimit(1)
            .help(connection.chain.joined(separator: " / "))
        }
        .width(min: 80, ideal: 110)

        TableColumn("Traffic") { connection in
          // Totals, not a rate: the column reads "1.2 MB", the same way the detail row does.
          Text(TrafficSample.formatBytes(connection.download + connection.upload))
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .width(min: 76, ideal: 90, max: 110)
      }
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
      .contextMenu(forSelectionType: ConnectionSnapshot.ID.self) { ids in
        connectionMenu(for: visibleConnections.filter { ids.contains($0.id) })
      } primaryAction: { _ in
        // Double-click opens the details for the row under the pointer.
        showsDetail = true
      }
    }
  }

  /// Issue #15 phase B2: a connection going the wrong way is where the user notices the problem,
  /// so the rule that fixes it is written from here, prefilled with the host in front of them.
  @ViewBuilder
  private func connectionMenu(for selection: [ConnectionSnapshot], includesShowDetails: Bool = true) -> some View {
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

      // Roadmap A2: the name is right here, and the core's resolver — not the Mac's — is what
      // decides where it goes. A connection opened by IP has nothing to resolve.
      if let domain = ConnectionMenuPolicy.resolvableDomain(for: connection) {
        Button(String(format: String(localized: "Resolve DNS for %@"), domain)) {
          appModel.openDNSResolution(for: connection)
        }
      }

      if includesShowDetails {
        Button("Show Details") {
          showsDetail = true
        }
      }

      Divider()

      if canCloseConnection(connection) {
        Button("Close Connection") {
          appModel.closeConnection(connection)
        }
        Divider()
      }

      Button("Copy Host") { copy(connectionRuleHost(connection)) }
      Button("Copy Destination") { copy(connection.destinationAddress) }
    } else if !selection.isEmpty {
      let closable = selection.filter(canCloseConnection)
      if !closable.isEmpty {
        Button(String.localizedStringWithFormat(NSLocalizedString("Close Selected (%lld)", comment: ""), Int64(closable.count))) {
          closeSelected(closable)
        }
        Divider()
      }
      Button("Copy Hosts") {
        copy(selection.map(connectionRuleHost).filter { !$0.isEmpty }.joined(separator: "\n"))
      }
    }
  }

  private func connectionRuleHost(_ connection: ConnectionSnapshot) -> String {
    ConnectionMenuPolicy.ruleHost(for: connection)
  }

  private func copy(_ text: String) {
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  // MARK: - Detail

  /// The detail scrolls its own rows rather than growing past `maxHeight`, so a long chain or process
  /// path can never push the connection list out of the page (issue #27).
  private func connectionDetail(visibleConnections: [ConnectionSnapshot], maxHeight: CGFloat) -> some View {
    let connection = selectedConnection(in: visibleConnections)
    return BoundedHeightSection(maxHeight: maxHeight) {
      VStack(alignment: .leading, spacing: 6) {
        if let connection {
          detailHeader(connection)
          detailRow("App", connection.appDisplayName)
          detailRow("Process", connection.processPath ?? "-")
          detailRow("Network", connection.network.isEmpty ? "-" : connection.network)
          detailRow("Source", connection.sourceAddress)
          detailRow("Destination", connection.destinationAddress)
          detailRow("Rule", connection.ruleSummary.isEmpty ? "-" : connection.ruleSummary)
          detailRow("Chain", connection.chain.isEmpty ? "-" : connection.chain.joined(separator: " / "))
          detailRow("Traffic", TrafficSample.formatBytes(connection.download + connection.upload))
          whyThisRule(connection)
          domainVisibility(connection)
        } else if selectedConnectionIDs.count > 1 {
          Text(String.localizedStringWithFormat(NSLocalizedString("%lld connections selected", comment: ""), Int64(selectedConnectionIDs.count)))
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
          Text("Select a connection to inspect the process, rule, and chain.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .padding(12)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Connection details")
  }

  private func detailHeader(_ connection: ConnectionSnapshot) -> some View {
    let isActive = runtimeData.connections.contains { $0.id == connection.id }
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(connection.host.isEmpty ? connection.destinationAddress : connection.host)
        .font(.headline)
        .lineLimit(2)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      if isActive {
        if canCloseConnection(connection) {
          Button("Close") {
            appModel.closeConnection(connection)
          }
          .controlSize(.small)
        } else if runtimeData.closingConnectionIDs.contains(connection.id) {
          ProgressView()
            .controlSize(.small)
        }
      } else {
        // The truth about a row that lingers in History: nothing here can act on it any more.
        Text("Closed")
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
      }
    }
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

  /// Whether any domain rule could have matched this connection at all — the half of the routing
  /// story `whyThisRule` cannot tell.
  ///
  /// Roadmap A1: a connection opened straight to an IP carries no name, so every `DOMAIN-SUFFIX`
  /// rule written for it is structurally unreachable. Nothing else in this panel says so, and the
  /// user reads the silence as "my rules do not work". The verdict names the reason and, when
  /// ClashMax can repair it, offers the repair here rather than sending the user to Routing to
  /// reconstruct it by hand.
  private func domainVisibility(_ connection: ConnectionSnapshot) -> some View {
    let verdict = SnifferDiagnosticsBuilder.build(
      SnifferDiagnosticsInput(
        connection: connection,
        sniffer: appModel.activeSnifferSettings,
        snifferChangedAt: appModel.activeSnifferSettingsChangedAt,
        rules: runtimeData.rules
      )
    )
    return VStack(alignment: .leading, spacing: 8) {
      Divider()
      Label("Domain Visibility", systemImage: "eye.trianglebadge.exclamationmark")
        .font(.caption.weight(.semibold))
      Label {
        Text(verdict.headline)
          .font(.caption.weight(.medium))
          .fixedSize(horizontal: false, vertical: true)
      } icon: {
        Image(systemName: Self.domainVerdictSymbol(verdict.status))
          .foregroundStyle(Self.domainVerdictTint(verdict.status))
      }
      Text(verdict.reason)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)

      // `Destination` is the row directly above this block, and `Match On Domain` is what
      // `whyThisRule` already simulated; repeating either would pad the panel without adding a fact.
      ForEach(verdict.facts.filter { $0.key != .destination && $0.key != .matchOnDomain }, id: \.key) { fact in
        VStack(alignment: .leading, spacing: 2) {
          Text(fact.title)
            .font(.caption2)
            .foregroundStyle(.tertiary)
          Text(fact.value)
            .font(.caption)
            .lineLimit(2)
            .textSelection(.enabled)
        }
      }

      ForEach(verdict.recoveryActions, id: \.self) { action in
        Label(action, systemImage: "arrow.turn.down.right")
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      if let fix = verdict.fix {
        snifferFixControl(fix)
      }
    }
  }

  @ViewBuilder
  private func snifferFixControl(_ fix: SnifferDiagnosticsFix) -> some View {
    switch snifferFixPhase {
    case .idle, .applying:
      Button {
        applySnifferFix(fix)
      } label: {
        if snifferFixPhase == .applying {
          ProgressView().controlSize(.small)
        } else {
          Label(fix.title, systemImage: "wand.and.stars")
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(snifferFixPhase == .applying)
    case .applied:
      // What the commit actually did, not merely that it was written: a sniffer change hot-reloads
      // while the core is up and waits for the next start when it is not, and those are different
      // answers to "is it on now?".
      Label(
        appModel.lastRuntimeApplyOutcome?.title ?? String(localized: "Sniffer settings updated"),
        systemImage: "checkmark.circle.fill"
      )
      .font(.caption2)
      .foregroundStyle(.green)
      .fixedSize(horizontal: false, vertical: true)
    case let .failed(message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption2)
        .foregroundStyle(.red)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func applySnifferFix(_ fix: SnifferDiagnosticsFix) {
    snifferFixPhase = .applying
    Task { @MainActor in
      let didApply = await appModel.applySnifferFix(fix)
      snifferFixPhase = didApply
        ? .applied
        : .failed(appModel.lastError ?? String(localized: "The sniffer change could not be applied."))
    }
  }

  private static func domainVerdictSymbol(_ status: SnifferDiagnosticsSnapshot.Status) -> String {
    switch status {
    case .pass: return "checkmark.seal.fill"
    case .info: return "info.circle.fill"
    case .warn: return "exclamationmark.triangle.fill"
    }
  }

  private static func domainVerdictTint(_ status: SnifferDiagnosticsSnapshot.Status) -> Color {
    switch status {
    case .pass: return .green
    case .info: return .secondary
    case .warn: return .orange
    }
  }

  /// Label and value on one line: under the list the detail has little height to spend, and a
  /// two-column row shows twice as many facts as stacked caption pairs did.
  private func detailRow(_ title: LocalizedStringResource, _ value: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 88, alignment: .leading)
      Text(value)
        .font(.caption)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  // MARK: - Data

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

  private func groupedConnections(_ connections: [ConnectionSnapshot]) -> [(app: String, connections: [ConnectionSnapshot])] {
    Dictionary(grouping: connections, by: \.appDisplayName)
      .map { (app: $0.key, connections: $0.value) }
      .sorted { $0.app.localizedStandardCompare($1.app) == .orderedAscending }
  }

  private func selectedConnection(in visibleConnections: [ConnectionSnapshot]) -> ConnectionSnapshot? {
    guard selectedConnectionIDs.count == 1, let id = selectedConnectionIDs.first else { return nil }
    return visibleConnections.first { $0.id == id }
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
    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return String(localized: "No app, host, rule, or chain matches the current search.")
    }
    if mode == .active, !runtimeData.connectionRecords.isEmpty {
      return String(localized: "Recently closed connections are kept under History.")
    }
    return String(localized: "Connections will appear here after apps send traffic through ClashMax.")
  }

  private func closeSelected(_ connections: [ConnectionSnapshot]) {
    for connection in connections {
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

/// What the selection-driven menus can offer for a connection. Shared by the row context menu and
/// the page's More menu so both agree on when "Resolve DNS" exists and what a rule is keyed on.
enum ConnectionMenuPolicy {
  /// A connection opened without a hostname has no domain to key a rule on, so the draft is
  /// prefilled with the destination address and turned into a CIDR rule. Reads the typed state
  /// instead of re-deriving it: `host` is the display fallback, so testing it for emptiness could
  /// never have told the two cases apart (roadmap A1a).
  static func ruleHost(for connection: ConnectionSnapshot) -> String {
    connection.domain ?? connection.destinationIPAddress ?? ""
  }

  /// The core's resolver can only be asked about a name; an IP-only connection offers no DNS action.
  static func resolvableDomain(for connection: ConnectionSnapshot) -> String? {
    guard let domain = connection.domain?.trimmingCharacters(in: .whitespacesAndNewlines), !domain.isEmpty else {
      return nil
    }
    return domain
  }

  /// Header of the selection section in the More menu: the one host, or how many rows are selected.
  static func selectionTitle(for selection: [ConnectionSnapshot]) -> String {
    if selection.count == 1, let connection = selection.first {
      let host = ruleHost(for: connection)
      return host.isEmpty ? connection.destinationAddress : host
    }
    return String.localizedStringWithFormat(NSLocalizedString("%lld connections selected", comment: ""), Int64(selection.count))
  }
}

enum ConnectionViewMode: String, CaseIterable, Identifiable {
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
