import Foundation
import SwiftUI
import Yams

struct ProfilesView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var profileCoordinator: ProfileCoordinator
  @EnvironmentObject private var providerAnalytics: ProviderAnalyticsStore
  @State private var subscriptionURL = ""
  @State private var profileBeingEdited: Profile?
  @State private var providerInsightsProfile: Profile?
  @State private var editProfileName = ""
  @State private var editSubscriptionURL = ""
  @State private var editProviderOptions = SubscriptionProviderOptions.default
  @State private var editRollbackProviderOptions = SubscriptionProviderOptions.default
  @State private var editUpdatePolicy = SubscriptionUpdatePolicy.default
  @State private var profilePendingDeletion: Profile?
  @State private var migrationReport: ClientMigrationReport?

  var body: some View {
    AdaptivePage(
      title: "Profiles",
      subtitle: profilesSubtitle
    ) {
      Button {
        appModel.updateDueSubscriptions()
      } label: {
        Label("Update Due", systemImage: "clock.arrow.circlepath")
      }
      .disabled(!profileStore.profiles.contains(where: \.isSubscription))

      Button {
        appModel.updateAllSubscriptions()
      } label: {
        Label("Update All", systemImage: "arrow.triangle.2.circlepath.circle")
      }
      .disabled(!profileStore.profiles.contains(where: \.isSubscription))

      Button {
        appModel.importLocalProfile()
      } label: {
        Label("Import YAML", systemImage: "square.and.arrow.down")
      }

      Button {
        importClientMigration()
      } label: {
        Label("Import Client", systemImage: "arrow.triangle.branch")
      }
    } content: {
      VStack(alignment: .leading, spacing: 14) {
        subscriptionControls

        if profileStore.profiles.isEmpty {
          CenteredUnavailableState(
            title: "No profiles",
            systemImage: "doc.badge.plus",
            message: "Profiles stay unchanged on disk; ClashMax generates a runtime copy when starting."
          )
        } else {
          ScrollView {
            LazyVGrid(columns: profileGridColumns, alignment: .leading, spacing: 12) {
              ForEach(profileStore.profiles) { profile in
                ProfileCard(
                  profile: profile,
                  isActive: profileStore.activeProfileID == profile.id,
                  isUpdating: profileCoordinator.updatingProfileIDs.contains(profile.id),
                  sourceURLString: profileStore.subscriptionURLString(for: profile),
                  selectAction: { appModel.selectProfile(profile) },
                  editAction: { beginEditing(profile) },
                  providerInsightsAction: { providerInsightsProfile = profile },
                  updateAction: {
                    Task { @MainActor in
                      await appModel.updateSubscription(profile)
                    }
                  },
                  deleteAction: { profilePendingDeletion = profile }
                )
              }
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .topLeading)
          }
        }

        if let message = profileCoordinator.message {
          Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
            .lineLimit(2)
        }

        if let error = appModel.lastError {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .lineLimit(3)
        }
      }
    }
    .sheet(item: $profileBeingEdited) { profile in
      ProfileEditSheet(
        profile: currentProfile(matching: profile) ?? profile,
        name: $editProfileName,
        subscriptionURL: $editSubscriptionURL,
        providerOptions: $editProviderOptions,
        rollbackProviderOptions: editRollbackProviderOptions,
        updatePolicy: $editUpdatePolicy,
        subscriptionDefaultUpdateIntervalMinutes: appModel.settings.subscriptionFetchSettings.defaultUpdateIntervalMinutes,
        developerMode: appModel.developerMode,
        onCancel: closeEditSheet,
        onResetRemoteName: {
          resetRemoteName(profile)
        },
        onRollbackProviderOptions: {
          editProviderOptions = editRollbackProviderOptions
        },
        onSave: {
          saveProfileEdits(profile)
        }
      )
    }
    .sheet(item: $providerInsightsProfile) { profile in
      let resolvedProfile = currentProfile(matching: profile) ?? profile
      ProfileProviderInsightsSheet(
        profile: resolvedProfile,
        isActive: profileStore.activeProfileID == resolvedProfile.id,
        summary: providerInsightsSummary(for: resolvedProfile),
        onClose: { providerInsightsProfile = nil }
      )
    }
    .alert("Delete Profile?", isPresented: deleteConfirmationPresented) {
      Button("Delete", role: .destructive) {
        confirmDeleteProfile()
      }
      Button("Cancel", role: .cancel) {
        profilePendingDeletion = nil
      }
    } message: {
      Text("Remove \(profilePendingDeletion?.name ?? "this profile") from ClashMax. Stored subscription metadata and the app-managed profile copy will be deleted.")
    }
    .sheet(isPresented: migrationReportPresented) {
      if let migrationReport {
        ClientMigrationReportSheet(
          report: migrationReport,
          developerMode: appModel.developerMode,
          onCancel: { self.migrationReport = nil },
          onApply: { options in applyMigrationReport(migrationReport, options: options) }
        )
        .frame(width: 720)
        .padding(20)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .clashMaxImportClashXRequested)) { _ in
      importClientMigration()
    }
  }

  private var profilesSubtitle: String {
    let count = profileStore.profiles.count
    if count == 0 {
      return String(localized: "Import a local YAML file or add a subscription.")
    }
    if count == 1 {
      return String(localized: "1 profile")
    }
    return String.localizedStringWithFormat(NSLocalizedString("%lld profiles", comment: ""), Int64(count))
  }

  private var subscriptionControls: some View {
    GroupBox("Subscription") {
      VStack(alignment: .leading, spacing: 8) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) {
            subscriptionField
            addSubscriptionButton
          }

          VStack(alignment: .leading, spacing: 10) {
            subscriptionField
            addSubscriptionButton
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if profileCoordinator.isAddingSubscription {
          subscriptionLoadingIndicator
        }
      }
      .animation(.easeInOut(duration: 0.16), value: profileCoordinator.isAddingSubscription)
    }
  }

  private var subscriptionField: some View {
    TextField("Subscription URL", text: $subscriptionURL)
      .textFieldStyle(.roundedBorder)
      .frame(minWidth: 320)
      .disabled(profileCoordinator.isAddingSubscription)
  }

  private var addSubscriptionButton: some View {
    Button {
      let urlString = subscriptionURL
      Task { @MainActor in
        let didAdd = await appModel.addSubscription(urlString: urlString)
        if didAdd {
          subscriptionURL = ""
        }
      }
    } label: {
      HStack(spacing: 6) {
        if profileCoordinator.isAddingSubscription {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: "plus")
        }
        Text(profileCoordinator.isAddingSubscription ? "Adding" : "Add")
      }
      .frame(minWidth: 64)
    }
    .disabled(subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || profileCoordinator.isAddingSubscription)
  }

  private var profileGridColumns: [GridItem] {
    [
      GridItem(
        .adaptive(minimum: 280, maximum: 360),
        spacing: 12,
        alignment: .topLeading
      )
    ]
  }

  private var subscriptionLoadingIndicator: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Fetching and validating subscription...")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
    .transition(.opacity)
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { profilePendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          profilePendingDeletion = nil
        }
      }
    )
  }

  private var migrationReportPresented: Binding<Bool> {
    Binding(
      get: { migrationReport != nil },
      set: { isPresented in
        if !isPresented {
          migrationReport = nil
        }
      }
    )
  }

  private func confirmDeleteProfile() {
    guard let profile = profilePendingDeletion else { return }
    profilePendingDeletion = nil
    appModel.deleteProfile(profile)
  }

  private func beginEditing(_ profile: Profile) {
    editProfileName = profile.name
    editSubscriptionURL = profileStore.subscriptionURLString(for: profile) ?? ""
    editProviderOptions = profile.subscriptionProviderOptions
    editRollbackProviderOptions = profile.subscriptionProviderOptions
    editUpdatePolicy = profile.subscriptionUpdatePolicy
    profileBeingEdited = profile
  }

  private func closeEditSheet() {
    profileBeingEdited = nil
    editProfileName = ""
    editSubscriptionURL = ""
    editProviderOptions = .default
    editRollbackProviderOptions = .default
    editUpdatePolicy = .default
  }

  private func providerInsightsSummary(for profile: Profile) -> ProviderAnalyticsProfileSummary {
    let isActive = profileStore.activeProfileID == profile.id
    return providerAnalytics.summary(
      profileID: profile.id,
      profileTraffic: profile.subscriptionMetadata?.traffic,
      currentProxyProviders: isActive ? appModel.proxyProviders : nil,
      currentRuleProviders: isActive ? appModel.ruleProviders : nil
    )
  }

  private func currentProfile(matching profile: Profile) -> Profile? {
    profileStore.profiles.first { $0.id == profile.id }
  }

  private func saveProfileEdits(_ profile: Profile) {
    let trimmedName = editProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else { return }
    let trimmedURL = editSubscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
    let originalURL = profileStore.subscriptionURLString(for: profile)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let nextProviderOptions = editProviderOptions
    let nextUpdatePolicy = editUpdatePolicy

    Task { @MainActor in
      var workingProfile = currentProfile(matching: profile) ?? profile
      let providerOptionsChanged = workingProfile.subscriptionProviderOptions != nextProviderOptions
      let updatePolicyChanged = workingProfile.subscriptionUpdatePolicy != nextUpdatePolicy
      let subscriptionURLChanged = workingProfile.isSubscription && trimmedURL != originalURL

      if workingProfile.isSubscription, providerOptionsChanged, subscriptionURLChanged {
        guard await appModel.updateSubscriptionSourceAndProviderOptions(
          workingProfile,
          urlString: trimmedURL,
          options: nextProviderOptions
        ) else { return }
        workingProfile = currentProfile(matching: workingProfile) ?? workingProfile
      } else if workingProfile.isSubscription, providerOptionsChanged {
        guard await appModel.updateSubscriptionProviderOptions(workingProfile, options: nextProviderOptions) else { return }
        workingProfile = currentProfile(matching: workingProfile) ?? workingProfile
      } else if subscriptionURLChanged {
        guard await appModel.updateSubscriptionSource(workingProfile, urlString: trimmedURL) else { return }
        workingProfile = currentProfile(matching: workingProfile) ?? workingProfile
      }

      if workingProfile.isSubscription, updatePolicyChanged {
        guard await appModel.updateSubscriptionPolicy(workingProfile, policy: nextUpdatePolicy) else { return }
        workingProfile = currentProfile(matching: workingProfile) ?? workingProfile
      }

      if workingProfile.name != trimmedName {
        guard await appModel.renameProfileAsync(workingProfile, to: trimmedName) else { return }
      }
      closeEditSheet()
    }
  }

  private func resetRemoteName(_ profile: Profile) {
    Task { @MainActor in
      guard await appModel.resetSubscriptionName(profile) else { return }
      if let updated = currentProfile(matching: profile) {
        editProfileName = updated.name
      }
    }
  }

  private func importClientMigration() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Inspect"
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    migrationReport = ClientMigrationParser().parse(directoryURL: url)
  }

  private func applyMigrationReport(_ report: ClientMigrationReport, options: ClientMigrationApplyOptions) {
    migrationReport = nil
    Task { @MainActor in
      var migratedProfileIDs: [String: Profile.ID] = [:]

      if options.importLocalProfiles {
        for candidate in report.localProfiles {
          do {
            let profile = try await profileCoordinator.importLocalProfile(from: URL(fileURLWithPath: candidate.filePath))
            migratedProfileIDs[candidate.id] = profile.id
          } catch {
            appModel.lastError = UserFacingError.message(for: error)
          }
        }
      }

      if options.importRemoteSubscriptions {
        for candidate in report.subscriptions {
          var importedProviderOptions = candidate.providerOptions
          if options.importRuleSnippets {
            importedProviderOptions = self.providerOptionsByApplyingRuleSnippets(
              importedProviderOptions,
              applyingRuleSnippets: report.ruleSnippets.filter { $0.profileSourceID == candidate.id }
            )
          }
          _ = await appModel.addSubscription(
            name: candidate.name,
            urlString: candidate.urlString,
            providerOptions: importedProviderOptions,
            updatePolicy: candidate.updatePolicy
          )
        }
      } else if report.subscriptions.isEmpty {
        for subscriptionURL in report.subscriptionURLs {
          _ = await appModel.addSubscription(urlString: subscriptionURL)
        }
      }

      if options.importRuleSnippets {
        await saveMigrationRuleSnippets(
          report.ruleSnippets,
          subscriptionSourceIDs: Set(report.subscriptions.map(\.id)),
          migratedProfileIDs: migratedProfileIDs
        )
      }

      applyMigrationRuntimeSettings(report, enableSystemProxy: options.enableSystemProxy)
      if options.importShortcuts, appModel.developerMode {
        applyMigrationShortcutSettings(report.shortcutBindings)
      }
      if options.enableSilentStart {
        appModel.setSilentStart(true)
      }
    }
  }

  private func applyMigrationRuntimeSettings(_ report: ClientMigrationReport, enableSystemProxy: Bool) {
    if let mixedPort = report.ports["mixed-port"] ?? report.ports["port"] {
      let normalizedPort = min(max(mixedPort, 1), 65_535)
      appModel.setMixedPort(normalizedPort)
    }

    if let allowLan = report.allowLan {
      appModel.setAllowLAN(allowLan)
    }

    if let mode = report.mode.flatMap(RunMode.init(rawValue:)) {
      appModel.setMode(mode)
    }

    if let logLevel = report.logLevel {
      appModel.setLogLevel(logLevel)
    }

    if !report.bypassDomains.isEmpty {
      var settings = appModel.systemProxySettings
      settings.customBypassDomains = SystemProxySettings.normalizedBypassDomains(
        settings.customBypassDomains + report.bypassDomains
      )
      appModel.systemProxySettings = settings
    }

    if enableSystemProxy, report.systemProxyEnabled == true {
      appModel.setSystemProxyEnabled(true)
    }
  }

  private func applyMigrationShortcutSettings(_ bindings: [MigratedShortcutBinding]) {
    guard appModel.developerMode else { return }
    guard !bindings.isEmpty else { return }
    var settings = appModel.globalShortcutSettings
    for binding in bindings {
      settings.set(binding.shortcut, for: binding.action, enabled: true)
    }
    appModel.globalShortcutSettings = settings
  }

  private func providerOptionsByApplyingRuleSnippets(
    _ providerOptions: SubscriptionProviderOptions,
    applyingRuleSnippets snippets: [MigratedRuleSnippetCandidate]
  ) -> SubscriptionProviderOptions {
    var result = providerOptions
    for snippet in snippets {
      result.ruleOverlay = mergedRuleOverlay(result.ruleOverlay, with: snippet.settings)
    }
    return result
  }

  private func mergedRuleOverlay(_ base: RuleOverlaySettings, with addition: RuleOverlaySettings) -> RuleOverlaySettings {
    RuleOverlaySettings(
      enabled: base.enabled || addition.enabled,
      prependRules: base.prependRules + addition.prependRules,
      appendRules: base.appendRules + addition.appendRules,
      disabledRuleMatchers: base.disabledRuleMatchers + addition.disabledRuleMatchers
    )
  }

  private func saveMigrationRuleSnippets(
    _ snippets: [MigratedRuleSnippetCandidate],
    subscriptionSourceIDs: Set<String>,
    migratedProfileIDs: [String: Profile.ID]
  ) async {
    for candidate in snippets {
      if let profileSourceID = candidate.profileSourceID,
         subscriptionSourceIDs.contains(profileSourceID) {
        continue
      }
      let binding: RuntimeSnippetBinding
      if let profileSourceID = candidate.profileSourceID {
        guard let profileID = migratedProfileIDs[profileSourceID] else { continue }
        binding = .profiles([profileID])
      } else {
        binding = .allProfiles
      }
      let snippet = RuntimeSnippet(
        name: candidate.name,
        binding: binding,
        payload: .rules(candidate.settings)
      )
      _ = await appModel.saveRuntimeSnippet(snippet)
    }
  }
}

