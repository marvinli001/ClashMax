import SwiftUI

struct RoutingView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var snippetLibrary: RuntimeSnippetLibraryStore
  @EnvironmentObject private var runtimeData: RuntimeDataStore
  @State private var selectedSnippetID: RuntimeSnippet.ID?
  @State private var draftSnippet = RuntimeSnippet.defaultRuleSnippet
  @State private var loadedSnippetSnapshot: RuntimeSnippet?
  @State private var isEditingDetachedDraft = false
  @State private var simulationDestination = ""
  @State private var simulationSourceIP = ""
  @State private var simulationDestinationPort = ""
  @State private var simulationSourcePort = ""
  @State private var simulationInboundPort = ""
  @State private var simulationProcess = ""
  @State private var simulationTrace: RuleMatchSimulationTrace = .noMatch
  @State private var explanationContext: RuleExplanation?

  var body: some View {
    AdaptivePage(
      title: "Routing",
      subtitle: String(localized: "Typed snippets are merged into generated runtime YAML without editing original profiles.")
    ) {
      Button {
        newRuleSnippet()
      } label: {
        Label("New Rule Snippet", systemImage: "plus.circle")
      }

      Button {
        newDNSPatchSnippet()
      } label: {
        Label("New DNS Patch", systemImage: "network")
      }

      Button {
        saveDraft()
      } label: {
        Label("Save", systemImage: "checkmark.circle")
      }
      .disabled(!canSave)

      Button(role: .destructive) {
        deleteSelectedSnippet()
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .disabled(selectedSnippet == nil)
    } content: {
      routingWorkspace
    }
    .task {
      await snippetLibrary.waitForLoad()
      selectInitialSnippetIfNeeded()
      consumeRoutingSimulationRequest()
    }
    .onChange(of: selectedSnippetID) { _, _ in loadSelectedSnippet() }
    .onChange(of: snippetLibrary.snippets) { _, _ in reconcileDraftWithLibrary() }
    .onChange(of: profileStore.activeProfileID) { _, _ in simulate() }
    .onChange(of: draftSnippet) { _, _ in simulate() }
    .onChange(of: simulationDestination) { _, _ in simulate() }
    .onChange(of: simulationSourceIP) { _, _ in simulate() }
    .onChange(of: simulationDestinationPort) { _, _ in simulate() }
    .onChange(of: simulationSourcePort) { _, _ in simulate() }
    .onChange(of: simulationInboundPort) { _, _ in simulate() }
    .onChange(of: simulationProcess) { _, _ in simulate() }
    .onChange(of: runtimeData.rules) { _, _ in simulate() }
    .onChange(of: appModel.routingSimulationRequest?.id) { _, _ in consumeRoutingSimulationRequest() }
  }

  private var routingWorkspace: some View {
    RoutingWorkspaceSurface {
      routingHeader
        .padding(.horizontal, 12)
        .padding(.vertical, 10)

      if let loadError = snippetLibrary.loadError {
        Divider()
        RoutingWorkspaceNotice(
          title: "Snippet Library Unavailable",
          systemImage: "exclamationmark.triangle.fill",
          message: loadError
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

  private var routingHeader: some View {
    HStack(spacing: 12) {
      Label("Snippet Library", systemImage: "square.stack.3d.up")
        .font(.headline)
      Text(librarySummary)
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if let activeProfile = profileStore.activeProfile {
        Label(activeProfile.name, systemImage: "doc.text")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var routingWorkspaceBody: some View {
    GeometryReader { proxy in
      if proxy.size.width >= 1120 {
        HStack(alignment: .top, spacing: 0) {
          snippetListPane
            .frame(width: 292, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)

          Divider()

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
            snippetListContent
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

  private var snippetListPane: some View {
    ScrollView {
      snippetListContent
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var snippetListContent: some View {
    VStack(alignment: .leading, spacing: 10) {
      if snippetLibrary.snippets.isEmpty {
        RoutingWorkspaceNotice(
          title: "No Snippets",
          systemImage: "square.stack.3d.up.slash",
          message: "Create a typed rule or DNS patch snippet to apply runtime changes safely."
        )
      } else {
        ForEach(Array(snippetLibrary.snippets.enumerated()), id: \.element.id) { index, snippet in
          RuntimeSnippetRow(
            snippet: snippet,
            isSelected: snippet.id == selectedSnippetID,
            canMoveUp: index > 0,
            canMoveDown: index < snippetLibrary.snippets.count - 1,
            onSelect: {
              selectedSnippetID = snippet.id
            },
            onToggle: {
              Task { @MainActor in
                _ = await appModel.setRuntimeSnippet(snippet, enabled: !snippet.enabled)
              }
            },
            onMoveUp: {
              Task { @MainActor in
                _ = await appModel.moveRuntimeSnippet(fromOffsets: IndexSet(integer: index), toOffset: index - 1)
              }
            },
            onMoveDown: {
              Task { @MainActor in
                _ = await appModel.moveRuntimeSnippet(fromOffsets: IndexSet(integer: index), toOffset: index + 2)
              }
            }
          )
        }
      }
    }
  }

  private var routingEditorPane: some View {
    ScrollView {
      routingEditorContent
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var routingEditorContent: some View {
    RoutingInspectorPanel(title: "Snippet Editor", systemImage: "slider.horizontal.3") {
      RoutingEditRow("Name") {
        TextField("Snippet Name", text: $draftSnippet.name)
          .textFieldStyle(.roundedBorder)
      }

      RoutingEditRow("Enabled") {
        Toggle("Enabled", isOn: $draftSnippet.enabled)
          .toggleStyle(.switch)
          .labelsHidden()
      }

      RoutingEditRow("Binding") {
        Picker("Binding", selection: bindingMode) {
          ForEach(RuntimeSnippetBindingMode.allCases) { mode in
            Text(mode.displayName).tag(mode)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
      }

      if case .profiles = draftSnippet.binding {
        profileBindingEditor
      }

      RoutingEditRow("Snippet Type") {
        Picker("Snippet Type", selection: payloadKind) {
          ForEach(RuntimeSnippetPayloadKind.allCases) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
      }

      Divider()

      switch draftSnippet.payload {
      case .rules:
        RuleOverlaySettingsEditor(settings: rulesPayloadBinding, showsHeader: false, showsEnableToggle: true)
      case .dnsPatch:
        RuntimeDNSPatchEditor(settings: dnsPayloadBinding)
      }

      if let validationError = draftSnippet.validationError {
        Label(validationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
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
      snippetStatus
      runtimeDiffPreview
      connectionExplanation
      matchSimulator
    }
  }

  private var snippetStatus: some View {
    RoutingInspectorPanel(title: "Active Profile", systemImage: "doc.text.magnifyingglass") {
      RoutingDetailRow(title: "Profile", value: profileStore.activeProfile?.name ?? String(localized: "No Profile"))
      RoutingDetailRow(title: "Snippet Binding", value: draftSnippet.binding.displayName)
      RoutingDetailRow(title: "Applies Here", value: draftAppliesToActiveProfile ? String(localized: "Yes") : String(localized: "No"))
      RoutingDetailRow(title: "Active Snippets", value: "\(activePreviewSnippets.count)")
    }
  }

  private var runtimeDiffPreview: some View {
    RoutingInspectorPanel(title: "Runtime Diff", systemImage: "doc.on.doc") {
      switch draftSnippet.payload {
      case let .rules(settings):
        runtimeRuleDiffSections(settings)
      case let .dnsPatch(settings):
        dnsDiffSection(settings)
      }
    }
  }

  private func runtimeRuleDiffSections(_ settings: RuleOverlaySettings) -> some View {
    let disabledValues = settings.runtimeDisabledRuleMatchers.map { "\($0.mode.displayName): \($0.normalizedPattern)" }

    return ViewThatFits(in: .horizontal) {
      HStack(alignment: .top, spacing: 10) {
        diffSection(title: "Before", values: settings.runtimePrependRules)
          .frame(minWidth: 96, maxWidth: .infinity, alignment: .topLeading)
        diffSection(title: "Disabled", values: disabledValues)
          .frame(minWidth: 96, maxWidth: .infinity, alignment: .topLeading)
        diffSection(title: "After", values: settings.runtimeAppendRules)
          .frame(minWidth: 96, maxWidth: .infinity, alignment: .topLeading)
      }

      VStack(alignment: .leading, spacing: 10) {
        diffSection(title: "Before", values: settings.runtimePrependRules)
        diffSection(title: "Disabled", values: disabledValues)
        diffSection(title: "After", values: settings.runtimeAppendRules)
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

  private func dnsDiffSection(_ settings: TunDNSSettings) -> some View {
    diffSection(title: "DNS Patch", values: dnsPatchPreviewLines(settings))
  }

  private var matchSimulator: some View {
    RoutingInspectorPanel(title: "Match Simulator", systemImage: "scope") {
      TextField("Destination host or IP", text: $simulationDestination)
        .textFieldStyle(.roundedBorder)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          TextField("Source IP", text: $simulationSourceIP)
          TextField("Process name or path", text: $simulationProcess)
        }
        VStack(alignment: .leading, spacing: 8) {
          TextField("Source IP", text: $simulationSourceIP)
          TextField("Process name or path", text: $simulationProcess)
        }
      }
      .textFieldStyle(.roundedBorder)

      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) {
          TextField("Dst Port", text: $simulationDestinationPort)
          TextField("Src Port", text: $simulationSourcePort)
          TextField("In Port", text: $simulationInboundPort)
        }
        VStack(alignment: .leading, spacing: 8) {
          TextField("Dst Port", text: $simulationDestinationPort)
          TextField("Src Port", text: $simulationSourcePort)
          TextField("In Port", text: $simulationInboundPort)
        }
      }
      .textFieldStyle(.roundedBorder)

      RoutingDetailRow(title: "Result", value: simulationTrace.title, isProminent: true)
      RoutingDetailRow(title: "Source", value: simulationTrace.sourceSummary)
      RoutingDetailRow(title: "Hit Rule", value: simulationTrace.ruleSummary, lineLimit: 3)
      RoutingDetailRow(title: "Policy / Sub-rule", value: simulationTrace.policySummary)
      RoutingDetailRow(title: "Provider", value: simulationTrace.providerSummary)
      RoutingDetailRow(title: "Detail", value: simulationTrace.detail, lineLimit: 4)
    }
  }

  @ViewBuilder
  private var connectionExplanation: some View {
    if let explanationContext {
      RoutingInspectorPanel(title: "Connection Context", systemImage: "point.3.connected.trianglepath.dotted") {
        RoutingDetailRow(
          title: "Mihomo Reported",
          value: explanationContext.reportedRuleSummary.isEmpty ? "-" : explanationContext.reportedRuleSummary
        )
        RoutingDetailRow(title: "Chosen Target", value: explanationContext.target.isEmpty ? "-" : explanationContext.target)
        RoutingDetailRow(title: "Chosen Policy", value: explanationContext.chosenPolicySummary)
        RoutingDetailRow(title: "Local Result", value: explanationContext.localSummary, lineLimit: 5)
      }
    }
  }

  private var canSave: Bool {
    draftSnippet.validationError == nil && draftSnippet != selectedSnippet
  }

  private var selectedSnippet: RuntimeSnippet? {
    guard let selectedSnippetID else { return nil }
    return snippetLibrary.snippets.first { $0.id == selectedSnippetID }
  }

  private var activeSubscriptionProfile: Profile? {
    guard let profile = profileStore.activeProfile, profile.isSubscription else { return nil }
    return profile
  }

  private var librarySummary: String {
    String(
      format: String(localized: "%lld snippets, %lld enabled"),
      Int64(snippetLibrary.snippets.count),
      Int64(snippetLibrary.snippets.filter(\.enabled).count)
    )
  }

  private var profileBindingEditor: some View {
    RoutingEditContentRow {
      VStack(alignment: .leading, spacing: 8) {
        if profileStore.profiles.isEmpty {
          Text("No profiles available")
            .font(.caption)
            .foregroundStyle(.tertiary)
        } else {
          ForEach(profileStore.profiles) { profile in
            Toggle(isOn: profileBinding(profile.id)) {
              Text(profile.name)
                .lineLimit(1)
            }
          }
        }
      }
    }
  }

  private var bindingMode: Binding<RuntimeSnippetBindingMode> {
    Binding(
      get: {
        switch draftSnippet.binding {
        case .allProfiles:
          return .allProfiles
        case .profiles:
          return .selectedProfiles
        }
      },
      set: { mode in
        switch mode {
        case .allProfiles:
          draftSnippet.binding = .allProfiles
        case .selectedProfiles:
          draftSnippet.binding = .profiles(profileStore.activeProfileID.map { [$0] } ?? [])
        }
      }
    )
  }

  private var payloadKind: Binding<RuntimeSnippetPayloadKind> {
    Binding(
      get: { draftSnippet.payload.kind },
      set: { kind in
        guard kind != draftSnippet.payload.kind else { return }
        switch kind {
        case .rules:
          draftSnippet.payload = .rules(RuntimeSnippet.defaultRuleSnippet.rulesPayload)
        case .dnsPatch:
          draftSnippet.payload = .dnsPatch(RuntimeSnippet.defaultDNSPatchSnippet.dnsPayload)
        }
      }
    )
  }

  private var rulesPayloadBinding: Binding<RuleOverlaySettings> {
    Binding(
      get: { draftSnippet.rulesPayload },
      set: { draftSnippet.payload = .rules($0) }
    )
  }

  private var dnsPayloadBinding: Binding<TunDNSSettings> {
    Binding(
      get: { draftSnippet.dnsPayload },
      set: { draftSnippet.payload = .dnsPatch($0) }
    )
  }

  private var draftAppliesToActiveProfile: Bool {
    guard let activeProfileID = profileStore.activeProfileID else { return false }
    return draftSnippet.enabled && draftSnippet.applies(to: activeProfileID)
  }

  private var activePreviewSnippets: [RuntimeSnippet] {
    guard let activeProfileID = profileStore.activeProfileID else { return [] }
    var snippets = snippetLibrary.snippets
    if let selectedSnippetID,
       let index = snippets.firstIndex(where: { $0.id == selectedSnippetID }) {
      snippets[index] = draftSnippet
    } else if selectedSnippet == nil {
      snippets.append(draftSnippet)
    }
    return snippets.filter { $0.enabled && $0.applies(to: activeProfileID) }
  }

  private func profileBinding(_ profileID: Profile.ID) -> Binding<Bool> {
    Binding(
      get: {
        draftSnippet.binding.profileIDs.contains(profileID)
      },
      set: { isEnabled in
        var profileIDs = draftSnippet.binding.profileIDs
        if isEnabled {
          if !profileIDs.contains(profileID) {
            profileIDs.append(profileID)
          }
        } else {
          profileIDs.removeAll { $0 == profileID }
        }
        draftSnippet.binding = .profiles(profileIDs)
      }
    )
  }

  private func newRuleSnippet() {
    selectedSnippetID = nil
    draftSnippet = RuntimeSnippet.defaultRuleSnippet
    loadedSnippetSnapshot = nil
    isEditingDetachedDraft = true
    simulate()
  }

  private func newDNSPatchSnippet() {
    selectedSnippetID = nil
    draftSnippet = RuntimeSnippet.defaultDNSPatchSnippet
    loadedSnippetSnapshot = nil
    isEditingDetachedDraft = true
    simulate()
  }

  private func saveDraft() {
    guard canSave else { return }
    let nextDraft = draftSnippet
    Task { @MainActor in
      if await appModel.saveRuntimeSnippet(nextDraft) {
        selectedSnippetID = nextDraft.id
        loadedSnippetSnapshot = nextDraft
        isEditingDetachedDraft = false
      }
    }
  }

  private func deleteSelectedSnippet() {
    guard let selectedSnippet else { return }
    Task { @MainActor in
      if await appModel.deleteRuntimeSnippet(selectedSnippet) {
        selectedSnippetID = snippetLibrary.snippets.first?.id
        loadedSnippetSnapshot = nil
        isEditingDetachedDraft = false
        reconcileDraftWithLibrary()
      }
    }
  }

  private func selectInitialSnippetIfNeeded() {
    guard !isEditingDetachedDraft else { return }
    if selectedSnippetID == nil, let first = snippetLibrary.snippets.first {
      selectedSnippetID = first.id
      draftSnippet = first
      loadedSnippetSnapshot = first
    }
  }

  private func loadSelectedSnippet() {
    guard let selectedSnippet else { return }
    draftSnippet = selectedSnippet
    loadedSnippetSnapshot = selectedSnippet
    isEditingDetachedDraft = false
    simulate()
  }

  private func reconcileDraftWithLibrary() {
    if let selectedSnippetID,
       let snippet = snippetLibrary.snippets.first(where: { $0.id == selectedSnippetID }) {
      if snippet == draftSnippet {
        loadedSnippetSnapshot = snippet
      } else if !draftHasUnsavedChanges {
        draftSnippet = snippet
        loadedSnippetSnapshot = snippet
      }
    } else if selectedSnippetID != nil, selectedSnippet == nil {
      if draftHasUnsavedChanges {
        selectedSnippetID = nil
        loadedSnippetSnapshot = nil
        isEditingDetachedDraft = true
      } else {
        selectedSnippetID = snippetLibrary.snippets.first?.id
        if let selectedSnippet {
          draftSnippet = selectedSnippet
          loadedSnippetSnapshot = selectedSnippet
        } else {
          loadedSnippetSnapshot = nil
        }
      }
    } else if isEditingDetachedDraft {
      loadedSnippetSnapshot = nil
    } else {
      selectInitialSnippetIfNeeded()
    }
    simulate()
  }

  private func simulate() {
    let simulator = RuleMatchSimulator()
    simulationTrace = simulator.simulate(input: simulationInput, candidates: effectiveRuleCandidates())
  }

  private func consumeRoutingSimulationRequest() {
    guard let request = appModel.routingSimulationRequest else { return }
    explanationContext = request.explanation
    simulationDestination = request.input.destination
    simulationSourceIP = request.input.sourceIP
    simulationDestinationPort = request.input.destinationPort
    simulationSourcePort = request.input.sourcePort
    simulationInboundPort = request.input.inboundPort
    simulationProcess = request.input.process
    simulate()
  }

  private var simulationInput: RuleMatchSimulationInput {
    RuleMatchSimulationInput(
      destination: simulationDestination,
      sourceIP: simulationSourceIP,
      destinationPort: simulationDestinationPort,
      sourcePort: simulationSourcePort,
      inboundPort: simulationInboundPort,
      process: simulationProcess
    )
  }

  private func effectiveRuleCandidates() -> [RuntimeRuleCandidate] {
    if appModel.isCoreRunning || !runtimeData.rules.isEmpty {
      return RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: runtimeData.rules)
    }
    let snippetOverlay = RuntimeSnippetApplication(snippets: activePreviewSnippets).ruleOverlay
    return RuntimeRuleCandidateBuilder.candidates(
      globalOverlay: appModel.ruleOverlaySettings,
      profileOverlay: activeSubscriptionProfile?.subscriptionProviderOptions.ruleOverlay ?? .disabled,
      snippetOverlay: snippetOverlay,
      runtimeRules: runtimeData.rules
    )
  }

  private var draftHasUnsavedChanges: Bool {
    if isEditingDetachedDraft {
      return true
    }
    guard let loadedSnippetSnapshot else {
      return selectedSnippet.map { $0 != draftSnippet } ?? false
    }
    return draftSnippet != loadedSnippetSnapshot
  }

  private func dnsPatchPreviewLines(_ settings: TunDNSSettings) -> [String] {
    var lines: [String] = []
    appendOptionalBool(settings.respectRules, title: "respect-rules", to: &lines)
    appendOptionalBool(settings.useSystemHosts, title: "use-system-hosts", to: &lines)
    appendOptionalBool(settings.useHosts, title: "use-hosts", to: &lines)
    appendOptionalBool(settings.preferH3, title: "prefer-h3", to: &lines)
    appendOptionalBool(settings.directNameserverFollowPolicy, title: "direct-nameserver-follow-policy", to: &lines)
    appendList(settings.fakeIPFilter, title: "fake-ip-filter", to: &lines)
    appendList(settings.defaultNameserver, title: "default-nameserver", to: &lines)
    appendList(settings.nameserver, title: "nameserver", to: &lines)
    appendList(settings.fallback, title: "fallback", to: &lines)
    appendList(settings.proxyServerNameserver, title: "proxy-server-nameserver", to: &lines)
    appendList(settings.directNameserver, title: "direct-nameserver", to: &lines)
    appendMap(settings.nameserverPolicy, title: "nameserver-policy", to: &lines)
    appendMap(settings.proxyServerNameserverPolicy, title: "proxy-server-nameserver-policy", to: &lines)
    appendMap(settings.hosts, title: "hosts", to: &lines)
    if let geoIP = settings.fallbackFilter.geoIP {
      lines.append("fallback-filter.geoip = \(geoIP)")
    }
    if let geoIPCode = settings.fallbackFilter.geoIPCode {
      lines.append("fallback-filter.geoip-code = \(geoIPCode)")
    }
    appendList(settings.fallbackFilter.geoSite, title: "fallback-filter.geosite", to: &lines)
    appendList(settings.fallbackFilter.ipCIDR, title: "fallback-filter.ipcidr", to: &lines)
    appendList(settings.fallbackFilter.domain, title: "fallback-filter.domain", to: &lines)
    return lines
  }

  private func appendOptionalBool(_ value: Bool?, title: String, to lines: inout [String]) {
    guard let value else { return }
    lines.append("\(title) = \(value)")
  }

  private func appendList(_ values: [String], title: String, to lines: inout [String]) {
    guard !values.isEmpty else { return }
    lines.append("\(title): \(values.joined(separator: ", "))")
  }

  private func appendMap(_ values: [String: String], title: String, to lines: inout [String]) {
    for key in values.keys.sorted() {
      lines.append("\(title).\(key) = \(values[key] ?? "")")
    }
  }
}

private enum RuntimeSnippetBindingMode: String, CaseIterable, Identifiable {
  case allProfiles
  case selectedProfiles

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .allProfiles:
      return String(localized: "All Profiles")
    case .selectedProfiles:
      return String(localized: "Selected Profiles")
    }
  }
}

private extension RuntimeSnippet {
  var rulesPayload: RuleOverlaySettings {
    if case let .rules(settings) = payload {
      return settings
    }
    return RuntimeSnippet.defaultRuleSnippet.rulesPayload
  }

  var dnsPayload: TunDNSSettings {
    if case let .dnsPatch(settings) = payload {
      return settings
    }
    return RuntimeSnippet.defaultDNSPatchSnippet.dnsPayload
  }
}

private struct RuntimeSnippetRow: View {
  let snippet: RuntimeSnippet
  let isSelected: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onSelect: () -> Void
  let onToggle: () -> Void
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    HStack(alignment: .center, spacing: 8) {
      Toggle("Enabled", isOn: Binding(get: { snippet.enabled }, set: { _ in onToggle() }))
        .labelsHidden()
        .toggleStyle(.switch)

      Button(action: onSelect) {
        VStack(alignment: .leading, spacing: 3) {
          Text(snippet.normalizedName.isEmpty ? String(localized: "Untitled Snippet") : snippet.normalizedName)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Text("\(snippet.payload.displayName) - \(snippet.binding.displayName)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Text(snippet.payload.summary)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      VStack(spacing: 2) {
        Button(action: onMoveUp) {
          Image(systemName: "chevron.up")
        }
        .disabled(!canMoveUp)
        .help("Move up")

        Button(action: onMoveDown) {
          Image(systemName: "chevron.down")
        }
        .disabled(!canMoveDown)
        .help("Move down")
      }
      .buttonStyle(.borderless)
    }
    .padding(8)
    .background(isSelected ? Color.accentColor.opacity(0.14) : RoutingSurface.secondary(for: .light).opacity(0), in: shape)
    .overlay {
      shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
    }
  }
}

private struct RoutingEditRow<Content: View>: View {
  let title: String
  let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 12) {
        Text(LocalizedStringKey(title))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 112, alignment: .leading)
        content
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(LocalizedStringKey(title))
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
        content
      }
    }
  }
}

private struct RoutingEditContentRow<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Spacer()
        .frame(width: 112)
      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct RuntimeDNSPatchEditor: View {
  @Binding var settings: TunDNSSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RoutingEditRow("DNS Booleans") {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            optionalBoolPicker("Respect", value: optionalBoolBinding(\.respectRules))
            optionalBoolPicker("System Hosts", value: optionalBoolBinding(\.useSystemHosts))
            optionalBoolPicker("Use Hosts", value: optionalBoolBinding(\.useHosts))
            optionalBoolPicker("Prefer H3", value: optionalBoolBinding(\.preferH3))
          }
          VStack(alignment: .leading, spacing: 8) {
            optionalBoolPicker("Respect", value: optionalBoolBinding(\.respectRules))
            optionalBoolPicker("System Hosts", value: optionalBoolBinding(\.useSystemHosts))
            optionalBoolPicker("Use Hosts", value: optionalBoolBinding(\.useHosts))
            optionalBoolPicker("Prefer H3", value: optionalBoolBinding(\.preferH3))
          }
        }
      }

      dnsListEditor("Fake-IP Filter", keyPath: \.fakeIPFilter)
      dnsListEditor("Default Nameserver", keyPath: \.defaultNameserver)
      dnsListEditor("Nameserver", keyPath: \.nameserver)
      dnsListEditor("Fallback", keyPath: \.fallback)
      dnsListEditor("Proxy Server Nameserver", keyPath: \.proxyServerNameserver)
      dnsListEditor("Direct Nameserver", keyPath: \.directNameserver)
      dnsMapEditor("Nameserver Policy", keyPath: \.nameserverPolicy)
      dnsMapEditor("Proxy Server Nameserver Policy", keyPath: \.proxyServerNameserverPolicy)
      dnsMapEditor("Hosts", keyPath: \.hosts)

      RoutingEditRow("Fallback Filter") {
        VStack(alignment: .leading, spacing: 8) {
          optionalBoolPicker("GeoIP", value: fallbackGeoIPBinding)
          TextField("GeoIP Code", text: fallbackGeoIPCodeBinding)
            .textFieldStyle(.roundedBorder)
          textArea("Geosite", text: fallbackListBinding(\.geoSite), minHeight: 44)
          textArea("IP CIDR", text: fallbackListBinding(\.ipCIDR), minHeight: 44)
          textArea("Domain", text: fallbackListBinding(\.domain), minHeight: 44)
        }
      }

      if let validationError = settings.validationError {
        Label(validationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
      }
    }
  }

  private func dnsListEditor(_ title: String, keyPath: WritableKeyPath<TunDNSSettings, [String]>) -> some View {
    RoutingEditRow(title) {
      textArea("One value per line", text: listBinding(keyPath), minHeight: 54)
    }
  }

  private func dnsMapEditor(_ title: String, keyPath: WritableKeyPath<TunDNSSettings, [String: String]>) -> some View {
    RoutingEditRow(title) {
      textArea("key = value", text: mapBinding(keyPath), minHeight: 54)
    }
  }

  private func optionalBoolPicker(_ title: String, value: Binding<Bool?>) -> some View {
    Picker(title, selection: Binding(
      get: { RuntimeOptionalBoolChoice(value: value.wrappedValue) },
      set: { value.wrappedValue = $0.value }
    )) {
      ForEach(RuntimeOptionalBoolChoice.allCases) { choice in
        Text(choice.displayName).tag(choice)
      }
    }
    .pickerStyle(.menu)
    .frame(maxWidth: 138)
  }

  private func textArea(_ placeholder: String, text: Binding<String>, minHeight: CGFloat) -> some View {
    TextEditor(text: text)
      .font(.system(.caption, design: .monospaced))
      .frame(minHeight: minHeight)
      .overlay(alignment: .topLeading) {
        if text.wrappedValue.isEmpty {
          Text(LocalizedStringKey(placeholder))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
            .allowsHitTesting(false)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
      }
  }

  private func optionalBoolBinding(_ keyPath: WritableKeyPath<TunDNSSettings, Bool?>) -> Binding<Bool?> {
    Binding(
      get: { settings[keyPath: keyPath] },
      set: { settings[keyPath: keyPath] = $0 }
    )
  }

  private func listBinding(_ keyPath: WritableKeyPath<TunDNSSettings, [String]>) -> Binding<String> {
    Binding(
      get: { settings[keyPath: keyPath].joined(separator: "\n") },
      set: { settings[keyPath: keyPath] = Self.normalizedLines($0) }
    )
  }

  private func mapBinding(_ keyPath: WritableKeyPath<TunDNSSettings, [String: String]>) -> Binding<String> {
    Binding(
      get: { Self.mapText(settings[keyPath: keyPath]) },
      set: { settings[keyPath: keyPath] = Self.normalizedMap($0) }
    )
  }

  private var fallbackGeoIPBinding: Binding<Bool?> {
    Binding(
      get: { settings.fallbackFilter.geoIP },
      set: { settings.fallbackFilter.geoIP = $0 }
    )
  }

  private var fallbackGeoIPCodeBinding: Binding<String> {
    Binding(
      get: { settings.fallbackFilter.geoIPCode ?? "" },
      set: { settings.fallbackFilter.geoIPCode = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    )
  }

  private func fallbackListBinding(_ keyPath: WritableKeyPath<TunDNSFallbackFilter, [String]>) -> Binding<String> {
    Binding(
      get: { settings.fallbackFilter[keyPath: keyPath].joined(separator: "\n") },
      set: { settings.fallbackFilter[keyPath: keyPath] = Self.normalizedLines($0) }
    )
  }

  private static func normalizedLines(_ text: String) -> [String] {
    text
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  private static func mapText(_ map: [String: String]) -> String {
    map.keys.sorted().map { "\($0) = \(map[$0] ?? "")" }.joined(separator: "\n")
  }

  private static func normalizedMap(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    for line in normalizedLines(text) {
      let separator = line.contains("=") ? "=" : ":"
      let parts = line.split(separator: Character(separator), maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { continue }
      let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !key.isEmpty, !value.isEmpty else { continue }
      result[key] = value
    }
    return result
  }
}

private enum RuntimeOptionalBoolChoice: String, CaseIterable, Identifiable {
  case noChange
  case enabled
  case disabled

  var id: String { rawValue }

  init(value: Bool?) {
    switch value {
    case true:
      self = .enabled
    case false:
      self = .disabled
    case nil:
      self = .noChange
    }
  }

  var value: Bool? {
    switch self {
    case .noChange:
      return nil
    case .enabled:
      return true
    case .disabled:
      return false
    }
  }

  var displayName: String {
    switch self {
    case .noChange:
      return String(localized: "No Change")
    case .enabled:
      return String(localized: "On")
    case .disabled:
      return String(localized: "Off")
    }
  }
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
