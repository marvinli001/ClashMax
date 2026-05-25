import SwiftUI
import Yams

struct ProfilesView: View {
  @EnvironmentObject private var appModel: AppModel
  @EnvironmentObject private var profileStore: ProfileStore
  @EnvironmentObject private var profileCoordinator: ProfileCoordinator
  @State private var subscriptionURL = ""
  @State private var profileBeingEdited: Profile?
  @State private var editProfileName = ""
  @State private var editSubscriptionURL = ""
  @State private var editProviderOptions = SubscriptionProviderOptions.default
  @State private var editUpdatePolicy = SubscriptionUpdatePolicy.default
  @State private var profilePendingDeletion: Profile?
  @State private var migrationReport: ClashXMigrationReport?

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
        importClashX()
      } label: {
        Label("Import ClashX", systemImage: "arrow.triangle.branch")
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
        updatePolicy: $editUpdatePolicy,
        onCancel: closeEditSheet,
        onResetRemoteName: {
          resetRemoteName(profile)
        },
        onSave: {
          saveProfileEdits(profile)
        }
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
        ClashXMigrationReportSheet(
          report: migrationReport,
          onCancel: { self.migrationReport = nil },
          onApply: { applyMigrationReport(migrationReport) }
        )
        .frame(width: 560)
        .padding(20)
      }
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
    editUpdatePolicy = profile.subscriptionUpdatePolicy
    profileBeingEdited = profile
  }

  private func closeEditSheet() {
    profileBeingEdited = nil
    editProfileName = ""
    editSubscriptionURL = ""
    editProviderOptions = .default
    editUpdatePolicy = .default
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

  private func importClashX() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Inspect"
    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/clash")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    migrationReport = Self.buildMigrationReport(from: url)
  }

  private func applyMigrationReport(_ report: ClashXMigrationReport) {
    migrationReport = nil
    let configURL = URL(fileURLWithPath: report.configDirectory).appendingPathComponent("config.yaml")
    applyMigrationRuntimeSettings(report)
    Task { @MainActor in
      if FileManager.default.fileExists(atPath: configURL.path) {
        do {
          _ = try await profileCoordinator.importLocalProfile(from: configURL)
        } catch {
          appModel.lastError = UserFacingError.message(for: error)
        }
      }
      for subscriptionURL in report.subscriptionURLs {
        _ = await appModel.addSubscription(urlString: subscriptionURL)
      }
    }
  }

  private func applyMigrationRuntimeSettings(_ report: ClashXMigrationReport) {
    if let mixedPort = report.ports["mixed-port"] ?? report.ports["port"] {
      let normalizedPort = min(max(mixedPort, 1), 65_535)
      appModel.overrides.mixedPort = normalizedPort
    }

    if !report.bypassDomains.isEmpty {
      var settings = appModel.systemProxySettings
      settings.customBypassDomains = SystemProxySettings.normalizedBypassDomains(
        settings.customBypassDomains + report.bypassDomains
      )
      appModel.systemProxySettings = settings
    }
  }

  private static func buildMigrationReport(from directoryURL: URL) -> ClashXMigrationReport {
    let configURL = directoryURL.appendingPathComponent("config.yaml")
    guard let source = try? String(contentsOf: configURL, encoding: .utf8),
          let root = try? Yams.load(yaml: source) as? [String: Any]
    else {
      return ClashXMigrationReport(
        configDirectory: directoryURL.path,
        warnings: ["config.yaml was not found or could not be parsed."]
      )
    }

    let providers = root["proxy-providers"] as? [String: Any] ?? [:]
    let subscriptionURLs = providers.values.compactMap { value -> String? in
      guard let provider = value as? [String: Any] else { return nil }
      return (provider["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    .filter { !$0.isEmpty }

    var ports: [String: Int] = [:]
    for key in ["mixed-port", "port", "socks-port", "redir-port"] {
      if let value = root[key] as? Int {
        ports[key] = value
      }
    }

    let bypassKeys = ["cfw-bypass", "bypass", "proxy-bypass"]
    let bypassDomains = bypassKeys.flatMap { key -> [String] in
      root[key] as? [String] ?? []
    }

    return ClashXMigrationReport(
      configDirectory: directoryURL.path,
      subscriptionURLs: subscriptionURLs,
      bypassDomains: bypassDomains,
      ports: ports,
      warnings: subscriptionURLs.isEmpty ? ["No remote provider subscription URLs were detected."] : []
    )
  }
}

private struct ClashXMigrationReportSheet: View {
  let report: ClashXMigrationReport
  let onCancel: () -> Void
  let onApply: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("ClashX Migration Report", systemImage: "arrow.triangle.branch")
        .font(.title3.weight(.semibold))

      Text(report.configDirectory)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)

      migrationSection("Subscriptions", values: report.subscriptionURLs)
      migrationSection("Bypass", values: report.bypassDomains)
      migrationSection("Ports", values: report.ports.map { "\($0.key): \($0.value)" }.sorted())
      migrationSection("Warnings", values: report.warnings)

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Apply", action: onApply)
          .keyboardShortcut(.defaultAction)
      }
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

private func localizedProfilesText(_ value: String) -> String {
  NSLocalizedString(value, comment: "")
}

private struct ProfileEditSheet: View {
  let profile: Profile
  @Binding var name: String
  @Binding var subscriptionURL: String
  @Binding var providerOptions: SubscriptionProviderOptions
  @Binding var updatePolicy: SubscriptionUpdatePolicy
  let onCancel: () -> Void
  let onResetRemoteName: () -> Void
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

      Form {
        TextField("Name", text: $name)
          .focused($isNameFocused)
          .onSubmit {
            if canSave {
              onSave()
            }
          }

        if profile.isSubscription {
          TextField("Subscription URL", text: $subscriptionURL)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              if canSave {
                onSave()
              }
            }

          Button {
            onResetRemoteName()
          } label: {
            Label("Restore Remote Name", systemImage: "arrow.counterclockwise")
          }
          .disabled(!profile.nameIsUserCustomized)

          SubscriptionUpdatePolicyEditor(policy: $updatePolicy)

          SubscriptionProviderOptionsEditor(
            options: $providerOptions,
            validationError: $providerOptionsValidationError
          )
        } else {
          LabeledContent("Source") {
            Text(profile.source.displayName)
              .foregroundStyle(.secondary)
          }
        }
      }

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
    .frame(width: 460)
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

private struct SubscriptionUpdatePolicyEditor: View {
  @Binding var policy: SubscriptionUpdatePolicy
  @State private var intervalDraft = ""

  var body: some View {
    Section("Subscription Updates") {
      Toggle("Automatic Updates", isOn: $policy.automaticUpdatesEnabled)
      Toggle("Use Remote Interval", isOn: $policy.prefersRemoteInterval)
        .disabled(!policy.automaticUpdatesEnabled || policy.intervalOverrideMinutes != nil)
      HStack {
        Text("Override Interval")
        Spacer()
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
      Text("Leave empty to use the remote profile-update-interval or the global default.")
        .font(.caption)
        .foregroundStyle(.secondary)
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

private struct SubscriptionProviderOptionsEditor: View {
  @Binding var options: SubscriptionProviderOptions
  @Binding var validationError: String?
  @State private var isRuleOverlayPresented = false
  @State private var showsAdvancedOptions = false

  var body: some View {
    Section("Provider Options") {
      Picker("Generated Template", selection: $options.generatedTemplate) {
        ForEach(SubscriptionTemplateKind.allCases) { template in
          Text(template.displayName).tag(template)
        }
      }
      Text(options.generatedTemplate.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      LabeledContent("Provider Interval") {
        VStack(alignment: .trailing, spacing: 4) {
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

      Picker("Fetch Proxy", selection: $options.fetchProxy) {
        ForEach(SubscriptionProviderFetchProxy.allCases) { proxy in
          Text(proxy.displayName).tag(proxy)
        }
      }

      TextField("Generated Select Group", text: $options.primaryGroupName)
      TextField("Generated URL-Test Group", text: $options.autoGroupName)

      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Profile Rule Overlay")
          Text(options.ruleOverlay.summary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        Spacer()
        Button {
          isRuleOverlayPresented = true
        } label: {
          Label("Edit", systemImage: "slider.horizontal.3")
        }
        .popover(isPresented: $isRuleOverlayPresented, arrowEdge: .bottom) {
          RuleOverlaySettingsPopover(settings: $options.ruleOverlay)
            .padding(16)
            .frame(width: 420)
          }
      }

      DisclosureGroup("Advanced YAML and Filters", isExpanded: $showsAdvancedOptions) {
        VStack(alignment: .leading, spacing: 10) {
          TextField("Filter", text: $options.filter)
          TextField("Exclude Filter", text: $options.excludeFilter)
          TextField("Exclude Type", text: $options.excludeType)
          TextField("Final MATCH Policy", text: $options.finalRulePolicy)

          yamlEditor("Provider Override YAML", text: $options.overrideYAML, minHeight: 72)
          yamlEditor("Runtime Merge YAML", text: $options.runtimeMergeYAML, minHeight: 88)
            .help("Merged into runtime config before app-managed launch settings.")

          customHeadersEditor

          HStack {
            Spacer()
            Button {
              options = .default
              validateAdvancedYAML()
            } label: {
              Label("Restore Defaults", systemImage: "arrow.uturn.backward")
            }
          }
        }
      }
    }
    .onAppear(perform: validateAdvancedYAML)
    .onChange(of: options.overrideYAML) { _, _ in validateAdvancedYAML() }
    .onChange(of: options.runtimeMergeYAML) { _, _ in validateAdvancedYAML() }
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

  private func yamlEditor(_ title: String, text: Binding<String>, minHeight: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(LocalizedStringKey(title))
        .font(.caption)
        .foregroundStyle(.secondary)
      TextEditor(text: text)
        .font(.system(.caption, design: .monospaced))
        .frame(minHeight: minHeight)
        .overlay {
          RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 1)
        }
    }
  }

  private var customHeadersEditor: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Custom Headers")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button {
          options.requestHeaders.append(SubscriptionRequestHeader())
        } label: {
          Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .help("Add custom header")
      }

      if options.requestHeaders.isEmpty {
        Text("Empty")
          .font(.caption)
          .foregroundStyle(.tertiary)
      } else {
        ForEach($options.requestHeaders) { $header in
          HStack(spacing: 8) {
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
    if let error = yamlValidationError(options.overrideYAML, label: "Provider override") {
      validationError = error
      return
    }
    if let error = yamlValidationError(options.runtimeMergeYAML, label: "Runtime merge") {
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
        return "\(label) YAML must be a mapping."
      }
      return nil
    } catch {
      return "\(label) YAML parse error: \(String(describing: error))"
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