private struct ClientMigrationApplyOptions {
  var importLocalProfiles: Bool
  var importRemoteSubscriptions: Bool
  var importRuleSnippets: Bool
  var enableSystemProxy: Bool
  var importShortcuts: Bool
  var enableSilentStart: Bool
}

private struct ClientMigrationReportSheet: View {
  let report: ClientMigrationReport
  let developerMode: Bool
  let onCancel: () -> Void
  let onApply: (ClientMigrationApplyOptions) -> Void
  @State private var importLocalProfiles = true
  @State private var importRemoteSubscriptions = true
  @State private var importRuleSnippets = true
  @State private var enableSystemProxy = false
  @State private var importShortcuts = false
  @State private var enableSilentStart = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label(report.client.reportTitle, systemImage: "arrow.triangle.branch")
        .font(.title3.weight(.semibold))

      Text(report.configDirectory)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          migrationSection("Source", values: sourceValues)
          migrationSection("Profiles", values: profileValues)
          migrationSection("Subscriptions", values: subscriptionValues)
          migrationSection("Rule Snippets", values: ruleSnippetValues)
          migrationSection("Runtime", values: runtimeValues)
          migrationSection("Conflicts", values: report.conflicts)
          unsupportedMappingSection
          migrationSection("Warnings", values: warningValues)
          migrationSection("Inspected Files", values: report.inspectedFiles)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 520)

      Toggle("Import local profiles", isOn: $importLocalProfiles)
        .toggleStyle(.checkbox)
        .disabled(report.localProfiles.isEmpty)

      Toggle("Import remote subscriptions as ClashMax subscription/provider-backed profiles", isOn: $importRemoteSubscriptions)
        .toggleStyle(.checkbox)
        .disabled(report.subscriptions.isEmpty)

      Toggle("Import rule snippets", isOn: $importRuleSnippets)
        .toggleStyle(.checkbox)
        .disabled(report.ruleSnippets.isEmpty)

      Toggle("Enable System Proxy after import", isOn: $enableSystemProxy)
        .toggleStyle(.checkbox)
        .disabled(report.systemProxyEnabled != true)
        .help("ClashMax only enables System Proxy during migration when this checkbox is selected.")

      Toggle("Import global shortcuts", isOn: $importShortcuts)
        .toggleStyle(.checkbox)
        .disabled(!developerMode || report.shortcutBindings.isEmpty)
        .help("Map ClashX shortcut and hotkey settings to ClashMax global shortcuts.")

      Toggle("Enable Silent Start for menu bar workflow", isOn: $enableSilentStart)
        .toggleStyle(.checkbox)
        .disabled(!report.menuBarMigrationSuggested)
        .help("Use the existing ClashMax menu bar extra and hide the main window on login start.")

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Apply") {
          onApply(
            ClientMigrationApplyOptions(
              importLocalProfiles: importLocalProfiles && !report.localProfiles.isEmpty,
              importRemoteSubscriptions: importRemoteSubscriptions && !report.subscriptions.isEmpty,
              importRuleSnippets: importRuleSnippets && !report.ruleSnippets.isEmpty,
              enableSystemProxy: enableSystemProxy,
              importShortcuts: developerMode && importShortcuts,
              enableSilentStart: enableSilentStart
            )
          )
        }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var sourceValues: [String] {
    [
      "Client: \(report.client.displayName)",
      "Directory: \(report.configDirectory)"
    ]
  }

  private var profileValues: [String] {
    report.localProfiles.map { candidate in
      "\(candidate.name.isEmpty ? candidate.source : candidate.name): \(candidate.source)"
    }
  }

  private var subscriptionValues: [String] {
    let candidates = report.subscriptions.map { candidate in
      let name = candidate.name.isEmpty ? "Subscription" : candidate.name
      let updateState = candidate.updatePolicy.automaticUpdatesEnabled ? "auto update" : "manual update"
      return "\(name): \(candidate.urlString) (\(updateState), \(candidate.providerOptions.fetchProxy.displayName))"
    }
    return candidates.isEmpty ? report.subscriptionURLs : candidates
  }

  private var ruleSnippetValues: [String] {
    report.ruleSnippets.map { candidate in
      let binding = candidate.profileSourceID == nil ? "all profiles" : "bound profile"
      return "\(candidate.name): \(candidate.settings.summary), \(binding)"
    }
  }

  private var runtimeValues: [String] {
    [
      report.allowLan.map { "allow-lan: \($0)" },
      report.mode.map { "mode: \($0)" },
      report.logLevel.map { "log-level: \($0)" },
      report.systemProxyEnabled.map { "system proxy intent: \($0)" },
      report.ports.isEmpty ? nil : report.ports.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "),
      report.bypassDomains.isEmpty ? nil : "bypass: \(report.bypassDomains.joined(separator: ", "))",
      shortcutValues.isEmpty ? nil : "shortcuts: \(shortcutValues.joined(separator: ", "))"
    ]
    .compactMap { $0 }
  }

  private var shortcutValues: [String] {
    report.shortcutBindings.map { binding in
      "\(binding.sourceKey): \(binding.action.displayName) \(binding.shortcut.displayName)"
    }
  }

  private var warningValues: [String] {
    report.warnings
      + report.duplicateSubscriptionURLs.map { "Duplicate subscription: \($0)" }
      + report.unknownKeys.map { "Unknown key: \($0)" }
  }

  private var unsupportedMappingSection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("Unsupported")
        .font(.headline)
      if report.unsupportedMappings.isEmpty, report.unsupportedSettings.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
          GridRow {
            Text("Source")
            Text("Field")
            Text("ClashMax handling")
            Text("Action")
          }
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          ForEach(unsupportedRows) { row in
            GridRow {
              Text(row.source)
              Text(row.field)
              Text(row.handling)
              Text(row.action)
            }
            .font(.caption)
          }
        }
      }
    }
  }

  private var unsupportedRows: [MigrationUnsupportedMapping] {
    if !report.unsupportedMappings.isEmpty {
      return report.unsupportedMappings
    }
    return report.unsupportedSettings.enumerated().map { index, value in
      MigrationUnsupportedMapping(
        id: "legacy-unsupported-\(index)",
        source: value,
        field: value,
        handling: "Not imported",
        action: "report only"
      )
    }
  }

  private func migrationSection(_ title: String, values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(LocalizedStringKey(title))
        .font(.headline)
      if values.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach(values, id: \.self) { value in
          Text(value)
            .font(.caption)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
    }
  }
}

