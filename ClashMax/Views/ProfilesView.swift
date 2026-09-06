import AppKit
import Foundation
import SwiftUI
import Yams

/// Layout policy for the Profiles page, kept pure so it can be unit-tested.
enum ProfilesLayout {
  /// Below this page width the detail pane would squeeze the Name column into uselessness, so the
  /// pane steps aside and every one of its actions stays reachable through the More and context menus.
  static let detailPaneBreakpoint: CGFloat = 700
  static let detailPaneWidth: CGFloat = 256
  /// The Usage column is the one column the table can do without: below this width it would only
  /// buy a horizontal scroller, and the detail pane carries the same facts for the selected profile.
  static let usageColumnBreakpoint: CGFloat = 1_000

  static func showsDetailPane(pageWidth: CGFloat, requested: Bool) -> Bool {
    requested && pageWidth.isFinite && pageWidth >= detailPaneBreakpoint
  }

  static func showsUsageColumn(pageWidth: CGFloat, hasUsageData: Bool) -> Bool {
    hasUsageData && pageWidth.isFinite && pageWidth >= usageColumnBreakpoint
  }
}

/// The one line of status a profile row carries. Everything else about a profile lives in the detail
/// pane or the edit sheet, so the list stays a list.
enum ProfileStatusSummary {
  static func text(for profile: Profile, isUpdating: Bool) -> String {
    switch profile.source {
    case .subscription:
      if isUpdating || profile.subscriptionUpdateStatus.result == .running {
        return String(localized: "Updating…")
      }
      let status = profile.subscriptionUpdateStatus
      switch status.result {
      case .failed:
        if let error = status.lastError {
          return String(format: String(localized: "Update failed: %@"), error)
        }
        return String(localized: "Update failed")
      case .succeeded:
        if let date = status.lastSucceededAt ?? status.lastFinishedAt {
          return String(
            format: String(localized: "Updated %@"),
            date.formatted(.relative(presentation: .named))
          )
        }
        return String(localized: "Updated")
      case .skipped:
        return String(localized: "Update skipped")
      case .never, .running:
        return String(localized: "Not updated yet")
      }
    case .localFile:
      return String(
        format: String(localized: "Imported %@"),
        profile.updatedAt.formatted(date: .abbreviated, time: .omitted)
      )
    case .manualProxy:
      return String(localized: "Manual proxy")
    }
  }

  static func isFailure(_ profile: Profile) -> Bool {
    profile.isSubscription && profile.subscriptionUpdateStatus.result == .failed
  }

  /// Traffic and expiry are only worth a column when at least one profile reports them.
  static func showsUsageColumn(for profiles: [Profile]) -> Bool {
    profiles.contains { usageText(for: $0) != nil }
  }

