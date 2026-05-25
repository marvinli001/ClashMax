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
  @State private var editRollbackProviderOptions = SubscriptionProviderOptions.default
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
        rollbackProviderOptions: editRollbackProviderOptions,
        updatePolicy: $editUpdatePolicy,
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
          onApply: { enableSystemProxy in applyMigrationReport(migrationReport, enableSystemProxy: enableSystemProxy) }
        )
        .frame(width: 560)
        .padding(20)
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .clashMaxImportClashXRequested)) { _ in
      importClashX()
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
    migrationReport = ClashXMigrationParser().parse(directoryURL: url)
  }

  private func applyMigrationReport(_ report: ClashXMigrationReport, enableSystemProxy: Bool) {
    migrationReport = nil
    let configURL = URL(fileURLWithPath: report.configDirectory).appendingPathComponent("config.yaml")
    applyMigrationRuntimeSettings(report, enableSystemProxy: enableSystemProxy)
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

  private func applyMigrationRuntimeSettings(_ report: ClashXMigrationReport, enableSystemProxy: Bool) {
    if let mixedPort = report.ports["mixed-port"] ?? report.ports["port"] {
      let normalizedPort = min(max(mixedPort, 1), 65_535)
      appModel.overrides.mixedPort = normalizedPort
    }

    if let allowLan = report.allowLan {
      appModel.overrides.allowLan = allowLan
    }

    if let mode = report.mode.flatMap(RunMode.init(rawValue:)) {
      appModel.overrides.mode = mode
    }

    if let logLevel = report.logLevel {
      appModel.overrides.logLevel = logLevel
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
}

private struct ClashXMigrationReportSheet: View {
  let report: ClashXMigrationReport
  let onCancel: () -> Void
  let onApply: (Bool) -> Void
  @State private var enableSystemProxy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("ClashX Migration Report", systemImage: "arrow.triangle.branch")
        .font(.title3.weight(.semibold))

      Text(report.configDirectory)
        .font(.caption.monospaced())
        .foregroundStyle(.secondary)
        .lineLimit(2)

      migrationSection("Subscriptions", values: report.subscriptionURLs)
      migrationSection("Duplicates", values: report.duplicateSubscriptionURLs)
      migrationSection("Bypass", values: report.bypassDomains)
      migrationSection("Ports", values: report.ports.map { "\($0.key): \($0.value)" }.sorted())
      migrationSection("Runtime", values: runtimeValues)
      migrationSection("Conflicts", values: report.conflicts)
      migrationSection("Unsupported", values: report.unsupportedSettings)
      migrationSection("Unknown Keys", values: report.unknownKeys)
      migrationSection("Inspected Files", values: report.inspectedFiles)
      migrationSection("Warnings", values: report.warnings)

      Toggle("Enable System Proxy after import", isOn: $enableSystemProxy)
        .toggleStyle(.checkbox)
        .disabled(report.systemProxyEnabled != true)
        .help("ClashMax only enables System Proxy during migration when this checkbox is selected.")

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Apply") {
          onApply(enableSystemProxy)
        }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private var runtimeValues: [String] {
    [
      report.allowLan.map { "allow-lan: \($0)" },
      report.mode.map { "mode: \($0)" },
      report.logLevel.map { "log-level: \($0)" },
      report.systemProxyEnabled.map { "system proxy intent: \($0)" }
    ]
    .compactMap { $0 }
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
  let rollbackProviderOptions: SubscriptionProviderOptions
  @Binding var updatePolicy: SubscriptionUpdatePolicy
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

            SubscriptionProviderOptionsEditor(
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
    .frame(width: 560)
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
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: ProfileEditLayout.rowSpacing) {
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
  @ViewBuilder let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: ProfileEditLayout.rowSpacing) {
      Spacer()
        .frame(width: ProfileEditLayout.labelWidth)

      content
        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ProfileEditDisclosureGroup<Content: View>: View {
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

          Text(title)
            .font(.callout.weight(.medium))
            .lineLimit(1)

          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))

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
      ProfileEditContentRow {
        Toggle("Automatic Updates", isOn: $policy.automaticUpdatesEnabled)
      }

      ProfileEditContentRow {
        Toggle("Use Remote Interval", isOn: $policy.prefersRemoteInterval)
          .disabled(!policy.automaticUpdatesEnabled || policy.intervalOverrideMinutes != nil)
      }

      ProfileEditRow("Override Interval") {
        HStack(spacing: 8) {
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

private struct SubscriptionProviderOptionsEditor: View {
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
        ProfileEditContentRow {
          ProfileEditDisclosureGroup("Advanced YAML and Filters", isExpanded: $showsAdvancedOptions) {
            VStack(alignment: .leading, spacing: 10) {
              TextField("Filter", text: $options.filter)
                .textFieldStyle(.roundedBorder)
              TextField("Exclude Filter", text: $options.excludeFilter)
                .textFieldStyle(.roundedBorder)
              TextField("Exclude Type", text: $options.excludeType)
                .textFieldStyle(.roundedBorder)
              TextField("Final MATCH Policy", text: $options.finalRulePolicy)
                .textFieldStyle(.roundedBorder)

              yamlEditor("Provider Override YAML", text: $options.overrideYAML, minHeight: 72)
              yamlEditor("Runtime Merge YAML", text: $options.runtimeMergeYAML, minHeight: 88)
                .help("Merged into runtime config before app-managed launch settings.")

              customHeadersEditor
            }
          }
        }
      } else {
        ProfileEditFootnote(verbatim: String(localized: "Developer Mode is required for raw provider filters, YAML merge fields, and custom request headers."))
      }
    }
    .onAppear(perform: validateAdvancedYAML)
    .onChange(of: options.overrideYAML) { _, _ in validateAdvancedYAML() }
    .onChange(of: options.runtimeMergeYAML) { _, _ in validateAdvancedYAML() }
  }

  private var guardrailReport: SubscriptionProviderOptionsGuardrailReport {
    SubscriptionProviderOptionsGuardrailReport.analyze(
      options: options,
      baseline: rollbackOptions,
      rollbackOptions: rollbackOptions
    )
  }

  private var presetDetails: some View {
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

  @ViewBuilder
  private var guardrailRisks: some View {
    if guardrailReport.risks.isEmpty {
      EmptyView()
    } else {
      VStack(alignment: .leading, spacing: 6) {
        Text("Guardrails")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(guardrailReport.risks) { risk in
          HStack(alignment: .top, spacing: 8) {
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
      .padding(10)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
      VStack(alignment: .leading, spacing: 6) {
        Text("Runtime Diff")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ForEach(visibleDiff) { diff in
          HStack(alignment: .top, spacing: 8) {
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
      .padding(10)
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
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