private struct ProfileCard: View {
  let profile: Profile
  let isActive: Bool
  let isUpdating: Bool
  let sourceURLString: String?
  let selectAction: () -> Void
  let editAction: () -> Void
  let providerInsightsAction: () -> Void
  let updateAction: () -> Void
  let deleteAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      titleBlock

      ProfileMetricsRow(profile: profile)

      Spacer(minLength: 4)

      actionButtons
    }
    .padding(12)
    .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
    .dashboardCard(interactive: true)
    .overlay(alignment: .leading) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(isActive ? Color.accentColor : Color.clear)
        .frame(width: 3)
        .padding(.vertical, 8)
    }
    .contentShape(Rectangle())
    .onTapGesture(perform: selectAction)
  }

  private var titleBlock: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(profile.name)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.76)
        if isActive {
          Text("Active")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: Capsule())
        }
      }

      Text(sourceLine)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
  }

  private var actionButtons: some View {
    HStack(spacing: 8) {
      Button {
        editAction()
      } label: {
        Label("Edit", systemImage: "pencil")
      }
      .help("Edit profile")

      Button {
        providerInsightsAction()
      } label: {
        Label("Providers", systemImage: "shippingbox")
      }
      .help("Show provider analytics")

      Button {
        updateAction()
      } label: {
        HStack(spacing: 5) {
          if isUpdating {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
          Text(localizedProfilesText(isUpdating ? "Updating" : "Update"))
        }
      }
      .disabled(!profile.isSubscription || isUpdating)
      .help(profile.isSubscription ? "Refresh nodes from the subscription URL" : "Only subscription profiles can be updated")

      Button(role: .destructive) {
        deleteAction()
      } label: {
        Label("Delete", systemImage: "trash")
      }
      .help("Delete profile")
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .buttonStyle(.borderless)
    .controlSize(.small)
  }

  private var sourceLine: String {
    if let sourceURLString, let url = URL(string: sourceURLString), let host = url.host(percentEncoded: false) {
      return "\(host) - \(sourceURLString)"
    }
    switch profile.source {
    case let .localFile(originalPath):
      return originalPath ?? localizedProfilesText("Local YAML")
    case .subscription:
      return localizedProfilesText("Subscription URL unavailable")
    }
  }
}

private struct ProfileMetricsRow: View {
  let profile: Profile

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
      metric("Source", profile.source.displayName, "externaldrive")
      metric("Usage", profile.subscriptionMetadata?.trafficSummary ?? "-", "chart.bar")
      metric("Expires", expiresLabel, "calendar")
      metric("Interval", updateIntervalLabel(profile.subscriptionMetadata?.updateIntervalMinutes), "clock.arrow.circlepath")
      metric("Next", nextUpdateLabel, "calendar.badge.clock")
      metric("Result", profile.subscriptionUpdateStatus.result.displayName, "checkmark.seal")
      metric("Updated", profile.updatedAt.formatted(date: .abbreviated, time: .omitted), "arrow.triangle.2.circlepath")
    }
  }

  private var columns: [GridItem] {
    [
      GridItem(.flexible(minimum: 92), spacing: 8, alignment: .topLeading),
      GridItem(.flexible(minimum: 92), spacing: 8, alignment: .topLeading)
    ]
  }

  private func metric(_ title: String, _ value: String, _ symbolName: String) -> some View {
    HStack(spacing: 6) {
      Image(systemName: symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 1) {
        Text(localizedProfilesText(title))
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(value)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var expiresLabel: String {
    guard let expireAt = profile.subscriptionMetadata?.traffic?.expireAt else { return "-" }
    return expireAt.formatted(date: .abbreviated, time: .omitted)
  }

  private func updateIntervalLabel(_ minutes: Int?) -> String {
    guard let minutes, minutes > 0 else { return "-" }
    return SubscriptionFetchSettings.intervalDescription(minutes)
  }

  private var nextUpdateLabel: String {
    guard let nextUpdateAt = profile.subscriptionUpdateStatus.nextUpdateAt else { return "-" }
    return nextUpdateAt.formatted(date: .abbreviated, time: .shortened)
  }
}

private struct ProfileProviderInsightsSheet: View {
  let profile: Profile
  let isActive: Bool
  let summary: ProviderAnalyticsProfileSummary
  let onClose: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Provider Analytics")
            .font(.title3.weight(.semibold))
          Text(profile.name)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Text(isActive ? "Live runtime" : "History snapshot")
          .font(.caption.weight(.semibold))
          .foregroundStyle(isActive ? .green : .secondary)
      }

      ProviderInsightsMetricGrid(summary: summary)

      Divider()

      if summary.hasData {
        ScrollView {
          VStack(alignment: .leading, spacing: 14) {
            ProviderInsightsSection(
              title: "Proxy Providers",
              systemImage: "shippingbox",
              rows: rows(for: .proxy)
            )
            ProviderInsightsSection(
              title: "Rule Providers",
              systemImage: "list.bullet.rectangle",
              rows: rows(for: .rule)
            )
          }
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.visible)
      } else {
        CenteredUnavailableState(
          title: "No provider analytics",
          systemImage: "shippingbox",
          message: "Start this profile and refresh runtime data to collect local provider analytics."
        )
        .frame(maxWidth: .infinity, minHeight: 260)
      }

      Divider()

      HStack {
        Spacer()
        Button("Close", action: onClose)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(20)
    .frame(width: 760)
    .frame(minHeight: 520)
  }

  private func rows(for kind: ProviderKind) -> [ProviderAnalyticsSummary] {
    summary.rows.filter { $0.kind == kind }
  }
}

private struct ProviderInsightsMetricGrid: View {
  let summary: ProviderAnalyticsProfileSummary

  var body: some View {
    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
      metric("Providers", "\(summary.providerCount)", "shippingbox")
      metric("Update Success", summary.successRateLabel, "checkmark.seal")
      metric("Recent Failure", recentFailureLabel, "exclamationmark.triangle")
      metric("Reminder", reminderLabel, "bell.badge")
    }
  }

  private var columns: [GridItem] {
    [
      GridItem(.flexible(minimum: 130), spacing: 10, alignment: .topLeading),
      GridItem(.flexible(minimum: 130), spacing: 10, alignment: .topLeading),
      GridItem(.flexible(minimum: 130), spacing: 10, alignment: .topLeading),
      GridItem(.flexible(minimum: 130), spacing: 10, alignment: .topLeading)
    ]
  }

  private func metric(_ title: String, _ value: String, _ symbolName: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(LocalizedStringKey(title))
          .font(.caption2)
          .foregroundStyle(.tertiary)
        Text(value)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
          .minimumScaleFactor(0.72)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var recentFailureLabel: String {
    guard let failure = summary.recentFailure else { return String(localized: "None") }
    return "\(failure.kind.displayName) \(failure.providerName)"
  }

  private var reminderLabel: String {
    guard let reminder = summary.reminders.first else { return String(localized: "None") }
    return "\(reminder.providerName): \(reminder.message)"
  }
}

private struct ProviderInsightsSection: View {
  let title: LocalizedStringKey
  let systemImage: String
  let rows: [ProviderAnalyticsSummary]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      if rows.isEmpty {
        Text("No provider data")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(rows) { row in
            ProviderInsightRow(row: row)
            if row.id != rows.last?.id {
              Divider()
            }
          }
        }
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
          RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 1)
        }
      }
    }
  }
}

