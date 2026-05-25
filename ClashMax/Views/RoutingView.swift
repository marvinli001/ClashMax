import SwiftUI

struct RoutingView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @State private var scope: RoutingRuleScope = .global
  @State private var draft = RuleOverlaySettings.disabled
  @State private var simulationTarget = ""
  @State private var simulationOutcome: RuleMatchSimulationOutcome = .noMatch

  var body: some View {
    AdaptivePage(
      title: "Routing",
      subtitle: subtitle
    ) {
      Button {
        saveDraft()
      } label: {
        Label("Save", systemImage: "checkmark.circle")
      }
      .disabled(!canSave)

      Button {
        resetDraft()
      } label: {
        Label("Rollback", systemImage: "arrow.counterclockwise")
      }
    } content: {
      VStack(alignment: .leading, spacing: 12) {
        controls

        HStack(alignment: .top, spacing: 12) {
          ScrollView {
            VStack(alignment: .leading, spacing: 12) {
              templateStrip
              RuleOverlaySettingsPopover(settings: $draft)
                .padding(12)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }

          VStack(alignment: .leading, spacing: 12) {
            runtimeDiffPreview
            matchSimulator
          }
          .frame(width: 360, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        if let error = appModel.lastError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(3)
        }
      }
    }
    .onAppear(perform: resetDraft)
    .onChange(of: scope) { _, _ in resetDraft() }
    .onChange(of: profileStore.activeProfileID) { _, _ in resetDraft() }
    .onChange(of: simulationTarget) { _, _ in simulate() }
    .onChange(of: runtimeData.rules) { _, _ in simulate() }
  }

  private var subtitle: String {
    switch scope {
    case .global:
      return String(localized: "Global managed rules are merged into the generated runtime profile.")
    case .profile:
      return activeSubscriptionProfile == nil
        ? String(localized: "Select a subscription profile to edit profile-specific routing.")
        : String(localized: "Profile routing is stored with this subscription's provider options.")
    }
  }

  private var controls: some View {
    HStack(spacing: 10) {
      Picker("Scope", selection: $scope) {
        ForEach(RoutingRuleScope.allCases) { scope in
          Text(scope.displayName).tag(scope)
        }
      }
      .pickerStyle(.segmented)
      .frame(width: 220)

      Toggle("Enabled", isOn: $draft.enabled)
        .toggleStyle(.switch)

      Spacer()

      Text(draft.summary)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var templateStrip: some View {
    HStack(spacing: 8) {
      Label("Templates", systemImage: "wand.and.stars")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      Button("Direct LAN") {
        addTemplate(.directLAN)
      }
      Button("CN Direct") {
        addTemplate(.cnDirect)
      }
      Button("Reject Ads") {
        addTemplate(.rejectAds)
      }
      Spacer()
      Button {
        draft = .disabled
      } label: {
        Label("Restore Defaults", systemImage: "arrow.uturn.backward")
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
  }

  private var runtimeDiffPreview: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Runtime Diff", systemImage: "doc.on.doc")
        .font(.headline)

      diffSection(title: "Before", values: draft.runtimePrependRules)
      diffSection(
        title: "Disabled",
        values: draft.runtimeDisabledRuleMatchers.map { "\($0.mode.displayName): \($0.normalizedPattern)" }
      )
      diffSection(title: "After", values: draft.runtimeAppendRules)

      if let validationError = draft.validationError {
        Label(validationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private func diffSection(title: String, values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(LocalizedStringKey(title))
        .font(.caption)
        .foregroundStyle(.secondary)
      if values.isEmpty {
        Text("No changes")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(values, id: \.self) { value in
          Text(value)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
  }

  private var matchSimulator: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label("Match Simulator", systemImage: "scope")
        .font(.headline)
      TextField("domain, IP, process name, or path", text: $simulationTarget)
        .textFieldStyle(.roundedBorder)
      VStack(alignment: .leading, spacing: 4) {
        Text(simulationOutcome.title)
          .font(.callout.weight(.medium))
        Text(simulationOutcome.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var canSave: Bool {
    draft.validationError == nil && (scope == .global || activeSubscriptionProfile != nil)
  }

  private var activeSubscriptionProfile: Profile? {
    guard let profile = profileStore.activeProfile, profile.isSubscription else { return nil }
    return profile
  }

  private func resetDraft() {
    switch scope {
    case .global:
      draft = appModel.ruleOverlaySettings
    case .profile:
      draft = activeSubscriptionProfile?.subscriptionProviderOptions.ruleOverlay ?? .disabled
    }
    simulate()
  }

  private func saveDraft() {
    guard canSave else { return }
    let nextDraft = draft
    Task { @MainActor in
      switch scope {
      case .global:
        _ = await appModel.updateGlobalRuleOverlay(nextDraft)
      case .profile:
        guard let profile = activeSubscriptionProfile else { return }
        var options = profile.subscriptionProviderOptions
        options.ruleOverlay = nextDraft
        _ = await appModel.updateSubscriptionProviderOptions(profile, options: options)
      }
    }
  }

  private func addTemplate(_ template: RoutingTemplate) {
    draft.enabled = true
    switch template {
    case .directLAN:
      draft.prependRules.append(contentsOf: [
        ManagedRuleOverlayRule(kind: .domainSuffix, value: "local", policy: "DIRECT"),
        ManagedRuleOverlayRule(kind: .ipCIDR, value: "10.0.0.0/8", policy: "DIRECT", noResolve: true),
        ManagedRuleOverlayRule(kind: .ipCIDR, value: "172.16.0.0/12", policy: "DIRECT", noResolve: true),
        ManagedRuleOverlayRule(kind: .ipCIDR, value: "192.168.0.0/16", policy: "DIRECT", noResolve: true)
      ])
    case .cnDirect:
      draft.prependRules.append(contentsOf: [
        ManagedRuleOverlayRule(kind: .geoSite, value: "cn", policy: "DIRECT"),
        ManagedRuleOverlayRule(kind: .geoIP, value: "CN", policy: "DIRECT", noResolve: true)
      ])
    case .rejectAds:
      draft.prependRules.append(
        ManagedRuleOverlayRule(kind: .geoSite, value: "category-ads-all", policy: "REJECT")
      )
    }
  }

  private func simulate() {
    let simulator = RuleMatchSimulator()
    let overlayRules = draft.runtimePrependRules.enumerated().map { index, rule in
      runtimeRule(index: index, raw: rule)
    }
      + runtimeData.rules.filter { !draft.disablesRule($0.raw) }
      + draft.runtimeAppendRules.enumerated().map { index, rule in
        runtimeRule(index: runtimeData.rules.count + index, raw: rule)
      }
    simulationOutcome = simulator.simulate(target: simulationTarget, rules: overlayRules)
  }

  private func runtimeRule(index: Int, raw: String) -> RuntimeRule {
    let components = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    return RuntimeRule(
      index: index + 1,
      type: components.first ?? "",
      payload: components.count > 1 ? components[1] : "",
      policy: components.count > 2 ? components[2] : "",
      raw: raw
    )
  }
}

private enum RoutingRuleScope: String, CaseIterable, Identifiable {
  case global
  case profile

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .global: String(localized: "Global")
    case .profile: String(localized: "Profile")
    }
  }
}

private enum RoutingTemplate {
  case directLAN
  case cnDirect
  case rejectAds
}
