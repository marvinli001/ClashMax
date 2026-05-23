import SwiftUI

struct RulesView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var runtimeData: RuntimeDataStore

  var body: some View {
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
          if !runtimeData.ruleProviders.isEmpty {
            RuleProviderList(providers: runtimeData.ruleProviders)
          }

          if runtimeData.rules.isEmpty {
            CenteredUnavailableState(
              title: "No rules loaded",
              systemImage: "list.bullet.rectangle",
              message: "Rules are loaded from the active profile after the runtime starts."
            )
          } else {
            List(runtimeData.rules, id: \.self) { rule in
              Text(rule)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
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
