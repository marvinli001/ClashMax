import SwiftUI

private enum EffectiveConfigInspectorTab: String, CaseIterable, Identifiable {
  case layers
  case diff
  case finalYAML

  var id: String { rawValue }

  var title: String {
    switch self {
    case .layers:
      return String(localized: "Layers")
    case .diff:
      return String(localized: "Diff")
    case .finalYAML:
      return String(localized: "Final YAML")
    }
  }
}

enum RoutingWorkspaceLayoutMode {
  case singleColumn
  case twoColumn
  case threeColumn
}

enum RoutingWorkspaceLayout {
  static let twoColumnBreakpoint: CGFloat = 820
  static let threeColumnBreakpoint: CGFloat = 1_220
  static let snippetListWidth: CGFloat = 292
  static let inspectorMinWidth: CGFloat = 320
  static let inspectorMaxWidth: CGFloat = 380

  static func mode(forWidth width: CGFloat) -> RoutingWorkspaceLayoutMode {
    if width >= threeColumnBreakpoint {
      return .threeColumn
    }
    if width >= twoColumnBreakpoint {
      return .twoColumn
    }
    return .singleColumn
  }
}

@MainActor
final class RuleMatchSimulationDebouncer {
  private let delayNanoseconds: UInt64
  private var task: Task<Void, Never>?

  init(delayNanoseconds: UInt64 = 250_000_000) {
    self.delayNanoseconds = delayNanoseconds
  }

  func schedule(_ action: @escaping @MainActor () -> Void) {
    task?.cancel()
    let delayNanoseconds = delayNanoseconds
    task = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      task = nil
      action()
    }
  }

  func runImmediately(_ action: @escaping @MainActor () -> Void) {
    task?.cancel()
    task = nil
    action()
  }

  func cancel() {
    task?.cancel()
    task = nil
  }
}

