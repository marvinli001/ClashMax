import SwiftUI

/// "Route This Site or App…": send the app in front, or a site it just opened, through a chosen
/// group, node or DIRECT without opening the main window.
///
/// The rule goes through the same quick-rule path the Connections page uses (issue #15 phase B):
/// one fixed-id snippet, `saveRuntimeSnippet`'s preflight/reload/rollback, then the "which rule
/// actually wins" verdict. Only the prefill is new, and it is decided by `FrontmostRoutePolicy`.
struct MenuBarRouteFrontmostSection: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  let groups: [ProxyGroup]

  @State private var isExpanded = false
  @State private var app: FrontmostAppSnapshot?
  @State private var subjects: [FrontmostRouteSubject] = []
  @State private var subject: FrontmostRouteSubject?
  @State private var target: FrontmostRouteTarget?
  @State private var phase = Phase.choosing
  @State private var verdict: QuickRuleVerdict?
  @State private var errorMessage: String?
  @State private var verdictFallback: Task<Void, Never>?

  private enum Phase: Equatable {
    case choosing
    case applying
    /// Applied; waiting for the core's refreshed rule list before saying what matches.
    case verifying
    case done(alreadyPresent: Bool)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      Button {
        isExpanded.toggle()
        if isExpanded { refreshSubjects() }
      } label: {
        HStack(spacing: 6) {
          Label(String(localized: "Route This Site or App…"), systemImage: "arrow.triangle.branch")
            .font(.callout)
            .lineLimit(1)
          Spacer(minLength: 4)
          Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .help(String(localized: "Send the app in front, or a site it just opened, through the policy you choose."))

      if isExpanded {
        expandedContent
      }
    }
    .onChange(of: FrontmostApplicationTracker.shared.lastApp) { _, _ in
      guard isExpanded, phase == .choosing else { return }
      refreshSubjects()
    }
    .onChange(of: runtimeData.rules) { _, _ in
      guard phase == .verifying else { return }
      settleVerdict()
    }
    .onDisappear {
      verdictFallback?.cancel()
      verdictFallback = nil
    }
  }

  @ViewBuilder
  private var expandedContent: some View {
    if let app {
      MenuBarControlRow(title: String(localized: "Match"), systemImage: "scope") {
        MenuBarPopUpSelection(
          selection: subject,
          items: { subjects.map { PopUpSelectionItem(value: $0, title: title(for: $0, app: app), systemImage: symbol(for: $0)) } },
          onSelect: { choose(subject: $0) }
        ) {
          Text(subject.map { title(for: $0, app: app) } ?? String(localized: "Select"))
            .truncationMode(.middle)
        }
        .disabled(subjects.isEmpty || phase == .applying)
      }

      MenuBarControlRow(title: String(localized: "Route Through"), systemImage: "arrow.turn.down.right") {
        MenuBarSelectionMenu {
          targetMenu
        } value: {
          Text(target?.policy ?? String(localized: "Select"))
            .truncationMode(.middle)
        }
        .disabled(phase == .applying)
      }

      notes(for: app)

      if let draft = currentDraft(app: app) {
        Text(draft.runtimeRule)
          .font(.system(.caption2, design: .monospaced))
          .lineLimit(2)
          .truncationMode(.middle)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .help(draft.runtimeRule)
      }

      resultContent

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      actions(app: app)
    } else {
      Text("Switch to the app or browser you want to route, then open this panel again.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var targetMenu: some View {
    let options = FrontmostRoutePolicy.targetOptions(groups: groups)
    ForEach(options.groups, id: \.self) { name in
      targetButton(.group(name), title: name, systemImage: MenuBarNodeSelection.groupSymbolName)
    }
    if !options.groups.isEmpty {
      Divider()
    }
    targetButton(.direct, title: FrontmostRouteTarget.direct.policy, systemImage: "arrow.right.circle")
    if !options.nodesByGroup.isEmpty {
      Divider()
      Menu(String(localized: "Single Node")) {
        ForEach(options.nodesByGroup, id: \.group) { entry in
          Menu(entry.group) {
            ForEach(entry.nodes, id: \.self) { node in
              targetButton(.node(node), title: node, systemImage: nil)
            }
          }
        }
      }
    }
  }

  private func targetButton(_ value: FrontmostRouteTarget, title: String, systemImage: String?) -> some View {
    Button {
      choose(target: value)
    } label: {
      if value == target {
        Label(title, systemImage: "checkmark")
      } else if let systemImage {
        Label(title, systemImage: systemImage)
      } else {
        Text(title)
      }
    }
  }

  @ViewBuilder
  private func notes(for app: FrontmostAppSnapshot) -> some View {
    if case .app = subject, app.loadsPagesThroughWebKit {
      Text(String(
        format: String(localized: "%@ loads pages through WebKit's networking service, which an app rule cannot see. Route one of its sites instead."),
        app.name
      ))
      .font(.caption)
      .foregroundStyle(.orange)
      .fixedSize(horizontal: false, vertical: true)
    } else if !subjects.contains(where: { if case .site = $0 { true } else { false } }) {
      Text(String(format: String(localized: "No recent connections from %@ yet, so only the app can be routed."), app.name))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  @ViewBuilder
  private var resultContent: some View {
    switch phase {
    case .choosing, .applying:
      EmptyView()
    case .verifying:
      HStack(spacing: 6) {
        ProgressView()
          .controlSize(.small)
        Text("Checking which rule matches now…")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case let .done(alreadyPresent):
      if alreadyPresent {
        Label("This rule was already in Quick Rules, so nothing was changed.", systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        RuntimeApplyOutcomeBanner()
      }
      if let verdict {
        QuickRuleVerdictView(verdict: verdict)
      }
    }
  }

  private func actions(app: FrontmostAppSnapshot) -> some View {
    HStack(spacing: 8) {
      if case .done = phase {
        Button(String(localized: "Open in Routing")) {
          AppDelegate.showMainWindow()
          appModel.selectedSection = .routing
        }
      }
      Spacer(minLength: 0)
      Button {
        apply(app: app)
      } label: {
        if phase == .applying {
          ProgressView().controlSize(.small)
        } else {
          Text("Add Rule")
        }
      }
      .buttonStyle(.borderedProminent)
      .disabled(!canApply(app: app))
    }
    .controlSize(.small)
  }

  // MARK: - State

  private func refreshSubjects() {
    let app = FrontmostApplicationTracker.shared.lastApp
    self.app = app
    guard let app else {
      subjects = []
      subject = nil
      return
    }
    subjects = FrontmostRoutePolicy.subjects(for: app, connections: runtimeData.connections)
    if subject.map({ !subjects.contains($0) }) ?? true {
      subject = FrontmostRoutePolicy.defaultSubject(in: subjects, app: app)
    }
    if let target, !isOffered(target) {
      self.target = nil
    }
    resetResult()
  }

  private func isOffered(_ target: FrontmostRouteTarget) -> Bool {
    let options = FrontmostRoutePolicy.targetOptions(groups: groups)
    switch target {
    case .direct: return true
    case let .group(name): return options.groups.contains(name)
    case let .node(name): return options.nodesByGroup.contains { $0.nodes.contains(name) }
    }
  }

  private func choose(subject: FrontmostRouteSubject) {
    self.subject = subject
    resetResult()
  }

  private func choose(target: FrontmostRouteTarget) {
    self.target = target
    resetResult()
  }

  private func resetResult() {
    guard phase != .applying else { return }
    verdictFallback?.cancel()
    verdictFallback = nil
    phase = .choosing
    verdict = nil
    errorMessage = nil
  }

  private func currentDraft(app: FrontmostAppSnapshot) -> QuickRuleDraft? {
    guard let subject else { return nil }
    return FrontmostRoutePolicy.draft(for: subject, app: app, target: target ?? .direct).map { draft in
      guard target == nil else { return draft }
      // Preview the match half of the line until a target is chosen, rather than implying DIRECT.
      var preview = draft
      preview.rule.policy = "…"
      return preview
    }
  }

  private func canApply(app: FrontmostAppSnapshot) -> Bool {
    guard phase == .choosing, let subject, let target,
          let draft = FrontmostRoutePolicy.draft(for: subject, app: app, target: target)
    else { return false }
    return draft.validationError == nil
  }

  private func apply(app: FrontmostAppSnapshot) {
    guard let subject, let target, let draft = FrontmostRoutePolicy.draft(for: subject, app: app, target: target) else {
      return
    }
    errorMessage = nil
    if appModel.quickRuleIsAlreadyActive(draft) {
      phase = .done(alreadyPresent: true)
      settleVerdict(for: draft)
      return
    }
    phase = .applying
    Task { @MainActor in
      let didApply = await appModel.addQuickRule(draft)
      guard didApply else {
        errorMessage = appModel.lastError ?? String(localized: "The rule could not be applied.")
        phase = .choosing
        return
      }
      if appModel.lastRuntimeApplyOutcome == .applied(.rules) {
        phase = .verifying
        scheduleVerdictFallback()
      } else {
        phase = .done(alreadyPresent: false)
        settleVerdict(for: draft)
      }
    }
  }

  /// A reload that never refreshes the rule list would otherwise leave "checking" up forever.
  private func scheduleVerdictFallback() {
    verdictFallback?.cancel()
    verdictFallback = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, phase == .verifying else { return }
      settleVerdict()
    }
  }

  private func settleVerdict(for draft: QuickRuleDraft? = nil) {
    verdictFallback?.cancel()
    verdictFallback = nil
    guard let app, let subject, let target,
          let draft = draft ?? FrontmostRoutePolicy.draft(for: subject, app: app, target: target)
    else { return }
    verdict = appModel.quickRuleVerdict(for: draft)
    if case .verifying = phase {
      phase = .done(alreadyPresent: false)
    }
  }

  // MARK: - Labels

  private func title(for subject: FrontmostRouteSubject, app: FrontmostAppSnapshot) -> String {
    switch subject {
    case .app:
      String(format: String(localized: "All of %@"), app.name)
    case let .site(host):
      host
    }
  }

  private func symbol(for subject: FrontmostRouteSubject) -> String {
    switch subject {
    case .app: "app"
    case .site: "globe"
    }
  }
}