private struct ProviderInsightRow: View {
  let row: ProviderAnalyticsSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(row.providerName)
            .font(.callout.weight(.medium))
            .lineLimit(1)
          Text(row.kind.displayName)
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)

        fact("Count", row.countLabel)
        fact("Change", row.deltaLabel)
        fact("Success", successLabel)
        fact("Source", row.isCurrentRuntimeData ? String(localized: "Live") : String(localized: "History"))
      }

      HStack(alignment: .top, spacing: 18) {
        detail("Recent Failure", recentFailureText)
        detail("Subscription", subscriptionText, tint: reminderTint)
      }
      .font(.caption)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 8)
  }

  private func fact(_ title: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(LocalizedStringKey(title))
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.72)
    }
    .frame(width: 74, alignment: .leading)
  }

  private func detail(_ title: String, _ value: String, tint: Color = .secondary) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Text(LocalizedStringKey(title))
        .foregroundStyle(.tertiary)
      Text(value)
        .foregroundStyle(tint)
        .lineLimit(2)
        .truncationMode(.tail)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var successLabel: String {
    row.successRateSampleCount > 0 ? row.successRateLabel : "-"
  }

  private var recentFailureText: String {
    guard let failure = row.lastFailure else { return String(localized: "None") }
    return failure.errorMessage ?? String(localized: "Failed")
  }

  private var subscriptionText: String {
    var parts: [String] = []
    if let reminder = row.reminder {
      parts.append(reminder.message)
    }
    if let remaining = row.subscriptionInfo?.remainingSummary {
      parts.append(remaining)
    } else if let usage = row.subscriptionInfo?.usageSummary {
      parts.append(usage)
    }
    if let expireAt = row.subscriptionInfo?.expireAt {
      parts.append(expireAt.formatted(date: .abbreviated, time: .omitted))
    }
    return parts.isEmpty ? String(localized: "Unknown") : parts.joined(separator: " - ")
  }

  private var reminderTint: Color {
    switch row.reminder?.severity {
    case .critical:
      return .red
    case .warning:
      return .orange
    case nil:
      return .secondary
    }
  }
}

