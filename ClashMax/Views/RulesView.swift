import AppKit
import SwiftUI

/// Column policy for the rules table. The payload is what a user reads a rule by, so on a narrow
/// page it keeps its room and the Provider column folds into the selected rule's detail line.
enum RulesLayout {
  static let providerColumnBreakpoint: CGFloat = 900

  static func showsProviderColumn(pageWidth: CGFloat, hasProviderRules: Bool) -> Bool {
    hasProviderRules && pageWidth.isFinite && pageWidth >= providerColumnBreakpoint
  }
}

struct RulesView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  @State private var searchText = ""
  @State private var quickRuleContext: QuickRuleSheetContext?
  @State private var selectedRuleIDs = Set<RuntimeRule.ID>()
  @State private var searchHelpPresented = false
  @State private var providersPresented = false
  @State private var pageWidth: CGFloat = 0

  init() {}

  /// Seeds the search and selection for previews and fixture renders; the app starts from the defaults.
  init(initialSearchText: String, initialSelection: Set<RuntimeRule.ID> = []) {
    _searchText = State(initialValue: initialSearchText)
    _selectedRuleIDs = State(initialValue: initialSelection)
  }

  var body: some View {
    let rules = filteredRules
    let selectedRules = rules.filter { selectedRuleIDs.contains($0.id) }
    AdaptivePage(title: "Rules") {
      EmptyView()
    } content: {
      if showsLoadingSkeleton {
        ClashMaxSkeletonTable(rows: 9)
      } else {
        VStack(alignment: .leading, spacing: 10) {
          ruleControls(selectedRules: selectedRules)

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
            let showsProviderColumn = RulesLayout.showsProviderColumn(
              pageWidth: pageWidth,
              hasProviderRules: rules.contains { $0.providerName != nil }
            )
            ruleTable(rules, showsProviderColumn: showsProviderColumn)

            if selectedRules.count == 1, let rule = selectedRules.first {
              selectedRuleDetail(rule, showsProvider: !showsProviderColumn)
            }

            PageStatusFooter(text: ruleSummary)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.width
        } action: { width in
          pageWidth = width
        }
      }
    }
    .onChange(of: rules.map(\.id)) { _, ids in
      selectedRuleIDs = selectedRuleIDs.intersection(Set(ids))
    }
    .quickRuleSheet($quickRuleContext)
  }

  /// The table keeps Mihomo's evaluation order: `#` is the runtime index, never a display sort.
  private func ruleTable(_ rules: [RuntimeRule], showsProviderColumn: Bool) -> some View {
    Table(rules, selection: $selectedRuleIDs) {
      TableColumn("#") { rule in
        Text("\(rule.index)")
          .font(.system(.callout, design: .monospaced))
          .foregroundStyle(.secondary)
      }
      .width(min: 44, ideal: 54, max: 64)

      TableColumn("Type") { rule in
        Text(rule.type.isEmpty ? "-" : rule.type)
          .lineLimit(1)
      }
      .width(min: 104, ideal: 124)

      TableColumn("Payload") { rule in
        Text(rule.payload.isEmpty ? "-" : rule.payload)
          .font(.system(.body, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
          .help(rule.payload)
      }

      TableColumn("Policy") { rule in
        Text(rule.policy.isEmpty ? "-" : rule.policy)
          .fontWeight(.medium)
          .lineLimit(1)
      }
      .width(min: 88, ideal: 120)

      if showsProviderColumn {
        TableColumn("Provider") { rule in
          Text(rule.providerName ?? "-")
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .width(min: 90, ideal: 120)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contextMenu(forSelectionType: RuntimeRule.ID.self) { ids in
      ruleMenu(for: rules.filter { ids.contains($0.id) })
    }
  }

  /// The full rule for the one selected row, so a payload the column truncated is still readable
  /// and the rule source stays reachable when its column is folded away on a narrow page.
  private func selectedRuleDetail(_ rule: RuntimeRule, showsProvider: Bool) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 12) {
      Text(verbatim: "#\(rule.index)")
        .font(.system(.callout, design: .monospaced))
        .foregroundStyle(.secondary)
      Text(rule.raw.isEmpty ? "-" : rule.raw)
        .font(.system(.callout, design: .monospaced))
        .textSelection(.enabled)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
      if showsProvider, let provider = rule.providerName, !provider.isEmpty {
        Spacer(minLength: 8)
        Text(String(format: String(localized: "Rule source: %@"), provider))
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
  }

  /// Issue #15 phase B1: the fix for a wrong route starts on the rule that caused it, not on
  /// another page. Everything here writes into the same "Quick Rules" snippet so Routing stays the
  /// one place rules live.
  @ViewBuilder
  private func ruleMenu(for selection: [RuntimeRule]) -> some View {
    if let rule = selection.first, selection.count == 1 {
      Button("Insert Rule Before This…") {
        quickRuleContext = QuickRuleSheetContext(
          title: "Insert Rule Before This",
          subtitle: String(
            format: String(localized: "Evaluated before rule #%lld: %@"),
            Int64(rule.index),
            rule.raw
          ),
          draft: .overriding(rule)
        )
      }

      let isDisabled = appModel.isDisabledByQuickRules(rule)
      Button(isDisabled ? "Enable This Rule" : "Disable This Rule") {
        Task { await appModel.setRuntimeRuleDisabled(rule, disabled: !isDisabled) }
      }
      .disabled(rule.raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

      Divider()

      Button("Copy Rule") { copy(rule.raw) }
      Button("Copy Payload") { copy(rule.payload) }
    } else if !selection.isEmpty {
      Button("Copy Rules") {
        copy(selection.map(\.raw).joined(separator: "\n"))
      }
    } else {
      Text("Select a rule")
    }
  }

  private func copy(_ text: String) {
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private var showsLoadingSkeleton: Bool {
    runtimeData.rules.isEmpty
      && appModel.profileStore.activeProfile != nil
      && (appModel.runtimeDataLoading || appModel.dashboardRuntimeState.isStarting)
  }

  /// Search first, then the rarely-needed entries: the query syntax lives behind a help button and
  /// rule providers open on demand instead of sitting above the table.
  private func ruleControls(selectedRules: [RuntimeRule]) -> some View {
    HStack(spacing: 10) {
      TextField("Search rules", text: $searchText)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 220, idealWidth: 360, maxWidth: 460)

      Button {
        searchHelpPresented = true
      } label: {
        Image(systemName: "questionmark.circle")
      }
      .buttonStyle(.borderless)
      .help("Search syntax")
      .accessibilityLabel("Search syntax")
      .popover(isPresented: $searchHelpPresented, arrowEdge: .bottom) {
        RuleSearchHelpPopover()
      }

      Spacer()

      if !runtimeData.ruleProviders.isEmpty {
        Button {
          providersPresented = true
        } label: {
          Label(
            String.localizedStringWithFormat(NSLocalizedString("Rule Sources (%lld)", comment: ""), Int64(runtimeData.ruleProviders.count)),
            systemImage: "shippingbox"
          )
        }
        .help("Rule providers loaded by the runtime, with update actions")
        .popover(isPresented: $providersPresented, arrowEdge: .bottom) {
          RuleProviderList(providers: runtimeData.ruleProviders)
            .environment(appModel)
            .environment(runtimeData)
        }
      }

      Menu {
        ruleMenu(for: selectedRules)
      } label: {
        Label("More", systemImage: "ellipsis.circle")
      }
      .help("Actions for the selected rule")
    }
  }

  private var ruleSummary: String {
    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return String.localizedStringWithFormat(
        NSLocalizedString("%lld rules", comment: ""),
        Int64(runtimeData.rules.count)
      )
    }
    return String.localizedStringWithFormat(
      NSLocalizedString("%lld of %lld", comment: ""),
      Int64(filteredRules.count),
      Int64(runtimeData.rules.count)
    )
  }

  private var filteredRules: [RuntimeRule] {
    let query = RuleSearchQuery(rawValue: searchText)
    guard !query.isEmpty else { return runtimeData.rules }
    return runtimeData.rules.filter { query.matches($0) }
  }
}

private struct RuleSearchHelpPopover: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Search Syntax")
        .font(.headline)
      Text("Plain words match the type, payload, policy and provider of a rule. Every word must match.")
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
        GridRow {
          Text(verbatim: "type=DOMAIN-SUFFIX")
            .font(.system(.callout, design: .monospaced))
          Text("Only rules of one type")
        }
        GridRow {
          Text(verbatim: "policy=DIRECT")
            .font(.system(.callout, design: .monospaced))
          Text("Only rules routed to one policy")
        }
        GridRow {
          Text(verbatim: "provider=name")
            .font(.system(.callout, design: .monospaced))
          Text("Only rules from one rule provider")
        }
      }
      .font(.callout)
    }
    .padding(14)
    .frame(width: 380)
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
        .compactMap(\.self)
        .joined(separator: " ")
        .localizedCaseInsensitiveContains(term)
    }
  }

  private func value(after prefix: String, in term: String) -> String {
    String(term.dropFirst(prefix.count))
  }
}

