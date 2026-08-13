import SwiftUI

/// Add one rule from wherever the user noticed the problem, instead of navigating to Routing and
/// building a snippet by hand.
///
/// Issue #15 phase B: the distance between "this connection is taking the wrong route" and "there
/// is now a rule fixing it" was a page change, a snippet, a payload-kind choice and a form. This
/// sheet is that path collapsed — prefilled from the row it was opened on, committed through the
/// same snippet apply path as everything else, and then checked, so it also answers the question
/// that made issue #15 worth filing: did the rule actually take effect.
struct QuickRuleSheet: View {
  @Environment(AppModel.self) private var appModel
  @Environment(ProfileStore.self) private var profileStore
  @Environment(RuntimeSnippetLibraryStore.self) private var snippetLibrary
  @Environment(RuntimeDataStore.self) private var runtimeData
  @Environment(\.dismiss) private var dismiss

  private let title: LocalizedStringKey
  private let subtitle: String
  @State private var draft: QuickRuleDraft
  @State private var phase = Phase.editing
  @State private var errorMessage: String?
  @State private var verdict: QuickRuleVerdict?
  @State private var verdictFallback: Task<Void, Never>?

  init(title: LocalizedStringKey, subtitle: String, draft: QuickRuleDraft) {
    self.title = title
    self.subtitle = subtitle
    _draft = State(initialValue: draft)
  }

  private enum Phase: Equatable {
    case editing
    case applying
    /// Applied and reloaded, but the rule list has not been read back yet, so there is nothing
    /// truthful to say about what matches. Shown as "checking" rather than guessed at.
    case verifying
    case done(alreadyPresent: Bool)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      switch phase {
      case .editing, .applying:
        editor
      case .verifying, .done:
        appliedSummary
      }