private func localizedProfilesText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private struct ProfileEditSheet: View {
  let profile: Profile
  @Binding var name: String
  @Binding var subscriptionURL: String
  @Binding var providerOptions: SubscriptionProviderOptions
  let rollbackProviderOptions: SubscriptionProviderOptions
  @Binding var updatePolicy: SubscriptionUpdatePolicy
  let subscriptionDefaultUpdateIntervalMinutes: Int
  let developerMode: Bool
  let onCancel: () -> Void
  let onResetRemoteName: () -> Void
  let onRollbackProviderOptions: () -> Void
  let onSave: () -> Void
  @FocusState private var isNameFocused: Bool
  @State private var providerOptionsValidationError: String?

  private var trimmedName: String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var trimmedSubscriptionURL: String {
    subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Edit Profile")
          .font(.title3.weight(.semibold))
        Text(profile.source.displayName)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ProfileEditRow("Name") {
            TextField("Name", text: $name)
              .textFieldStyle(.roundedBorder)
              .focused($isNameFocused)
              .onSubmit {
                if canSave {
                  onSave()
                }
              }
          }

          if profile.isSubscription {
            ProfileEditRow("Subscription URL") {
              TextField("Subscription URL", text: $subscriptionURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                  if canSave {
                    onSave()
                  }
                }
            }

            ProfileEditContentRow {
              Button {
                onResetRemoteName()
              } label: {
                Label("Restore Remote Name", systemImage: "arrow.counterclockwise")
              }
              .disabled(!profile.nameIsUserCustomized)
            }

            SubscriptionUpdatePolicyEditor(policy: $updatePolicy)

            SubscriptionDiagnosticsView(
              profile: profile,
              subscriptionURL: subscriptionURL,
              defaultUpdateIntervalMinutes: subscriptionDefaultUpdateIntervalMinutes
            )

            SubscriptionProviderOptionsEditor(
              profile: profile,
              options: $providerOptions,
              validationError: $providerOptionsValidationError,
              rollbackOptions: rollbackProviderOptions,
              developerMode: developerMode,
              onRollback: onRollbackProviderOptions
            )
          } else {
            ProfileEditRow("Source") {
              Text(profile.source.displayName)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 560)
      .scrollIndicators(.visible)

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save", action: onSave)
          .keyboardShortcut(.defaultAction)
          .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(width: 620)
    .onAppear {
      isNameFocused = true
    }
  }

  private var canSave: Bool {
    guard !trimmedName.isEmpty else { return false }
    guard profile.isSubscription else { return true }
    return !trimmedSubscriptionURL.isEmpty && providerOptionsValidationError == nil
  }
}

private enum ProfileEditLayout {
  static let labelWidth: CGFloat = 166
  static let rowSpacing: CGFloat = 12
  static let rowInnerSpacing: CGFloat = 8
  static let panelCornerRadius: CGFloat = 6
}

private struct ProfileEditSection<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 9) {
        content
      }
    }
  }
}

private struct ProfileEditRow<Content: View>: View {
  let title: LocalizedStringKey
  let alignment: VerticalAlignment
  @ViewBuilder let content: Content

  init(
    _ title: LocalizedStringKey,
    alignment: VerticalAlignment = .firstTextBaseline,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.alignment = alignment
    self.content = content()
  }

