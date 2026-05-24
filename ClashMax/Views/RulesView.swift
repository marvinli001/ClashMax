import SwiftUI

struct RulesView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @State private var searchText = ""

  var body: some View {
    let rules = filteredRules
    AdaptivePage(
      title: "Rules",
      subtitle: String.localizedStringWithFormat(
        NSLocalizedString("%lld loaded", comment: ""),
        Int64(runtimeData.rules.count)
      )
    ) {
      EmptyView()
    } content: {
      if showsLoadingSkeleton {
        ClashMaxSkeletonTable(rows: 9)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ruleControls

          if !runtimeData.ruleProviders.isEmpty {
            RuleProviderList(providers: runtimeData.ruleProviders)
          }

          if runtimeData.rules.isEmpty {
            CenteredUnavailableState(
              title: "No rules loaded",
              systemImage: "list.bullet.rectangle",
              message: "Rules are loaded from the active profile after the runtime starts."
            )
          } else if rules.isEmpty {
            CenteredUnavailableState(
              title: "No matching rules",
              systemImage: "line.3.horizontal.decrease.circle",
              message: "No loaded rules match the current search."
            )
          } else {
            Table(rules) {
              TableColumn("#") { rule in
                Text("\(rule.index)")
                  .font(.system(.caption, design: .monospaced))
                  .foregroundStyle(.secondary)
              }
              .width(min: 44, ideal: 54, max: 64)

              TableColumn("Type") { rule in
                Text(rule.type.isEmpty ? "-" : rule.type)
                  .font(.callout.weight(.medium))
                  .lineLimit(1)
              }
              .width(min: 110, ideal: 150)

              TableColumn("Payload") { rule in
                Text(rule.payload.isEmpty ? "-" : rule.payload)
                  .font(.system(.body, design: .monospaced))
                  .lineLimit(1)
              }

              TableColumn("Policy") { rule in
                RulePolicyBadge(policy: rule.policy)
              }
              .width(min: 120, ideal: 160)

              TableColumn("Provider") { rule in
                Text(rule.providerName ?? "-")
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              .width(min: 110, ideal: 150)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
  }

  private var showsLoadingSkeleton: Bool {
    runtimeData.rules.isEmpty
      && appModel.profileStore.activeProfile != nil
      && (appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting)
  }

  private var ruleControls: some View {
    HStack(spacing: 10) {
      TextField("Search rules, type=, policy=, provider=", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 220, idealWidth: 360, maxWidth: 460)
      Spacer()
      Text(ruleSummary)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var ruleSummary: String {
    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "\(runtimeData.rules.count) rules"
    }
    return "\(filteredRules.count) of \(runtimeData.rules.count)"
  }

  private var filteredRules: [RuntimeRule] {
    let query = RuleSearchQuery(rawValue: searchText)
    guard !query.isEmpty else { return runtimeData.rules }
    return runtimeData.rules.filter { query.matches($0) }
  }
}

private struct RuleSearchQuery {
  let terms: [String]

  init(rawValue: String) {
    terms = rawValue
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .split(whereSeparator: \.isWhitespace)
      .map(String.init)
  }

  var isEmpty: Bool { terms.isEmpty }

  func matches(_ rule: RuntimeRule) -> Bool {
    terms.allSatisfy { term in
      let lowercased = term.lowercased()
      if lowercased.hasPrefix("type=") {
        return rule.type.localizedCaseInsensitiveContains(value(after: "type=", in: term))
      }
      if lowercased.hasPrefix("policy=") {
        return rule.policy.localizedCaseInsensitiveContains(value(after: "policy=", in: term))
      }
      if lowercased.hasPrefix("provider=") {
        return (rule.providerName ?? "").localizedCaseInsensitiveContains(value(after: "provider=", in: term))
      }
      return [rule.type, rule.payload, rule.policy, rule.providerName, rule.raw]
        .compactMap { $0 }
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(term)
    }
  }

  private func value(after prefix: String, in term: String) -> String {
    String(term.dropFirst(prefix.count))
  }
}

private struct RulePolicyBadge: View {
  let policy: String

  var body: some View {
    Text(policy.isEmpty ? "-" : policy)
      .font(.caption.weight(.semibold))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 7)
      .padding(.vertical, 3)
      .background(tint.opacity(0.10), in: Capsule())
  }

  private var tint: Color {
    switch policy.uppercased() {
    case "DIRECT":
      return .green
    case "REJECT", "REJECT-DROP":
      return .red
    case "GLOBAL":
      return .purple
    default:
      return .cyan
    }
  }
}

private struct RuleProviderList: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  let providers: [RuleProvider]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Label("Rule Providers", systemImage: "list.bullet.rectangle")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          appModel.updateAllRuleProviders()
        } label: {
          Label("Update All", systemImage: "arrow.clockwise")
            .labelStyle(.titleAndIcon)
        }
        .controlSize(.small)
        .disabled(!appModel.canControlRuntimeProxies || providers.isEmpty || allUpdatesInFlight)
      }

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
            appModel.updateRuleProvider(provider)
          } label: {
            if runtimeData.ruleProviderUpdatesInFlight.contains(provider.id) {
              Image(systemName: "clock.arrow.circlepath")
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .buttonStyle(.borderless)
          .disabled(!appModel.canControlRuntimeProxies || runtimeData.ruleProviderUpdatesInFlight.contains(provider.id))
          .help("Update rule provider")
          .accessibilityLabel("Update rule provider \(provider.name)")
        }
        .padding(.vertical, 4)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .strokeBorder(.quaternary, lineWidth: 1)
    }
  }

  private var allUpdatesInFlight: Bool {
    !providers.isEmpty && providers.allSatisfy { runtimeData.ruleProviderUpdatesInFlight.contains($0.id) }
  }

  private func providerSubtitle(_ provider: RuleProvider) -> String {
    [
      provider.type,
      provider.vehicleType,
      provider.behavior,
      provider.format,
      provider.ruleCount.map { "\($0) rules" }
    ]
    .compactMap { $0 }
    .filter { !$0.isEmpty }
    .joined(separator: " - ")
  }
}
