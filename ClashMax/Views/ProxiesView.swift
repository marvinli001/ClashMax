import SwiftUI

struct ProxiesView: View {
  @EnvironmentObject private var appModel: AppModel
  @State private var searchText = ""
  @State private var sortOrder: ProxyNodeSort = .name

  var body: some View {
    let groups = filteredGroups(from: appModel.visibleProxyGroups)
    let isStarting = appModel.dashboardRuntimeState.isStarting
    let canStart = ProxiesPageActionState.canStart(
      isRunning: appModel.isRunning,
      hasActiveProfile: appModel.profileStore.activeProfile != nil,
      isStarting: isStarting,
      readinessIssue: appModel.readinessIssue
    )

    AdaptivePage(
      title: "Proxies",
      subtitle: subtitle(for: groups)
    ) {
      if !appModel.isRunning, appModel.profileStore.activeProfile != nil {
        Button {
          appModel.start()
        } label: {
          Label(isStarting ? "Starting" : "Start", systemImage: isStarting ? "clock.arrow.circlepath" : "play.fill")
        }
        .disabled(!canStart)
      }
      Button {
        appModel.reloadRuntimeData()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .disabled(!ProxiesPageActionState.canRefresh(isStarting: isStarting))
    } content: {
      if groups.isEmpty {
        CenteredUnavailableState(
          title: "No proxy groups",
          systemImage: "point.3.connected.trianglepath.dotted",
          message: appModel.proxyGroupsUnavailableMessage
        )
      } else {
        VStack(alignment: .leading, spacing: 10) {
          proxyControls

          if appModel.previewRuntimeActive {
            ProxyPreviewNotice(
              icon: "wand.and.stars",
              message: "Preview core is running on loopback for delay testing. Hit Start on Home to redirect traffic."
            )
          } else if appModel.isShowingProxyPreview {
            ProxyPreviewNotice(
              icon: "info.circle",
              message: "Pick a node and we'll remember it. Tests start a quiet preview core automatically."
            )
          }

          if !appModel.proxyProviders.isEmpty {
            ProxyProviderList(providers: appModel.proxyProviders)
          }

          List {
            ForEach(groups) { group in
              Section(group.name) {
                ForEach(group.nodes) { node in
                  ProxyNodeRow(group: group, node: node)
                }
              }
            }
          }
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
      }
    }
    .onAppear {
      appModel.enterPreviewRuntime()
    }
    .onDisappear {
      Task { @MainActor in
        await appModel.leavePreviewRuntime()
      }
    }
  }

  private func subtitle(for groups: [ProxyGroup]) -> String {
    if groups.isEmpty {
      return "Proxy groups load from the active profile and runtime."
    }
    if appModel.previewRuntimeActive {
      return "\(groups.count) groups · preview core"
    }
    if appModel.isShowingProxyPreview {
      return "\(groups.count) preview groups"
    }
    return "\(groups.count) groups"
  }

  private var proxyControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        TextField("Search", text: $searchText)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 180, idealWidth: 260, maxWidth: 320)
        sortPicker
      }

      VStack(alignment: .leading, spacing: 8) {
        TextField("Search", text: $searchText)
          .textFieldStyle(.roundedBorder)
        sortPicker
      }
    }
  }

  private var sortPicker: some View {
    Picker("Sort", selection: $sortOrder) {
      ForEach(ProxyNodeSort.allCases) { order in
        Text(order.displayName).tag(order)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 260)
  }

  private func filteredGroups(from groups: [ProxyGroup]) -> [ProxyGroup] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return groups.compactMap { group in
      var group = group
      let nodes = sortedNodes(group.nodes)
      if query.isEmpty || group.name.lowercased().contains(query) {
        group.nodes = nodes
        return group
      }
      group.nodes = nodes.filter { node in
        node.name.lowercased().contains(query) || node.type.lowercased().contains(query)
      }
      return group.nodes.isEmpty ? nil : group
    }
  }

  private func sortedNodes(_ nodes: [ProxyNode]) -> [ProxyNode] {
    switch sortOrder {
    case .name:
      return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    case .delay:
      return nodes.sorted {
        let first = $0.delay ?? Int.max
        let second = $1.delay ?? Int.max
        if first == second {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return first < second
      }
    case .type:
      return nodes.sorted {
        let comparison = $0.type.localizedStandardCompare($1.type)
        if comparison == .orderedSame {
          return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return comparison == .orderedAscending
      }
    }
  }
}

private enum ProxyNodeSort: String, CaseIterable, Identifiable {
  case name
  case delay
  case type

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .name: "Name"
    case .delay: "Delay"
    case .type: "Type"
    }
  }
}

private struct ProxyProviderList: View {
  @EnvironmentObject private var appModel: AppModel
  let providers: [ProxyProvider]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(providers) { provider in
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(provider.name)
              .font(.callout.weight(.medium))
              .lineLimit(1)
            Text(providerSubtitle(provider))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 12)
          if let updatedAt = provider.updatedAt {
            Text(updatedAt, style: .date)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Button {
            appModel.healthCheckProvider(provider)
          } label: {
            if appModel.providerHealthChecksInFlight.contains(provider.id) {
              Image(systemName: "clock.arrow.circlepath")
            } else {
              Image(systemName: "waveform.path.ecg")
            }
          }
          .buttonStyle(.borderless)
          .disabled(!appModel.canControlRuntimeProxies || appModel.providerHealthChecksInFlight.contains(provider.id))
          .help("Run provider health check")
          .accessibilityLabel("Run health check for \(provider.name)")
        }
        .padding(.vertical, 4)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func providerSubtitle(_ provider: ProxyProvider) -> String {
    let vehicle = provider.vehicleType.map { " \($0)" } ?? ""
    return "\(provider.type)\(vehicle) - \(provider.proxies.count) nodes"
  }
}

private struct ProxyNodeRow: View {
  @EnvironmentObject private var appModel: AppModel
  let group: ProxyGroup
  let node: ProxyNode

  var body: some View {
    let canSelect = node.isSelectable && (appModel.canControlRuntimeProxies || appModel.canSelectProxyOffline)
    let canTest = node.isSelectable && appModel.canControlRuntimeProxies

    HStack(spacing: 10) {
      Button {
        appModel.selectProxy(group: group, node: node)
      } label: {
        HStack(spacing: 10) {
          Image(systemName: group.selected == node.name ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(group.selected == node.name ? .green : .secondary)
          VStack(alignment: .leading, spacing: 2) {
            Text(node.name)
              .foregroundStyle(node.isSelectable ? .primary : .secondary)
            Text(node.delay.map { "\($0) ms" } ?? "No delay")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 12)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(!canSelect)
      .help(canSelect ? "Select \(node.name)" : appModel.proxyRuntimeActionMessage)

      Button {
        appModel.testDelay(for: node)
      } label: {
        Image(systemName: "speedometer")
      }
      .buttonStyle(.borderless)
      .disabled(!canTest)
      .help(canTest ? "Test delay" : "Preview core needs a moment to come up before delay testing.")
      .accessibilityLabel("Test delay for \(node.name)")
    }
  }
}

enum ProxiesPageActionState {
  static func canStart(isRunning: Bool, hasActiveProfile: Bool, isStarting: Bool, readinessIssue: String?) -> Bool {
    !isRunning && hasActiveProfile && !isStarting && readinessIssue == nil
  }

  static func canRefresh(isStarting: Bool) -> Bool {
    !isStarting
  }
}

private struct ProxyPreviewNotice: View {
  let icon: String
  let message: String

  var body: some View {
    Label(message, systemImage: icon)
      .font(.callout)
      .foregroundStyle(.secondary)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}