  var body: some View {
    HStack(alignment: alignment, spacing: ProfileEditLayout.rowSpacing) {
      Text(title)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: ProfileEditLayout.labelWidth, alignment: .trailing)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ProfileEditContentRow<Content: View>: View {
  let alignment: VerticalAlignment
  @ViewBuilder let content: Content

  init(alignment: VerticalAlignment = .firstTextBaseline, @ViewBuilder content: () -> Content) {
    self.alignment = alignment
    self.content = content()
  }

  var body: some View {
    HStack(alignment: alignment, spacing: ProfileEditLayout.rowSpacing) {
      Spacer()
        .frame(width: ProfileEditLayout.labelWidth)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
}

private struct ProfileEditToggleRow: View {
  let title: LocalizedStringKey
  @Binding var isOn: Bool
  var isDisabled = false

  init(_ title: LocalizedStringKey, isOn: Binding<Bool>, isDisabled: Bool = false) {
    self.title = title
    _isOn = isOn
    self.isDisabled = isDisabled
  }

  var body: some View {
    ProfileEditRow(title, alignment: .center) {
      Toggle(title, isOn: $isOn)
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(isDisabled)
    }
  }
}

private struct ProfileEditTextEditorRow: View {
  let title: LocalizedStringKey
  @Binding var text: String
  var minHeight: CGFloat

  init(_ title: LocalizedStringKey, text: Binding<String>, minHeight: CGFloat) {
    self.title = title
    _text = text
    self.minHeight = minHeight
  }

  var body: some View {
    ProfileEditRow(title, alignment: .top) {
      TextEditor(text: $text)
        .font(.system(.caption, design: .monospaced))
        .frame(minHeight: minHeight)
        .overlay {
          RoundedRectangle(cornerRadius: ProfileEditLayout.panelCornerRadius, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
  }
}

private struct ProfileEditInfoRow<Content: View>: View {
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ProfileEditContentRow(alignment: .top) {
      content
    }
  }
}

private struct ProfileEditFootnote: View {
  let content: Text

  init(_ text: LocalizedStringKey) {
    content = Text(text)
  }

  init(verbatim text: String) {
    content = Text(verbatim: text)
  }

  var body: some View {
    ProfileEditContentRow {
      content
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

private struct ProfileEditInfoPanel<Content: View>: View {
  let title: LocalizedStringKey
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      content
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .quaternary,
      in: RoundedRectangle(cornerRadius: ProfileEditLayout.panelCornerRadius, style: .continuous)
    )
  }
}

private struct ProfileEditDisclosureRow<Content: View>: View {
  let title: LocalizedStringKey
  @Binding var isExpanded: Bool
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
    self.title = title
    _isExpanded = isExpanded
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      ProfileEditRow(title, alignment: .center) {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .rotationEffect(.degrees(isExpanded ? 90 : 0))
              .frame(width: 10)
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
      }

      if isExpanded {
        content
          .transition(.opacity)
      }
    }
  }
}

private struct SubscriptionUpdatePolicyEditor: View {
  @Binding var policy: SubscriptionUpdatePolicy
  @State private var intervalDraft = ""

  var body: some View {
    ProfileEditSection("Subscription Updates") {
      ProfileEditToggleRow("Automatic Updates", isOn: $policy.automaticUpdatesEnabled)

      ProfileEditToggleRow(
        "Use Remote Interval",
        isOn: $policy.prefersRemoteInterval,
        isDisabled: !policy.automaticUpdatesEnabled || policy.intervalOverrideMinutes != nil
      )

      ProfileEditRow("Override Interval") {
        HStack(spacing: ProfileEditLayout.rowInnerSpacing) {
          TextField("Default", text: $intervalDraft)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .multilineTextAlignment(.trailing)
            .monospacedDigit()
            .onSubmit {
              commitInterval()
            }
            .onChange(of: intervalDraft) { _, _ in commitInterval(allowEmpty: true) }
          Text("minutes")
            .foregroundStyle(.secondary)
        }
      }

      ProfileEditFootnote("Leave empty to use the remote profile-update-interval or the global default.")
    }
    .onAppear {
      intervalDraft = policy.intervalOverrideMinutes.map(String.init) ?? ""
    }
    .onChange(of: policy.intervalOverrideMinutes) { _, value in
      intervalDraft = value.map(String.init) ?? ""
    }
  }

  private func commitInterval(allowEmpty: Bool = false) {
    let trimmed = intervalDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      if allowEmpty || policy.intervalOverrideMinutes != nil {
        policy.intervalOverrideMinutes = nil
      }
      return
    }
    guard let parsed = Int(trimmed) else { return }
    policy.intervalOverrideMinutes = SubscriptionUpdatePolicy.normalizedInterval(parsed)
  }
}

private struct SubscriptionDiagnosticsView: View {
  let profile: Profile
  let subscriptionURL: String
  let defaultUpdateIntervalMinutes: Int
  @State private var isExpanded = true

  private var diagnostics: SubscriptionDiagnostics {
    profile.subscriptionDiagnostics
  }

  private var latestFetch: SubscriptionFetchDiagnostics? {
    diagnostics.latestFetch
  }

  var body: some View {
    ProfileEditDisclosureRow("Subscription Diagnostics", isExpanded: $isExpanded) {
      ProfileEditInfoRow {
        VStack(alignment: .leading, spacing: 12) {
          diagnosticsGrid
          historySection
        }
      }
    }
  }

  private var diagnosticsGrid: some View {
    LazyVGrid(columns: diagnosticColumns, alignment: .leading, spacing: 10) {
      diagnosticValue("URL", displayURL)
      diagnosticValue("User-Agent", latestFetch?.userAgent ?? "-")
      diagnosticValue("Fetch Proxy", fetchProxySummary)
      diagnosticValue("Request Headers", requestHeaderSummary)
      diagnosticValue("Response Headers", responseHeaderSummary)
      diagnosticValue("Content-Type", latestFetch?.contentType ?? "-")
      diagnosticValue("subscription-userinfo", latestFetch?.subscriptionUserInfo ?? "-")
      diagnosticValue("profile-update-interval", profileUpdateIntervalSummary)
      diagnosticValue("Charset", charsetSummary)
      diagnosticValue("Preflight", preflightSummary)
      diagnosticValue("Update Interval Source", updateIntervalSourceSummary)
    }
  }

  private var historySection: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("Recent Updates")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      if diagnostics.updateHistory.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(Array(diagnostics.updateHistory.prefix(SubscriptionDiagnostics.historyLimit))) { entry in
            historyRow(entry)
          }
        }
      }
    }
  }

  private var diagnosticColumns: [GridItem] {
    [
      GridItem(.flexible(minimum: 170), spacing: 10, alignment: .topLeading),
      GridItem(.flexible(minimum: 170), spacing: 10, alignment: .topLeading)
    ]
  }

