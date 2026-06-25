import SwiftUI

struct PublicIPInfoCard: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var publicIP: PublicIPCoordinator
  let availableWidth: CGFloat
  /// Provider-resolved current group/node supplied by `RunningDashboardView` so the proxy-effect
  /// check shares the same off-main resolution as the Current Node card (issue #13 / #14).
  var currentGroup: ProxyGroup?
  var currentNode: ProxyNode?
  var hasMissingSelection = false
  @State private var showsFullIP = false
  @State private var isDirectModeProxyEffectExpanded = false

  var body: some View {
    TimelineView(.periodic(from: Date(), by: 5)) { context in
      content(now: context.date)
        .task(id: refreshTickID(for: context.date)) {
          appModel.refreshPublicIPInfo(now: context.date)
        }
    }
    .task {
      appModel.refreshPublicIPInfo()
    }
  }

  private func content(now: Date) -> some View {
    let state = publicIP.state

    return VStack(alignment: .leading, spacing: cardVerticalSpacing) {
      HStack(spacing: 10) {
        DashboardSectionHeader(
          title: "Public IP",
          symbolName: "globe",
          trailing: isCompact ? nil : state.info.map { "Updated \($0.fetchedAt.formatted(date: .omitted, time: .standard))" }
        )

        if state.isLoading {
          ProgressView()
            .controlSize(.small)
        }

        Button {
          appModel.refreshPublicIPInfo(force: true, now: now)
          // Also refresh the inputs the proxy-effect check reads, so a manual refresh re-evaluates
          // capture/route status. User-initiated only — never on the periodic tick (no refresh loop).
          if appModel.canControlRuntimeProxies {
            appModel.reloadRuntimeData()
          }
          if appModel.proxyRoutingMode == .tun {
            appModel.refreshTunDiagnostics()
          }
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .disabled(state.isLoading)
        .help("Refresh public IP and proxy effect")
      }

      if let info = state.info {
        infoBody(info)
      } else if state.isLoading {
        publicIPSkeletonBody
      } else {
        placeholderBody(
          title: "Public IP unavailable",
          symbolName: "network.slash",
          message: state.errorMessage ?? "Refresh after the runtime is ready."
        )
      }

      if let message = state.errorMessage {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(isCompact ? 3 : 2)
          .fixedSize(horizontal: false, vertical: true)
      }

      if appModel.isCoreRunning {
        proxyEffectSection()
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, minHeight: isCompact ? 190 : 210, alignment: .topLeading)
    .dashboardCard(interactive: true)
  }

  private func infoBody(_ info: PublicIPInfo) -> some View {
    VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
      if shouldStackIdentity {
        VStack(alignment: .leading, spacing: 10) {
          regionIdentity(for: info)
          ipAddressPill(for: info)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        HStack(spacing: 12) {
          regionIdentity(for: info)
          Spacer(minLength: 8)
          ipAddressPill(for: info)
        }
      }

      LazyVGrid(columns: detailColumns, alignment: .leading, spacing: isCompact ? 6 : 8) {
        PublicIPInfoDetail(title: "ASN / ISP", value: asnISPSummary(for: info))
        PublicIPInfoDetail(title: "Organization", value: info.organization ?? "--")
        PublicIPInfoDetail(title: "Location", value: locationSummary(for: info))
        PublicIPInfoDetail(title: "Timezone", value: info.timezone ?? "--")
        PublicIPInfoDetail(title: "Coordinates", value: coordinateSummary(for: info))
        PublicIPInfoDetail(title: "Source", value: info.sourceName)
      }
    }
  }

  private func proxyEffectSection() -> some View {
    let diagnostics = appModel.proxyEffectDiagnostics(
      currentGroup: currentGroup,
      currentNode: currentNode,
      hasMissingSelection: hasMissingSelection
    )
    let presentation = PublicIPProxyEffectPresentation(
      diagnostics: diagnostics,
      isExpanded: isDirectModeProxyEffectExpanded
    )

    return VStack(alignment: .leading, spacing: isCompact ? 7 : 9) {
      Divider()
        .opacity(0.24)

      proxyEffectHeader(diagnostics, presentation: presentation)

      if presentation.showsDetails {
        Text(diagnostics.reason)
          .font(.caption)
          .foregroundStyle(.primary)
          .fixedSize(horizontal: false, vertical: true)

        if !diagnostics.facts.isEmpty {
          LazyVGrid(columns: detailColumns, alignment: .leading, spacing: isCompact ? 5 : 7) {
            ForEach(Array(diagnostics.facts.prefix(4).enumerated()), id: \.offset) { _, fact in
              PublicIPInfoDetail(title: fact.title, value: fact.value)
            }
          }
        }

        if !diagnostics.recoveryActions.isEmpty {
          VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(diagnostics.recoveryActions.enumerated()), id: \.offset) { _, action in
              Label(action, systemImage: "arrow.turn.down.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(.easeInOut(duration: 0.16), value: presentation.showsDetails)
    .onChange(of: diagnostics.cause) { _, cause in
      if cause != .directRunMode {
        isDirectModeProxyEffectExpanded = false
      }
    }
  }

  @ViewBuilder
  private func proxyEffectHeader(
    _ diagnostics: ProxyEffectDiagnosticsSnapshot,
    presentation: PublicIPProxyEffectPresentation
  ) -> some View {
    if presentation.isCollapsible {
      Button {
        isDirectModeProxyEffectExpanded.toggle()
      } label: {
        proxyEffectHeaderContent(diagnostics, presentation: presentation)
      }
      .buttonStyle(.plain)
      .contentShape(Rectangle())
      .help(isDirectModeProxyEffectExpanded ? "Collapse proxy effect details" : "Show proxy effect details")
    } else {
      proxyEffectHeaderContent(diagnostics, presentation: presentation)
    }
  }

  private func proxyEffectHeaderContent(
    _ diagnostics: ProxyEffectDiagnosticsSnapshot,
    presentation: PublicIPProxyEffectPresentation
  ) -> some View {
    HStack(spacing: 8) {
      Image(systemName: proxyEffectSymbol(diagnostics.status))
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(proxyEffectTint(diagnostics.status))
        .frame(width: 16)
      Text("Proxy Effect")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 6)
      Text(diagnostics.statusLabel)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(proxyEffectTint(diagnostics.status))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(proxyEffectTint(diagnostics.status).opacity(0.14), in: Capsule())
      if presentation.isCollapsible {
        Image(systemName: presentation.showsDetails ? "chevron.down" : "chevron.right")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 10)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func proxyEffectSymbol(_ status: ProxyEffectDiagnosticsSnapshot.Status) -> String {
    switch status {
    case .pass: return "checkmark.seal.fill"
    case .warn: return "exclamationmark.triangle.fill"
    case .fail: return "xmark.octagon.fill"
    case .waiting: return "clock"
    }
  }

  private func proxyEffectTint(_ status: ProxyEffectDiagnosticsSnapshot.Status) -> Color {
    switch status {
    case .pass: return .green
    case .warn: return .orange
    case .fail: return .red
    case .waiting: return .secondary
    }
  }

  private var publicIPSkeletonBody: some View {
    VStack(alignment: .leading, spacing: isCompact ? 8 : 12) {
      if shouldStackIdentity {
        VStack(alignment: .leading, spacing: 10) {
          ClashMaxCurrentNodeSkeleton(isCompact: isCompact)
        }
      } else {
        HStack(spacing: 12) {
          ClashMaxCurrentNodeSkeleton(isCompact: isCompact)
          Spacer(minLength: 8)
          ClashMaxSkeletonBar(width: 128, height: 32, cornerRadius: 8)
        }
      }

      LazyVGrid(columns: detailColumns, alignment: .leading, spacing: isCompact ? 6 : 8) {
        ForEach(0..<6, id: \.self) { index in
          VStack(alignment: .leading, spacing: 5) {
            ClashMaxSkeletonBar(width: 62, height: 8)
            ClashMaxSkeletonBar(width: index.isMultiple(of: 2) ? 128 : 96, height: 11)
          }
        }
      }
    }
    .frame(maxWidth: .infinity, minHeight: isCompact ? 98 : 128, alignment: .topLeading)
    .accessibilityHidden(true)
  }

  private func regionIdentity(for info: PublicIPInfo) -> some View {
    HStack(spacing: 12) {
      Image(systemName: "location.circle.fill")
        .font(.system(size: 22, weight: .semibold))
        .foregroundStyle(.cyan)
        .frame(width: 42, height: 42)
        .background(.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

      VStack(alignment: .leading, spacing: 3) {
        Text(countryTitle(for: info))
          .font(.system(.title3, design: .rounded).weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.68)
        Text(info.sourceName)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }

  private func ipAddressPill(for info: PublicIPInfo) -> some View {
    HStack(spacing: 6) {
      Text(showsFullIP ? info.ipAddress : info.maskedAddress)
        .font(.system(.callout, design: .monospaced).weight(.semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.64)

      Button {
        showsFullIP.toggle()
      } label: {
        Image(systemName: showsFullIP ? "eye.slash" : "eye")
      }
      .buttonStyle(.borderless)
      .help(showsFullIP ? "Hide IP address" : "Show IP address")
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(.tileSurface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func placeholderBody(title: String, symbolName: String, message: String? = nil) -> some View {
    VStack(spacing: isCompact ? 8 : 10) {
      Image(systemName: symbolName)
        .font(.system(size: isCompact ? 22 : 24, weight: .semibold))
        .foregroundStyle(.secondary)
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      if let message {
        Text(message)
          .font(.caption)
          .foregroundStyle(Color.secondary.opacity(0.86))
          .multilineTextAlignment(.center)
          .lineLimit(isCompact ? 3 : 2)
      }
    }
    .frame(maxWidth: .infinity, minHeight: isCompact ? 98 : 128)
    .frame(maxHeight: .infinity, alignment: .center)
  }

  private var detailColumns: [GridItem] {
    if availableWidth < 340 {
      return [GridItem(.flexible(minimum: 120), spacing: 8)]
    }

    let minimum: CGFloat = isCompact ? 118 : 150
    return [
      GridItem(.flexible(minimum: minimum), spacing: 10),
      GridItem(.flexible(minimum: minimum), spacing: 10)
    ]
  }

  private var isCompact: Bool {
    availableWidth < 460
  }

  private var shouldStackIdentity: Bool {
    availableWidth < 360
  }

  private var cardVerticalSpacing: CGFloat {
    isCompact ? 10 : 12
  }

  private func refreshTickID(for date: Date) -> Int {
    Int(date.timeIntervalSince1970 / 5)
  }

  private func countryTitle(for info: PublicIPInfo) -> String {
    let country = info.countryName ?? info.countryCode
    return country ?? "Unknown Region"
  }

  private func asnISPSummary(for info: PublicIPInfo) -> String {
    [info.asn, info.isp]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " / ")
      .nonEmpty ?? "--"
  }

  private func locationSummary(for info: PublicIPInfo) -> String {
    [info.city, info.region]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: ", ")
      .nonEmpty ?? "--"
  }

  private func coordinateSummary(for info: PublicIPInfo) -> String {
    guard let latitude = info.latitude, let longitude = info.longitude else {
      return "--"
    }
    return String(format: "%.2f, %.2f", latitude, longitude)
  }

}

struct PublicIPProxyEffectPresentation: Equatable {
  var diagnostics: ProxyEffectDiagnosticsSnapshot
  var isExpanded: Bool

  var isCollapsible: Bool {
    diagnostics.status == .warn && diagnostics.cause == .directRunMode
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
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