  static func usageText(for profile: Profile) -> String? {
    var parts: [String] = []
    if let traffic = profile.subscriptionMetadata?.trafficSummary {
      parts.append(traffic)
    }
    if let expireAt = profile.subscriptionMetadata?.traffic?.expireAt {
      parts.append(String(
        format: String(localized: "Expires %@"),
        expireAt.formatted(date: .abbreviated, time: .omitted)
      ))
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
}

struct ProfilesView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(ProfileStore.self) private var profileStore
  @Environment(ProfileCoordinator.self) private var profileCoordinator
  @Environment(ProviderAnalyticsStore.self) private var providerAnalytics
  /// Browsing selection only. Making a profile current is a separate, explicit action, so restoring
  /// or moving this selection can never switch the runtime's profile.
  @State private var selectedProfileID: Profile.ID?
  @State private var showsDetailPane = true
  @State private var pageWidth: CGFloat = 0
  @State private var addSubscriptionPresented = false
  @State private var profileBeingEdited: Profile?
  @State private var providerInsightsProfile: Profile?
  @State private var editProfileName = ""
  @State private var editSubscriptionURL = ""
  @State private var editProviderOptions = SubscriptionProviderOptions.default
  @State private var editRollbackProviderOptions = SubscriptionProviderOptions.default
  @State private var editUpdatePolicy = SubscriptionUpdatePolicy.default
  @State private var editUpstreamEndpointID: UUID?
  @State private var profilePendingDeletion: Profile?
  @State private var migrationReport: ClientMigrationReport?
  @State private var manualProxySheetPresented = false
  @State private var endpointManagerPresented = false

  init() {}

  /// Seeds the browsing selection and detail pane for previews and fixture renders; the app starts
  /// from the defaults (current profile selected, pane shown).
  init(initialSelectedProfileID: Profile.ID?, initialShowsDetailPane: Bool = true) {
    _selectedProfileID = State(initialValue: initialSelectedProfileID)
    _showsDetailPane = State(initialValue: initialShowsDetailPane)
  }

  var body: some View {
    let profiles = profileStore.profiles
    let selectedProfile = selectedProfile(in: profiles)

    AdaptivePage(title: "Profiles") {
      addMenu
      updateButton(selectedProfile: selectedProfile)
      moreMenu(selectedProfile: selectedProfile, hasSubscriptions: profiles.contains(where: \.isSubscription))
    } content: {
      VStack(alignment: .leading, spacing: 10) {
        if profiles.isEmpty {
          emptyState
        } else {
          workspace(profiles: profiles, selectedProfile: selectedProfile)
        }

        if let message = profileCoordinator.message {
          Label(message, systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
            .lineLimit(2)
        }

        if appModel.lastRuntimeApplyOutcome != nil {
          RuntimeApplyOutcomeBanner()
        }

        if let error = appModel.lastError,
           PageErrorPresentation.showsInlineError(readinessIssue: appModel.readinessIssue, hasDetails: appModel.lastErrorDetails != nil)
        {
          GlobalErrorBanner(
            message: error,
            details: appModel.lastErrorDetails
          )
        }
      }
    }
    .onAppear {
      reconcileSelection(with: profiles)
    }
    .onChange(of: profiles.map(\.id)) { _, _ in
      reconcileSelection(with: profileStore.profiles)
    }
    .onDeleteCommand {
      if let selectedProfile {
        profilePendingDeletion = selectedProfile
      }
    }
    .sheet(isPresented: $addSubscriptionPresented) {
      AddSubscriptionSheet(onCancel: { addSubscriptionPresented = false }) {
        addSubscriptionPresented = false
      }
      .environment(appModel)
      .environment(profileCoordinator)
    }
    .sheet(item: $profileBeingEdited) { profile in
      ProfileEditSheet(
        profile: currentProfile(matching: profile) ?? profile,
        name: $editProfileName,
        subscriptionURL: $editSubscriptionURL,
        providerOptions: $editProviderOptions,
        rollbackProviderOptions: editRollbackProviderOptions,
        updatePolicy: $editUpdatePolicy,
        upstreamEndpointID: $editUpstreamEndpointID,
        outboundProxyEndpoints: selectableUpstreamEndpoints(for: profile),
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
    .sheet(isPresented: $manualProxySheetPresented) {
      ManualProxyProfileSheet(
        onCancel: { manualProxySheetPresented = false },
        onSave: { endpoint, password, profileName in
          Task { @MainActor in
            guard await appModel.addManualProxyProfile(
              endpoint: endpoint,
              password: password,
              profileName: profileName
            ) else { return }
            manualProxySheetPresented = false
          }
        }
      )
      .environment(appModel)
    }
    .sheet(isPresented: $endpointManagerPresented) {
      OutboundProxyEndpointManagerSheet(
        onClose: { endpointManagerPresented = false }
      )
      .environment(appModel)
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

  // MARK: - Page actions

  /// Every way a profile enters ClashMax, in one place. The subscription URL field used to sit
  /// permanently above the list; it now appears only when the user asks to add one.
  private var addMenu: some View {
    Menu {
      Button {
        addSubscriptionPresented = true
      } label: {
        Label("Add Subscription…", systemImage: "link.badge.plus")
      }
      Button {
        appModel.importLocalProfile()
      } label: {
        Label("Import YAML…", systemImage: "square.and.arrow.down")
      }
      Button {
        manualProxySheetPresented = true
      } label: {
        Label("Add Manual Proxy…", systemImage: "point.3.connected.trianglepath.dotted")
      }
      Divider()
      Button {
        importClientMigration()
      } label: {
        Label("Import from Other Client…", systemImage: "arrow.triangle.branch")
      }
    } label: {
      Label("Add", systemImage: "plus")
    }
    .help("Add a subscription, import a YAML file, add a manual proxy, or import from another client")
  }

  /// Updating the selected subscription is the page's one primary action. The wider scopes (all, due)
  /// live in More ▾: a split button would have put them one click away, but SwiftUI's split menu
  /// exposes its chevron to VoiceOver as an unnamed menu button, so the plain button won.
  private func updateButton(selectedProfile: Profile?) -> some View {
    let canUpdateSelected = selectedProfile.map { $0.isSubscription && !isUpdating($0) } ?? false
    let isUpdatingSelected = selectedProfile.map(isUpdating) ?? false
    return Button {
      if let selectedProfile {
        updateSubscription(selectedProfile)
      }
    } label: {
      Label(
        isUpdatingSelected ? "Updating" : "Update",
        systemImage: isUpdatingSelected ? "clock.arrow.circlepath" : "arrow.triangle.2.circlepath"
      )
    }
    .disabled(!canUpdateSelected)
    .help(canUpdateSelected ? "Update the selected subscription" : "Only subscription profiles can be updated")
  }

  private func moreMenu(selectedProfile: Profile?, hasSubscriptions: Bool) -> some View {
    Menu {
      profileActions(for: selectedProfile, includesEdit: true)
      Divider()
      Button("Update All") {
        appModel.updateAllSubscriptions()
      }
      .disabled(!hasSubscriptions)
      Button("Update Due") {
        appModel.updateDueSubscriptions()
      }
      .disabled(!hasSubscriptions)
      Divider()
      Toggle("Show Details", isOn: $showsDetailPane)
      Button {
        endpointManagerPresented = true
      } label: {
        Label("Manage Proxy Endpoints…", systemImage: "network")
      }
    } label: {
      Label("More", systemImage: "ellipsis.circle")
    }
    .help("More profile actions")
  }

  /// Shared between the More menu and the row context menu so both offer exactly the same set.
  @ViewBuilder
  private func profileActions(for profile: Profile?, includesEdit: Bool) -> some View {
    let isActive = profile.map { profileStore.activeProfileID == $0.id } ?? false
    Button("Set as Current") {
      if let profile {
        appModel.selectProfile(profile)
      }
    }
    .disabled(profile == nil || isActive)

    if includesEdit {
      Button("Edit…") {
        if let profile {
          beginEditing(profile)
        }
      }
      .disabled(profile == nil)
    }

    Button("Update Subscription") {
      if let profile {
        updateSubscription(profile)
      }
    }
    .disabled(!(profile.map { $0.isSubscription && !isUpdating($0) } ?? false))

    Button("Provider Details…") {
      providerInsightsProfile = profile
    }
    .disabled(profile == nil)

    Divider()

    Button("Delete…", role: .destructive) {
      profilePendingDeletion = profile
    }
    .disabled(profile == nil)
  }

  // MARK: - Content

  private var emptyState: some View {
    ContentUnavailableView {
      Label("No profiles", systemImage: "doc.badge.plus")
    } description: {
      Text("Profiles stay unchanged on disk; ClashMax generates a runtime copy when starting.")
    } actions: {
      Button("Add Subscription…") {
        addSubscriptionPresented = true
      }
      Button("Import YAML…") {
        appModel.importLocalProfile()
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
  }

  private func workspace(profiles: [Profile], selectedProfile: Profile?) -> some View {
    let showsPane = ProfilesLayout.showsDetailPane(pageWidth: pageWidth, requested: showsDetailPane)
    return VStack(spacing: 8) {
      HStack(alignment: .top, spacing: 12) {
        profileTable(profiles: profiles)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        if showsPane {
          ProfileDetailPane(
            profile: selectedProfile,
            isActive: selectedProfile.map { profileStore.activeProfileID == $0.id } ?? false,
            isUpdating: selectedProfile.map(isUpdating) ?? false,
            sourceSummary: selectedProfile.map(sourceSummary) ?? "",
            upstreamEndpointName: selectedProfile.flatMap(upstreamEndpoint)?.name,
            onActivate: { profile in appModel.selectProfile(profile) },
            onEdit: beginEditing,
            onUpdate: updateSubscription,
            onProviderDetails: { profile in providerInsightsProfile = profile }
          )
          .frame(width: ProfilesLayout.detailPaneWidth, alignment: .topLeading)
          .frame(maxHeight: .infinity, alignment: .topLeading)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

      PageStatusFooter(text: String.localizedStringWithFormat(
        NSLocalizedString("%lld profiles", comment: ""),
        Int64(profiles.count)
      ))
    }
    .onGeometryChange(for: CGFloat.self) { proxy in
      proxy.size.width
    } action: { width in
      pageWidth = width
    }
  }

  private func profileTable(profiles: [Profile]) -> some View {
    Table(profiles, selection: $selectedProfileID) {
      TableColumn("Name") { profile in
        ProfileNameCell(
          profile: profile,
          isActive: profileStore.activeProfileID == profile.id,
          isUpdating: isUpdating(profile)
        )
      }
      .width(min: 130, ideal: 180)

      TableColumn("Source") { profile in
        Text(profile.source.displayName)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .width(min: 72, ideal: 84, max: 120)

      // No fixed width: the status line takes whatever the pane leaves, so the table never needs a
      // horizontal scroller at the minimum window.
      TableColumn("Status") { profile in
        Text(ProfileStatusSummary.text(for: profile, isUpdating: isUpdating(profile)))
          .foregroundStyle(ProfileStatusSummary.isFailure(profile) ? Color.red : Color.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          .help(ProfileStatusSummary.text(for: profile, isUpdating: isUpdating(profile)))
      }

      if ProfilesLayout.showsUsageColumn(pageWidth: pageWidth, hasUsageData: ProfileStatusSummary.showsUsageColumn(for: profiles)) {
        TableColumn("Usage") { profile in
          Text(ProfileStatusSummary.usageText(for: profile) ?? "")
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .width(min: 120, ideal: 200)
      }
    }
    .contextMenu(forSelectionType: Profile.ID.self) { ids in
      profileActions(for: ids.first.flatMap { id in profiles.first { $0.id == id } }, includesEdit: true)
    } primaryAction: { ids in
      // Double-click opens the editor; making a profile current stays a deliberate menu action.
      if let id = ids.first, let profile = profiles.first(where: { $0.id == id }) {
        beginEditing(profile)
      }
    }
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  // MARK: - Selection

  private func selectedProfile(in profiles: [Profile]) -> Profile? {
    guard let selectedProfileID else { return nil }
    return profiles.first { $0.id == selectedProfileID }
  }

  /// Keeps the browsing selection pointing at a profile that still exists, defaulting to the current
  /// profile the first time the page appears. This only ever writes `selectedProfileID`.
  private func reconcileSelection(with profiles: [Profile]) {
    if let selectedProfileID, profiles.contains(where: { $0.id == selectedProfileID }) {
      return
    }
    selectedProfileID = profileStore.activeProfileID.flatMap { activeID in
      profiles.first { $0.id == activeID }?.id
    } ?? profiles.first?.id
  }

  private func isUpdating(_ profile: Profile) -> Bool {
    profileCoordinator.updatingProfileIDs.contains(profile.id)
  }

  private func updateSubscription(_ profile: Profile) {
    guard profile.isSubscription else { return }
    Task { @MainActor in
      await appModel.updateSubscription(profile)
    }
  }

  /// What the detail pane says about where a profile comes from. Never the full subscription URL:
  /// the host is enough to tell profiles apart, and the URL itself carries the token.
  private func sourceSummary(_ profile: Profile) -> String {
    switch profile.source {
    case .subscription:
      if let sourceURLString = profileStore.subscriptionURLString(for: profile),
         let host = URL(string: sourceURLString)?.host(percentEncoded: false)
      {
        return host
      }
      return String(localized: "Subscription URL unavailable")
    case let .localFile(originalPath):
      guard let originalPath else { return String(localized: "Local YAML") }
      return URL(fileURLWithPath: originalPath).lastPathComponent
    case .manualProxy:
      guard let manualEndpoint = manualEndpoint(for: profile) else {
        return String(localized: "Manual Proxy · Missing Endpoint")
      }
      let type = manualEndpoint.kind == .socks5 ? "SOCKS5" : "HTTP"
      return "\(type) · \(manualEndpoint.name)"
    }
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
    editUpstreamEndpointID = profile.upstreamEndpointID
    profileBeingEdited = profile
  }

  private func closeEditSheet() {
    profileBeingEdited = nil
    editProfileName = ""
    editSubscriptionURL = ""
    editProviderOptions = .default
    editRollbackProviderOptions = .default
    editUpdatePolicy = .default
    editUpstreamEndpointID = nil
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

      if workingProfile.upstreamEndpointID != editUpstreamEndpointID {
        guard await appModel.setUpstreamEndpoint(editUpstreamEndpointID, for: workingProfile) else {
          return
        }
        workingProfile = currentProfile(matching: workingProfile) ?? workingProfile
      }

      if workingProfile.name != trimmedName {
        guard await appModel.renameProfileAsync(workingProfile, to: trimmedName) else { return }
      }
      closeEditSheet()
    }
  }

  private func manualEndpoint(for profile: Profile) -> OutboundProxyEndpoint? {
    guard case let .manualProxy(endpointID) = profile.source else { return nil }
    return appModel.outboundProxyEndpoints.first { $0.id == endpointID }
  }

  private func upstreamEndpoint(for profile: Profile) -> OutboundProxyEndpoint? {
    guard let endpointID = profile.upstreamEndpointID else { return nil }
    return appModel.outboundProxyEndpoints.first { $0.id == endpointID }
  }

  private func selectableUpstreamEndpoints(for profile: Profile) -> [OutboundProxyEndpoint] {
    let manualEndpointID: UUID?
    if case let .manualProxy(endpointID) = profile.source {
      manualEndpointID = endpointID
    } else {
      manualEndpointID = nil
    }
    return appModel.outboundProxyEndpoints.filter { $0.id != manualEndpointID }
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
            importedProviderOptions = providerOptionsByApplyingRuleSnippets(
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

    // Validated by the parser, so this is expected to succeed; `updateGeoDatabaseSettings` still
    // reports its own refusal through `lastError` rather than failing silently if it ever does not.
    if let geoDatabase = report.geoDatabase {
      appModel.updateGeoDatabaseSettings(geoDatabase)
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
         subscriptionSourceIDs.contains(profileSourceID)
      {
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
      "Directory: \(report.configDirectory)",
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
      report.geoDatabase.map { geo in
        var parts = [
          "geo-auto-update: \(geo.autoUpdateEnabled)",
          "geo-update-interval: \(geo.normalizedUpdateIntervalHours)",
          "geodata-mode: \(geo.geodataMode)",
        ]
        if !geo.usesDefaultURLs {
          parts.append("geox-url: custom")
        }
        return parts.joined(separator: ", ")
      },
      report.systemProxyEnabled.map { "system proxy intent: \($0)" },
      report.ports.isEmpty ? nil : report.ports.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "),
      report.bypassDomains.isEmpty ? nil : "bypass: \(report.bypassDomains.joined(separator: ", "))",
      shortcutValues.isEmpty ? nil : "shortcuts: \(shortcutValues.joined(separator: ", "))",
    ]
    .compactMap(\.self)
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

  private func migrationSection(_ title: LocalizedStringResource, values: [String]) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
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

private struct ProfileNameCell: View {
  let profile: Profile
  let isActive: Bool
  let isUpdating: Bool

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(Color.accentColor)
        .opacity(isActive ? 1 : 0)
        .frame(width: 16)
        .accessibilityHidden(!isActive)
        .accessibilityLabel("Current")

      Text(profile.name)
        .fontWeight(isActive ? .semibold : .regular)
        .lineLimit(1)
        .truncationMode(.tail)

      if isUpdating {
        ProgressView()
          .controlSize(.mini)
      }
    }
    .help(profile.name)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(isActive ? String(format: String(localized: "%@, current profile"), profile.name) : profile.name)
  }
}

/// Facts and actions for the selected profile. Selection-driven so the list never carries them.
private struct ProfileDetailPane: View {
  let profile: Profile?
  let isActive: Bool
  let isUpdating: Bool
  let sourceSummary: String
  let upstreamEndpointName: String?
  let onActivate: (Profile) -> Void
  let onEdit: (Profile) -> Void
  let onUpdate: (Profile) -> Void
  let onProviderDetails: (Profile) -> Void

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        if let profile {
          header(profile)
          facts(profile)
          actions(profile)
        } else {
          Text("Select a profile to see its details.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .padding(.top, 4)
      .padding(.leading, 12)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .overlay(alignment: .leading) {
      Divider()
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Profile details")
  }

  private func header(_ profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(profile.name)
        .font(.headline)
        .lineLimit(2)
        .fixedSize(horizontal: false, vertical: true)

      if isActive {
        Label("Current profile", systemImage: "checkmark.circle.fill")
          .font(.callout)
          .foregroundStyle(Color.accentColor)
      } else {
        Button {
          onActivate(profile)
        } label: {
          Label("Set as Current", systemImage: "checkmark.circle")
        }
        .controlSize(.small)
        .help("Use this profile the next time the runtime starts, or restart now if it is running")
      }
    }
  }

  private func facts(_ profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      fact("Source", profile.source.displayName)
      fact(profile.isSubscription ? "Host" : "Location", sourceSummary)
      if let upstreamEndpointName {
        fact("Upstream", upstreamEndpointName)
      }

      Divider()

      fact(
        "Status",
        ProfileStatusSummary.text(for: profile, isUpdating: isUpdating),
        tint: ProfileStatusSummary.isFailure(profile) ? .red : .primary
      )
      if profile.isSubscription {
        if let nextUpdateAt = profile.subscriptionUpdateStatus.nextUpdateAt {
          fact("Next Update", nextUpdateAt.formatted(date: .abbreviated, time: .shortened))
        }
        fact("Interval", intervalText(profile))
        if let usage = profile.subscriptionMetadata?.trafficSummary {
          fact("Usage", usage)
        }
        if let expireAt = profile.subscriptionMetadata?.traffic?.expireAt {
          fact("Expires", expireAt.formatted(date: .abbreviated, time: .omitted))
        }
      }
      fact("Updated", profile.updatedAt.formatted(date: .abbreviated, time: .shortened))
    }
  }

  private func actions(_ profile: Profile) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        onEdit(profile)
      } label: {
        Label("Edit…", systemImage: "pencil")
      }
      if profile.isSubscription {
        Button {
          onUpdate(profile)
        } label: {
          Label(isUpdating ? "Updating" : "Update Subscription", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(isUpdating)
      }
      Button {
        onProviderDetails(profile)
      } label: {
        Label("Provider Details…", systemImage: "shippingbox")
      }
    }
    .controlSize(.small)
    .buttonStyle(.bordered)
  }

  private func fact(_ title: LocalizedStringKey, _ value: String, tint: Color = .primary) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout)
        .foregroundStyle(tint)
        .lineLimit(3)
        .truncationMode(.middle)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
    .accessibilityElement(children: .combine)
  }

  private func intervalText(_ profile: Profile) -> String {
    if !profile.subscriptionUpdatePolicy.automaticUpdatesEnabled {
      return String(localized: "Automatic updates off")
    }
    if let minutes = profile.subscriptionUpdatePolicy.intervalOverrideMinutes, minutes > 0 {
      return SubscriptionFetchSettings.intervalDescription(minutes)
    }
    if let minutes = profile.subscriptionMetadata?.updateIntervalMinutes, minutes > 0 {
      return SubscriptionFetchSettings.intervalDescription(minutes)
    }
    return String(localized: "Default")
  }
}

/// The add-subscription flow, presented on demand instead of living above the list.
private struct AddSubscriptionSheet: View {
  @Environment(AppModel.self) private var appModel
  @Environment(ProfileCoordinator.self) private var profileCoordinator
  let onCancel: () -> Void
  let onAdded: () -> Void
  @State private var subscriptionURL = ""
  @State private var upstreamEndpointID: UUID?
  @State private var attemptFailed = false
  @FocusState private var isURLFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add Subscription")
          .font(.title3.weight(.semibold))
        Text("ClashMax downloads the profile, validates it with the core, and keeps the original YAML unchanged.")
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      VStack(alignment: .leading, spacing: 10) {
        TextField("Subscription URL", text: $subscriptionURL)
          .textFieldStyle(.roundedBorder)
          .focused($isURLFocused)
          .disabled(profileCoordinator.isAddingSubscription)
          .onSubmit(addIfPossible)

        HStack(spacing: 10) {
          Text("Download via")
            .foregroundStyle(.secondary)
          Picker("Download via", selection: $upstreamEndpointID) {
            Text("No Upstream").tag(nil as UUID?)
            ForEach(appModel.outboundProxyEndpoints) { endpoint in
              Text(endpointLabel(endpoint))
                .tag(Optional(endpoint.id))
            }
          }
          .labelsHidden()
          .frame(maxWidth: 260)
        }
      }

      if profileCoordinator.isAddingSubscription {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Fetching and validating subscription...")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      } else if attemptFailed, let error = appModel.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }

      Divider()

      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button(profileCoordinator.isAddingSubscription ? "Adding" : "Add", action: addIfPossible)
          .keyboardShortcut(.defaultAction)
          .disabled(!canAdd)
      }
    }
    .padding(20)
    .frame(width: 520)
    .onAppear {
      isURLFocused = true
    }
  }

  private var canAdd: Bool {
    !subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !profileCoordinator.isAddingSubscription
  }

  private func addIfPossible() {
    guard canAdd else { return }
    let urlString = subscriptionURL
    attemptFailed = false
    Task { @MainActor in
      let didAdd = await appModel.addSubscription(
        urlString: urlString,
        upstreamEndpointID: upstreamEndpointID
      )
      if didAdd {
        onAdded()
      } else {
        attemptFailed = true
      }
    }
  }

  private func endpointLabel(_ endpoint: OutboundProxyEndpoint) -> String {
    let type = endpoint.kind == .socks5 ? "SOCKS5" : "HTTP"
    if appModel.outboundProxyEndpointSecretStates[endpoint.id] == .missingSecret {
      return "\(endpoint.name) · \(type) · \(String(localized: "Missing Password"))"
    }
    return "\(endpoint.name) · \(type)"
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
      GridItem(.flexible(minimum: 130), spacing: 10, alignment: .topLeading),
    ]
  }

  private func metric(_ title: LocalizedStringResource, _ value: String, _ symbolName: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: symbolName)
        .foregroundStyle(.secondary)
        .frame(width: 16)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
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

  private func fact(_ title: LocalizedStringResource, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
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

  private func detail(_ title: LocalizedStringResource, _ value: String, tint: Color = .secondary) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 5) {
      Text(title)
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
  @Binding var upstreamEndpointID: UUID?
  let outboundProxyEndpoints: [OutboundProxyEndpoint]
  let subscriptionDefaultUpdateIntervalMinutes: Int
  let developerMode: Bool
  let onCancel: () -> Void
  let onResetRemoteName: () -> Void
  let onRollbackProviderOptions: () -> Void
  let onSave: () -> Void
  @FocusState private var isNameFocused: Bool
  @State private var providerOptionsValidationError: String?
  @State private var showsUpdatePolicy = true
  @State private var showsProviderOptions = false

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
          } else {
            ProfileEditRow("Source") {
              Text(profile.source.displayName)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
          }

          ProfileEditRow("Upstream Proxy") {
            Picker("Upstream Proxy", selection: $upstreamEndpointID) {
              Text("Off").tag(nil as UUID?)
              ForEach(outboundProxyEndpoints) { endpoint in
                let type = endpoint.kind == .socks5 ? "SOCKS5" : "HTTP"
                Text("\(endpoint.name) · \(type)")
                  .tag(Optional(endpoint.id))
              }
            }
            .labelsHidden()
          }

          if let upstreamEndpoint = outboundProxyEndpoints.first(where: { $0.id == upstreamEndpointID }),
             upstreamEndpoint.isTCPOnly
          {
            ProfileEditContentRow {
              Label(
                "TCP Only: System Proxy does not capture UDP; TUN and Network Extension reject UDP for this profile.",
                systemImage: "exclamationmark.triangle"
              )
              .font(.caption)
              .foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
            }
          }

          // The rarely-touched sections open on demand so the sheet reads top-down as name, source,
          // upstream, and only then the update policy, provider options and diagnostics.
          if profile.isSubscription {
            Divider()

            ProfileEditDisclosureRow("Subscription Updates", isExpanded: $showsUpdatePolicy) {
              SubscriptionUpdatePolicyEditor(policy: $updatePolicy, showsHeader: false)
            }

            ProfileEditDisclosureRow("Provider Options", isExpanded: $showsProviderOptions) {
              SubscriptionProviderOptionsEditor(
                profile: profile,
                options: $providerOptions,
                validationError: $providerOptionsValidationError,
                rollbackOptions: rollbackProviderOptions,
                developerMode: developerMode,
                onRollback: onRollbackProviderOptions,
                showsHeader: false
              )
            }

            SubscriptionDiagnosticsView(
              profile: profile,
              subscriptionURL: subscriptionURL,
              defaultUpdateIntervalMinutes: subscriptionDefaultUpdateIntervalMinutes
            )

            if let providerOptionsValidationError, !showsProviderOptions {
              ProfileEditContentRow {
                Label(providerOptionsValidationError, systemImage: "exclamationmark.triangle.fill")
                  .font(.caption)
                  .foregroundStyle(.red)
                  .lineLimit(2)
              }
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
  /// `nil` when the enclosing disclosure already names the section.
  let title: LocalizedStringKey?
  @ViewBuilder let content: Content

  init(_ title: LocalizedStringKey?, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let title {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
      }

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
  var showsHeader = true
  @State private var intervalDraft = ""

  var body: some View {
    ProfileEditSection(showsHeader ? "Subscription Updates" : nil) {
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

private struct GlobalErrorBanner: View {
  let message: String
  let details: String?
  @State private var isDetailsExpanded = false
  @State private var copyConfirmation: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .top, spacing: 8) {
        Label(message, systemImage: "exclamationmark.triangle.fill")
          .font(.callout)
          .foregroundStyle(.red)
          .lineLimit(3)
          .textSelection(.enabled)
        Spacer(minLength: 0)
        if details != nil {
          Button {
            withAnimation(.easeInOut(duration: 0.16)) {
              isDetailsExpanded.toggle()
            }
          } label: {
            Label(
              isDetailsExpanded ? "Hide Details" : "Show Details",
              systemImage: isDetailsExpanded ? "chevron.up" : "chevron.down"
            )
            .labelStyle(.titleOnly)
            .font(.caption)
          }
          .buttonStyle(.borderless)
          Button {
            copyDetails()
          } label: {
            Label(
              copyConfirmation == nil ? "Copy Details" : "Copied",
              systemImage: copyConfirmation == nil ? "doc.on.doc" : "checkmark"
            )
            .labelStyle(.titleAndIcon)
            .font(.caption)
          }
          .buttonStyle(.borderless)
        }
      }

      if isDetailsExpanded, let details {
        ScrollView(.vertical, showsIndicators: true) {
          Text(details)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 220)
        .background(
          .quaternary,
          in: SurfaceRadius.shape(SurfaceRadius.chip)
        )

        Text("Review before sharing: this may include hostnames, ports, or other details from your profile.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func copyDetails() {
    guard let details else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(details, forType: .string)
    let stamp = Date()
    copyConfirmation = stamp
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_600_000_000)
      if copyConfirmation == stamp {
        copyConfirmation = nil
      }
    }
  }
}

private struct SubscriptionDiagnosticsView: View {
  let profile: Profile
  let subscriptionURL: String
  let defaultUpdateIntervalMinutes: Int
  @State private var isExpanded = false
  @State private var isPreflightOutputExpanded = false
  @State private var preflightCopyConfirmation: Date?

  private var diagnostics: SubscriptionDiagnostics {
    profile.subscriptionDiagnostics
  }

  private var latestFetch: SubscriptionFetchDiagnostics? {
    diagnostics.latestFetch
  }

  private var latestPreflight: SubscriptionPreflightDiagnostics? {
    diagnostics.latestPreflight
  }

  private var preflightFullOutput: String? {
    latestPreflight?.fullMessage
  }

  var body: some View {
    ProfileEditDisclosureRow("Subscription Diagnostics", isExpanded: $isExpanded) {
      ProfileEditInfoRow {
        VStack(alignment: .leading, spacing: 12) {
          diagnosticsGrid
          if preflightFullOutput != nil {
            preflightOutputSection
          }
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

  private var preflightOutputSection: some View {
    VStack(alignment: .leading, spacing: 7) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            isPreflightOutputExpanded.toggle()
          }
        } label: {
          HStack(spacing: 5) {
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
              .rotationEffect(.degrees(isPreflightOutputExpanded ? 90 : 0))
              .frame(width: 10)
            Text("Preflight Output")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        Spacer(minLength: 0)
        Button {
          copyPreflightFullOutput()
        } label: {
          Label(
            preflightCopyConfirmation == nil ? "Copy" : "Copied",
            systemImage: preflightCopyConfirmation == nil ? "doc.on.doc" : "checkmark"
          )
          .labelStyle(.titleAndIcon)
          .font(.caption)
        }
        .buttonStyle(.borderless)
        .disabled(preflightFullOutput == nil)
      }

      if isPreflightOutputExpanded, let fullOutput = preflightFullOutput {
        ScrollView(.vertical, showsIndicators: true) {
          Text(fullOutput)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
        .frame(maxHeight: 220)
        .background(
          .quaternary,
          in: SurfaceRadius.shape(SurfaceRadius.chip)
        )

        Text("Review before sharing: this may include hostnames, ports, or other details from your profile.")
          .font(.caption2)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func copyPreflightFullOutput() {
    guard let fullOutput = preflightFullOutput else { return }
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(fullOutput, forType: .string)
    let stamp = Date()
    preflightCopyConfirmation = stamp
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 1_600_000_000)
      if preflightCopyConfirmation == stamp {
        preflightCopyConfirmation = nil
      }
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
      GridItem(.flexible(minimum: 170), spacing: 10, alignment: .topLeading),
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
  @Environment(AppModel.self) private var appModel
  let profile: Profile
  @Binding var options: SubscriptionProviderOptions
  @Binding var validationError: String?
  let rollbackOptions: SubscriptionProviderOptions
  let developerMode: Bool
  let onRollback: () -> Void
  var showsHeader = true
  @State private var isRuleOverlayPresented = false
  @State private var showsAdvancedOptions = false

  var body: some View {
    ProfileEditSection(showsHeader ? "Provider Options" : nil) {
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
            RuleOverlayDraftPopover(
              baseline: options.ruleOverlay,
              pendingSummary: String(localized: "Staged in this editor: saving the profile applies it to the runtime."),
              applyTitle: "Stage"
            ) { draft in
              options.ruleOverlay = draft
              isRuleOverlayPresented = false
            }
            .padding(16)
            .frame(width: 460)
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
            .help("Merged into this one profile before ClashMax writes its own keys, so mode, tun, dns.enable and the geo keys still win over it. For an override that actually has the last word, use a Raw YAML snippet on the Routing page.")

          customHeadersEditor
        }
      } else {
        ProfileEditFootnote(verbatim: String(localized: "Developer Mode is required for legacy raw provider filters, YAML merge fields, and custom request headers. Nothing here is needed to override a Mihomo key: a Raw YAML snippet on the Routing page reaches every key, with the same preflight and rollback as any other snippet."))
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

private struct OutboundProxyEndpointDraft {
  var id: UUID
  var name: String
  var kind: OutboundProxyEndpointKind
  var host: String
  var port: Int
  var authenticationEnabled: Bool
  var username: String
  var password: String
  var httpTLSEnabled: Bool
  var httpServerName: String
  var httpSkipCertificateVerification: Bool
  var socks5UDPEnabled: Bool

  init(endpoint: OutboundProxyEndpoint? = nil) {
    id = endpoint?.id ?? UUID()
    name = endpoint?.name ?? ""
    kind = endpoint?.kind ?? .socks5
    host = endpoint?.host ?? ""
    port = endpoint?.port ?? 1080
    authenticationEnabled = endpoint?.authentication != nil
    username = endpoint?.authentication?.username ?? ""
    password = ""
    httpTLSEnabled = endpoint?.httpOptions.tlsEnabled ?? false
    httpServerName = endpoint?.httpOptions.serverName ?? ""
    httpSkipCertificateVerification = endpoint?.httpOptions.skipCertificateVerification ?? false
    socks5UDPEnabled = endpoint?.socks5Options.udpEnabled ?? false
  }

  var endpoint: OutboundProxyEndpoint {
    OutboundProxyEndpoint(
      id: id,
      name: name.trimmingCharacters(in: .whitespacesAndNewlines),
      kind: kind,
      host: host.trimmingCharacters(in: .whitespacesAndNewlines),
      port: port,
      authentication: authenticationEnabled
        ? OutboundProxyAuthentication(
          username: username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        : nil,
      httpOptions: OutboundProxyHTTPOptions(
        tlsEnabled: kind == .http && httpTLSEnabled,
        serverName: normalizedOptional(httpServerName),
        skipCertificateVerification: kind == .http
          && httpTLSEnabled
          && httpSkipCertificateVerification
      ),
      socks5Options: OutboundProxySOCKS5Options(
        udpEnabled: kind == .socks5 && socks5UDPEnabled
      )
    )
  }

  var suppliedPassword: String? {
    guard authenticationEnabled else { return nil }
    return normalizedOptional(password)
  }

  var hasRequiredMetadata: Bool {
    !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...65_535).contains(port)
      && (!authenticationEnabled
        || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  private func normalizedOptional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

private struct OutboundProxyEndpointEditorFields: View {
  @Binding var draft: OutboundProxyEndpointDraft

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ProfileEditRow("Type") {
        Picker("Type", selection: $draft.kind) {
          Text("SOCKS5").tag(OutboundProxyEndpointKind.socks5)
          Text("HTTP").tag(OutboundProxyEndpointKind.http)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
      }

      ProfileEditRow("Name") {
        TextField("Endpoint name", text: $draft.name)
          .textFieldStyle(.roundedBorder)
      }

      ProfileEditRow("Server") {
        HStack(spacing: 8) {
          TextField("Host or IP address", text: $draft.host)
            .textFieldStyle(.roundedBorder)
          TextField("Port", value: $draft.port, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .frame(width: 86)
        }
      }

      ProfileEditToggleRow("Authentication", isOn: $draft.authenticationEnabled)

      if draft.authenticationEnabled {
        ProfileEditRow("Username") {
          TextField("Username", text: $draft.username)
            .textFieldStyle(.roundedBorder)
        }
        ProfileEditRow("Password") {
          SecureField("Required for new credentials; leave blank to keep the saved password", text: $draft.password)
            .textFieldStyle(.roundedBorder)
        }
      }

      if draft.kind == .http {
        ProfileEditToggleRow("TLS to Proxy", isOn: $draft.httpTLSEnabled)
        if draft.httpTLSEnabled {
          ProfileEditRow("SNI") {
            TextField("Optional TLS server name", text: $draft.httpServerName)
              .textFieldStyle(.roundedBorder)
          }
          ProfileEditToggleRow(
            "Skip Proxy Certificate Check",
            isOn: $draft.httpSkipCertificateVerification
          )
          if draft.httpSkipCertificateVerification {
            ProfileEditContentRow {
              Label(
                "The proxy certificate will not be verified.",
                systemImage: "exclamationmark.shield"
              )
              .font(.caption)
              .foregroundStyle(.orange)
            }
          }
        }
      } else {
        ProfileEditToggleRow("SOCKS5 UDP", isOn: $draft.socks5UDPEnabled)
      }

      if draft.endpoint.isTCPOnly {
        ProfileEditContentRow {
          Label("TCP Only", systemImage: "network.slash")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)
        }
      }
    }
  }
}

private struct ManualProxyProfileSheet: View {
  @Environment(AppModel.self) private var appModel
  let onCancel: () -> Void
  let onSave: (OutboundProxyEndpoint, String?, String) -> Void
  @State private var profileName = ""
  @State private var draft = OutboundProxyEndpointDraft()

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Add Manual Proxy")
          .font(.title3.weight(.semibold))
        Text("Creates a shared endpoint and a profile that keeps private networks direct.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ProfileEditRow("Profile Name") {
            TextField("Optional; defaults to Manual Proxy", text: $profileName)
              .textFieldStyle(.roundedBorder)
          }
          Divider()
          OutboundProxyEndpointEditorFields(draft: $draft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 520)

      if let error = appModel.lastError {
        GlobalErrorBanner(message: error, details: appModel.lastErrorDetails)
      }

      Divider()
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Add") {
          onSave(
            draft.endpoint,
            draft.suppliedPassword,
            profileName.trimmingCharacters(in: .whitespacesAndNewlines)
          )
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(width: 640)
  }

  private var canSave: Bool {
    draft.hasRequiredMetadata
      && (!draft.authenticationEnabled || draft.suppliedPassword != nil)
  }
}

private struct OutboundProxyEndpointEditorContext: Identifiable {
  let id = UUID()
  var existingEndpoint: OutboundProxyEndpoint?
  var draft: OutboundProxyEndpointDraft

  init(endpoint: OutboundProxyEndpoint? = nil) {
    existingEndpoint = endpoint
    draft = OutboundProxyEndpointDraft(endpoint: endpoint)
  }
}

private struct OutboundProxyEndpointManagerSheet: View {
  @Environment(AppModel.self) private var appModel
  let onClose: () -> Void
  @State private var editorContext: OutboundProxyEndpointEditorContext?
  @State private var endpointPendingDeletion: OutboundProxyEndpoint?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Proxy Endpoints")
            .font(.title3.weight(.semibold))
          Text("Shared SOCKS5 and HTTP upstreams for manual profiles, subscriptions, and profile routing.")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          editorContext = OutboundProxyEndpointEditorContext()
        } label: {
          Label("Add Endpoint", systemImage: "plus")
        }
      }

      Divider()

      if let loadError = appModel.outboundProxyEndpointLoadError {
        GlobalErrorBanner(message: loadError, details: nil)
      } else if appModel.outboundProxyEndpoints.isEmpty {
        CenteredUnavailableState(
          title: "No proxy endpoints",
          systemImage: "network",
          message: "Add an endpoint here, or create one together with a Manual Proxy profile."
        )
        .frame(maxWidth: .infinity, minHeight: 260)
      } else {
        ScrollView {
          VStack(spacing: 0) {
            ForEach(appModel.outboundProxyEndpoints) { endpoint in
              endpointRow(endpoint)
              if endpoint.id != appModel.outboundProxyEndpoints.last?.id {
                Divider()
              }
            }
          }
          .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(.quaternary, lineWidth: 1)
          }
        }
      }

      if let error = appModel.lastError {
        GlobalErrorBanner(message: error, details: appModel.lastErrorDetails)
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
    .frame(minHeight: 500)
    .task {
      await appModel.refreshOutboundProxyEndpoints()
    }
    .sheet(item: $editorContext) { context in
      OutboundProxyEndpointEditorSheet(
        initialContext: context,
        onCancel: { editorContext = nil },
        onSave: { endpoint, password in
          Task { @MainActor in
            let didSave: Bool
            if context.existingEndpoint == nil {
              didSave = await appModel.addOutboundProxyEndpoint(endpoint, password: password)
            } else {
              didSave = await appModel.updateOutboundProxyEndpoint(endpoint, password: password)
            }
            if didSave {
              editorContext = nil
            }
          }
        }
      )
      .environment(appModel)
    }
    .alert("Delete Proxy Endpoint?", isPresented: deleteConfirmationPresented) {
      Button("Delete", role: .destructive) {
        guard let endpoint = endpointPendingDeletion else { return }
        endpointPendingDeletion = nil
        Task { @MainActor in
          _ = await appModel.deleteOutboundProxyEndpoint(endpoint.id)
        }
      }
      Button("Cancel", role: .cancel) {
        endpointPendingDeletion = nil
      }
    } message: {
      Text("Referenced endpoints cannot be deleted. ClashMax will list the profiles that must be changed first.")
    }
  }

  private func endpointRow(_ endpoint: OutboundProxyEndpoint) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: endpoint.kind == .socks5 ? "point.3.connected.trianglepath.dotted" : "network")
        .foregroundStyle(.secondary)
        .frame(width: 20)

      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(endpoint.name)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          endpointBadges(endpoint)
        }
        Text("\(endpoint.kind == .socks5 ? "SOCKS5" : "HTTP") · \(endpoint.host):\(endpoint.port)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button("Test") {
        Task { @MainActor in
          await appModel.testOutboundProxyEndpoint(endpoint.id)
        }
      }
      .disabled(appModel.outboundProxyEndpointTestStates[endpoint.id] == .testing)

      Button("Edit") {
        editorContext = OutboundProxyEndpointEditorContext(endpoint: endpoint)
      }

      Button(role: .destructive) {
        endpointPendingDeletion = endpoint
      } label: {
        Image(systemName: "trash")
      }
      .help("Delete proxy endpoint")
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private func endpointBadges(_ endpoint: OutboundProxyEndpoint) -> some View {
    if appModel.outboundProxyEndpointSecretStates[endpoint.id] == .missingSecret {
      endpointBadge("Missing Password", color: .red)
    } else {
      let state = appModel.outboundProxyEndpointTestStates[endpoint.id] ?? .untested
      switch state {
      case .untested:
        endpointBadge("Untested", color: .secondary)
      case .testing:
        endpointBadge("Testing", color: .blue)
      case .ready:
        endpointBadge("Ready", color: .green)
      case .unreachable:
        endpointBadge("Unreachable", color: .orange)
      }
    }
    if endpoint.isTCPOnly {
      endpointBadge("TCP Only", color: .orange)
    }
  }

  private func endpointBadge(_ title: LocalizedStringKey, color: Color) -> some View {
    Text(title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(color.opacity(0.1), in: Capsule())
  }

  private var deleteConfirmationPresented: Binding<Bool> {
    Binding(
      get: { endpointPendingDeletion != nil },
      set: { isPresented in
        if !isPresented {
          endpointPendingDeletion = nil
        }
      }
    )
  }
}

private struct OutboundProxyEndpointEditorSheet: View {
  @Environment(AppModel.self) private var appModel
  let initialContext: OutboundProxyEndpointEditorContext
  let onCancel: () -> Void
  let onSave: (OutboundProxyEndpoint, String?) -> Void
  @State private var draft: OutboundProxyEndpointDraft

  init(
    initialContext: OutboundProxyEndpointEditorContext,
    onCancel: @escaping () -> Void,
    onSave: @escaping (OutboundProxyEndpoint, String?) -> Void
  ) {
    self.initialContext = initialContext
    self.onCancel = onCancel
    self.onSave = onSave
    _draft = State(initialValue: initialContext.draft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(initialContext.existingEndpoint == nil ? "Add Proxy Endpoint" : "Edit Proxy Endpoint")
          .font(.title3.weight(.semibold))
        Text("Passwords are stored in Keychain and are never written to the endpoint manifest.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }

      ScrollView {
        OutboundProxyEndpointEditorFields(draft: $draft)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: 520)

      if let error = appModel.lastError {
        GlobalErrorBanner(message: error, details: appModel.lastErrorDetails)
      }

      Divider()
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
          .keyboardShortcut(.cancelAction)
        Button("Save") {
          onSave(draft.endpoint, draft.suppliedPassword)
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canSave)
      }
    }
    .padding(20)
    .frame(width: 640)
  }

  private var canSave: Bool {
    guard draft.hasRequiredMetadata else { return false }
    if initialContext.existingEndpoint == nil, draft.authenticationEnabled {
      return draft.suppliedPassword != nil
    }
    return true
  }
}