  private func diagnosticValue(_ title: LocalizedStringKey, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption2)
        .foregroundStyle(.tertiary)
      Text(value)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .truncationMode(.middle)
        .textSelection(.enabled)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func historyRow(_ entry: SubscriptionUpdateHistoryEntry) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(entry.date.formatted(date: .abbreviated, time: .shortened))
          .font(.caption.monospacedDigit())
          .frame(width: 118, alignment: .leading)
        Text(entry.trigger.displayName)
          .font(.caption)
          .frame(width: 118, alignment: .leading)
        Text(entry.result.displayName)
          .font(.caption.weight(.medium))
          .foregroundStyle(entry.result == .failed ? .red : .secondary)
        if let failureKind = entry.failureKind {
          Text(failureKind.displayName)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if let message = entry.message {
        Text(message)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
          .textSelection(.enabled)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var displayURL: String {
    latestFetch?.sanitizedURL ?? Self.redactedURL(subscriptionURL) ?? "-"
  }

  private var fetchProxySummary: String {
    guard let latestFetch else { return profile.subscriptionProviderOptions.fetchProxy.displayName }
    let attempted = latestFetch.attemptedStrategies.map(\.displayName).joined(separator: " -> ")
    guard let successfulStrategy = latestFetch.successfulStrategy else {
      return attempted.isEmpty ? "-" : attempted
    }
    return attempted.isEmpty
      ? successfulStrategy.displayName
      : "\(attempted) (success: \(successfulStrategy.displayName))"
  }

  private var requestHeaderSummary: String {
    guard let latestFetch, !latestFetch.requestHeaders.isEmpty else { return "-" }
    return latestFetch.requestHeaders
      .map { header in
        header.hasValue
          ? String(format: String(localized: "%@ (set)"), header.name)
          : String(format: String(localized: "%@ (empty)"), header.name)
      }
      .joined(separator: ", ")
  }

  private var responseHeaderSummary: String {
    guard let latestFetch, !latestFetch.responseHeaderNames.isEmpty else { return "-" }
    return latestFetch.responseHeaderNames.joined(separator: ", ")
  }

  private var profileUpdateIntervalSummary: String {
    guard let latestFetch else { return "-" }
    let raw = latestFetch.rawProfileUpdateInterval ?? "-"
    guard let minutes = latestFetch.parsedProfileUpdateIntervalMinutes else {
      return raw
    }
    return "\(raw) -> \(SubscriptionFetchSettings.intervalDescription(minutes))"
  }

  private var charsetSummary: String {
    guard let latestFetch else { return "-" }
    let declared = latestFetch.declaredCharset ?? "-"
    let decoded = latestFetch.decodedCharset ?? "-"
    return "declared: \(declared), decoded: \(decoded)"
  }

  private var preflightSummary: String {
    guard let latestPreflight = diagnostics.latestPreflight else { return "-" }
    guard let message = latestPreflight.localizedMessage else {
      return latestPreflight.result.displayName
    }
    return "\(latestPreflight.result.displayName): \(message)"
  }

  private var updateIntervalSourceSummary: String {
    let resolution = profile.subscriptionUpdatePolicy.intervalResolution(
      remoteIntervalMinutes: profile.subscriptionMetadata?.updateIntervalMinutes,
      globalDefaultMinutes: defaultUpdateIntervalMinutes
    )
    guard let minutes = resolution.minutes else {
      return resolution.source.displayName
    }
    return "\(resolution.source.displayName) - \(SubscriptionFetchSettings.intervalDescription(minutes))"
  }

  private static func redactedURL(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else {
      return nil
    }
    components.user = nil
    components.password = nil
    if let items = components.queryItems {
      components.queryItems = items.map { item in
        URLQueryItem(name: item.name, value: item.value == nil ? nil : "<redacted>")
      }
    }
    return components.string?
      .replacingOccurrences(of: "%3Credacted%3E", with: "<redacted>")
      .replacingOccurrences(of: "%3credacted%3e", with: "<redacted>")
  }
}

private struct SubscriptionProviderOptionsEditor: View {
  @EnvironmentObject private var appModel: AppModel
  let profile: Profile
  @Binding var options: SubscriptionProviderOptions
  @Binding var validationError: String?
  let rollbackOptions: SubscriptionProviderOptions
  let developerMode: Bool
  let onRollback: () -> Void
  @State private var isRuleOverlayPresented = false
  @State private var showsAdvancedOptions = false

  var body: some View {
    ProfileEditSection("Provider Options") {
      ProfileEditRow("Generated Template") {
        Picker("Generated Template", selection: $options.generatedTemplate) {
          ForEach(SubscriptionTemplateKind.allCases) { template in
            Text(template.displayName).tag(template)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
      }

      ProfileEditFootnote(verbatim: options.generatedTemplate.description)
      presetDetails
      guardrailRisks
      runtimeDiff

      ProfileEditRow("Provider Interval") {
        VStack(alignment: .leading, spacing: 4) {
          ProfileNumberStepperField(
            accessibilityLabel: "Provider Interval",
            value: intervalBinding,
            validationError: $validationError,
            range: SubscriptionProviderOptions.minimumIntervalSeconds...SubscriptionProviderOptions.maximumIntervalSeconds,
            step: 60,
            fieldWidth: 58
          )

          if let validationError {
            Label(validationError, systemImage: "exclamationmark.triangle.fill")
              .font(.caption)
              .foregroundStyle(.red)
              .lineLimit(2)
          }
        }
      }

      ProfileEditRow("Fetch Proxy") {
        Picker("Fetch Proxy", selection: $options.fetchProxy) {
          ForEach(SubscriptionProviderFetchProxy.allCases) { proxy in
            Text(proxy.displayName).tag(proxy)
          }
        }
        .labelsHidden()
        .frame(maxWidth: 180)
      }

      ProfileEditRow("Generated Select Group") {
        TextField("Generated Select Group", text: $options.primaryGroupName)
          .textFieldStyle(.roundedBorder)
      }

      ProfileEditRow("Generated URL-Test Group") {
        TextField("Generated URL-Test Group", text: $options.autoGroupName)
          .textFieldStyle(.roundedBorder)
      }

      ProfileEditRow("Profile Rule Overlay") {
        HStack(spacing: 10) {
          Text(options.ruleOverlay.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
          Spacer(minLength: 8)
          Button {
            isRuleOverlayPresented = true
          } label: {
            Image(systemName: "slider.horizontal.3")
          }
          .accessibilityLabel("Edit")
          .help("Edit")
          .popover(isPresented: $isRuleOverlayPresented, arrowEdge: .bottom) {
            RuleOverlaySettingsPopover(settings: $options.ruleOverlay)
              .padding(16)
              .frame(width: 420)
          }
        }
      }

      ProfileEditContentRow {
        HStack(spacing: 10) {
          Spacer()
          Button {
            onRollback()
            validateAdvancedYAML()
          } label: {
            Label("Rollback to Last Working", systemImage: "clock.arrow.circlepath")
          }
          .disabled(options == rollbackOptions)

          Button {
            options = .default
            validateAdvancedYAML()
          } label: {
            Label("Restore Defaults", systemImage: "arrow.uturn.backward")
          }
        }
      }

      if developerMode {
        providerSideLoadPreflightRow

        ProfileEditDisclosureRow("Legacy Advanced YAML and Filters", isExpanded: $showsAdvancedOptions) {
          ProfileEditRow("Filter") {
            TextField("Filter", text: $options.filter)
              .textFieldStyle(.roundedBorder)
          }
          ProfileEditRow("Exclude Filter") {
            TextField("Exclude Filter", text: $options.excludeFilter)
              .textFieldStyle(.roundedBorder)
          }
          ProfileEditRow("Exclude Type") {
            TextField("Exclude Type", text: $options.excludeType)
              .textFieldStyle(.roundedBorder)
          }
          ProfileEditRow("Final MATCH Policy") {
            TextField("Final MATCH Policy", text: $options.finalRulePolicy)
              .textFieldStyle(.roundedBorder)
          }

          ProfileEditTextEditorRow("Provider Override YAML", text: $options.overrideYAML, minHeight: 72)
          ProfileEditTextEditorRow("Legacy Runtime Merge YAML", text: $options.runtimeMergeYAML, minHeight: 88)
            .help("Legacy raw YAML merge. Prefer typed snippets on the Routing page for normal rule and DNS changes.")

          customHeadersEditor
        }
      } else {
        ProfileEditFootnote(verbatim: String(localized: "Developer Mode is required for legacy raw provider filters, YAML merge fields, and custom request headers. Use Routing snippets for normal rule and DNS changes."))
      }
    }
    .onAppear(perform: validateAdvancedYAML)
    .onChange(of: options.overrideYAML) { _, _ in validateAdvancedYAML() }
    .onChange(of: options.runtimeMergeYAML) { _, _ in validateAdvancedYAML() }
  }

  private var providerSideLoadPreflightRow: some View {
    let unsupportedReason = appModel.providerSideLoadPreflightUnsupportedReason(for: profile)
    let isRunning = appModel.providerSideLoadPreflightStatus.isRunning(for: profile.id)
    return ProfileEditRow("Provider Side-load Preflight") {
      VStack(alignment: .leading, spacing: 6) {
        HStack(spacing: 8) {
          Button {
            appModel.chooseProviderSideLoadPreflightFile(for: profile)
          } label: {
            Label("Choose Provider File...", systemImage: "doc.badge.gearshape")
          }
          .disabled(unsupportedReason != nil || isRunning)

          if isRunning {
            ProgressView()
              .controlSize(.small)
          }
        }

        if let statusMessage = appModel.providerSideLoadPreflightStatus.message(for: profile.id) {
          Label(statusMessage, systemImage: providerSideLoadStatusIcon)
            .font(.caption)
            .foregroundStyle(providerSideLoadStatusColor)
            .lineLimit(3)
        } else if let unsupportedReason {
          Label(unsupportedReason, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        } else {
          Text("Temporarily validates a local provider file against this profile's generated runtime YAML.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var providerSideLoadStatusIcon: String {
    switch appModel.providerSideLoadPreflightStatus {
    case .idle:
      return "info.circle"
    case .running:
      return "hourglass"
    case .succeeded:
      return "checkmark.circle.fill"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  private var providerSideLoadStatusColor: Color {
    switch appModel.providerSideLoadPreflightStatus {
    case .succeeded:
      return .green
    case .failed:
      return .red
    default:
      return .secondary
    }
  }

  private var guardrailReport: SubscriptionProviderOptionsGuardrailReport {
    SubscriptionProviderOptionsGuardrailReport.analyze(
      options: options,
      baseline: rollbackOptions,
      rollbackOptions: rollbackOptions
    )
  }

  @ViewBuilder
  private var presetDetails: some View {
    if !guardrailReport.presetDetails.isEmpty {
      ProfileEditInfoRow {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(guardrailReport.presetDetails, id: \.self) { detail in
            Label(detail, systemImage: "checkmark.circle")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  @ViewBuilder
  private var guardrailRisks: some View {
    if !guardrailReport.risks.isEmpty {
      ProfileEditInfoRow {
        ProfileEditInfoPanel("Guardrails") {
          ForEach(guardrailReport.risks) { risk in
            HStack(alignment: .top, spacing: ProfileEditLayout.rowInnerSpacing) {
              Image(systemName: risk.severity == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(risk.severity == .danger ? .red : .orange)
                .frame(width: 16)
              VStack(alignment: .leading, spacing: 2) {
                Text("\(risk.source): \(risk.keyPath)")
                  .font(.caption.weight(.medium))
                  .lineLimit(1)
                Text(risk.message)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
            }
          }
        }
      }
    }
  }

  @ViewBuilder
  private var runtimeDiff: some View {
    let visibleDiff = developerMode
      ? guardrailReport.runtimeDiff
      : guardrailReport.runtimeDiff.filter { !$0.isAdvanced }
    if visibleDiff.isEmpty {
      ProfileEditFootnote(verbatim: String(localized: "Runtime diff: no generated-template changes from the last working provider options."))
    } else {
      ProfileEditInfoRow {
        ProfileEditInfoPanel("Runtime Diff") {
          ForEach(visibleDiff) { diff in
            HStack(alignment: .top, spacing: ProfileEditLayout.rowInnerSpacing) {
              Text(diff.title)
                .font(.caption)
                .frame(width: 126, alignment: .leading)
              Text(diff.before)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
              Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
              Text(diff.after)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            }
          }
        }
      }
    }
  }

  private var intervalBinding: Binding<Int> {
    Binding(
      get: { options.intervalSeconds },
      set: { options.intervalSeconds = min(
        max($0, SubscriptionProviderOptions.minimumIntervalSeconds),
        SubscriptionProviderOptions.maximumIntervalSeconds
      ) }
    )
  }

  private var customHeadersEditor: some View {
    ProfileEditRow("Custom Headers", alignment: .top) {
      VStack(alignment: .leading, spacing: ProfileEditLayout.rowInnerSpacing) {
        HStack {
          if options.requestHeaders.isEmpty {
            Text("Empty")
              .font(.caption)
              .foregroundStyle(.tertiary)
          }
          Spacer()
          Button {
            options.requestHeaders.append(SubscriptionRequestHeader())
          } label: {
            Image(systemName: "plus")
          }
          .buttonStyle(.borderless)
          .help("Add custom header")
        }

        ForEach($options.requestHeaders) { $header in
          HStack(spacing: ProfileEditLayout.rowInnerSpacing) {
            TextField("Header", text: $header.name)
              .textFieldStyle(.roundedBorder)
            SecureField("Value", text: $header.value)
              .textFieldStyle(.roundedBorder)
            Button {
              options.requestHeaders.removeAll { $0.id == header.id }
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove header")
          }
        }
      }
    }
  }

  private func validateAdvancedYAML() {
    if let error = yamlValidationError(options.overrideYAML, label: String(localized: "Provider Override YAML")) {
      validationError = error
      return
    }
    if let error = yamlValidationError(options.runtimeMergeYAML, label: String(localized: "Runtime Merge YAML")) {
      validationError = error
      return
    }
    validationError = nil
  }

  private func yamlValidationError(_ yaml: String, label: String) -> String? {
    let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    do {
      let loaded = try Yams.load(yaml: trimmed)
      guard loaded is [String: Any] else {
        return String(format: String(localized: "%@ YAML must be a mapping."), label)
      }
      return nil
    } catch {
      return String(format: String(localized: "%@ YAML parse error: %@"), label, String(describing: error))
    }
  }
}

private struct ProfileNumberStepperField: View {
  let accessibilityLabel: String
  @Binding var value: Int
  @Binding var validationError: String?
  let range: ClosedRange<Int>
  var step = 1
  var fieldWidth: CGFloat = 82
  @State private var draft = ""
  @FocusState private var isFocused: Bool

  var body: some View {
    HStack(spacing: 8) {
      TextField("", text: $draft)
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .frame(width: fieldWidth)
        .accessibilityLabel(localizedProfilesText(accessibilityLabel))
        .focused($isFocused)
        .onSubmit(commitDraft)
        .onChange(of: draft) { _, newValue in
          updateValidation(for: newValue)
          updateValueIfValid(newValue)
        }
        .onAppear {
          let current = syncDraft()
          updateValidation(for: current)
        }
        .onChange(of: value) { _, _ in
          _ = syncDraft()
        }
        .onChange(of: isFocused) { _, focused in
          if !focused {
            commitDraft()
          }
        }

      Stepper(localizedProfilesText(accessibilityLabel), value: clampedValue, in: range, step: step)
        .labelsHidden()
    }
  }

  private var clampedValue: Binding<Int> {
    Binding(
      get: { clamped(value) },
      set: { value = clamped($0) }
    )
  }

  private func updateValueIfValid(_ text: String) {
    guard let parsed = parsedDraft(text), range.contains(parsed) else { return }
    value = parsed
  }

  private func commitDraft() {
    guard let parsed = parsedDraft(draft) else {
      let current = syncDraft()
      updateValidation(for: current)
      return
    }
    value = clamped(parsed)
    let current = syncDraft()
    updateValidation(for: current)
  }

  private func syncDraft() -> String {
    let current = "\(clamped(value))"
    if draft != current {
      draft = current
    }
    return current
  }

  private func clamped(_ value: Int) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
  }

  private func updateValidation(for text: String) {
    guard let parsed = parsedDraft(text), range.contains(parsed) else {
      validationError = "Enter \(range.lowerBound)-\(range.upperBound) seconds."
      return
    }
    validationError = nil
  }

  private func parsedDraft(_ text: String) -> Int? {
    Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
  }
}