      if let errorMessage {
        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()
      footer
    }
    .padding(18)
    .frame(width: 460)
    .onDisappear {
      verdictFallback?.cancel()
      verdictFallback = nil
    }
    .onChange(of: runtimeData.rules) { _, _ in
      // The reload publishes before the rule list is refetched, so the verdict is computed on the
      // first list that arrives afterwards rather than on the stale one.
      guard phase == .verifying else { return }
      settleVerdict()
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title)
        .font(.headline)
      Text(subtitle)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var editor: some View {
    VStack(alignment: .leading, spacing: 12) {
      LabeledContent("Type") {
        Picker("Type", selection: $draft.rule.kind) {
          ForEach(ManagedRuleOverlayRule.Kind.allCases) { kind in
            Text(kind.displayName).tag(kind)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }

      if draft.rule.kind.requiresValue {
        LabeledContent("Value") {
          TextField(draft.rule.kind.valuePlaceholder, text: $draft.rule.value)
            .textFieldStyle(.roundedBorder)
        }
      }

      LabeledContent("Policy") {
        HStack(spacing: 6) {
          TextField(draft.rule.kind.policyPlaceholder, text: $draft.rule.policy)
            .textFieldStyle(.roundedBorder)
          Menu {
            ForEach(policySuggestions, id: \.self) { policy in
              Button(policy) { draft.rule.policy = policy }
            }
          } label: {
            Image(systemName: "list.bullet")
          }
          .menuStyle(.borderlessButton)
          .fixedSize()
          .disabled(policySuggestions.isEmpty)
          .help("Choose a policy group or built-in outbound")
          .accessibilityLabel("Choose a policy")
        }
      }

      if draft.rule.kind.allowsNoResolve {
        Toggle("Match without resolving DNS (no-resolve)", isOn: $draft.rule.noResolve)
          .toggleStyle(.checkbox)
      }

      LabeledContent("Placement") {
        Picker("Placement", selection: $draft.placement) {
          ForEach(QuickRulePlacement.allCases) { placement in
            Text(placement.displayName).tag(placement)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)
      }
      Text(draft.placement.explanation)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      rulePreview

      Label(appModel.runtimeApplyMode(for: .rules).pendingSummary, systemImage: "bolt.horizontal.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var rulePreview: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Rule Line")
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(draft.runtimeRule)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: SurfaceRadius.shape(SurfaceRadius.tile))
      Text("Saved in the \"Quick Rules\" snippet, where Routing can edit, reorder or remove it.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private var appliedSummary: some View {
    VStack(alignment: .leading, spacing: 12) {
      if case .done(true) = phase {
        Label("This rule was already in Quick Rules, so nothing was changed.", systemImage: "checkmark.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        RuntimeApplyOutcomeBanner()
      }

      rulePreview
      verdictSection
    }
  }

  /// The point of phase B3: after applying, say what the rule actually does now — including the
  /// case that matters most, a rule that is live but loses to something earlier in the list.
  private var verdictSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Effect")
        .font(.caption2)
        .foregroundStyle(.tertiary)

      if phase == .verifying {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text("Checking which rule matches now…")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      } else if let verdict {
        Label {
          VStack(alignment: .leading, spacing: 2) {
            Text(verdict.title)
              .font(.callout.weight(.semibold))
            Text(verdict.detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let probe = verdict.probeSummary {
              Text(probe)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        } icon: {
          Image(systemName: verdict.systemImage)
            .foregroundStyle(verdict.tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(verdict.tint.opacity(0.10), in: SurfaceRadius.shape(SurfaceRadius.tile))
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 10) {
      if case .done = phase {
        Button("Open in Routing") {
          appModel.selectedSection = .routing
          dismiss()
        }
        Spacer()
        Button("Done") { dismiss() }
          .keyboardShortcut(.defaultAction)
      } else {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button {
          apply()
        } label: {
          if phase == .applying {
            ProgressView().controlSize(.small)
          } else {
            Text("Add Rule")
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(phase == .applying || draft.validationError != nil)
      }
    }
  }

  private var policySuggestions: [String] {
    var seen = Set<String>()
    var suggestions: [String] = []
    for name in runtimeData.proxyGroups.map(\.name) + ["DIRECT", "REJECT", "REJECT-DROP", "PASS"]
      where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      if seen.insert(name.uppercased()).inserted {
        suggestions.append(name)
      }
    }
    return suggestions
  }

  private func apply() {
    errorMessage = nil
    if let validationError = draft.validationError {
      errorMessage = validationError
      return
    }
    // An identical rule already in place would reload the core to change nothing, and the apply
    // path would then report it as a next-start change — true of the write, misleading about the
    // rule. Skip straight to verifying what is already there.
    if appModel.quickRuleIsAlreadyActive(draft) {
      phase = .done(alreadyPresent: true)
      settleVerdict()
      return
    }
    phase = .applying
    Task { @MainActor in
      let didApply = await appModel.addQuickRule(draft)
      guard didApply else {
        errorMessage = appModel.lastError ?? String(localized: "The rule could not be applied.")
        phase = .editing
        return
      }
      if appModel.lastRuntimeApplyOutcome == .applied(.rules) {
        phase = .verifying
        scheduleVerdictFallback()
      } else {
        phase = .done(alreadyPresent: false)
        settleVerdict()
      }
    }
  }

  /// A reload that never produces a refreshed rule list would otherwise leave "checking" on screen
  /// forever, so the verdict is computed from whatever is known after a bounded wait.
  private func scheduleVerdictFallback() {
    verdictFallback?.cancel()
    verdictFallback = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, phase == .verifying else { return }
      settleVerdict()
    }
  }

  private func settleVerdict() {
    verdictFallback?.cancel()
    verdictFallback = nil
    verdict = computeVerdict()
    if case .verifying = phase {
      phase = .done(alreadyPresent: false)
    }
  }

  private func computeVerdict() -> QuickRuleVerdict {
    guard let input = draft.verificationInput else { return .unavailable }
    let trace = RuleMatchSimulator().simulate(input: input, candidateProvider: effectiveRuleCandidates)
    let probe = QuickRuleVerdict.probeDescription(for: input)
    switch trace.outcome {
    case let .matched(rule):
      return draft.describes(rule) ? .winning(rule, probe: probe) : .shadowed(rule, probe: probe)
    case let .mihomoOnly(reason):
      return .mihomoOnly(reason, probe: probe)
    case .noMatch:
      return .noMatch(probe: probe)
    }
  }

  /// The same rule list the Routing simulator evaluates, so the two pages never disagree about
  /// what matches: the running core's own list when there is one, the composed overlay preview
  /// otherwise.
  private func effectiveRuleCandidates() -> [RuntimeRuleCandidate] {
    if appModel.isCoreRunning || !runtimeData.rules.isEmpty {
      return RuntimeRuleCandidateBuilder.runtimeCandidates(runtimeRules: runtimeData.rules)
    }
    let activeSnippets = profileStore.activeProfileID.map { snippetLibrary.snippets(applyingTo: $0) } ?? []
    let activeProfile = profileStore.activeProfile
    return RuntimeRuleCandidateBuilder.candidates(
      globalOverlay: appModel.ruleOverlaySettings,
      profileOverlay: activeProfile?.isSubscription == true
        ? activeProfile?.subscriptionProviderOptions.ruleOverlay ?? .disabled
        : .disabled,
      snippetOverlay: RuntimeSnippetApplication(snippets: activeSnippets).ruleOverlay,
      runtimeRules: runtimeData.rules
    )
  }
}

/// What the rule the user just added actually does, once the rule list it joined is known.
enum QuickRuleVerdict: Equatable {
  /// The rule's own match cannot be reproduced outside Mihomo, so no claim is made either way.
  case unavailable
  case winning(RuntimeRule, probe: String?)
  case shadowed(RuntimeRule, probe: String?)
  case mihomoOnly(String, probe: String?)
  case noMatch(probe: String?)

  var title: String {
    switch self {
    case .unavailable:
      return String(localized: "Cannot be checked here")
    case .winning:
      return String(localized: "Your rule is the one that matches")
    case .shadowed:
      return String(localized: "An earlier rule wins")
    case .mihomoOnly:
      return String(localized: "Decided inside Mihomo")
    case .noMatch:
      return String(localized: "Nothing matched")
    }
  }

  var detail: String {
    switch self {
    case .unavailable:
      return String(localized: "This rule type is matched by Mihomo itself, so ClashMax cannot confirm it locally.")
    case let .winning(rule, _):
      return String(
        format: String(localized: "Rule #%lld is yours, and it routes to %@."),
        Int64(rule.index),
        rule.policy.isEmpty ? "-" : rule.policy
      )
    case let .shadowed(rule, _):
      return String(
        format: String(localized: "Rule #%lld matches first and routes to %@: %@. Reorder it in Routing, or narrow that rule, for yours to take effect."),
        Int64(rule.index),
        rule.policy.isEmpty ? "-" : rule.policy,
        rule.raw
      )
    case let .mihomoOnly(reason, _):
      return reason
    case .noMatch:
      return String(localized: "No rule matched the probe, so the rule is stored but was not reached.")
    }
  }

  var probeSummary: String? {
    switch self {
    case .unavailable:
      return nil
    case let .winning(_, probe),
         let .shadowed(_, probe),
         let .mihomoOnly(_, probe),
         let .noMatch(probe):
      return probe
    }
  }

  var systemImage: String {
    switch self {
    case .unavailable:
      return "questionmark.circle.fill"
    case .winning:
      return "checkmark.seal.fill"
    case .shadowed:
      return "exclamationmark.triangle.fill"
    case .mihomoOnly:
      return "gearshape.2.fill"
    case .noMatch:
      return "circle.slash"
    }
  }

  var tint: Color {
    switch self {
    case .winning:
      return .green
    case .shadowed:
      return .orange
    case .unavailable, .mihomoOnly, .noMatch:
      return .secondary
    }
  }

  /// Names the input the verdict was reached with, so the answer is never mistaken for a claim
  /// about live traffic — it is a simulation over the current rule list.
  static func probeDescription(for input: RuleMatchSimulationInput) -> String? {
    let fields: [(String, String)] = [
      (String(localized: "destination"), input.destination),
      (String(localized: "source IP"), input.sourceIP),
      (String(localized: "destination port"), input.destinationPort),
      (String(localized: "source port"), input.sourcePort),
      (String(localized: "inbound port"), input.inboundPort),
      (String(localized: "process"), input.process),
    ]
    let described = fields
      .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
      .map { "\($0.0) \($0.1)" }
    guard !described.isEmpty else { return nil }
    return String(
      format: String(localized: "Simulated against the current rule list with %@."),
      described.joined(separator: ", ")
    )
  }
}

/// Carries the prefill from whichever row the sheet was opened on.
struct QuickRuleSheetContext: Identifiable {
  let id = UUID()
  var title: LocalizedStringKey
  var subtitle: String
  var draft: QuickRuleDraft
}

extension View {
  func quickRuleSheet(_ context: Binding<QuickRuleSheetContext?>) -> some View {
    sheet(item: context) { context in
      QuickRuleSheet(title: context.title, subtitle: context.subtitle, draft: context.draft)
    }
  }
}