struct RoutingView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(ProfileStore.self) private var profileStore
  @Environment(RuntimeSnippetLibraryStore.self) private var snippetLibrary
  @Environment(RuntimeDataStore.self) private var runtimeData
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
  @State private var domainVerdictContext: SnifferDiagnosticsSnapshot?
  @State private var effectiveConfigTab: EffectiveConfigInspectorTab = .layers
  @State private var simulationDebouncer = RuleMatchSimulationDebouncer()
  /// Toggling a snippet preflights the effective config and can reload the running core, so a switch
  /// bound straight to the store stays frozen on its old value for the whole round trip.
  @State private var pendingSnippetEnabled: [RuntimeSnippet.ID: Bool] = [:]
  @State private var snippetToggleTokens: [RuntimeSnippet.ID: Int] = [:]

  var body: some View {
    AdaptivePage(title: "Routing") {
      routingPageActions
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
    .onChange(of: profileStore.activeProfileID) { _, _ in scheduleSimulation() }
    .onChange(of: draftSnippet) { _, _ in scheduleSimulation() }
    .onChange(of: simulationDestination) { _, _ in scheduleSimulation() }
    .onChange(of: simulationSourceIP) { _, _ in scheduleSimulation() }
    .onChange(of: simulationDestinationPort) { _, _ in scheduleSimulation() }
    .onChange(of: simulationSourcePort) { _, _ in scheduleSimulation() }
    .onChange(of: simulationInboundPort) { _, _ in scheduleSimulation() }
    .onChange(of: simulationProcess) { _, _ in scheduleSimulation() }
    .onChange(of: runtimeData.rules) { _, _ in scheduleSimulation() }
    .onChange(of: appModel.routingSimulationRequest?.id) { _, _ in consumeRoutingSimulationRequest() }
    .onDisappear {
      simulationDebouncer.cancel()
    }
  }

  private var routingPageActions: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 6) {
        newRuleSnippetButton
        newDNSPatchSnippetButton
        newSnifferSnippetButton
        saveDraftButton
        deleteSelectedSnippetButton
      }
      .labelStyle(.titleAndIcon)

      HStack(spacing: 4) {
        newRuleSnippetButton
        newDNSPatchSnippetButton
        newSnifferSnippetButton
        saveDraftButton
        deleteSelectedSnippetButton
      }
      .labelStyle(.iconOnly)
    }
    .controlSize(.small)
  }

  private var newRuleSnippetButton: some View {
    Button {
      newRuleSnippet()
    } label: {
      Label("New Rule Snippet", systemImage: "plus.circle")
    }
    .help(String(localized: "New Rule Snippet"))
  }

  private var newDNSPatchSnippetButton: some View {
    Button {
      newDNSPatchSnippet()
    } label: {
      Label("New DNS Patch", systemImage: "network")
    }
    .help(String(localized: "New DNS Patch"))
  }

  private var newSnifferSnippetButton: some View {
    Button {
      newSnifferSnippet()
    } label: {
      Label("New Sniffer Patch", systemImage: "waveform.badge.magnifyingglass")
    }
    .help(String(localized: "New Sniffer Patch"))
  }

  private var saveDraftButton: some View {
    Button {
      saveDraft()
    } label: {
      Label("Save", systemImage: "checkmark.circle")
    }
    .disabled(!canSave)
    .help(String(localized: "Save"))
  }

  private var deleteSelectedSnippetButton: some View {
    Button(role: .destructive) {
      deleteSelectedSnippet()
    } label: {
      Label("Delete", systemImage: "trash")
    }
    .disabled(selectedSnippet == nil)
    .help(String(localized: "Delete"))
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

      if appModel.lastRuntimeApplyOutcome != nil {
        Divider()
        RuntimeApplyOutcomeBanner()
          .padding(.horizontal, 12)
          .padding(.vertical, 10)
      }

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
      switch RoutingWorkspaceLayout.mode(forWidth: proxy.size.width) {
      case .threeColumn:
        routingThreeColumnWorkspace(width: proxy.size.width)
      case .twoColumn:
        routingTwoColumnWorkspace
      case .singleColumn:
        routingSingleColumnWorkspace
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private func routingThreeColumnWorkspace(width: CGFloat) -> some View {
    HStack(alignment: .top, spacing: 0) {
      snippetListPane
        .frame(width: RoutingWorkspaceLayout.snippetListWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)

      Divider()

      routingEditorPane
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      Divider()

      routingInspectorPane
        .frame(width: inspectorWidth(for: width), alignment: .topLeading)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var routingTwoColumnWorkspace: some View {
    HStack(alignment: .top, spacing: 0) {
      snippetListPane
        .frame(width: RoutingWorkspaceLayout.snippetListWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)

      Divider()

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
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }

  private var routingSingleColumnWorkspace: some View {
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

  private func inspectorWidth(for width: CGFloat) -> CGFloat {
    min(
      max(width * 0.34, RoutingWorkspaceLayout.inspectorMinWidth),
      RoutingWorkspaceLayout.inspectorMaxWidth
    )
  }

  private var snippetListPane: some View {
    ScrollView {
      snippetListContent
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
  }

  private var snippetListContent: some View {
    LazyVStack(alignment: .leading, spacing: 10) {
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
            isEnabled: pendingSnippetEnabled[snippet.id] ?? snippet.enabled,
            isSelected: snippet.id == selectedSnippetID,
            canMoveUp: index > 0,
            canMoveDown: index < snippetLibrary.snippets.count - 1,
            onSelect: {
              selectedSnippetID = snippet.id
            },
            onToggle: { enabled in
              setSnippetEnabled(snippet, enabled: enabled)
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

  /// Shows the requested value immediately and falls back to the store once the write settles, so a
  /// rejected preflight snaps the switch back instead of leaving it lying about the runtime. The
  /// token makes a rapid second click win: a stale round trip no longer clears the newer intent.
  private func setSnippetEnabled(_ snippet: RuntimeSnippet, enabled: Bool) {
    pendingSnippetEnabled[snippet.id] = enabled
    let token = (snippetToggleTokens[snippet.id] ?? 0) &+ 1
    snippetToggleTokens[snippet.id] = token
    Task { @MainActor in
      _ = await appModel.setRuntimeSnippet(snippet, enabled: enabled)
      guard snippetToggleTokens[snippet.id] == token else { return }
      pendingSnippetEnabled[snippet.id] = nil
      snippetToggleTokens[snippet.id] = nil
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
        // The snippet's own "Enabled" row above is the only switch — a second overlay-level toggle
        // just gives the same snippet two ways to be off.
        RuleOverlaySettingsEditor(settings: rulesPayloadBinding, showsHeader: false, showsEnableToggle: false)
      case .dnsPatch:
        RuntimeDNSPatchEditor(settings: dnsPayloadBinding)
      case .sniffer:
        RuntimeSnifferPatchEditor(settings: snifferPayloadBinding)
      }

      if let validationError = draftSnippet.validationError {
        Label(validationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
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
      effectiveConfigPreview
      dnsOverrideStatus
      runtimeDiffPreview
      connectionExplanation
      matchSimulator
    }
  }

  /// Answers "is my DNS override on, what does it change, and does anything reach it?" — the three
  /// questions issue #16 says the rule and DNS surfaces never connected.
  private var dnsOverrideStatus: some View {
    RoutingInspectorPanel(title: "DNS Override", systemImage: "shield.lefthalf.filled") {
      if let snapshot = loadedEffectiveConfigSnapshot {
        dnsOverrideContent(snapshot.dnsOverride)
      } else {
        RoutingWorkspaceNotice(
          title: "Not Generated",
          systemImage: "doc.badge.clock",
          message: String(localized: "Refresh the effective config to see which DNS keys Mihomo really reads.")
        )
      }
    }
  }

  @ViewBuilder
  private func dnsOverrideContent(_ plan: DNSOverridePlan) -> some View {
    RoutingDetailRow(title: "Status", value: plan.enablement.displayName, isProminent: true)
    RoutingDetailRow(title: "Effect", value: plan.summary, lineLimit: 3)

    if plan.hasOverride {
      diffSection(title: "Overridden Keys", values: plan.overriddenFieldNames)
    }
    if !plan.contributors.isEmpty {
      diffSection(title: "Contributors", values: plan.contributors)
    }

    ForEach(plan.issues) { issue in
      Label(
        issue.message,
        systemImage: issue.isBlocking ? "exclamationmark.octagon.fill" : "info.circle"
      )
      .font(.caption)
      .foregroundStyle(issue.isBlocking ? Color.red : Color.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }

    ForEach(dnsOverrideRelationshipHints, id: \.self) { hint in
      Text(hint)
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  /// How the override interacts with the capture modes: without TUN or the NE proxy, only traffic
  /// that already goes through Mihomo ever asks Mihomo's resolver.
  private var dnsOverrideRelationshipHints: [String] {
    var hints: [String] = []
    if appModel.tunEnabled {
      hints.append(String(localized: "TUN is on, so its DNS hijack sends system queries to Mihomo's resolver."))
    } else if appModel.networkExtensionEnabled {
      hints.append(String(localized: "NE Proxy is on, so captured queries use Mihomo's resolver."))
    } else if appModel.systemProxyEnabled {
      hints.append(String(localized: "Only system proxy is on: proxied requests resolve inside Mihomo, while macOS keeps resolving everything else."))
    } else {
      hints.append(String(localized: "No traffic capture is active, so nothing reaches Mihomo's resolver yet."))
    }
    hints.append(
      appModel.isRunning
        ? String(localized: "Saving reloads the running config, so DNS changes apply immediately.")
        : String(localized: "DNS changes apply the next time the core starts.")
    )
    return hints
  }

  private var loadedEffectiveConfigSnapshot: EffectiveRuntimeConfigSnapshot? {
    guard case let .loaded(snapshot) = appModel.effectiveRuntimeConfigState,
          snapshot.profileID == profileStore.activeProfile?.id
    else { return nil }
    return snapshot
  }

  private var snippetStatus: some View {
    RoutingInspectorPanel(title: "Active Profile", systemImage: "doc.text.magnifyingglass") {
      let facts = activeProfileFacts
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .top, spacing: 10) {
          ForEach(facts) { fact in
            RoutingCompactDetailItem(fact: fact)
          }
        }

        LazyVGrid(
          columns: [
            GridItem(.flexible(minimum: 96), spacing: 10, alignment: .leading),
            GridItem(.flexible(minimum: 96), spacing: 10, alignment: .leading),
          ],
          alignment: .leading,
          spacing: 8
        ) {
          ForEach(facts) { fact in
            RoutingCompactDetailItem(fact: fact)
          }
        }
      }
    }
  }

  private var activeProfileFacts: [RoutingCompactFact] {
    [
      RoutingCompactFact(title: "Profile", value: profileStore.activeProfile?.name ?? String(localized: "No Profile")),
      RoutingCompactFact(title: "Snippet Binding", value: draftSnippet.binding.displayName),
      RoutingCompactFact(title: "Applies Here", value: draftAppliesToActiveProfile ? String(localized: "Yes") : String(localized: "No")),
      RoutingCompactFact(title: "Active Snippets", value: "\(activePreviewSnippets.count)"),
    ]
  }

  private var runtimeDiffPreview: some View {
    RoutingInspectorPanel(title: "Runtime Diff", systemImage: "doc.on.doc") {
      switch draftSnippet.payload {
      case let .rules(settings):
        runtimeRuleDiffSections(settings)
      case let .dnsPatch(settings):
        dnsDiffSection(settings)
      case let .sniffer(settings):
        snifferDiffSection(settings)
      }
    }
  }

  private var effectiveConfigPreview: some View {
    RoutingInspectorPanel(title: "Effective Config", systemImage: "doc.text.magnifyingglass") {
      effectiveConfigToolbar
      effectiveConfigStateContent
    }
  }

  private var effectiveConfigToolbar: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 8) {
        effectiveConfigViewPicker
          .frame(width: 256)
        Spacer(minLength: 12)
        HStack(spacing: 6) {
          effectiveConfigActions
        }
        .labelStyle(.titleAndIcon)
      }

      HStack(spacing: 8) {
        effectiveConfigViewPicker
          .frame(width: 240)
        Spacer(minLength: 8)
        HStack(spacing: 4) {
          effectiveConfigActions
        }
        .labelStyle(.iconOnly)
      }

      VStack(alignment: .leading, spacing: 8) {
        effectiveConfigViewPicker
        HStack(spacing: 6) {
          effectiveConfigActions
        }
        .labelStyle(.titleAndIcon)
      }
    }
    .controlSize(.small)
  }

  private var effectiveConfigViewPicker: some View {
    Picker("Effective Config View", selection: $effectiveConfigTab) {
      ForEach(EffectiveConfigInspectorTab.allCases) { tab in
        Text(tab.title).tag(tab)
      }
    }
    .labelsHidden()
    .pickerStyle(.segmented)
  }

  private var effectiveConfigActions: some View {
    Group {
      Button {
        refreshEffectiveConfigPreview()
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
      .help(String(localized: "Refresh"))

      Button {
        appModel.copyEffectiveRuntimeConfigRedacted()
      } label: {
        Label("Copy Redacted", systemImage: "doc.on.doc")
      }
      .disabled(!effectiveConfigIsLoaded)
      .help(String(localized: "Copy Redacted"))

      Button {
        appModel.exportEffectiveRuntimeConfigRedacted()
      } label: {
        Label("Export Redacted", systemImage: "square.and.arrow.down")
      }
      .disabled(!effectiveConfigIsLoaded)
      .help(String(localized: "Export Redacted"))
    }
  }

  @ViewBuilder
  private var effectiveConfigStateContent: some View {
    switch appModel.effectiveRuntimeConfigState {
    case .idle:
      RoutingWorkspaceNotice(
        title: "Not Generated",
        systemImage: "doc.badge.clock",
        message: "Refresh to preview the redacted final runtime YAML and its diff."
      )
    case .loading:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Generating effective config")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case let .unavailable(message):
      RoutingWorkspaceNotice(title: "Unavailable", systemImage: "exclamationmark.triangle.fill", message: message)
    case let .failed(message):
      RoutingWorkspaceNotice(title: "Generation Failed", systemImage: "exclamationmark.triangle.fill", message: message)
    case let .loaded(snapshot) where snapshot.profileID == profileStore.activeProfile?.id:
      effectiveConfigSnapshotContent(snapshot)
    case .loaded:
      RoutingWorkspaceNotice(
        title: "Not Generated",
        systemImage: "doc.badge.clock",
        message: "Refresh to preview the redacted final runtime YAML and its diff."
      )
    }
  }

  @ViewBuilder
  private func effectiveConfigSnapshotContent(_ snapshot: EffectiveRuntimeConfigSnapshot) -> some View {
    RoutingDetailRow(title: "Preflight", value: effectiveConfigPreflightSummary(snapshot), isProminent: true, lineLimit: 3)
    switch effectiveConfigTab {
    case .layers:
      VStack(alignment: .leading, spacing: 10) {
        ForEach(snapshot.layers) { layer in
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Image(systemName: layer.isActive ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(layer.isActive ? .green : .secondary)
              Text(layer.title)
                .font(.caption.weight(.semibold))
              Spacer()
            }
            Text(layer.summary)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            redactedCodeBlock(layer.redactedContent, maxHeight: 150)
          }
        }
      }
    case .diff:
      diffRows(snapshot.diffRows)
    case .finalYAML:
      redactedCodeBlock(snapshot.redactedFinalYAML, maxHeight: 280)
    }
  }

  private func diffRows(_ rows: [EffectiveRuntimeConfigDiffRow]) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        ForEach(rows) { row in
          Text(row.displayLine)
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(diffColor(row.kind))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: 280)
  }

  private func redactedCodeBlock(_ text: String, maxHeight: CGFloat) -> some View {
    ScrollView {
      Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Empty") : text)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: maxHeight)
  }

  private func diffColor(_ kind: EffectiveRuntimeConfigDiffKind) -> Color {
    switch kind {
    case .unchanged:
      return .secondary
    case .removed:
      return .red
    case .added:
      return .green
    case .omitted:
      return .secondary
    }
  }

  private func effectiveConfigPreflightSummary(_ snapshot: EffectiveRuntimeConfigSnapshot) -> String {
    if let message = snapshot.preflightStatus.message {
      return "\(snapshot.preflightStatus.displayName): \(message)"
    }
    return snapshot.preflightStatus.displayName
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

  private func diffSection(title: LocalizedStringResource, values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
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

  private func snifferDiffSection(_ settings: SnifferSettings) -> some View {
    diffSection(title: "Sniffer Patch", values: snifferPatchPreviewLines(settings))
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
        // The simulator above answers "which rule wins for this destination". For a connection that
        // never carried a domain, the destination in that field is an address, and no domain rule
        // could ever have matched it — a fact the simulator alone leaves the user to infer.
        if let verdict = domainVerdictContext {
          RoutingDetailRow(title: "Domain Visibility", value: verdict.headline, isProminent: true)
          RoutingDetailRow(title: "Reason", value: verdict.reason, lineLimit: 5)
          ForEach(verdict.recoveryActions, id: \.self) { action in
            RoutingDetailRow(title: "Suggested Fix", value: action, lineLimit: 3)
          }
        }
      }
    }
  }

  private var canSave: Bool {
    draftSnippet.validationError == nil && draftSnippet != selectedSnippet
  }

  private var effectiveConfigIsLoaded: Bool {
    appModel.hasLoadedEffectiveRuntimeConfigForActiveProfile
  }

  private var effectiveConfigDraftSnippet: RuntimeSnippet? {
    draftHasUnsavedChanges || isEditingDetachedDraft ? draftSnippet : nil
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
        case .sniffer:
          draftSnippet.payload = .sniffer(RuntimeSnippet.defaultSnifferSnippet.snifferPayload)
        }
      }
    )
  }

  private var rulesPayloadBinding: Binding<RuleOverlaySettings> {
    Binding(
      get: { draftSnippet.rulesPayload },
      set: { settings in
        var settings = settings
        settings.enabled = true
        draftSnippet.payload = .rules(settings)
      }
    )
  }

  private var dnsPayloadBinding: Binding<TunDNSSettings> {
    Binding(
      get: { draftSnippet.dnsPayload },
      set: { draftSnippet.payload = .dnsPatch($0) }
    )
  }

  private var snifferPayloadBinding: Binding<SnifferSettings> {
    Binding(
      get: { draftSnippet.snifferPayload },
      set: { draftSnippet.payload = .sniffer($0) }
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
       let index = snippets.firstIndex(where: { $0.id == selectedSnippetID })
    {
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
    runSimulationImmediately()
  }

  private func newDNSPatchSnippet() {
    selectedSnippetID = nil
    draftSnippet = RuntimeSnippet.defaultDNSPatchSnippet
    loadedSnippetSnapshot = nil
    isEditingDetachedDraft = true
    runSimulationImmediately()
  }

  private func newSnifferSnippet() {
    selectedSnippetID = nil
    draftSnippet = RuntimeSnippet.defaultSnifferSnippet
    loadedSnippetSnapshot = nil
    isEditingDetachedDraft = true
    runSimulationImmediately()
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

  private func refreshEffectiveConfigPreview() {
    let draft = effectiveConfigDraftSnippet
    Task { @MainActor in
      await appModel.refreshEffectiveRuntimeConfigPreview(draftSnippet: draft)
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
    runSimulationImmediately()
  }

  private func reconcileDraftWithLibrary() {
    if let selectedSnippetID,
       let snippet = snippetLibrary.snippets.first(where: { $0.id == selectedSnippetID })
    {
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
    runSimulationImmediately()
  }

  private func scheduleSimulation() {
    simulationDebouncer.schedule {
      simulate()
    }
  }

  private func runSimulationImmediately() {
    simulationDebouncer.runImmediately {
      simulate()
    }
  }

  private func simulate() {
    let simulator = RuleMatchSimulator()
    simulationTrace = simulator.simulate(input: simulationInput, candidateProvider: effectiveRuleCandidates)
  }

  private func consumeRoutingSimulationRequest() {
    guard let request = appModel.routingSimulationRequest else { return }
    explanationContext = request.explanation
    domainVerdictContext = request.domainVerdict
    simulationDestination = request.input.destination
    simulationSourceIP = request.input.sourceIP
    simulationDestinationPort = request.input.destinationPort
    simulationSourcePort = request.input.sourcePort
    simulationInboundPort = request.input.inboundPort
    simulationProcess = request.input.process
    runSimulationImmediately()
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

  private func snifferPatchPreviewLines(_ settings: SnifferSettings) -> [String] {
    var lines: [String] = []
    appendOptionalBool(settings.enabled, title: "enable", to: &lines)
    appendOptionalBool(settings.overrideDestination, title: "override-destination", to: &lines)
    appendOptionalBool(settings.forceDNSMapping, title: "force-dns-mapping", to: &lines)
    appendOptionalBool(settings.parsePureIP, title: "parse-pure-ip", to: &lines)
    for entry in settings.protocols {
      lines.append("sniff.\(entry.networkProtocol.rawValue): \(entry.summary)")
    }
    appendList(settings.forceDomain, title: "force-domain", to: &lines)
    appendList(settings.skipDomain, title: "skip-domain", to: &lines)
    appendList(settings.skipSourceAddress, title: "skip-src-address", to: &lines)
    appendList(settings.skipDestinationAddress, title: "skip-dst-address", to: &lines)
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

  var snifferPayload: SnifferSettings {
    if case let .sniffer(settings) = payload {
      return settings
    }
    return .appManagedDefault
  }
}

private struct RuntimeSnippetRow: View {
  let snippet: RuntimeSnippet
  /// Not `snippet.enabled`: the owner shows the requested value while the write is in flight.
  let isEnabled: Bool
  let isSelected: Bool
  let canMoveUp: Bool
  let canMoveDown: Bool
  let onSelect: () -> Void
  let onToggle: (Bool) -> Void
  let onMoveUp: () -> Void
  let onMoveDown: () -> Void

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    HStack(alignment: .center, spacing: 8) {
      Toggle("Enabled", isOn: Binding(get: { isEnabled }, set: { onToggle($0) }))
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
    .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear, in: shape)
    .overlay {
      shape.strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
    }
  }
}

private struct RoutingEditRow<Content: View>: View {
  let title: LocalizedStringResource
  let content: Content

  init(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(alignment: .center, spacing: 12) {
        Text(title)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .frame(width: 112, alignment: .leading)
        content
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(title)
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
          .foregroundStyle(.orange)
          .lineLimit(3)
      }

      // Advisory, not blocking: another layer (the profile or TUN) may still supply the resolver, so
      // only the merged runtime config can decide. See DNSOverridePlanBuilder (issue #16).
      if let compatibilityWarning = settings.compatibilityWarning {
        Label(compatibilityWarning, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
      }
    }
  }

  private func dnsListEditor(_ title: LocalizedStringResource, keyPath: WritableKeyPath<TunDNSSettings, [String]>) -> some View {
    RoutingEditRow(title) {
      textArea("One value per line", text: listBinding(keyPath), minHeight: 54)
    }
  }

  private func dnsMapEditor(_ title: LocalizedStringResource, keyPath: WritableKeyPath<TunDNSSettings, [String: String]>) -> some View {
    RoutingEditRow(title) {
      textArea("key = value", text: mapBinding(keyPath), minHeight: 54)
    }
  }

  private func optionalBoolPicker(_ title: String, value: Binding<Bool?>) -> some View {
    RoutingOptionalBoolPicker(title: title, value: value)
  }

  private func textArea(_ placeholder: String, text: Binding<String>, minHeight: CGFloat) -> some View {
    RoutingSnippetTextArea(placeholder: placeholder, text: text, minHeight: minHeight)
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

private struct RoutingOptionalBoolPicker: View {
  let title: String
  @Binding var value: Bool?
  var maxWidth: CGFloat = 138

  var body: some View {
    Picker(title, selection: Binding(
      get: { RuntimeOptionalBoolChoice(value: value) },
      set: { value = $0.value }
    )) {
      ForEach(RuntimeOptionalBoolChoice.allCases) { choice in
        Text(choice.displayName).tag(choice)
      }
    }
    .pickerStyle(.menu)
    .frame(maxWidth: maxWidth)
  }
}

private struct RoutingSnippetTextArea: View {
  let placeholder: String
  @Binding var text: String
  var minHeight: CGFloat

  var body: some View {
    TextEditor(text: $text)
      .font(.system(.caption, design: .monospaced))
      .frame(minHeight: minHeight)
      .overlay(alignment: .topLeading) {
        if text.isEmpty {
          Text(LocalizedStringKey(placeholder))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
            .allowsHitTesting(false)
        }
      }
      .overlay {
        SurfaceRadius.shape(SurfaceRadius.chip)
          .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
      }
  }
}

/// Sniffing is what turns a domainless connection back into a `DOMAIN-SUFFIX`-matchable one, so the
/// editor names the consequence of each switch rather than the YAML key (roadmap A1).
private struct RuntimeSnifferPatchEditor: View {
  @Binding var settings: SnifferSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RoutingEditRow("Sniffing") {
        RoutingOptionalBoolPicker(title: String(localized: "Sniffing"), value: $settings.enabled)
      }

      RoutingEditRow("Rewrite Target") {
        VStack(alignment: .leading, spacing: 4) {
          RoutingOptionalBoolPicker(
            title: String(localized: "Rewrite Target"),
            value: $settings.overrideDestination
          )
          Text("Replaces the connection's IP destination with the sniffed domain, so rules, logs and the Connections list all show the real host.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      RoutingEditRow("Advanced") {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            RoutingOptionalBoolPicker(title: String(localized: "DNS Mapping"), value: $settings.forceDNSMapping)
            RoutingOptionalBoolPicker(title: String(localized: "Parse Pure IP"), value: $settings.parsePureIP)
          }
          VStack(alignment: .leading, spacing: 8) {
            RoutingOptionalBoolPicker(title: String(localized: "DNS Mapping"), value: $settings.forceDNSMapping)
            RoutingOptionalBoolPicker(title: String(localized: "Parse Pure IP"), value: $settings.parsePureIP)
          }
        }
      }

      ForEach(SnifferProtocol.allCases) { networkProtocol in
        protocolEditor(networkProtocol)
      }

      snifferListEditor("Always Sniff", keyPath: \.forceDomain, placeholder: "One domain per line")
      snifferListEditor("Never Sniff", keyPath: \.skipDomain, placeholder: "One domain per line")
      snifferListEditor("Skip Sources", keyPath: \.skipSourceAddress, placeholder: "One IP or CIDR per line")
      snifferListEditor("Skip Destinations", keyPath: \.skipDestinationAddress, placeholder: "One IP or CIDR per line")

      if let validationError = settings.validationError {
        Label(validationError, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
      }

      // The core accepts an empty `sniff` map without complaint and then sniffs nothing, so this
      // stays advisory here — a patch is allowed to be sparse — and only the merged config decides.
      if settings.validationError == nil, let effectiveError = settings.effectiveValidationError {
        Label(effectiveError, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(3)
      }
    }
  }

  private func protocolEditor(_ networkProtocol: SnifferProtocol) -> some View {
    RoutingEditRow(LocalizedStringResource(stringLiteral: networkProtocol.displayName)) {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Toggle("Sniff", isOn: protocolEnabledBinding(networkProtocol))
            .toggleStyle(.switch)
            .labelsHidden()
          TextField("Ports", text: portsBinding(networkProtocol))
            .textFieldStyle(.roundedBorder)
            .disabled(settings.settings(for: networkProtocol) == nil)
        }
        Text(networkProtocol.explanation)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        // Leaving the field empty is legal, but it is not "all ports" — the core falls back to one
        // port per protocol, so the row says which one rather than letting it look unlimited.
        if let entry = settings.settings(for: networkProtocol), entry.ports.isEmpty {
          Text(
            String(
              format: String(localized: "Empty means the core's own default: %@."),
              entry.effectivePorts.joined(separator: ", ")
            )
          )
          .font(.caption2)
          .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func snifferListEditor(
    _ title: LocalizedStringResource,
    keyPath: WritableKeyPath<SnifferSettings, [String]>,
    placeholder: String
  ) -> some View {
    RoutingEditRow(title) {
      RoutingSnippetTextArea(placeholder: placeholder, text: listBinding(keyPath), minHeight: 54)
    }
  }

  /// Listing a protocol at all is what enables it; unchecking removes the entry rather than writing
  /// an empty one, because the core treats an empty `sniff` map as "sniff nothing" without erroring.
  private func protocolEnabledBinding(_ networkProtocol: SnifferProtocol) -> Binding<Bool> {
    Binding(
      get: { settings.settings(for: networkProtocol) != nil },
      set: { isEnabled in
        var protocols = settings.protocols.filter { $0.networkProtocol != networkProtocol }
        if isEnabled {
          protocols.append(
            SnifferProtocolSettings(
              networkProtocol: networkProtocol,
              ports: networkProtocol.defaultPorts
            )
          )
          protocols.sort { lhs, rhs in
            let order = SnifferProtocol.allCases
            return (order.firstIndex(of: lhs.networkProtocol) ?? 0) < (order.firstIndex(of: rhs.networkProtocol) ?? 0)
          }
        }
        settings.protocols = protocols
      }
    )
  }

  private func portsBinding(_ networkProtocol: SnifferProtocol) -> Binding<String> {
    Binding(
      get: { settings.settings(for: networkProtocol)?.ports.joined(separator: ", ") ?? "" },
      set: { text in
        guard let index = settings.protocols.firstIndex(where: { $0.networkProtocol == networkProtocol }) else {
          return
        }
        settings.protocols[index].ports = text
          .components(separatedBy: CharacterSet(charactersIn: ",\n"))
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }
      }
    )
  }

  private func listBinding(_ keyPath: WritableKeyPath<SnifferSettings, [String]>) -> Binding<String> {
    Binding(
      get: { settings[keyPath: keyPath].joined(separator: "\n") },
      set: { text in
        settings[keyPath: keyPath] = text
          .components(separatedBy: .newlines)
          .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
          .filter { !$0.isEmpty }
      }
    )
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
    .background(.cardSurface, in: shape)
    .clipShape(shape)
    .overlay(shape.strokeBorder(.separator, lineWidth: 1))
  }
}

private struct RoutingWorkspaceNotice: View {
  let title: LocalizedStringResource
  let systemImage: String
  let message: String

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.orange)
        .frame(width: 18)

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
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
  let title: LocalizedStringResource
  let systemImage: String
  let content: Content

  init(title: LocalizedStringResource, systemImage: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.systemImage = systemImage
    self.content = content()
  }

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    VStack(alignment: .leading, spacing: 10) {
      Label {
        Text(title)
      } icon: {
        Image(systemName: systemImage)
      }
      .font(.headline)
      .lineLimit(1)

      content
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(.insetSurface, in: shape)
    .overlay(shape.strokeBorder(.separator.opacity(0.82), lineWidth: 1))
  }
}

private struct RoutingCompactFact: Identifiable {
  let id: String
  let title: LocalizedStringResource
  let value: String

  init(title: LocalizedStringResource, value: String) {
    id = String(localized: title)
    self.title = title
    self.value = value
  }
}

private struct RoutingCompactDetailItem: View {
  let fact: RoutingCompactFact

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(fact.title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
        .truncationMode(.tail)

      Text(fact.value)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .frame(minWidth: 58, maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }
}

private struct RoutingDetailRow: View {
  let title: LocalizedStringResource
  let value: String
  var isProminent = false
  var lineLimit = 2

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
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
