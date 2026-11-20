import SwiftUI

struct HomeExitWell: View {
  @Environment(AppModel.self) private var appModel
  @Environment(PublicIPCoordinator.self) private var publicIP
  let compact: Bool
  let running: Bool
  let currentGroup: ProxyGroup?
  let currentNode: ProxyNode?
  let hasMissingSelection: Bool
  @State private var showsFullIP = false
  @State private var showsDiagnostics = false

  var body: some View {
    Group {
      if running {
        TimelineView(.periodic(from: .now, by: 5)) { context in
          content
            .task(id: Int(context.date.timeIntervalSince1970 / 5)) {
              appModel.refreshPublicIPInfo(now: context.date)
            }
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          title
          Text("Exit is checked after startup.").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(.horizontal, 14).padding(.vertical, compact ? 8 : 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .homeWell()
    .onChange(of: captureActive) { _, active in
      if running, active { appModel.refreshPublicIPInfo(force: true) }
    }
    .onChange(of: running) { _, _ in showsFullIP = false; showsDiagnostics = false }
  }

  private var captureActive: Bool {
    appModel.systemProxyEnabled || appModel.tunEnabled || appModel.networkExtensionEnabled
  }

  private var title: some View {
    Label("Exit", systemImage: "globe").font(.callout).foregroundStyle(.secondary)
  }

  private var content: some View {
    let state = publicIP.state
    let diagnostics = appModel.proxyEffectDiagnostics(currentGroup: currentGroup, currentNode: currentNode, hasMissingSelection: hasMissingSelection)
    let presentation = PublicIPProxyEffectPresentation(diagnostics: diagnostics, isExpanded: showsDiagnostics)
    return VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 7) {
        title
        Spacer(minLength: 2)
        if state.errorMessage == nil || diagnostics.status != .waiting {
          Button { showsDiagnostics = true } label: {
            HomeChip(text: String(localized: presentation.title), symbol: "chevron.right", tone: presentation.tint)
          }
          .buttonStyle(.plain)
          .help("Show proxy effect details")
          .popover(isPresented: $showsDiagnostics, arrowEdge: .bottom) {
            diagnosticDetails(diagnostics)
          }
        }
        Button {
          refresh()
        } label: {
          if state.isLoading { ProgressView().controlSize(.mini) }
          else { Image(systemName: "arrow.clockwise") }
        }
        .buttonStyle(.borderless).disabled(state.isLoading)
        .help("Refresh public IP and proxy effect").accessibilityLabel("Refresh public IP and proxy effect")
      }
      if let info = state.info {
        if compact {
          HStack(spacing: 12) {
            location(info)
            Spacer(minLength: 4)
            address(info)
            timestamp(info)
          }
        } else {
          location(info)
          address(info)
          timestamp(info)
        }
      } else if state.isLoading {
        VStack(alignment: .leading, spacing: 6) {
          ClashMaxSkeletonBar(width: 128, height: 14)
          ClashMaxSkeletonBar(width: 96, height: 10)
        }
        .clashMaxSkeleton()
        .accessibilityLabel("Checking exit…")
      } else if state.errorMessage == nil {
        Text("Public IP unavailable").font(.caption).foregroundStyle(.secondary)
      }
      if let message = state.errorMessage {
        HStack {
          Label(NSLocalizedString(message, comment: ""), systemImage: "exclamationmark.triangle")
            .fixedSize(horizontal: false, vertical: true)
          Button(String(localized: "Retry")) { refresh() }.buttonStyle(.link)
        }
        .font(.caption)
      } else if diagnostics.status != .waiting, !presentation.isCollapsible {
        Text(diagnostics.reason).font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func refresh() {
    appModel.refreshPublicIPInfo(force: true)
    if appModel.canControlRuntimeProxies { appModel.reloadRuntimeData() }
    if appModel.proxyRoutingMode == .tun { appModel.refreshTunDiagnostics() }
  }

  private func location(_ info: PublicIPInfo) -> some View {
    let place = DashboardHeaderRoute.location(of: info) ?? String(localized: "Unknown Region")
    return HStack(spacing: 7) {
      if let code = info.countryCode, !code.isEmpty, code != place {
        Text(code.uppercased()).font(.caption.weight(.semibold))
          .padding(.horizontal, 6).padding(.vertical, 2)
          .background(.cardSurface, in: RoundedRectangle(cornerRadius: 6))
      }
      Text(place).font(.title3.weight(.semibold)).lineLimit(1).truncationMode(.middle).help(place)
    }
  }

  private func address(_ info: PublicIPInfo) -> some View {
    HStack(spacing: 6) {
      Text(verbatim: showsFullIP ? info.ipAddress : info.maskedAddress)
        .font(.callout.monospaced()).lineLimit(1).minimumScaleFactor(0.75).truncationMode(.middle)
      Button { showsFullIP.toggle() } label: {
        Image(systemName: showsFullIP ? "eye.slash" : "eye")
      }
      .buttonStyle(.borderless)
      .help(showsFullIP ? "Hide IP address" : "Show IP address")
      .accessibilityLabel(showsFullIP ? Text("Hide IP address") : Text("Show IP address"))
    }
  }

  private func timestamp(_ info: PublicIPInfo) -> some View {
    HStack(spacing: 4) {
      if let asn = info.asn, !asn.isEmpty { Text(asn); Text(verbatim: "·") }
      Text(info.fetchedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
    }
    .font(.caption).foregroundStyle(.tertiary)
  }

  private func diagnosticDetails(_ diagnostics: ProxyEffectDiagnosticsSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(diagnostics.headline).font(.headline)
      Text(diagnostics.reason).font(.callout).fixedSize(horizontal: false, vertical: true)
      LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], alignment: .leading, spacing: 8) {
        ForEach(Array(diagnostics.facts.enumerated()), id: \.offset) { _, fact in
          PublicIPInfoDetail(title: fact.title, value: fact.value)
        }
      }
      ForEach(Array(diagnostics.recoveryActions.enumerated()), id: \.offset) { _, action in
        Label(action, systemImage: "arrow.turn.down.right").font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(16).frame(width: 340)
  }
}

struct PublicIPProxyEffectPresentation: Equatable {
  var diagnostics: ProxyEffectDiagnosticsSnapshot
  var isExpanded: Bool

  var title: LocalizedStringResource {
    switch diagnostics.status {
    case .pass: "Proxy active"
    case .warn: "Check proxy"
    case .fail: "Proxy inactive"
    case .waiting: "Waiting"
    }
  }

  var tint: Color? {
    switch diagnostics.status {
    case .pass: .green
    case .warn: .orange
    case .fail: .red
    case .waiting: nil
    }
  }

  var isCollapsible: Bool {
    diagnostics.status == .pass || (diagnostics.status == .warn && diagnostics.cause == .directRunMode)
  }

  var showsDetails: Bool {
    !isCollapsible || isExpanded
  }
}

private struct PublicIPInfoDetail: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(.caption, design: .rounded).weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.68)
        .help(value)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