/// Rule providers, on demand. Updating a single provider or all of them stays here, with in-flight
/// and failure feedback, but the list no longer takes space away from the rules table.
private struct RuleProviderList: View {
  @Environment(AppModel.self) private var appModel
  @Environment(RuntimeDataStore.self) private var runtimeData
  let providers: [RuleProvider]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Label("Rule Providers", systemImage: "list.bullet.rectangle")
          .font(.headline)
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

      List(providers) { provider in
        HStack(spacing: 10) {
          VStack(alignment: .leading, spacing: 2) {
            Text(provider.name)
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
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "arrow.clockwise")
            }
          }
          .buttonStyle(.borderless)
          .disabled(!appModel.canControlRuntimeProxies || runtimeData.ruleProviderUpdatesInFlight.contains(provider.id))
          .help("Update rule provider")
          .accessibilityLabel("Update rule provider \(provider.name)")
        }
        .padding(.vertical, 2)
      }
      .listStyle(.inset)
      // Sized to the providers it lists (capped), so a dozen sources do not squeeze into three rows.
      .frame(height: min(CGFloat(max(providers.count, 1)) * 44 + 12, 320))

      if !appModel.canControlRuntimeProxies {
        Text("Provider updates need a running core.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let error = appModel.lastError,
         PageErrorPresentation.showsInlineError(readinessIssue: appModel.readinessIssue, hasDetails: false)
      {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .lineLimit(3)
          .textSelection(.enabled)
      }
    }
    .padding(14)
    .frame(width: 480)
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
      provider.ruleCount.map { String.localizedStringWithFormat(NSLocalizedString("%lld rules", comment: ""), Int64($0)) },
    ]
    .compactMap(\.self)
    .filter { !$0.isEmpty }
    .joined(separator: " - ")
  }
}
