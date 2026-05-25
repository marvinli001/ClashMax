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
      routingWorkspace
    }
    .onAppear(perform: resetDraft)
    .onChange(of: scope) { _, _ in resetDraft() }
    .onChange(of: profileStore.activeProfileID) { _, _ in resetDraft() }
    .onChange(of: draft) { _, _ in simulate() }
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

  private var routingWorkspace: some View {
    RoutingWorkspaceSurface {
      routingControlStrip
        .padding(.horizontal, 8)
        .padding(.vertical, 10)

      if !canEditCurrentScope {
        Divider()
        RoutingWorkspaceNotice(
          title: "No Profile",
          systemImage: "person.crop.circle.badge.exclamationmark",
          message: "Select a subscription profile to edit profile-specific routing."
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
      }

      Divider()
      routingWorkspaceBody

      if let error = appModel.lastError {
        Divider()
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(3)
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
      }
    }
  }

  private var routingControlStrip: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 10) {
        scopePicker
        enabledToggle
        Spacer(minLength: 16)
        templateStrip
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 10) {
          scopePicker
          enabledToggle
          Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
          Spacer(minLength: 0)
          templateStrip
        }
      }
    }
  }

  private var routingWorkspaceBody: some View {
    GeometryReader { proxy in
      if proxy.size.width >= 900 {
        HStack(alignment: .top, spacing: 0) {
          routingEditorPane
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

          Divider()

          routingInspectorPane
            .frame(width: min(max(proxy.size.width * 0.34, 320), 380), alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            routingEditorContent
            routingInspectorContent
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var routingEditorPane: some View {
    ScrollView {
      routingEditorContent
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var routingEditorContent: some View {
    RuleOverlaySettingsEditor(
      settings: $draft,
      showsHeader: false,
      showsEnableToggle: false
    )
    .disabled(!canEditCurrentScope)
  }

  private var routingInspectorPane: some View {
    ScrollView {
      routingInspectorContent
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var routingInspectorContent: some View {
    VStack(alignment: .leading, spacing: 12) {
      runtimeDiffPreview
      matchSimulator
    }
  }

  private var scopePicker: some View {
    Picker("Scope", selection: $scope) {
      ForEach(RoutingRuleScope.allCases) { scope in
        Text(scope.displayName).tag(scope)
      }
    }
    .pickerStyle(.segmented)
    .frame(width: 148)
  }

  private var enabledToggle: some View {
    Toggle(isOn: $draft.enabled) {
      Text(LocalizedStringKey(draft.enabled ? "Enabled" : "Disabled"))
    }
    .toggleStyle(.switch)
    .disabled(!canEditCurrentScope)
  }

  private var templateStrip: some View {
    HStack(spacing: 8) {
      Label("Templates", systemImage: "wand.and.stars")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      Button("Direct LAN") {
        addTemplate(.directLAN)
      }
      .disabled(!canEditCurrentScope)

      Button("CN Direct") {
        addTemplate(.cnDirect)
      }
      .disabled(!canEditCurrentScope)

      Button("Reject Ads") {
        addTemplate(.rejectAds)
      }
      .disabled(!canEditCurrentScope)

      Button {
        draft = .disabled
      } label: {
        Label("Restore Defaults", systemImage: "arrow.uturn.backward")
      }
      .disabled(!canEditCurrentScope)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .fixedSize(horizontal: true, vertical: false)
  }

  private var runtimeDiffPreview: some View {
    RoutingInspectorPanel(title: "Runtime Diff", systemImage: "doc.on.doc") {
      runtimeDiffSections

      if let validationError = draft.validationError {
        Label(validationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
  }

  private var runtimeDiffSections: some View {
    let disabledValues = draft.runtimeDisabledRuleMatchers.map { "\($0.mode.displayName): \($0.normalizedPattern)" }

    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) {
        diffSection(title: "Before", values: draft.runtimePrependRules)
          .frame(minWidth: 96, maxWidth: .infinity, alignment: .topLeading)
        diffSection(title: "Disabled", values: disabledValues)
          .frame(minWidth: 96, maxWidth: .infinity, alignment: .topLeading)
        diffSection(title: "After", values: draft.runtimeAppendRules)
          .frame(minWidth: 96, maxWidth: .infinity, alignment: .topLeading)
      }

      VStack(alignment: .leading, spacing: 10) {
        diffSection(title: "Before", values: draft.runtimePrependRules)
        diffSection(title: "Disabled", values: disabledValues)
        diffSection(title: "After", values: draft.runtimeAppendRules)
      }
    }
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
            .textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var matchSimulator: some View {
    RoutingInspectorPanel(title: "Match Simulator", systemImage: "scope") {
      TextField("domain, IP, process name, or path", text: $simulationTarget)
        .textFieldStyle(.roundedBorder)

      RoutingDetailRow(title: "Result", value: simulationOutcome.title, isProminent: true)
      RoutingDetailRow(title: "Detail", value: simulationOutcome.detail, lineLimit: 4)
    }
  }

  private var canSave: Bool {
    draft.validationError == nil && (scope == .global || activeSubscriptionProfile != nil)
  }

  private var canEditCurrentScope: Bool {
    scope == .global || activeSubscriptionProfile != nil
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

private struct RoutingWorkspaceSurface<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    VStack(alignment: .leading, spacing: 0) {
      content
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background {
      if colorScheme == .dark {
        ZStack {
          shape.fill(.regularMaterial)
          shape.fill(RoutingSurface.workspace(for: colorScheme))
        }
      } else {
        shape.fill(RoutingSurface.workspace(for: colorScheme))
      }
    }
    .clipShape(shape)
    .overlay {
      shape.strokeBorder(RoutingSurface.border(for: colorScheme), lineWidth: 1)
    }
  }
}

private struct RoutingWorkspaceNotice: View {
  let title: String
  let systemImage: String
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.orange)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey(title))
          .font(.callout.weight(.medium))
        Text(LocalizedStringKey(message))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .accessibilityElement(children: .combine)
  }
}

private struct RoutingInspectorPanel<Content: View>: View {
  @Environment(\.colorScheme) private var colorScheme
  let title: String
  let systemImage: String
  let content: Content

  init(title: String, systemImage: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      Label(LocalizedStringKey(title), systemImage: systemImage)
        .font(.headline)
        .lineLimit(1)

      content
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(RoutingSurface.secondary(for: colorScheme), in: shape)
    .overlay {
      shape.strokeBorder(RoutingSurface.border(for: colorScheme).opacity(0.82), lineWidth: 1)
    }
  }
}

private struct RoutingDetailRow: View {
  let title: String
  let value: String
  var isProminent = false
  var lineLimit = 2

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(LocalizedStringKey(title))
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(value)
        .font(isProminent ? .callout.weight(.medium) : .caption)
        .foregroundStyle(isProminent ? .primary : .secondary)
        .lineLimit(lineLimit)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private enum RoutingSurface {
  static func workspace(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.primary.opacity(0.032) : Color(nsColor: .textBackgroundColor)
  }

  static func secondary(for colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? Color.primary.opacity(0.040) : Color(nsColor: .controlBackgroundColor)
  }

  static func border(for colorScheme: ColorScheme) -> Color {
    Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.34 : 0.55)
  }
}
