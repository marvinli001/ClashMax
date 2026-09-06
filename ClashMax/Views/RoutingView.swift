import SwiftUI

enum EffectiveConfigInspectorTab: String, CaseIterable, Identifiable {
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

/// The on-demand tools of the Routing page. Exactly one is open at a time, or none.
enum RoutingTool: String, CaseIterable, Identifiable {
  case effectiveConfig
  case diagnostics
  case simulator

  var id: String { rawValue }

  var title: String {
    switch self {
    case .effectiveConfig:
      return String(localized: "Effective Config")
    case .diagnostics:
      return String(localized: "Diagnostics")
    case .simulator:
      return String(localized: "Match Simulator")
    }
  }

  var systemImage: String {
    switch self {
    case .effectiveConfig:
      return "doc.text.magnifyingglass"
    case .diagnostics:
      return "stethoscope"
    case .simulator:
      return "scope"
    }
  }
}

/// The diagnostics the Routing page can show, one at a time, in a compact selection list.
enum RoutingDiagnostic: String, CaseIterable, Identifiable {
  case dnsOverride
  case dnsResolution
  case fakeIP
  case listeners
  case geoDatabases

  var id: String { rawValue }

  var title: String {
    switch self {
    case .dnsOverride:
      return String(localized: "DNS Override")
    case .dnsResolution:
      return String(localized: "DNS Resolution")
    case .fakeIP:
      return String(localized: "Fake IP")
    case .listeners:
      return String(localized: "Inbound Listeners")
    case .geoDatabases:
      return String(localized: "Geo Databases")
    }
  }

  var systemImage: String {
    switch self {
    case .dnsOverride:
      return "shield.lefthalf.filled"
    case .dnsResolution:
      return "magnifyingglass.circle"
    case .fakeIP:
      return "arrow.triangle.2.circlepath"
    case .listeners:
      return "antenna.radiowaves.left.and.right"
    case .geoDatabases:
      return "globe.badge.chevron.backward"
    }
  }
}

enum RoutingWorkspaceLayout {
  static let snippetListWidth: CGFloat = 248
  static let toolPaneWidth: CGFloat = 344
  /// Below this page width a tool opens as a sheet instead of a third column, so the editor never
  /// shares the row with something it cannot fit beside. The editor and the snippet list are never
  /// stacked: the window's minimum width always leaves room for both.
  static let toolPaneBreakpoint: CGFloat = 1_120

  static func showsToolPane(pageWidth: CGFloat) -> Bool {
    pageWidth.isFinite && pageWidth >= toolPaneBreakpoint
  }
}

/// Everything about the Routing editor a user would be upset to lose by switching pages: the
/// selection, the draft being edited, which tool is open and what the simulator was asked.
///
/// Owned by `AppModel` (like the proxy search coordinators) because `RoutingView` is recreated on
/// every page switch, and an unsaved draft parked in view `@State` used to vanish with it.
@MainActor
@Observable
final class RoutingEditorState {
  var selectedSnippetID: RuntimeSnippet.ID?
  var draftSnippet = RuntimeSnippet.defaultRuleSnippet
  var loadedSnippetSnapshot: RuntimeSnippet?
  var isEditingDetachedDraft = false
  var activeTool: RoutingTool?
  var selectedDiagnostic: RoutingDiagnostic = .dnsOverride
  var effectiveConfigTab: EffectiveConfigInspectorTab = .layers
  var simulationInput = RuleMatchSimulationInput()
  var explanationContext: RuleExplanation?
  var domainVerdictContext: SnifferDiagnosticsSnapshot?

  var draftHasUnsavedChanges: Bool {
    if isEditingDetachedDraft {
      return true
    }
    guard let loadedSnippetSnapshot else { return false }
    return draftSnippet != loadedSnippetSnapshot
  }

  func beginDetachedDraft(_ snippet: RuntimeSnippet) {
    selectedSnippetID = nil
    draftSnippet = snippet
    loadedSnippetSnapshot = nil
    isEditingDetachedDraft = true
  }

  func load(_ snippet: RuntimeSnippet) {
    selectedSnippetID = snippet.id
    draftSnippet = snippet
    loadedSnippetSnapshot = snippet
    isEditingDetachedDraft = false
  }

  func clearSelection() {
    selectedSnippetID = nil
    loadedSnippetSnapshot = nil
    isEditingDetachedDraft = false
  }

  func openTool(_ tool: RoutingTool) {
    activeTool = tool
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

/// What the Routing page does when the user tries to leave a draft with unsaved changes.
private enum RoutingPendingAction: Equatable {
  case select(RuntimeSnippet.ID?)
  case newSnippet(RuntimeSnippetPayloadKind)
}

struct RoutingView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(ProfileStore.self) private var profileStore
  @Environment(RuntimeSnippetLibraryStore.self) private var snippetLibrary
  @Environment(RuntimeDataStore.self) private var runtimeData
  @State private var simulationTrace: RuleMatchSimulationTrace = .noMatch
  @State private var simulationDebouncer = RuleMatchSimulationDebouncer()
  /// Toggling a snippet preflights the effective config and can reload the running core, so a switch
  /// bound straight to the store stays frozen on its old value for the whole round trip.
  @State private var pendingSnippetEnabled: [RuntimeSnippet.ID: Bool] = [:]
  @State private var snippetToggleTokens: [RuntimeSnippet.ID: Int] = [:]
  @State private var pendingAction: RoutingPendingAction?
  @State private var snippetPendingDeletion: RuntimeSnippet?
  @State private var pageWidth: CGFloat = 0
  @State private var attemptedSave = false

  private var editor: RoutingEditorState { appModel.routingEditor }

  var body: some View {
    @Bindable var editor = editor
    let showsToolPane = RoutingWorkspaceLayout.showsToolPane(pageWidth: pageWidth)

    AdaptivePage(title: "Routing") {
      newSnippetMenu
      saveButton
      moreMenu(showsToolPane: showsToolPane)
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        if let loadError = snippetLibrary.loadError {
          RoutingWorkspaceNotice(
            title: "Snippet Library Unavailable",
            systemImage: "exclamationmark.triangle.fill",
            message: loadError
          )
        }

        if snippetLibrary.snippets.isEmpty, !editor.isEditingDetachedDraft {
          emptyLibraryState
        } else {
          workspace(showsToolPane: showsToolPane)
        }

        if appModel.lastRuntimeApplyOutcome != nil {
          RuntimeApplyOutcomeBanner()
        }

        if let error = appModel.lastError,
           PageErrorPresentation.showsInlineError(readinessIssue: appModel.readinessIssue, hasDetails: false)
        {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(3)
            .textSelection(.enabled)
        }
      }
      .onGeometryChange(for: CGFloat.self) { proxy in
        proxy.size.width
      } action: { width in
        pageWidth = width
      }
    }
    .sheet(isPresented: toolSheetPresented(showsToolPane: showsToolPane)) {
      RoutingToolSheet(simulationTrace: simulationTrace) {
        editor.activeTool = nil
      }
      .environment(appModel)
      .environment(profileStore)
      .environment(runtimeData)
    }
    .confirmationDialog(
      "Unsaved changes",
      isPresented: unsavedChangesDialogPresented,
      titleVisibility: .visible
    ) {
      if canSave {
        Button("Save Changes") {
          saveDraft(then: pendingAction)
        }
      }
      Button("Discard Changes", role: .destructive) {
        discardDraft(then: pendingAction)
      }
      Button("Cancel", role: .cancel) {
        pendingAction = nil
      }
    } message: {
      Text("The current snippet has changes that have not been saved.")
    }
    .alert("Delete Snippet?", isPresented: deleteConfirmationPresented) {
      Button("Delete", role: .destructive) {
        confirmDeleteSnippet()
      }
      Button("Cancel", role: .cancel) {
        snippetPendingDeletion = nil
      }
    } message: {
      Text("Remove \(snippetPendingDeletion?.normalizedName ?? "this snippet") from the snippet library. Saving the library reloads the running core when the snippet applied to it.")
    }
    .task {
      await snippetLibrary.waitForLoad()
      selectInitialSnippetIfNeeded()
      consumeRoutingSimulationRequest()
      runSimulationImmediately()
    }
    .onChange(of: snippetLibrary.snippets) { _, _ in reconcileDraftWithLibrary() }
    .onChange(of: profileStore.activeProfileID) { _, _ in scheduleSimulation() }
    .onChange(of: editor.draftSnippet) { _, _ in scheduleSimulation() }
    .onChange(of: editor.simulationInput) { _, _ in scheduleSimulation() }
    .onChange(of: runtimeData.rules) { _, _ in scheduleSimulation() }
    .onChange(of: appModel.routingSimulationRequest?.id) { _, _ in consumeRoutingSimulationRequest() }
    .onDisappear {
      simulationDebouncer.cancel()
    }
  }

  // MARK: - Page actions

  private var newSnippetMenu: some View {
    Menu {
      ForEach(RuntimeSnippetPayloadKind.allCases) { kind in
        Button {
          requestNewSnippet(kind)
        } label: {
          Label(newSnippetTitle(kind), systemImage: newSnippetSymbol(kind))
        }
      }
    } label: {
      Label("New Snippet", systemImage: "plus")
    }
    .help("Create a rule, DNS, sniffer, or raw YAML snippet")
  }

  /// Prominent only while there is something valid to save, so the eye is drawn to it exactly when
  /// it matters.
  @ViewBuilder
  private var saveButton: some View {
    if canSave {
      Button {
        saveDraft(then: nil)
      } label: {
        Label("Save", systemImage: "checkmark.circle")
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut("s", modifiers: [.command])
      .help("Save the snippet and apply it to the runtime")
    } else {
      Button {} label: {
        Label("Save", systemImage: "checkmark.circle")
      }
      .disabled(true)
      .help(saveHelp)
    }
  }

  private var saveHelp: String {
    if !hasEditableDraft {
      return String(localized: "Select or create a snippet to edit")
    }
    if let error = editor.draftSnippet.validationError {
      return error
    }
    return String(localized: "No unsaved changes")
  }

  private func moreMenu(showsToolPane _: Bool) -> some View {
    Menu {
      ForEach(RoutingTool.allCases) { tool in
        Toggle(isOn: toolBinding(tool)) {
          Label(tool.title, systemImage: tool.systemImage)
        }
      }

      Divider()

      Button("Move Snippet Up") {
        moveSelectedSnippet(by: -1)
      }
      .disabled(!canMoveSelectedSnippet(by: -1))
      Button("Move Snippet Down") {
        moveSelectedSnippet(by: 1)
      }
      .disabled(!canMoveSelectedSnippet(by: 1))

      Divider()

      Button("Delete Snippet…", role: .destructive) {
        snippetPendingDeletion = selectedSnippet
      }
      .disabled(selectedSnippet == nil)
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .help("Tools and snippet actions")
  }

  private func toolBinding(_ tool: RoutingTool) -> Binding<Bool> {
    Binding(
      get: { editor.activeTool == tool },
      set: { isOn in editor.activeTool = isOn ? tool : nil }
    )
  }

  // MARK: - Content

  private var emptyLibraryState: some View {
    ContentUnavailableView {
      Label("No Snippets", systemImage: "square.stack.3d.up.slash")
    } description: {
      Text("Create a typed rule or DNS patch snippet to apply runtime changes safely.")
    } actions: {
      Button(newSnippetTitle(.rules)) {
        requestNewSnippet(.rules)
      }
      Button(newSnippetTitle(.dnsPatch)) {
        requestNewSnippet(.dnsPatch)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private func workspace(showsToolPane: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return HStack(spacing: 0) {
      snippetList
        .frame(width: RoutingWorkspaceLayout.snippetListWidth)

      Divider()

      editorColumn
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      if showsToolPane, editor.activeTool != nil {
        Divider()
        RoutingToolPane(simulationTrace: simulationTrace, showsCloseButton: true) {
          editor.activeTool = nil
        }
        .frame(width: RoutingWorkspaceLayout.toolPaneWidth)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .background(.cardSurface, in: shape)
    .clipShape(shape)
    .overlay(shape.strokeBorder(.separator, lineWidth: 1))
  }

  private var snippetList: some View {
    VStack(spacing: 0) {
      List(selection: listSelectionBinding) {
        if editor.isEditingDetachedDraft {
          RuntimeSnippetRow(
            name: editor.draftSnippet.normalizedName,
            subtitle: "\(editor.draftSnippet.payload.displayName) - \(editor.draftSnippet.binding.displayName)",
            isEnabled: editor.draftSnippet.enabled,
            isUnsaved: true,
            onToggle: nil
          )
          .tag(editor.draftSnippet.id)
        }

        ForEach(snippetLibrary.snippets) { snippet in
          RuntimeSnippetRow(
            name: snippet.normalizedName,
            subtitle: "\(snippet.payload.displayName) - \(snippet.binding.displayName)",
            isEnabled: pendingSnippetEnabled[snippet.id] ?? snippet.enabled,
            isUnsaved: snippet.id == editor.selectedSnippetID && editor.draftHasUnsavedChanges,
            onToggle: { enabled in setSnippetEnabled(snippet, enabled: enabled) }
          )
          .tag(snippet.id)
          .contextMenu {
            snippetMenu(for: snippet)
          }
        }
        .onMove { source, destination in
          Task { @MainActor in
            _ = await appModel.moveRuntimeSnippet(fromOffsets: source, toOffset: destination)
          }
        }
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .onDeleteCommand {
        snippetPendingDeletion = selectedSnippet
      }
      .accessibilityLabel("Snippets")

      Divider()

      Text(librarySummary)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
    }
  }

  @ViewBuilder
  private func snippetMenu(for snippet: RuntimeSnippet) -> some View {
    let index = snippetLibrary.snippets.firstIndex { $0.id == snippet.id }
    Button("Move Up") {
      if let index {
        moveSnippet(at: index, by: -1)
      }
    }
    .disabled(index.map { $0 == 0 } ?? true)
    Button("Move Down") {
      if let index {
        moveSnippet(at: index, by: 1)
      }
    }
    .disabled(index.map { $0 >= snippetLibrary.snippets.count - 1 } ?? true)
    Divider()
    Button("Delete…", role: .destructive) {
      snippetPendingDeletion = snippet
    }
  }

  /// The snippet editor: identity rows on top, the payload below. Nothing else shares this column.
  private var editorColumn: some View {
    @Bindable var editor = editor
    return VStack(alignment: .leading, spacing: 0) {
      if hasEditableDraft {
        snippetIdentityForm
          .padding(12)

        Divider()

        payloadEditor
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        if let validationError = visibleValidationError {
          Divider()
          Label(validationError, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
      } else {
        CenteredUnavailableState(
          title: "No snippet selected",
          systemImage: "square.stack.3d.up",
          message: "Select a snippet to edit it, or create a new one."
        )
      }
    }
  }

  private var snippetIdentityForm: some View {
    @Bindable var editor = editor
    return VStack(alignment: .leading, spacing: 10) {
      RoutingEditRow("Name") {
        TextField("Snippet Name", text: $editor.draftSnippet.name)
          .textFieldStyle(.roundedBorder)
      }

      RoutingEditRow("Enabled") {
        Toggle("Enabled", isOn: $editor.draftSnippet.enabled)
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

      if case .profiles = editor.draftSnippet.binding {
        profileBindingEditor
      }

      RoutingEditContentRow {
        Text(appliesSummary)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
      }

      RoutingEditRow("Snippet Type") {
        if editor.isEditingDetachedDraft {
          Picker("Snippet Type", selection: payloadKind) {
            ForEach(RuntimeSnippetPayloadKind.allCases) { kind in
              Text(kind.displayName).tag(kind)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 180)
        } else {
          Text(editor.draftSnippet.payload.displayName)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var payloadEditor: some View {
    switch editor.draftSnippet.payload {
    case .rules:
      // The snippet's own "Enabled" row above is the only switch — a second overlay-level toggle
      // just gives the same snippet two ways to be off.
      RoutingRuleListEditor(settings: rulesPayloadBinding)
    case .dnsPatch:
      ScrollView {
        RuntimeDNSPatchEditor(settings: dnsPayloadBinding)
          .padding(12)
      }
    case .sniffer:
      ScrollView {
        RuntimeSnifferPatchEditor(settings: snifferPayloadBinding)
          .padding(12)
      }
    case .rawYAML:
      ScrollView {
        RuntimeRawYAMLPatchEditor(settings: rawYAMLPayloadBinding)
          .padding(12)
      }
    }
  }

  /// A brand-new snippet is valid until the user touches it, so a pristine draft never opens with a
  /// warning; the moment it is edited (or a save is attempted) the real error is shown.
  private var visibleValidationError: String? {
    guard let error = editor.draftSnippet.validationError else { return nil }
    if editor.isEditingDetachedDraft, !attemptedSave, editor.draftSnippet == pristineDraft(for: editor.draftSnippet.payload.kind, id: editor.draftSnippet.id) {
      return nil
    }
    return error
  }

  private func pristineDraft(for kind: RuntimeSnippetPayloadKind, id: RuntimeSnippet.ID) -> RuntimeSnippet {
    var snippet = Self.newSnippet(of: kind)
    snippet.id = id
    return snippet
  }

  // MARK: - Snippet lifecycle

  private var hasEditableDraft: Bool {
    editor.isEditingDetachedDraft || selectedSnippet != nil
  }

  private var canSave: Bool {
    hasEditableDraft
      && editor.draftSnippet.validationError == nil
      && editor.draftHasUnsavedChanges
  }

  private var selectedSnippet: RuntimeSnippet? {
    guard let selectedSnippetID = editor.selectedSnippetID else { return nil }
    return snippetLibrary.snippets.first { $0.id == selectedSnippetID }
  }

  private var listSelectionBinding: Binding<RuntimeSnippet.ID?> {
    Binding(
      get: {
        editor.isEditingDetachedDraft ? editor.draftSnippet.id : editor.selectedSnippetID
      },
      set: { newValue in
        let current = editor.isEditingDetachedDraft ? editor.draftSnippet.id : editor.selectedSnippetID
        guard newValue != current else { return }
        if editor.draftHasUnsavedChanges {
          pendingAction = .select(newValue)
        } else {
          select(newValue)
        }
      }
    )
  }

  private func select(_ id: RuntimeSnippet.ID?) {
    guard let id, let snippet = snippetLibrary.snippets.first(where: { $0.id == id }) else {
      editor.clearSelection()
      runSimulationImmediately()
      return
    }
    attemptedSave = false
    editor.load(snippet)
    runSimulationImmediately()
  }

  private func requestNewSnippet(_ kind: RuntimeSnippetPayloadKind) {
    if editor.draftHasUnsavedChanges {
      pendingAction = .newSnippet(kind)
    } else {
      beginNewSnippet(kind)
    }
  }

  private func beginNewSnippet(_ kind: RuntimeSnippetPayloadKind) {
    attemptedSave = false
    editor.beginDetachedDraft(Self.newSnippet(of: kind))
    runSimulationImmediately()
  }

  static func newSnippet(of kind: RuntimeSnippetPayloadKind) -> RuntimeSnippet {
    switch kind {
    case .rules:
      return RuntimeSnippet.defaultRuleSnippet
    case .dnsPatch:
      return RuntimeSnippet.defaultDNSPatchSnippet
    case .sniffer:
      return RuntimeSnippet.defaultSnifferSnippet
    case .rawYAML:
      return RuntimeSnippet.defaultRawYAMLSnippet
    }
  }

  private func newSnippetTitle(_ kind: RuntimeSnippetPayloadKind) -> String {
    switch kind {
    case .rules:
      return String(localized: "New Rule Snippet")
    case .dnsPatch:
      return String(localized: "New DNS Patch")
    case .sniffer:
      return String(localized: "New Sniffer Patch")
    case .rawYAML:
      return String(localized: "New Raw YAML Patch")
    }
  }

  private func newSnippetSymbol(_ kind: RuntimeSnippetPayloadKind) -> String {
    switch kind {
    case .rules:
      return "list.bullet.rectangle"
    case .dnsPatch:
      return "network"
    case .sniffer:
      return "waveform.badge.magnifyingglass"
    case .rawYAML:
      return "curlybraces"
    }
  }

  private func saveDraft(then action: RoutingPendingAction?) {
    attemptedSave = true
    guard canSave else { return }
    let nextDraft = editor.draftSnippet
    pendingAction = nil
    Task { @MainActor in
      if await appModel.saveRuntimeSnippet(nextDraft) {
        editor.load(nextDraft)
        attemptedSave = false
        perform(action)
      }
    }
  }

  private func discardDraft(then action: RoutingPendingAction?) {
    pendingAction = nil
    if let selectedSnippet {
      editor.load(selectedSnippet)
    } else {
      editor.clearSelection()
    }
    perform(action)
  }

  private func perform(_ action: RoutingPendingAction?) {
    switch action {
    case let .select(id):
      select(id)
    case let .newSnippet(kind):
      beginNewSnippet(kind)
    case nil:
      break
    }
  }

  private var unsavedChangesDialogPresented: Binding<Bool> {
    Binding(
      get: { pendingAction != nil },
      set: { isPresented in
        if !isPresented {
          pendingAction = nil
        }
      }
    )
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { snippetPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          snippetPendingDeletion = nil
        }
      }
    )
  }

  private func toolSheetPresented(showsToolPane: Bool) -> Binding<Bool> {
    Binding(
      get: { !showsToolPane && editor.activeTool != nil },
      set: { isPresented in
        if !isPresented {
          editor.activeTool = nil
        }
      }
    )
  }

  private func confirmDeleteSnippet() {
    guard let snippet = snippetPendingDeletion else { return }
    snippetPendingDeletion = nil
    Task { @MainActor in
      if await appModel.deleteRuntimeSnippet(snippet) {
        if editor.selectedSnippetID == snippet.id {
          editor.clearSelection()
        }
        reconcileDraftWithLibrary()
      }
    }
  }

  private func canMoveSelectedSnippet(by offset: Int) -> Bool {
    guard let selectedSnippet,
          let index = snippetLibrary.snippets.firstIndex(where: { $0.id == selectedSnippet.id })
    else { return false }
    return snippetLibrary.snippets.indices.contains(index + offset)
  }

  private func moveSelectedSnippet(by offset: Int) {
    guard let selectedSnippet,
          let index = snippetLibrary.snippets.firstIndex(where: { $0.id == selectedSnippet.id })
    else { return }
    moveSnippet(at: index, by: offset)
  }

  private func moveSnippet(at index: Int, by offset: Int) {
    let destination = index + offset
    guard snippetLibrary.snippets.indices.contains(destination) else { return }
    Task { @MainActor in
      _ = await appModel.moveRuntimeSnippet(
        fromOffsets: IndexSet(integer: index),
        toOffset: offset > 0 ? destination + 1 : destination
      )
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

  private func selectInitialSnippetIfNeeded() {
    guard !editor.isEditingDetachedDraft else { return }
    if let selectedSnippetID = editor.selectedSnippetID,
       snippetLibrary.snippets.contains(where: { $0.id == selectedSnippetID })
    {
      return
    }
    if let first = snippetLibrary.snippets.first {
      editor.load(first)
    } else {
      editor.clearSelection()
    }
  }

  private func reconcileDraftWithLibrary() {
    if let selectedSnippetID = editor.selectedSnippetID,
       let snippet = snippetLibrary.snippets.first(where: { $0.id == selectedSnippetID })
    {
      if snippet == editor.draftSnippet {
        editor.loadedSnippetSnapshot = snippet
      } else if !editor.draftHasUnsavedChanges {
        editor.load(snippet)
      }
    } else if editor.selectedSnippetID != nil, selectedSnippet == nil {
      // The selected snippet vanished from the library (deleted elsewhere or restored from backup).
      if editor.draftHasUnsavedChanges {
        editor.beginDetachedDraft(editor.draftSnippet)
      } else if let first = snippetLibrary.snippets.first {
        editor.load(first)
      } else {
        editor.clearSelection()
      }
    } else if editor.isEditingDetachedDraft {
      editor.loadedSnippetSnapshot = nil
    } else {
      selectInitialSnippetIfNeeded()
    }
    runSimulationImmediately()
  }

  // MARK: - Simulation

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
    simulationTrace = simulator.simulate(input: editor.simulationInput, candidateProvider: effectiveRuleCandidates)
  }

  private func consumeRoutingSimulationRequest() {
    guard let request = appModel.routingSimulationRequest else { return }
    editor.explanationContext = request.explanation
    editor.domainVerdictContext = request.domainVerdict
    editor.simulationInput = request.input
    editor.activeTool = .simulator
    runSimulationImmediately()
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

  private var activeSubscriptionProfile: Profile? {
    guard let profile = profileStore.activeProfile, profile.isSubscription else { return nil }
    return profile
  }

  private var activePreviewSnippets: [RuntimeSnippet] {
    guard let activeProfileID = profileStore.activeProfileID else { return [] }
    var snippets = snippetLibrary.snippets
    if let selectedSnippetID = editor.selectedSnippetID,
       let index = snippets.firstIndex(where: { $0.id == selectedSnippetID })
    {
      snippets[index] = editor.draftSnippet
    } else if editor.isEditingDetachedDraft {
      snippets.append(editor.draftSnippet)
    }
    return snippets.filter { $0.enabled && $0.applies(to: activeProfileID) }
  }

  // MARK: - Facts

  private var librarySummary: String {
    String(
      format: String(localized: "%lld snippets, %lld enabled"),
      Int64(snippetLibrary.snippets.count),
      Int64(snippetLibrary.snippets.filter(\.enabled).count)
    )
  }

  /// One line in place of the old "Active Profile" panel: does this draft touch the profile that is
  /// current right now, and how many snippets do.
  private var appliesSummary: String {
    guard let activeProfile = profileStore.activeProfile else {
      return String(localized: "No Profile")
    }
    let applies = editor.draftSnippet.enabled && editor.draftSnippet.applies(to: activeProfile.id)
    let appliesText = applies
      ? String(format: String(localized: "Applies to %@"), activeProfile.name)
      : String(format: String(localized: "Does not apply to %@"), activeProfile.name)
    return "\(appliesText) · \(String.localizedStringWithFormat(NSLocalizedString("%lld active snippets", comment: ""), Int64(activePreviewSnippets.count)))"
  }

  // MARK: - Bindings

  private var profileBindingEditor: some View {
    RoutingEditContentRow {
      VStack(alignment: .leading, spacing: 6) {
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
            .toggleStyle(.checkbox)
          }
        }
      }
    }
  }

  private var bindingMode: Binding<RuntimeSnippetBindingMode> {
    Binding(
      get: {
        switch editor.draftSnippet.binding {
        case .allProfiles:
          return .allProfiles
        case .profiles:
          return .selectedProfiles
        }
      },
      set: { mode in
        switch mode {
        case .allProfiles:
          editor.draftSnippet.binding = .allProfiles
        case .selectedProfiles:
          editor.draftSnippet.binding = .profiles(profileStore.activeProfileID.map { [$0] } ?? [])
        }
      }
    )
  }

  private var payloadKind: Binding<RuntimeSnippetPayloadKind> {
    Binding(
      get: { editor.draftSnippet.payload.kind },
      set: { kind in
        guard kind != editor.draftSnippet.payload.kind else { return }
        var replacement = Self.newSnippet(of: kind)
        replacement.id = editor.draftSnippet.id
        replacement.binding = editor.draftSnippet.binding
        replacement.enabled = editor.draftSnippet.enabled
        editor.draftSnippet = replacement
      }
    )
  }

  private var rulesPayloadBinding: Binding<RuleOverlaySettings> {
    Binding(
      get: { editor.draftSnippet.rulesPayload },
      set: { settings in
        var settings = settings
        settings.enabled = true
        editor.draftSnippet.payload = .rules(settings)
      }
    )
  }

  private var dnsPayloadBinding: Binding<TunDNSSettings> {
    Binding(
      get: { editor.draftSnippet.dnsPayload },
      set: { editor.draftSnippet.payload = .dnsPatch($0) }
    )
  }

  private var snifferPayloadBinding: Binding<SnifferSettings> {
    Binding(
      get: { editor.draftSnippet.snifferPayload },
      set: { editor.draftSnippet.payload = .sniffer($0) }
    )
  }

  private var rawYAMLPayloadBinding: Binding<RawYAMLPatchSettings> {
    Binding(
      get: { editor.draftSnippet.rawYAMLPayload },
      set: { editor.draftSnippet.payload = .rawYAML($0) }
    )
  }

  private func profileBinding(_ profileID: Profile.ID) -> Binding<Bool> {
    Binding(
      get: {
        editor.draftSnippet.binding.profileIDs.contains(profileID)
      },
      set: { isEnabled in
        var profileIDs = editor.draftSnippet.binding.profileIDs
        if isEnabled {
          if !profileIDs.contains(profileID) {
            profileIDs.append(profileID)
          }
        } else {
          profileIDs.removeAll { $0 == profileID }
        }
        editor.draftSnippet.binding = .profiles(profileIDs)
      }
    )
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

extension RuntimeSnippet {
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

  var rawYAMLPayload: RawYAMLPatchSettings {
    if case let .rawYAML(settings) = payload {
      return settings
    }
    return .empty
  }
}

/// One snippet in the library column: its switch, its name, and what kind of thing it is.
private struct RuntimeSnippetRow: View {
  let name: String
  let subtitle: String
  /// Not the stored value: the owner shows the requested value while the write is in flight.
  let isEnabled: Bool
  let isUnsaved: Bool
  /// `nil` for a draft that has never been saved — there is nothing in the library to switch yet.
  let onToggle: ((Bool) -> Void)?

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Toggle("Enabled", isOn: Binding(get: { isEnabled }, set: { onToggle?($0) }))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .disabled(onToggle == nil)
        .accessibilityLabel(String(format: String(localized: "%@ enabled"), displayName))

      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(displayName)
            .lineLimit(1)
            .truncationMode(.tail)
          if isUnsaved {
            Text("Unsaved")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.orange)
          }
        }
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.vertical, 2)
  }

  private var displayName: String {
    name.isEmpty ? String(localized: "Untitled Snippet") : name
  }
}

/// Which list a rule-snippet row belongs to. The order of the sections is the order Mihomo evaluates
/// them: rules added before the profile, then the profile's own rules with the disabled ones
/// removed, then rules added after.
private enum RoutingRuleSection: Hashable, CaseIterable {
  case before
  case disabled
  case after

  var title: LocalizedStringKey {
    switch self {
    case .before: "Before profile rules"
    case .disabled: "Disabled profile rules"
    case .after: "After profile rules"
    }
  }

  var explanation: LocalizedStringKey {
    switch self {
    case .before: "Evaluated first, so they win over every rule in the profile."
    case .disabled: "Profile rules matching these patterns are removed from the runtime config."
    case .after: "Evaluated after the profile's rules, before its final MATCH."
    }
  }

  var emptyText: LocalizedStringKey {
    switch self {
    case .before, .after: "No rules"
    case .disabled: "No disabled rules"
    }
  }
}

private enum RoutingRuleRowID: Hashable {
  case rule(UUID)
  case matcher(UUID)
}

private enum RoutingRuleSheet: Identifiable {
  case addRule(RoutingRuleSection)
  case editRule(ManagedRuleOverlayRule, RoutingRuleSection)
  case addMatcher
  case editMatcher(ManagedRuleDisableMatcher)

  var id: String {
    switch self {
    case let .addRule(section): "add-\(section)"
    case let .editRule(rule, _): "rule-\(rule.id)"
    case .addMatcher: "add-matcher"
    case let .editMatcher(matcher): "matcher-\(matcher.id)"
    }
  }
}

/// The rule snippet's content as one ordered list: three sections in evaluation order, every row a
/// finished rule, and the forms for adding or editing a rule opened only when asked for.
///
/// This replaces the Settings page's `RuleOverlaySettingsEditor` on the Routing page only. Both write
/// the same `RuleOverlaySettings`, so the model and its validation are shared; what differs is that
/// nothing here is a permanent input field, and a pristine snippet shows no required-field error.
struct RoutingRuleListEditor: View {
  @Binding var settings: RuleOverlaySettings
  @State private var selection: RoutingRuleRowID?
  @State private var sheet: RoutingRuleSheet?

  var body: some View {
    List(selection: $selection) {
      Section {
        ruleRows(\.prependRules, section: .before)
      } header: {
        sectionHeader(.before, count: settings.prependRules.count) {
          sheet = .addRule(.before)
        }
      }

      Section {
        matcherRows
      } header: {
        sectionHeader(.disabled, count: settings.disabledRuleMatchers.count) {
          sheet = .addMatcher
        }
      }

      Section {
        ruleRows(\.appendRules, section: .after)
      } header: {
        sectionHeader(.after, count: settings.appendRules.count) {
          sheet = .addRule(.after)
        }
      }
    }
    .listStyle(.inset)
    .scrollContentBackground(.hidden)
    .onDeleteCommand(perform: removeSelection)
    .sheet(item: $sheet) { sheet in
      switch sheet {
      case let .addRule(section):
        RoutingRuleFormSheet(mode: .add, rule: ManagedRuleOverlayRule(kind: .domainSuffix, policy: "DIRECT")) { rule in
          append(rule, to: section)
        }
      case let .editRule(rule, section):
        RoutingRuleFormSheet(mode: .edit, rule: rule) { edited in
          replace(edited, in: section)
        }
      case .addMatcher:
        RoutingMatcherFormSheet(mode: .add, matcher: ManagedRuleDisableMatcher()) { matcher in
          settings.disabledRuleMatchers.append(matcher)
        }
      case let .editMatcher(matcher):
        RoutingMatcherFormSheet(mode: .edit, matcher: matcher) { edited in
          if let index = settings.disabledRuleMatchers.firstIndex(where: { $0.id == edited.id }) {
            settings.disabledRuleMatchers[index] = edited
          }
        }
      }
    }
    .accessibilityLabel("Snippet rules")
  }

  private func sectionHeader(_ section: RoutingRuleSection, count: Int, onAdd: @escaping () -> Void) -> some View {
    HStack(spacing: 8) {
      Text(section.title)
      Text(verbatim: "\(count)")
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Spacer(minLength: 8)
      Button(action: onAdd) {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .help(section == .disabled ? String(localized: "Disable a profile rule…") : String(localized: "Add rule…"))
      .accessibilityLabel(section == .disabled ? String(localized: "Disable a profile rule…") : String(localized: "Add rule…"))
    }
    .help(Text(section.explanation))
  }

  @ViewBuilder
  private func ruleRows(_ keyPath: WritableKeyPath<RuleOverlaySettings, [ManagedRuleOverlayRule]>, section: RoutingRuleSection) -> some View {
    let rules = settings[keyPath: keyPath]
    if rules.isEmpty {
      Text(section.emptyText)
        .font(.callout)
        .foregroundStyle(.tertiary)
        .selectionDisabled()
    } else {
      ForEach(rules) { rule in
        RoutingRuleRowView(text: rule.runtimeRule, validationError: rule.validationError)
          .tag(RoutingRuleRowID.rule(rule.id))
          .contextMenu {
            Button("Edit…") { sheet = .editRule(rule, section) }
            Button("Duplicate") { duplicate(rule, in: keyPath) }
            Divider()
            Button("Move Up") { move(rule.id, in: keyPath, by: -1) }
              .disabled(rules.first?.id == rule.id)
            Button("Move Down") { move(rule.id, in: keyPath, by: 1) }
              .disabled(rules.last?.id == rule.id)
            Divider()
            Button("Remove", role: .destructive) {
              settings[keyPath: keyPath].removeAll { $0.id == rule.id }
            }
          }
          .onTapGesture(count: 2) {
            sheet = .editRule(rule, section)
          }
      }
      .onMove { source, destination in
        settings[keyPath: keyPath].move(fromOffsets: source, toOffset: destination)
      }
    }
  }

  @ViewBuilder
  private var matcherRows: some View {
    let matchers = settings.disabledRuleMatchers
    if matchers.isEmpty {
      Text(RoutingRuleSection.disabled.emptyText)
        .font(.callout)
        .foregroundStyle(.tertiary)
        .selectionDisabled()
    } else {
      ForEach(matchers) { matcher in
        RoutingRuleRowView(
          text: "\(matcher.mode.displayName): \(matcher.normalizedPattern)",
          validationError: matcher.validationError
        )
        .tag(RoutingRuleRowID.matcher(matcher.id))
        .contextMenu {
          Button("Edit…") { sheet = .editMatcher(matcher) }
          Divider()
          Button("Move Up") { moveMatcher(matcher.id, by: -1) }
            .disabled(matchers.first?.id == matcher.id)
          Button("Move Down") { moveMatcher(matcher.id, by: 1) }
            .disabled(matchers.last?.id == matcher.id)
          Divider()
          Button("Remove", role: .destructive) {
            settings.disabledRuleMatchers.removeAll { $0.id == matcher.id }
          }
        }
        .onTapGesture(count: 2) {
          sheet = .editMatcher(matcher)
        }
      }
      .onMove { source, destination in
        settings.disabledRuleMatchers.move(fromOffsets: source, toOffset: destination)
      }
    }
  }

  private func append(_ rule: ManagedRuleOverlayRule, to section: RoutingRuleSection) {
    switch section {
    case .before: settings.prependRules.append(rule)
    case .after: settings.appendRules.append(rule)
    case .disabled: break
    }
  }

  private func replace(_ rule: ManagedRuleOverlayRule, in section: RoutingRuleSection) {
    switch section {
    case .before:
      if let index = settings.prependRules.firstIndex(where: { $0.id == rule.id }) {
        settings.prependRules[index] = rule
      }
    case .after:
      if let index = settings.appendRules.firstIndex(where: { $0.id == rule.id }) {
        settings.appendRules[index] = rule
      }
    case .disabled:
      break
    }
  }

  private func duplicate(_ rule: ManagedRuleOverlayRule, in keyPath: WritableKeyPath<RuleOverlaySettings, [ManagedRuleOverlayRule]>) {
    guard let index = settings[keyPath: keyPath].firstIndex(where: { $0.id == rule.id }) else { return }
    var copy = rule
    copy.id = UUID()
    settings[keyPath: keyPath].insert(copy, at: index + 1)
  }

  private func move(_ id: UUID, in keyPath: WritableKeyPath<RuleOverlaySettings, [ManagedRuleOverlayRule]>, by offset: Int) {
    guard let index = settings[keyPath: keyPath].firstIndex(where: { $0.id == id }),
          settings[keyPath: keyPath].indices.contains(index + offset)
    else { return }
    settings[keyPath: keyPath].swapAt(index, index + offset)
  }

  private func moveMatcher(_ id: UUID, by offset: Int) {
    guard let index = settings.disabledRuleMatchers.firstIndex(where: { $0.id == id }),
          settings.disabledRuleMatchers.indices.contains(index + offset)
    else { return }
    settings.disabledRuleMatchers.swapAt(index, index + offset)
  }

  private func removeSelection() {
    switch selection {
    case let .rule(id):
      settings.prependRules.removeAll { $0.id == id }
      settings.appendRules.removeAll { $0.id == id }
    case let .matcher(id):
      settings.disabledRuleMatchers.removeAll { $0.id == id }
    case nil:
      return
    }
    selection = nil
  }
}

private struct RoutingRuleRowView: View {
  let text: String
  let validationError: String?

  var body: some View {
    HStack(spacing: 8) {
      Text(text)
        .font(.system(.callout, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer(minLength: 8)
      if let validationError {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help(validationError)
          .accessibilityLabel(validationError)
      }
    }
    .padding(.vertical, 1)
    .help(text)
  }
}

private enum RoutingFormMode {
  case add
  case edit
}

/// Add or edit one rule. Validation appears only once the user has typed something or tried to
/// commit, so an empty form never opens with a warning.
private struct RoutingRuleFormSheet: View {
  let mode: RoutingFormMode
  @State private var rule: ManagedRuleOverlayRule
  let onCommit: (ManagedRuleOverlayRule) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var attemptedCommit = false
  @FocusState private var isValueFocused: Bool

  init(mode: RoutingFormMode, rule: ManagedRuleOverlayRule, onCommit: @escaping (ManagedRuleOverlayRule) -> Void) {
    self.mode = mode
    _rule = State(initialValue: rule)
    self.onCommit = onCommit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(mode == .add ? "Add Rule" : "Edit Rule")
        .font(.headline)

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
        GridRow {
          Text("Rule Type")
            .foregroundStyle(.secondary)
          Picker("Rule Type", selection: kindBinding) {
            ForEach(ManagedRuleOverlayRule.Kind.allCases) { kind in
              Text(kind.displayName).tag(kind)
            }
          }
          .labelsHidden()
          .frame(maxWidth: 220, alignment: .leading)
        }

        if rule.kind == .subRule {
          GridRow {
            Text("Condition")
              .foregroundStyle(.secondary)
            Picker("Condition", selection: subRuleConditionBinding) {
              ForEach(RoutingSubRuleCondition.allCases) { condition in
                Text(condition.displayName).tag(condition)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220, alignment: .leading)
          }
        } else if rule.kind.requiresValue {
          GridRow {
            Text("Value")
              .foregroundStyle(.secondary)
            TextField(LocalizedStringKey(rule.kind.valuePlaceholder), text: $rule.value)
              .textFieldStyle(.roundedBorder)
              .focused($isValueFocused)
              .onSubmit(commit)
          }
        }

        GridRow {
          Text(rule.kind == .subRule ? "Sub-rule" : "Policy")
            .foregroundStyle(.secondary)
          TextField(LocalizedStringKey(rule.kind.policyPlaceholder), text: $rule.policy)
            .textFieldStyle(.roundedBorder)
            .onSubmit(commit)
        }

        if rule.kind.allowsNoResolve {
          GridRow {
            Color.clear.frame(width: 1, height: 1)
            Toggle("No Resolve", isOn: $rule.noResolve)
              .toggleStyle(.checkbox)
          }
        }
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Runtime: \(rule.runtimeRule)")
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)

        if showsValidation, let error = rule.validationError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(mode == .add ? "Add" : "Save", action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(rule.validationError != nil)
      }
    }
    .padding(18)
    .frame(width: 440)
    .onAppear {
      isValueFocused = rule.kind.requiresValue && rule.kind != .subRule
    }
  }

  private var showsValidation: Bool {
    attemptedCommit || !rule.value.isEmpty || mode == .edit
  }

  private func commit() {
    attemptedCommit = true
    guard rule.validationError == nil else { return }
    onCommit(rule)
    dismiss()
  }

  private var kindBinding: Binding<ManagedRuleOverlayRule.Kind> {
    Binding(
      get: { rule.kind },
      set: { kind in
        rule.kind = kind
        if !kind.allowsNoResolve {
          rule.noResolve = false
        }
        if kind == .subRule {
          if RoutingSubRuleCondition(condition: rule.value) == nil {
            rule.value = RoutingSubRuleCondition.tcp.ruleCondition
          }
        } else if rule.value.contains(",") {
          rule.value = ""
        }
      }
    )
  }

  private var subRuleConditionBinding: Binding<RoutingSubRuleCondition> {
    Binding(
      get: { RoutingSubRuleCondition(condition: rule.value) ?? .tcp },
      set: { rule.value = $0.ruleCondition }
    )
  }
}

private enum RoutingSubRuleCondition: String, CaseIterable, Identifiable {
  case tcp
  case udp

  var id: String { rawValue }

  init?(condition: String) {
    let parts = condition
      .split(separator: ",", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard parts.count == 2,
          parts[0].caseInsensitiveCompare("NETWORK") == .orderedSame
    else {
      return nil
    }
    self.init(rawValue: parts[1].lowercased())
  }

  var displayName: String {
    switch self {
    case .tcp:
      return String(localized: "Network TCP")
    case .udp:
      return String(localized: "Network UDP")
    }
  }

  var ruleCondition: String {
    "NETWORK,\(rawValue)"
  }
}

/// Add or edit one disabled-rule matcher.
private struct RoutingMatcherFormSheet: View {
  let mode: RoutingFormMode
  @State private var matcher: ManagedRuleDisableMatcher
  let onCommit: (ManagedRuleDisableMatcher) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var attemptedCommit = false
  @FocusState private var isPatternFocused: Bool

  init(mode: RoutingFormMode, matcher: ManagedRuleDisableMatcher, onCommit: @escaping (ManagedRuleDisableMatcher) -> Void) {
    self.mode = mode
    _matcher = State(initialValue: matcher)
    self.onCommit = onCommit
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(mode == .add ? "Disable Profile Rule" : "Edit Disabled Rule")
        .font(.headline)

      Text("Profile rules matching this pattern are removed from the runtime config. The profile file itself stays unchanged.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Picker("Match", selection: $matcher.mode) {
        ForEach(RuleDisableMatchMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()

      TextField("Rule pattern", text: $matcher.pattern)
        .textFieldStyle(.roundedBorder)
        .focused($isPatternFocused)
        .onSubmit(commit)

      if showsValidation, let error = matcher.validationError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.orange)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(mode == .add ? "Add" : "Save", action: commit)
          .keyboardShortcut(.defaultAction)
          .disabled(matcher.validationError != nil)
      }
    }
    .padding(18)
    .frame(width: 420)
    .onAppear {
      isPatternFocused = true
    }
  }

  private var showsValidation: Bool {
    attemptedCommit || !matcher.pattern.isEmpty || mode == .edit
  }

  private func commit() {
    attemptedCommit = true
    guard matcher.validationError == nil else { return }
    onCommit(matcher)
    dismiss()
  }
}

/// The tools column beside the editor: one tool at a time, chosen with a segmented control.
private struct RoutingToolPane: View {
  @Environment(AppModel.self) private var appModel
  let simulationTrace: RuleMatchSimulationTrace
  let showsCloseButton: Bool
  let onClose: () -> Void

  var body: some View {
    @Bindable var editor = appModel.routingEditor
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Picker("Tool", selection: Binding(
          get: { editor.activeTool ?? .effectiveConfig },
          set: { editor.activeTool = $0 }
        )) {
          ForEach(RoutingTool.allCases) { tool in
            Text(tool.title).tag(tool)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if showsCloseButton {
          Button(action: onClose) {
            Image(systemName: "xmark")
              .font(.caption.weight(.semibold))
          }
          .buttonStyle(.borderless)
          .help("Close tools")
          .accessibilityLabel("Close tools")
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      switch editor.activeTool ?? .effectiveConfig {
      case .effectiveConfig:
        RoutingEffectiveConfigTool()
      case .diagnostics:
        RoutingDiagnosticsTool()
      case .simulator:
        RoutingSimulatorTool(simulationTrace: simulationTrace)
      }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }
}

/// The same tools presented as a sheet when the window is too narrow for a third column.
private struct RoutingToolSheet: View {
  let simulationTrace: RuleMatchSimulationTrace
  let onDone: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      RoutingToolPane(simulationTrace: simulationTrace, showsCloseButton: false, onClose: onDone)
        .frame(maxHeight: .infinity)

      Divider()

      HStack {
        Spacer()
        Button("Done", action: onDone)
          .keyboardShortcut(.defaultAction)
      }
      .padding(12)
    }
    .frame(width: 560, height: 560)
  }
}

// MARK: - Effective Config

private struct RoutingEffectiveConfigTool: View {
  @Environment(AppModel.self) private var appModel
  @Environment(ProfileStore.self) private var profileStore

  var body: some View {
    @Bindable var editor = appModel.routingEditor
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Picker("Effective Config View", selection: $editor.effectiveConfigTab) {
          ForEach(EffectiveConfigInspectorTab.allCases) { tab in
            Text(tab.title).tag(tab)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)

        Spacer(minLength: 8)

        Button {
          refresh()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
        .accessibilityLabel("Refresh")

        Button {
          appModel.copyEffectiveRuntimeConfigRedacted()
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .disabled(!appModel.hasLoadedEffectiveRuntimeConfigForActiveProfile)
        .help("Copy Redacted")
        .accessibilityLabel("Copy Redacted")

        Button {
          appModel.exportEffectiveRuntimeConfigRedacted()
        } label: {
          Image(systemName: "square.and.arrow.down")
        }
        .disabled(!appModel.hasLoadedEffectiveRuntimeConfigForActiveProfile)
        .help("Export Redacted")
        .accessibilityLabel("Export Redacted")
      }
      .controlSize(.small)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          snippetEffect
          Divider()
          stateContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  /// What the draft on the left contributes, so the runtime diff never has to be read twice.
  private var snippetEffect: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("This Snippet")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      let lines = RoutingSnippetEffectSummary.lines(for: appModel.routingEditor.draftSnippet.payload)
      if lines.isEmpty {
        Text("No changes")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
          Text(line)
            .font(.system(.caption, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private var stateContent: some View {
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
      snapshotContent(snapshot)
    case .loaded:
      RoutingWorkspaceNotice(
        title: "Not Generated",
        systemImage: "doc.badge.clock",
        message: "Refresh to preview the redacted final runtime YAML and its diff."
      )
    }
  }

  @ViewBuilder
  private func snapshotContent(_ snapshot: EffectiveRuntimeConfigSnapshot) -> some View {
    RoutingDetailRow(title: "Preflight", value: preflightSummary(snapshot), isProminent: true, lineLimit: 3)
    switch appModel.routingEditor.effectiveConfigTab {
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
            RoutingRedactedCodeBlock(text: layer.redactedContent, maxHeight: 150)
          }
        }
      }
    case .diff:
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 2) {
          ForEach(snapshot.diffRows) { row in
            Text(row.displayLine)
              .font(.system(.caption2, design: .monospaced))
              .foregroundStyle(diffColor(row.kind))
              .textSelection(.enabled)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 320)
    case .finalYAML:
      RoutingRedactedCodeBlock(text: snapshot.redactedFinalYAML, maxHeight: 360)
    }
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

  private func preflightSummary(_ snapshot: EffectiveRuntimeConfigSnapshot) -> String {
    if let message = snapshot.preflightStatus.message {
      return "\(snapshot.preflightStatus.displayName): \(message)"
    }
    return snapshot.preflightStatus.displayName
  }

  private func refresh() {
    let editor = appModel.routingEditor
    let draft = editor.draftHasUnsavedChanges ? editor.draftSnippet : nil
    Task { @MainActor in
      await appModel.refreshEffectiveRuntimeConfigPreview(draftSnippet: draft)
    }
  }
}

private struct RoutingRedactedCodeBlock: View {
  let text: String
  let maxHeight: CGFloat

  var body: some View {
    ScrollView {
      Text(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? String(localized: "Empty") : text)
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: maxHeight)
  }
}

// MARK: - Diagnostics

/// A compact selection list on top, one diagnosis below. Warnings are visible in the list at a
/// glance without every panel being open at once.
private struct RoutingDiagnosticsTool: View {
  @Environment(AppModel.self) private var appModel
  @Environment(ProfileStore.self) private var profileStore

  var body: some View {
    @Bindable var editor = appModel.routingEditor
    VStack(spacing: 0) {
      List(RoutingDiagnostic.allCases, selection: Binding(
        get: { Optional(editor.selectedDiagnostic) },
        set: { if let value = $0 { editor.selectedDiagnostic = value } }
      )) { diagnostic in
        let status = status(for: diagnostic)
        HStack(spacing: 8) {
          Image(systemName: status.systemImage)
            .foregroundStyle(status.tint)
            .frame(width: 16)
          VStack(alignment: .leading, spacing: 1) {
            Text(diagnostic.title)
            Text(headline(for: diagnostic))
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        .tag(diagnostic)
        .accessibilityElement(children: .combine)
      }
      .listStyle(.inset)
      .scrollContentBackground(.hidden)
      .frame(height: 5 * 40 + 12)
      .accessibilityLabel("Diagnostics")

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          switch editor.selectedDiagnostic {
          case .dnsOverride:
            dnsOverride
          case .dnsResolution:
            dnsResolution
          case .fakeIP:
            fakeIP
          case .listeners:
            listeners
          case .geoDatabases:
            geoDatabases
          }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
    }
  }

  private func status(for diagnostic: RoutingDiagnostic) -> RoutingDiagnosisHeadline.DiagnosisStatus {
    switch diagnostic {
    case .dnsOverride:
      guard let plan = loadedEffectiveConfigSnapshot?.dnsOverride else { return .info }
      if plan.issues.contains(where: \.isBlocking) { return .fail }
      if !plan.issues.isEmpty { return .warn }
      return plan.hasOverride ? .pass : .info
    case .dnsResolution:
      return .init(appModel.dnsResolutionDiagnostics.status)
    case .fakeIP:
      return .init(appModel.fakeIPDiagnostics.status)
    case .listeners:
      return .init(appModel.listenerExposureDiagnostics.status)
    case .geoDatabases:
      return .init(appModel.geoDatabaseDiagnostics.status)
    }
  }

  private func headline(for diagnostic: RoutingDiagnostic) -> String {
    switch diagnostic {
    case .dnsOverride:
      guard let plan = loadedEffectiveConfigSnapshot?.dnsOverride else {
        return String(localized: "Not Generated")
      }
      return plan.enablement.displayName
    case .dnsResolution:
      return appModel.dnsResolutionDiagnostics.headline
    case .fakeIP:
      return appModel.fakeIPDiagnostics.headline
    case .listeners:
      return appModel.listenerExposureDiagnostics.headline
    case .geoDatabases:
      return appModel.geoDatabaseDiagnostics.headline
    }
  }

  private var loadedEffectiveConfigSnapshot: EffectiveRuntimeConfigSnapshot? {
    guard case let .loaded(snapshot) = appModel.effectiveRuntimeConfigState,
          snapshot.profileID == profileStore.activeProfile?.id
    else { return nil }
    return snapshot
  }

  /// Answers "is my DNS override on, what does it change, and does anything reach it?" — the three
  /// questions issue #16 says the rule and DNS surfaces never connected.
  @ViewBuilder
  private var dnsOverride: some View {
    if let plan = loadedEffectiveConfigSnapshot?.dnsOverride {
      RoutingDetailRow(title: "Status", value: plan.enablement.displayName, isProminent: true)
      RoutingDetailRow(title: "Effect", value: plan.summary, lineLimit: 3)

      if plan.hasOverride {
        RoutingSnippetEffectSummary.section(title: "Overridden Keys", values: plan.overriddenFieldNames)
      }
      if !plan.contributors.isEmpty {
        RoutingSnippetEffectSummary.section(title: "Contributors", values: plan.contributors)
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
    } else {
      RoutingWorkspaceNotice(
        title: "Not Generated",
        systemImage: "doc.badge.clock",
        message: String(localized: "Refresh the effective config to see which DNS keys Mihomo really reads.")
      )
      Button("Refresh Effective Config") {
        let editor = appModel.routingEditor
        let draft = editor.draftHasUnsavedChanges ? editor.draftSnippet : nil
        Task { @MainActor in
          await appModel.refreshEffectiveRuntimeConfigPreview(draftSnippet: draft)
        }
      }
      .controlSize(.small)
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

  /// Roadmap A2. `GET /dns/query` asks the **core's** resolver, which is a different question from
  /// the one `dig` answers on this Mac and the only one that explains routing.
  @ViewBuilder
  private var dnsResolution: some View {
    @Bindable var appModel = appModel
    let diagnosis = appModel.dnsResolutionDiagnostics
    HStack(spacing: 8) {
      TextField("Domain", text: $appModel.dnsResolutionQuery)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .onSubmit { appModel.resolveDNSQuery() }

      Picker("Type", selection: $appModel.dnsResolutionQueryType) {
        ForEach(DNSQueryType.allCases) { type in
          Text(type.displayName).tag(type)
        }
      }
      .labelsHidden()
      .controlSize(.small)
      .fixedSize()

      Button {
        appModel.resolveDNSQuery()
      } label: {
        if case .querying = appModel.dnsResolutionOutcome {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Resolve")
        }
      }
      .controlSize(.small)
      .disabled(!appModel.canResolveDNSQuery)
      .help(diagnosis.reason)
    }

    RoutingDiagnosisHeadline(headline: diagnosis.headline, status: diagnosis.status)
    Text(diagnosis.reason)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

    ForEach(Array(diagnosis.facts.enumerated()), id: \.offset) { _, fact in
      RoutingDiagnosisFactRow(title: fact.title, value: fact.value)
    }

    if !diagnosis.records.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(diagnosis.records.enumerated()), id: \.offset) { _, record in
          // Wire data, not copy: rendered verbatim so it is neither extracted for translation
          // nor reformatted by the locale.
          Text(verbatim: "\(record.name) \(record.ttl) \(record.typeName) \(record.data)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }

    recoveryActions(diagnosis.recoveryActions)
  }

  /// Roadmap A3: the fake-ip table survives events that invalidate it; this is the remedy.
  @ViewBuilder
  private var fakeIP: some View {
    let diagnosis = appModel.fakeIPDiagnostics
    RoutingDiagnosisHeadline(headline: diagnosis.headline, status: diagnosis.status)
    Text(diagnosis.reason)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

    ForEach(Array(diagnosis.facts.enumerated()), id: \.offset) { _, fact in
      RoutingDiagnosisFactRow(title: fact.title, value: fact.value)
    }

    HStack(spacing: 8) {
      Button {
        appModel.flushFakeIPCache()
      } label: {
        if appModel.fakeIPFlushInFlight {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Flush Fake IP Cache")
        }
      }
      .controlSize(.small)
      .disabled(!appModel.canFlushFakeIPCache)
      // The action stays visible when it would do nothing, with the diagnosis as the tooltip: a
      // control that is not there cannot explain why it is not there.
      .help(diagnosis.reason)

      if let lastFlushAt = appModel.lastFakeIPFlushAt {
        Text(lastFlushAt, format: .relative(presentation: .named))
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }
  }

  /// Roadmap C3: exposure is never silent.
  @ViewBuilder
  private var listeners: some View {
    let diagnosis = appModel.listenerExposureDiagnostics
    RoutingDiagnosisHeadline(headline: diagnosis.headline, status: diagnosis.status)
    Text(diagnosis.reason)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

    ForEach(Array(diagnosis.facts.enumerated()), id: \.offset) { _, fact in
      RoutingDiagnosisFactRow(title: fact.title, value: fact.value)
    }

    recoveryActions(diagnosis.recoveryActions)
  }

  /// Roadmap B5: geo databases download once and then go stale unless refreshed.
  @ViewBuilder
  private var geoDatabases: some View {
    let diagnosis = appModel.geoDatabaseDiagnostics
    RoutingDiagnosisHeadline(headline: diagnosis.headline, status: diagnosis.status)
    Text(diagnosis.reason)
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

    ForEach(Array(diagnosis.facts.enumerated()), id: \.offset) { _, fact in
      RoutingDiagnosisFactRow(title: fact.title, value: fact.value)
    }

    HStack(spacing: 8) {
      Button {
        appModel.updateGeoDatabases()
      } label: {
        if appModel.geoDatabaseUpdateInFlight {
          ProgressView()
            .controlSize(.small)
        } else {
          Text("Update Now")
        }
      }
      .controlSize(.small)
      .disabled(!appModel.canUpdateGeoDatabases)
      .help(diagnosis.reason)

      if appModel.geoDatabaseUpdateInFlight {
        Text("Downloading through the core; this can take a while.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
    }

    // Reported from what changed on disk, not from the endpoint's status code: `POST /configs/geo`
    // answers 204 for "downloaded four files" and for "did nothing at all".
    if let message = appModel.geoDatabaseUpdateStatusMessage {
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    recoveryActions(diagnosis.recoveryActions)
      .task(id: appModel.geoDatabaseSettings) {
        appModel.refreshGeoDatabaseInventory()
      }
  }

  private func recoveryActions(_ actions: [String]) -> some View {
    ForEach(actions, id: \.self) { action in
      Label(action, systemImage: "arrow.right.circle")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

// MARK: - Match Simulator

private struct RoutingSimulatorTool: View {
  @Environment(AppModel.self) private var appModel
  let simulationTrace: RuleMatchSimulationTrace
  @State private var showsAdvancedConditions = false

  var body: some View {
    @Bindable var editor = appModel.routingEditor
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let explanation = editor.explanationContext {
          connectionContext(explanation, verdict: editor.domainVerdictContext)
          Divider()
        }

        TextField("Destination host or IP", text: $editor.simulationInput.destination)
          .textFieldStyle(.roundedBorder)

        DisclosureGroup("Advanced Conditions", isExpanded: $showsAdvancedConditions) {
          VStack(alignment: .leading, spacing: 8) {
            TextField("Source IP", text: $editor.simulationInput.sourceIP)
            TextField("Process name or path", text: $editor.simulationInput.process)
            HStack(spacing: 8) {
              TextField("Dst Port", text: $editor.simulationInput.destinationPort)
              TextField("Src Port", text: $editor.simulationInput.sourcePort)
              TextField("In Port", text: $editor.simulationInput.inboundPort)
            }
          }
          .textFieldStyle(.roundedBorder)
          .padding(.top, 6)
        }
        .font(.callout)

        Divider()

        RoutingDetailRow(title: "Result", value: simulationTrace.title, isProminent: true)
        RoutingDetailRow(title: "Source", value: simulationTrace.sourceSummary)
        RoutingDetailRow(title: "Hit Rule", value: simulationTrace.ruleSummary, lineLimit: 3)
        RoutingDetailRow(title: "Policy / Sub-rule", value: simulationTrace.policySummary)
        RoutingDetailRow(title: "Provider", value: simulationTrace.providerSummary)
        RoutingDetailRow(title: "Detail", value: simulationTrace.detail, lineLimit: 4)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .onAppear {
      // Conditions carried over from a connection are worth seeing; an empty set stays folded.
      let input = editor.simulationInput
      if !input.sourceIP.isEmpty || !input.process.isEmpty || !input.destinationPort.isEmpty
        || !input.sourcePort.isEmpty || !input.inboundPort.isEmpty
      {
        showsAdvancedConditions = true
      }
    }
  }

  /// The connection this simulation was opened from. The simulator answers "which rule wins for this
  /// destination"; for a connection that never carried a domain the verdict says why no domain rule
  /// could ever have matched it.
  private func connectionContext(_ explanation: RuleExplanation, verdict: SnifferDiagnosticsSnapshot?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label("Connection Context", systemImage: "point.3.connected.trianglepath.dotted")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button("Clear") {
          appModel.routingEditor.explanationContext = nil
          appModel.routingEditor.domainVerdictContext = nil
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
      }
      RoutingDetailRow(
        title: "Mihomo Reported",
        value: explanation.reportedRuleSummary.isEmpty ? "-" : explanation.reportedRuleSummary
      )
      RoutingDetailRow(title: "Chosen Target", value: explanation.target.isEmpty ? "-" : explanation.target)
      RoutingDetailRow(title: "Chosen Policy", value: explanation.chosenPolicySummary)
      RoutingDetailRow(title: "Local Result", value: explanation.localSummary, lineLimit: 5)
      if let verdict {
        RoutingDetailRow(title: "Domain Visibility", value: verdict.headline, isProminent: true)
        RoutingDetailRow(title: "Reason", value: verdict.reason, lineLimit: 5)
        ForEach(verdict.recoveryActions, id: \.self) { action in
          RoutingDetailRow(title: "Suggested Fix", value: action, lineLimit: 3)
        }
      }
    }
  }
}

// MARK: - Snippet effect summary

/// The lines a snippet contributes to the runtime, as text. Pure so the tools and tests share it.
enum RoutingSnippetEffectSummary {
  static func lines(for payload: RuntimeSnippetPayload) -> [String] {
    switch payload {
    case let .rules(settings):
      var lines = settings.runtimePrependRules.map { "\(String(localized: "Before")): \($0)" }
      lines += settings.runtimeDisabledRuleMatchers.map { "\(String(localized: "Disabled")): \($0.mode.displayName) \($0.normalizedPattern)" }
      lines += settings.runtimeAppendRules.map { "\(String(localized: "After")): \($0)" }
      return lines
    case let .dnsPatch(settings):
      return dnsPatchPreviewLines(settings)
    case let .sniffer(settings):
      return snifferPatchPreviewLines(settings)
    case let .rawYAML(settings):
      return rawYAMLPatchPreviewLines(settings)
    }
  }

  static func section(title: LocalizedStringResource, values: [String]) -> some View {
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

  /// Names the top-level keys the patch wins, not the YAML body: the body is already in the editor
  /// right next to this panel, and it is the one payload that can be arbitrarily long.
  static func rawYAMLPatchPreviewLines(_ settings: RawYAMLPatchSettings) -> [String] {
    guard settings.hasRuntimeOverlay else { return [] }
    if let validationError = settings.validationError {
      return [validationError]
    }
    var lines = settings.topLevelKeys.map { "\($0): \(String(localized: "set by this snippet"))" }
    for keyPath in settings.overriddenManagedKeyPaths {
      lines.append("\(keyPath): \(String(localized: "taken over from ClashMax"))")
    }
    lines.append(settings.listStrategy.explanation)
    return lines
  }

  static func dnsPatchPreviewLines(_ settings: TunDNSSettings) -> [String] {
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

  static func snifferPatchPreviewLines(_ settings: SnifferSettings) -> [String] {
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

  private static func appendOptionalBool(_ value: Bool?, title: String, to lines: inout [String]) {
    guard let value else { return }
    lines.append("\(title) = \(value)")
  }

  private static func appendList(_ values: [String], title: String, to lines: inout [String]) {
    guard !values.isEmpty else { return }
    lines.append("\(title): \(values.joined(separator: ", "))")
  }

  private static func appendMap(_ values: [String: String], title: String, to lines: inout [String]) {
    for key in values.keys.sorted() {
      lines.append("\(title).\(key) = \(values[key] ?? "")")
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

/// The generic escape hatch (ROADMAP INV-2), as an ordinary snippet editor rather than a legacy
/// field in Developer Mode. It is deliberately the plainest editor on this page: the point is that
/// keys ClashMax has no UI for — `tcp-concurrent`, `ntp`, `keep-alive-interval` — are reachable
/// through the same save, preflight and rollback path as every other snippet, so the app does not
/// have to grow a switch per key (§2.4).

/// The generic escape hatch (ROADMAP INV-2), as an ordinary snippet editor rather than a legacy
/// field in Developer Mode. It is deliberately the plainest editor on this page: the point is that
/// keys ClashMax has no UI for — `tcp-concurrent`, `ntp`, `keep-alive-interval` — are reachable
/// through the same save, preflight and rollback path as every other snippet, so the app does not
/// have to grow a switch per key (§2.4).
private struct RuntimeRawYAMLPatchEditor: View {
  @Binding var settings: RawYAMLPatchSettings

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      RoutingEditRow("Lists") {
        Picker("Lists", selection: $settings.listStrategy) {
          ForEach(RawYAMLPatchListStrategy.allCases) { strategy in
            Text(strategy.displayName).tag(strategy)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
      }

      RoutingEditContentRow {
        Text(settings.listStrategy.explanation)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      RoutingEditRow("YAML") {
        RoutingSnippetTextArea(
          placeholder: String(localized: "tcp-concurrent: true\nntp:\n  enable: true\n  server: time.apple.com"),
          text: $settings.yaml,
          minHeight: 132
        )
      }

      RoutingEditContentRow {
        VStack(alignment: .leading, spacing: 6) {
          Text("Merged after every key ClashMax manages, so this snippet has the last word.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

          // Naming the ClashMax controls that stop deciding is the honest half of INV-2: the
          // override is allowed, but the user should not later wonder why a Settings switch does
          // nothing.
          if !overriddenManagedKeyPaths.isEmpty {
            Label(
              String(
                format: String(localized: "These ClashMax settings no longer decide: %@."),
                overriddenManagedKeyPaths.joined(separator: ", ")
              ),
              systemImage: "hand.raised.fill"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
          }

          Text("mixed-port, external-controller and secret stay with ClashMax — the app applies, verifies and rolls back this snippet through them.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var overriddenManagedKeyPaths: [String] {
    settings.overriddenManagedKeyPaths
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

private struct RoutingDiagnosisHeadline: View {
  let headline: String
  let status: DiagnosisStatus

  /// The three diagnostics builders (`SnifferDiagnosticsSnapshot`, `FakeIPDiagnosticsSnapshot`,
  /// `GeoDatabaseDiagnosticsSnapshot`) each carry their own `Status` enum so no model depends on
  /// another; this is the one place the three collapse onto a shared icon and tint.
  enum DiagnosisStatus {
    case pass
    case info
    case warn
    case fail

    init(_ status: FakeIPDiagnosticsSnapshot.Status) {
      switch status {
      case .pass: self = .pass
      case .info: self = .info
      case .warn: self = .warn
      }
    }

    init(_ status: GeoDatabaseDiagnosticsSnapshot.Status) {
      switch status {
      case .pass: self = .pass
      case .info: self = .info
      case .warn: self = .warn
      }
    }

    init(_ status: DNSResolutionSnapshot.Status) {
      switch status {
      case .pass: self = .pass
      case .info: self = .info
      case .warn: self = .warn
      case .fail: self = .fail
      }
    }

    init(_ status: ListenerExposureSnapshot.Status) {
      switch status {
      case .pass: self = .pass
      case .info: self = .info
      case .warn: self = .warn
      case .fail: self = .fail
      }
    }

    var systemImage: String {
      switch self {
      case .pass: return "checkmark.seal.fill"
      case .info: return "info.circle.fill"
      case .warn: return "exclamationmark.triangle.fill"
      case .fail: return "xmark.octagon.fill"
      }
    }

    var tint: Color {
      switch self {
      case .pass: return .green
      case .info: return .secondary
      case .warn: return .orange
      case .fail: return .red
      }
    }
  }

  init(headline: String, status: FakeIPDiagnosticsSnapshot.Status) {
    self.headline = headline
    self.status = DiagnosisStatus(status)
  }

  init(headline: String, status: GeoDatabaseDiagnosticsSnapshot.Status) {
    self.headline = headline
    self.status = DiagnosisStatus(status)
  }

  init(headline: String, status: DNSResolutionSnapshot.Status) {
    self.headline = headline
    self.status = DiagnosisStatus(status)
  }

  init(headline: String, status: ListenerExposureSnapshot.Status) {
    self.headline = headline
    self.status = DiagnosisStatus(status)
  }

  var body: some View {
    Label {
      Text(headline)
        .font(.callout.weight(.medium))
        .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: status.systemImage)
        .foregroundStyle(status.tint)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// `RoutingDetailRow` takes a `LocalizedStringResource`; diagnostics facts carry titles composed at
/// runtime, so they need a row that takes a plain `String`.

/// `RoutingDetailRow` takes a `LocalizedStringResource`; diagnostics facts carry titles composed at
/// runtime, so they need a row that takes a plain `String`.
private struct RoutingDiagnosisFactRow: View {
  let title: String
  let value: String

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
