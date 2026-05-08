import AppKit
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
  @Published var selectedSection: AppSection = .home
  @Published var overrides = RuntimeOverrides.defaultForLaunch()
  @Published var proxyRoutingMode: ProxyRoutingMode = .systemProxy
  @Published var systemProxySettings = SystemProxySettings.default {
    didSet {
      saveCodable(systemProxySettings, forKey: Self.systemProxySettingsDefaultsKey)
    }
  }
  @Published var tunSettings = TunSettings.default {
    didSet {
      overrides.tunSettings = tunSettings
      saveCodable(tunSettings, forKey: Self.tunSettingsDefaultsKey)
    }
  }
  @Published var delayTestSettings = DelayTestSettings.default {
    didSet {
      overrides.unifiedDelay = delayTestSettings.unifiedDelay
      saveCodable(delayTestSettings, forKey: Self.delayTestSettingsDefaultsKey)
    }
  }
  @Published var appTheme = AppTheme.system {
    didSet {
      saveCodable(appTheme, forKey: Self.appThemeDefaultsKey)
    }
  }
  @Published var externalControllerSettings = ExternalControllerSettings.default {
    didSet {
      syncExternalControllerSettings()
      saveCodable(externalControllerSettings, forKey: Self.externalControllerSettingsDefaultsKey)
    }
  }
  @Published private(set) var launchSettings = LaunchSettings.default
  @Published private(set) var runtimeOwner: RuntimeOwner = .stopped
  @Published var systemProxyEnabled = false
  @Published var tunEnabled = false
  @Published var tunnelCoreRunning = false
  @Published private(set) var isAddingSubscription = false
  @Published private(set) var startInFlight = false
  @Published private(set) var sessionStartedAt: Date?
  @Published var proxyGroups: [ProxyGroup] = []
  @Published var proxyProviders: [ProxyProvider] = []
  @Published var rules: [String] = []
  @Published var connections: [ConnectionSnapshot] = []
  @Published var logs: [LogEntry] = []
  @Published var helperLogs: [String] = []
  @Published var trafficSample: TrafficSample = .zero
  @Published var trafficHistory: [TrafficSample] = []
  @Published private(set) var publicIPInfoState: PublicIPInfoState = .idle
  @Published var lastError: String?
  @Published private(set) var updatingProfileIDs: Set<Profile.ID> = []
  @Published private(set) var profileOperationMessage: String?
  @Published private(set) var profilePreviewGroups: [ProxyGroup] = []
  @Published private(set) var previewRuntimeActive = false
  @Published private(set) var previewSelections: [String: String] = [:]
  @Published private(set) var providerHealthChecksInFlight: Set<ProxyProvider.ID> = []
  @Published private(set) var closingConnectionIDs: Set<ConnectionSnapshot.ID> = []
  @Published private(set) var closingAllConnections = false
  @Published var developerMode = false {
    didSet {
      defaults.set(developerMode, forKey: Self.developerModeDefaultsKey)
    }
  }

  let profileStore: ProfileStore
  let coreController: CoreProcessController
  let systemProxyController: SystemProxyController
  let helperClient: TunnelHelperClient
  private let loginItemService: any LoginItemManaging
  private let tunnelReadinessProbe: CoreReadinessProbing
  private let pingTester: any PingTesting
  private let publicIPInfoClient: any PublicIPInfoFetching
  private let paths: RuntimePaths
  private let normalizer = ConfigNormalizer()
  private let profilePreviewBuilder = ProfilePreviewBuilder()
  private var apiClient: (any MihomoAPIControlling)?
  private var startTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var pendingModeTask: Task<Void, Never>?
  private var pendingRoutingModeTask: Task<Void, Never>?
  private var systemProxyGuardTask: Task<Void, Never>?
  private var publicIPInfoTask: Task<Void, Never>?
  private var streamTasks: [Task<Void, Never>] = []
  private var logBuffer = BoundedBuffer<LogEntry>(limit: AppConstants.retainedLogLimit)
  private var connectionBuffer = BoundedBuffer<ConnectionSnapshot>(limit: AppConstants.retainedConnectionLimit)
  private let defaults: UserDefaults
  private static let previewSelectionsDefaultsKey = "io.github.clashmax.previewSelections"
  private static let developerModeDefaultsKey = "io.github.clashmax.developerMode"
  private static let systemProxySettingsDefaultsKey = "io.github.clashmax.systemProxySettings"
  private static let systemProxyManagedDefaultsKey = "io.github.clashmax.systemProxyManaged"
  private static let tunSettingsDefaultsKey = "io.github.clashmax.tunSettings"
  private static let delayTestSettingsDefaultsKey = "io.github.clashmax.delayTestSettings"
  private static let appThemeDefaultsKey = "io.github.clashmax.appTheme"
  private static let externalControllerSettingsDefaultsKey = "io.github.clashmax.externalControllerSettings"
  private static let externalControllerCORSSettingsDefaultsKey = "io.github.clashmax.externalControllerCORSSettings"
  static let publicIPRefreshInterval: TimeInterval = 300
  static let silentStartDefaultsKey = "io.github.clashmax.silentStart"
  static let startWallClockSeconds: TimeInterval = 22

  static func bootstrap() -> AppModel {
    do {
      let paths = try RuntimePaths.live()
      return AppModel(paths: paths)
    } catch {
      let fallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClashMax", isDirectory: true)
      try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
      let paths = RuntimePaths(
        appSupport: fallback,
        profiles: fallback.appendingPathComponent("Profiles", isDirectory: true),
        runtime: fallback.appendingPathComponent("Runtime", isDirectory: true),
        subscriptions: fallback.appendingPathComponent("Subscriptions", isDirectory: true),
        logs: fallback.appendingPathComponent("Logs", isDirectory: true)
      )
      let model = AppModel(paths: paths)
      model.lastError = UserFacingError.message(for: error)
      return model
    }
  }

  init(
    paths: RuntimePaths,
    profileStore: ProfileStore? = nil,
    coreController: CoreProcessController = CoreProcessController(),
    systemProxyController: SystemProxyController = SystemProxyController(),
    helperClient: TunnelHelperClient = TunnelHelperClient(),
    loginItemService: any LoginItemManaging = MainAppLoginItemService(),
    tunnelReadinessProbe: CoreReadinessProbing = MihomoCoreReadinessProbe(),
    apiClient: (any MihomoAPIControlling)? = nil,
    pingTester: any PingTesting = SystemPingTester(),
    publicIPInfoClient: any PublicIPInfoFetching = PublicIPInfoClient(),
    defaults: UserDefaults = .standard
  ) {
    self.paths = paths
    self.profileStore = profileStore ?? ProfileStore(paths: paths)
    self.coreController = coreController
    self.systemProxyController = systemProxyController
    self.helperClient = helperClient
    self.loginItemService = loginItemService
    self.tunnelReadinessProbe = tunnelReadinessProbe
    self.pingTester = pingTester
    self.publicIPInfoClient = publicIPInfoClient
    self.apiClient = apiClient
    self.defaults = defaults
    developerMode = defaults.bool(forKey: Self.developerModeDefaultsKey)
    systemProxySettings = Self.loadCodable(
      SystemProxySettings.self,
      forKey: Self.systemProxySettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    tunSettings = Self.loadCodable(
      TunSettings.self,
      forKey: Self.tunSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    delayTestSettings = Self.loadCodable(
      DelayTestSettings.self,
      forKey: Self.delayTestSettingsDefaultsKey,
      defaults: defaults
    ) ?? .default
    appTheme = Self.loadCodable(
      AppTheme.self,
      forKey: Self.appThemeDefaultsKey,
      defaults: defaults
    ) ?? .system
    let migratedCORSSettings = Self.loadCodable(
      ExternalControllerCORSSettings.self,
      forKey: Self.externalControllerCORSSettingsDefaultsKey,
      defaults: defaults
    )
    externalControllerSettings = Self.loadCodable(
      ExternalControllerSettings.self,
      forKey: Self.externalControllerSettingsDefaultsKey,
      defaults: defaults
    ) ?? ExternalControllerSettings(cors: migratedCORSSettings ?? .default)
    overrides.tunSettings = tunSettings
    overrides.unifiedDelay = delayTestSettings.unifiedDelay
    syncExternalControllerSettings()
    refreshLaunchSettings()
    recoverDanglingSystemProxyIfNeeded()
    refreshProfilePreview()
    loadPreviewSelectionsForActiveProfile()
  }

  var isCoreRunning: Bool {
    if case .running = coreController.status { return true }
    return tunnelCoreRunning
  }

  var isRunning: Bool {
    isCoreRunning && !previewRuntimeActive
  }

  var dashboardRuntimeState: DashboardRuntimeState {
    let effectiveCoreStatus: CoreStatus = previewRuntimeActive ? .stopped : coreController.status
    return DashboardRuntimeState.resolve(
      startInFlight: startInFlight,
      tunnelCoreRunning: previewRuntimeActive ? false : tunnelCoreRunning,
      coreStatus: effectiveCoreStatus,
      readinessIssue: readinessIssue
    )
  }

  var statusSummary: String {
    if previewRuntimeActive {
      return "Preview"
    }
    if tunnelCoreRunning {
      return "Running TUN"
    }
    switch coreController.status {
    case .stopped:
      return "Stopped"
    case .starting:
      return "Starting"
    case let .running(version):
      return version.map { "Running \($0)" } ?? "Running"
    case let .crashed(message):
      return "Crashed: \(message)"
    case .restarting:
      return "Restarting"
    }
  }

  var readinessIssue: String? {
    if profileStore.activeProfile == nil {
      return "No active profile selected."
    }
    if (try? bundledCoreURL()) == nil {
      return AppError.missingBundledCore.description
    }
    return nil
  }

  var proxyGroupsUnavailableMessage: String {
    if profileStore.activeProfile == nil {
      return "Add or select a profile first."
    }
    if !isCoreRunning {
      return "No proxy groups were found in the active profile. Start it to let Mihomo parse provider subscriptions."
    }
    return "No proxy groups were reported by Mihomo. Refresh runtime data or check the active profile's proxy-groups."
  }

  var visibleProxyGroups: [ProxyGroup] {
    if isCoreRunning {
      return mergedPreviewSelections(into: proxyGroups)
    }
    return mergedPreviewSelections(into: profilePreviewGroups)
  }

  var isShowingProxyPreview: Bool {
    !isCoreRunning && !profilePreviewGroups.isEmpty
  }

  var canControlRuntimeProxies: Bool {
    apiClient != nil
  }

  var canSelectProxyOffline: Bool {
    !isCoreRunning && profileStore.activeProfile != nil && !profilePreviewGroups.isEmpty
  }

  var userVisibleLogs: [LogEntry] {
    LogVisibility.visibleEntries(in: logs, developerMode: developerMode)
  }

  var proxyRuntimeActionMessage: String {
    if profileStore.activeProfile == nil {
      return "Add or select a profile before selecting proxies or testing delay."
    }
    if dashboardRuntimeState.isStarting {
      return "Wait for the core to finish starting before selecting proxies or testing delay."
    }
    if !isCoreRunning {
      return "Start the core before selecting proxies or testing delay."
    }
    return "Runtime controller is unavailable. Restart the core before selecting proxies or testing delay."
  }

  func importLocalProfile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.yaml, .yml, .text]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let profile = try profileStore.importLocalConfig(from: url)
      refreshProfilePreview()
      loadPreviewSelectionsForActiveProfile()
      lastError = nil
      profileOperationMessage = "Imported profile \(profile.name)."
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
    }
  }

  @discardableResult
  func addSubscription(name: String = "", urlString: String, session: URLSession = .shared) async -> Bool {
    guard !isAddingSubscription else { return false }

    let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURLString) else {
      profileOperationMessage = nil
      lastError = "Invalid subscription URL."
      return false
    }

    isAddingSubscription = true
    lastError = nil
    profileOperationMessage = nil
    defer { isAddingSubscription = false }

    do {
      let profile = try await profileStore.addSubscription(
        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
        url: url,
        session: session
      )
      refreshProfilePreview()
      loadPreviewSelectionsForActiveProfile()
      profileOperationMessage = "Added subscription \(profile.name)."
      return true
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func updateActiveSubscription() {
    guard let profile = profileStore.activeProfile else { return }
    Task {
      await updateSubscription(profile)
    }
  }

  @discardableResult
  func updateSubscription(_ profile: Profile, session: URLSession = .shared) async -> Bool {
    guard profile.isSubscription else {
      profileOperationMessage = nil
      lastError = "Only subscription profiles can be updated."
      return false
    }
    guard !updatingProfileIDs.contains(profile.id) else { return false }

    setProfile(profile.id, updating: true)
    lastError = nil
    profileOperationMessage = nil
    defer { setProfile(profile.id, updating: false) }

    do {
      try await profileStore.updateSubscription(profile, session: session)
      refreshProfilePreview()
      let name = profileStore.profiles.first { $0.id == profile.id }?.name ?? profile.name
      profileOperationMessage = "Updated subscription \(name)."
      return true
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  @discardableResult
  func updateSubscriptionSource(_ profile: Profile, urlString: String, session: URLSession = .shared) async -> Bool {
    guard profile.isSubscription else {
      profileOperationMessage = nil
      lastError = "Only subscription profiles can update their source URL."
      return false
    }
    guard !updatingProfileIDs.contains(profile.id) else { return false }
    let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedURLString) else {
      profileOperationMessage = nil
      lastError = "Invalid subscription URL."
      return false
    }

    setProfile(profile.id, updating: true)
    lastError = nil
    profileOperationMessage = nil
    defer { setProfile(profile.id, updating: false) }

    do {
      try await profileStore.updateSubscriptionSource(profile, url: url, session: session)
      refreshProfilePreview()
      loadPreviewSelectionsForActiveProfile()
      let name = profileStore.profiles.first { $0.id == profile.id }?.name ?? profile.name
      profileOperationMessage = "Updated subscription source for \(name)."
      return true
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func renameActiveProfile(to name: String) {
    guard let profile = profileStore.activeProfile else { return }
    renameProfile(profile, to: name)
  }

  func renameProfile(_ profile: Profile, to name: String) {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      profileOperationMessage = nil
      lastError = "Profile name cannot be empty."
      return
    }

    do {
      try profileStore.rename(profile, to: trimmedName)
      refreshProfilePreview()
      lastError = nil
      profileOperationMessage = "Renamed profile to \(trimmedName)."
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
    }
  }

  func resetSubscriptionName(_ profile: Profile) {
    do {
      try profileStore.resetSubscriptionName(profile)
      refreshProfilePreview()
      lastError = nil
      if let name = profileStore.profiles.first(where: { $0.id == profile.id })?.name {
        profileOperationMessage = "Restored subscription name to \(name)."
      }
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
    }
  }

  func deleteActiveProfile() {
    guard let profile = profileStore.activeProfile else { return }
    deleteProfile(profile)
  }

  func deleteProfile(_ profile: Profile) {
    do {
      try profileStore.delete(profile)
      previewSelections = [:]
      saveCurrentPreviewSelections(forProfileID: profile.id)
      refreshProfilePreview()
      loadPreviewSelectionsForActiveProfile()
      lastError = nil
      profileOperationMessage = "Deleted profile \(profile.name)."
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
    }
  }

  func selectProfile(_ profile: Profile) {
    let isChangingProfile = profileStore.activeProfileID != profile.id
    guard isChangingProfile else { return }
    do {
      let shouldRestart = isRunning || startInFlight
      try profileStore.select(profile)
      proxyGroups = []
      refreshProfilePreview()
      loadPreviewSelectionsForActiveProfile()
      lastError = nil
      if shouldRestart {
        restart()
      }
    } catch {
      profileOperationMessage = nil
      lastError = UserFacingError.message(for: error)
    }
  }

  private func setProfile(_ id: Profile.ID, updating isUpdating: Bool) {
    var ids = updatingProfileIDs
    if isUpdating {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    updatingProfileIDs = ids
  }

  private func setProvider(_ id: ProxyProvider.ID, healthCheckInFlight isRunning: Bool) {
    var ids = providerHealthChecksInFlight
    if isRunning {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    providerHealthChecksInFlight = ids
  }

  private func setConnection(_ id: ConnectionSnapshot.ID, closing isClosing: Bool) {
    var ids = closingConnectionIDs
    if isClosing {
      ids.insert(id)
    } else {
      ids.remove(id)
    }
    closingConnectionIDs = ids
  }

  func start() {
    guard startTask == nil, !startInFlight else { return }
    startTask = Task { [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      await self.performStart()
    }
  }

  private func performStart() async {
    startInFlight = true
    lastError = nil
    defer {
      startInFlight = false
      startTask = nil
    }
    do {
      try await withTimeout(seconds: Self.startWallClockSeconds) { @Sendable [weak self] in
        guard let self else { return }
        try await self.runStartSequence()
      }
    } catch is CancellationError {
      await stopRuntime()
    } catch let error as OperationTimedOutError {
      publishStartupDiagnostics(level: "error")
      let diagnostics = startupDiagnosticsSummary()
      await stopRuntime()
      lastError = "ClashMax could not start within \(Int(error.seconds))s.\(diagnostics.isEmpty ? "" : "\n\(diagnostics)")"
    } catch {
      publishStartupDiagnostics(level: "error")
      await stopRuntime()
      lastError = UserFacingError.message(for: error)
    }
  }

  private func runStartSequence() async throws {
    if previewRuntimeActive {
      await leavePreviewRuntime()
    }
    try Task.checkCancellation()
    let profile = try requireActiveProfile()
    let routingMode = proxyRoutingMode
    let shouldUseTun = routingMode == .tun
    syncExternalControllerSettings()
    overrides.tunEnabled = shouldUseTun
    overrides.tunSettings = tunSettings
    systemProxyEnabled = false
    tunEnabled = false
    let runtimeConfig = try generateRuntimeConfig(for: profile, selections: previewSelections)
    let coreURL = try bundledCoreURL()
    appendAppLog(level: "info", message: "Runtime config path: \(runtimeConfig.path)")
    appendAppLog(level: "info", message: "Mihomo core path: \(coreURL.path)")
    let client = MihomoAPIClient(baseURL: overrides.endpoint.baseURL, secret: overrides.secret)
    apiClient = client
    try Task.checkCancellation()

    if shouldUseTun {
      try await helperClient.register()
      let response = try await helperClient.startTunnel(
        coreURL: coreURL,
        configURL: runtimeConfig,
        workDirectory: paths.runtime,
        secret: overrides.secret
      )
      try Task.checkCancellation()
      if !response.ok {
        throw AppError.helperResponse(response.message.isEmpty ? "Helper failed to start TUN." : response.message)
      }
      guard response.running else {
        throw AppError.helperResponse("Helper reported success but TUN is not running.")
      }
      do {
        let version = try await tunnelReadinessProbe.waitUntilReady(api: overrides.endpoint)
        appendAppLog(level: "info", message: "TUN Mihomo controller ready: \(overrides.endpoint.host):\(overrides.endpoint.port), version \(version)")
      } catch {
        _ = try? await helperClient.stopTunnel()
        tunnelCoreRunning = false
        tunEnabled = false
        runtimeOwner = .stopped
        throw error
      }
      tunnelCoreRunning = true
      tunEnabled = true
      runtimeOwner = .tunnel
      coreController.stop()
    } else {
      tunnelCoreRunning = false
      try await coreController.startUserMode(
        coreURL: coreURL,
        configURL: runtimeConfig,
        workDirectory: paths.runtime,
        api: overrides.endpoint,
        proxyPort: overrides.mixedPort
      )
      runtimeOwner = .user
      publishStartupDiagnostics()
    }
    try Task.checkCancellation()

    if routingMode == .systemProxy {
      try await applySystemProxySettings()
      systemProxyEnabled = true
      try await activateSystemProxyGuardIfNeeded()
    }
    try Task.checkCancellation()
    sessionStartedAt = Date()
    refreshProfilePreview()
    startStreams(client: client)
    reloadRuntimeData(clearAfterConfirmation: !previewSelections.isEmpty)
    refreshPublicIPInfo()
  }

  func stop() {
    startTask?.cancel()
    startTask = nil
    startInFlight = false
    previewTask?.cancel()
    previewTask = nil
    Task {
      await stopRuntime()
    }
  }

  func restart() {
    startTask?.cancel()
    startTask = nil
    startInFlight = false
    Task {
      await stopRuntime()
      start()
    }
  }

  func setProxyRoutingMode(_ mode: ProxyRoutingMode) {
    guard proxyRoutingMode != mode else { return }
    if mode == .tun, systemProxyEnabled {
      stopSystemProxyGuard()
      Task { @MainActor [weak self] in
        guard let self else { return }
        try? await restoreSystemProxyState(disableWhenNoSnapshot: true)
      }
      systemProxyEnabled = false
    }
    proxyRoutingMode = mode
    if isRunning || startInFlight {
      restart()
    }
  }

  func setMode(_ mode: RunMode) {
    guard overrides.mode != mode else { return }
    overrides.mode = mode
    guard isRunning else { return }
    guard let apiClient else {
      lastError = proxyRuntimeActionMessage
      return
    }
    Task {
      do {
        try await apiClient.updateMode(mode)
      } catch {
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func requestMode(_ mode: RunMode) {
    pendingModeTask?.cancel()
    pendingModeTask = nil
    guard overrides.mode != mode else { return }
    pendingModeTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      setMode(mode)
      pendingModeTask = nil
    }
  }

  func requestProxyRoutingMode(_ mode: ProxyRoutingMode) {
    pendingRoutingModeTask?.cancel()
    pendingRoutingModeTask = nil
    guard proxyRoutingMode != mode else { return }
    pendingRoutingModeTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      setProxyRoutingMode(mode)
      pendingRoutingModeTask = nil
    }
  }

  func registerHelper() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        lastError = nil
        try await helperClient.register()
      } catch {
        let message = UserFacingError.message(for: error)
        helperClient.statusMessage = message
        lastError = message
      }
    }
  }

  func refreshHelperRegistrationStatus() {
    Task { @MainActor [weak self] in
      await self?.helperClient.refreshRegistrationStatus()
    }
  }

  func repairHelperRegistration() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        lastError = nil
        try await helperClient.repairRegistration()
      } catch {
        let message = UserFacingError.message(for: error)
        helperClient.statusMessage = message
        lastError = message
      }
    }
  }

  func openHelperApprovalSettings() {
    helperClient.openApprovalSettings()
  }

  func refreshLaunchSettings() {
    launchSettings = LaunchSettings(
      launchAtLogin: Self.isLoginItemRegistered(loginItemService.status),
      silentStart: defaults.bool(forKey: Self.silentStartDefaultsKey),
      statusMessage: Self.loginItemStatusMessage(for: loginItemService.status)
    )
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    Task { @MainActor [weak self] in
      await self?.updateLaunchAtLogin(enabled)
    }
  }

  @discardableResult
  func updateLaunchAtLogin(_ enabled: Bool) async -> Bool {
    do {
      lastError = nil
      if enabled {
        try loginItemService.register()
      } else {
        try await loginItemService.unregister()
      }
      refreshLaunchSettings()
      if loginItemService.status == .requiresApproval {
        loginItemService.openSystemSettingsLoginItems()
      }
      return true
    } catch {
      refreshLaunchSettings()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func setSilentStart(_ enabled: Bool) {
    defaults.set(enabled, forKey: Self.silentStartDefaultsKey)
    refreshLaunchSettings()
  }

  func openLoginItemsSettings() {
    loginItemService.openSystemSettingsLoginItems()
  }

  func reloadRuntimeData(clearAfterConfirmation: Bool = false) {
    guard isCoreRunning, let apiClient else {
      proxyGroups = []
      proxyProviders = []
      rules = []
      connections = []
      refreshProfilePreview()
      return
    }
    Task {
      do {
        let knownDelays = proxyDelayMap(from: proxyGroups)
        let cachedRuntimeGroups = proxyGroups
        let runtimeGroups = try await apiClient.proxyGroups()
        let refreshedProviders: [ProxyProvider]
        do {
          refreshedProviders = try await apiClient.structuredProxyProviders()
        } catch {
          refreshedProviders = []
        }
        proxyProviders = refreshedProviders
        proxyGroups = enrichProxyGroupsWithKnownEndpoints(
          runtimeGroups,
          providers: refreshedProviders,
          cachedRuntimeGroups: cachedRuntimeGroups
        ).preservingKnownDelays(knownDelays)
        rules = try await apiClient.rules()
        connections = try await apiClient.connections()
        if clearAfterConfirmation, let activeID = profileStore.activeProfileID {
          let confirmed = previewSelections.allSatisfy { groupName, nodeName in
            proxyGroups.first(where: { $0.name == groupName })?.selected == nodeName
          }
          if confirmed {
            previewSelections = [:]
            saveCurrentPreviewSelections(forProfileID: activeID)
          }
        }
      } catch {
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func publicIPInfoNeedsRefresh(now: Date = Date()) -> Bool {
    guard isCoreRunning else { return false }
    if publicIPInfoState.isLoading { return false }
    guard let anchor = publicIPInfoState.refreshAnchor else { return true }
    return now.timeIntervalSince(anchor) >= Self.publicIPRefreshInterval
  }

  func refreshPublicIPInfo(force: Bool = false, now: Date = Date()) {
    guard isCoreRunning else {
      cancelPublicIPInfoRefresh(clearState: true)
      return
    }
    guard force || publicIPInfoNeedsRefresh(now: now) else { return }
    guard !publicIPInfoState.isLoading else { return }

    let previous = publicIPInfoState.info
    publicIPInfoState = .loading(previous: previous, startedAt: now)
    publicIPInfoTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let info = try await self.publicIPInfoClient.fetchPublicIPInfo()
        guard !Task.isCancelled else { return }
        self.publicIPInfoState = .loaded(info)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        self.publicIPInfoState = .failed(
          message: UserFacingError.message(for: error),
          previous: previous,
          failedAt: Date()
        )
      }
      self.publicIPInfoTask = nil
    }
  }

  func refreshHelperStatus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let response = try await withTimeout(seconds: 4) { @Sendable [helperClient] in
          try await helperClient.status()
        }
        self.helperClient.statusMessage = response.running
          ? "Helper running with pid \(response.pid)"
          : "Helper registered but not running"
      } catch is OperationTimedOutError {
        let message = "Helper not responding. Open System Settings > General > Login Items & Extensions, approve ClashMax, then click Repair or switch to System Proxy."
        self.helperClient.statusMessage = message
        self.lastError = message
      } catch {
        let message = UserFacingError.message(for: error)
        self.helperClient.statusMessage = message
        self.lastError = message
      }
    }
  }

  func refreshHelperLogs() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let lines = try await withTimeout(seconds: 4) { @Sendable [helperClient] in
          try await helperClient.recentLogs()
        }
        self.helperLogs = lines
      } catch is OperationTimedOutError {
        let message = "Helper not responding. Open System Settings > General > Login Items & Extensions, approve ClashMax, then click Repair or switch to System Proxy."
        self.helperClient.statusMessage = message
        self.lastError = message
      } catch {
        let message = UserFacingError.message(for: error)
        self.helperClient.statusMessage = message
        self.lastError = message
      }
    }
  }

  func selectProxy(group: ProxyGroup, node: ProxyNode) {
    guard node.isSelectable else {
      lastError = "\(node.name) cannot be selected from the runtime."
      return
    }
    if isCoreRunning, let apiClient {
      Task {
        do {
          try await apiClient.selectProxy(group: group.name, proxy: node.name)
          applySelectedProxy(groupName: group.name, nodeName: node.name)
          reloadRuntimeData()
        } catch {
          lastError = UserFacingError.message(for: error)
        }
      }
    } else if canSelectProxyOffline {
      previewSelections[group.name] = node.name
      saveCurrentPreviewSelections()
      lastError = nil
    } else {
      lastError = proxyRuntimeActionMessage
    }
  }

  func testDelay(for node: ProxyNode) {
    guard node.isSelectable else {
      lastError = "\(node.name) cannot be tested from the runtime."
      return
    }
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    let settings = delayTestSettings
    Task {
      do {
        let delay = try await measureDelay(for: node, apiClient: apiClient, settings: settings)
        applyDelay(delay, to: node.name)
        reloadRuntimeData()
      } catch {
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func healthCheckProvider(_ provider: ProxyProvider) {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    setProvider(provider.id, healthCheckInFlight: true)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.setProvider(provider.id, healthCheckInFlight: false) }
      do {
        try await apiClient.healthCheckProvider(named: provider.name)
        self.reloadRuntimeData()
      } catch {
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  private func measureDelay(
    for node: ProxyNode,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings
  ) async throws -> Int {
    let attempts = settings.unifiedDelay ? 2 : 1
    var lastDelay: Int?
    var lastError: Error?

    for _ in 0..<attempts {
      do {
        lastDelay = try await measureDelayOnce(for: node, apiClient: apiClient, settings: settings)
        lastError = nil
      } catch {
        lastError = error
        if !settings.unifiedDelay {
          throw error
        }
      }
    }

    if let lastDelay {
      return lastDelay
    }
    throw lastError ?? DelayTestError.noResult(node.name)
  }

  private func measureDelayOnce(
    for node: ProxyNode,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings
  ) async throws -> Int {
    switch settings.mode {
    case .mihomoURL:
      return try await apiClient.testDelay(
        proxy: node.name,
        testURL: AppConstants.defaultDelayTestURL,
        timeout: settings.normalizedTimeoutMilliseconds
      )
    case .nativePing:
      let host = nativePingHost(for: node) ?? ""
      guard !host.isEmpty else {
        throw DelayTestError.missingServerHost(node.name)
      }
      return try await pingTester.ping(host: host, timeoutMilliseconds: settings.normalizedTimeoutMilliseconds)
    }
  }

  func closeConnection(_ connection: ConnectionSnapshot) {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    setConnection(connection.id, closing: true)
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.setConnection(connection.id, closing: false) }
      do {
        try await apiClient.closeConnection(id: connection.id)
        self.removeConnection(id: connection.id)
      } catch {
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  func closeAllRuntimeConnections() {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard !closingAllConnections else { return }
    closingAllConnections = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer { self.closingAllConnections = false }
      do {
        try await apiClient.closeAllConnections()
        self.connectionBuffer.replace(with: [])
        self.connections = []
      } catch {
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  func setSystemProxyEnabled(_ enabled: Bool) {
    Task { [self] in
      do {
        if enabled {
          proxyRoutingMode = .systemProxy
          try await applySystemProxySettings()
          systemProxyEnabled = true
          try await activateSystemProxyGuardIfNeeded()
        } else {
          try await restoreSystemProxyState(disableWhenNoSnapshot: true)
          systemProxyEnabled = false
        }
      } catch {
        if !systemProxyController.hasManagedSystemProxyState {
          markSystemProxyManaged(false)
        }
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func updateSystemProxySettings(_ settings: SystemProxySettings) -> Bool {
    if let validationError = settings.validationError {
      lastError = validationError
      return false
    }
    systemProxySettings = settings
    if systemProxyEnabled {
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await applySystemProxySettings()
          try await activateSystemProxyGuardIfNeeded()
          lastError = nil
        } catch {
          lastError = UserFacingError.message(for: error)
        }
      }
    }
    return true
  }

  func updateTunSettings(_ settings: TunSettings) {
    tunSettings = settings
    if proxyRoutingMode == .tun, isRunning {
      restart()
    }
  }

  private func applySystemProxySettings() async throws {
    if let validationError = systemProxySettings.validationError {
      throw AppError.invalidProfileConfig(validationError)
    }
    markSystemProxyManaged(true)
    do {
      try await systemProxyController.apply(
        host: systemProxySettings.normalizedProxyHost,
        port: overrides.mixedPort,
        bypassDomains: systemProxySettings.effectiveBypassDomains
      )
    } catch {
      if !systemProxyController.hasManagedSystemProxyState {
        markSystemProxyManaged(false)
      }
      throw error
    }
  }

  private func activateSystemProxyGuardIfNeeded() async throws {
    stopSystemProxyGuard()
    guard systemProxySettings.guardEnabled else { return }
    try await systemProxyController.enableGuard(
      host: systemProxySettings.normalizedProxyHost,
      port: overrides.mixedPort,
      bypassDomains: systemProxySettings.effectiveBypassDomains
    )
    startSystemProxyGuardLoop(intervalSeconds: systemProxySettings.normalizedGuardIntervalSeconds)
  }

  private func startSystemProxyGuardLoop(intervalSeconds: Int) {
    systemProxyGuardTask?.cancel()
    systemProxyGuardTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          let result = try await self.systemProxyController.verifyGuardOnceDetailed()
          for warning in result.warnings {
            self.appendAppLog(level: "warn", message: warning)
          }
        } catch is CancellationError {
          return
        } catch {
          self.lastError = UserFacingError.message(for: error)
        }
        let delay = UInt64(intervalSeconds) * 1_000_000_000
        try? await Task.sleep(nanoseconds: delay)
      }
    }
  }

  private func stopSystemProxyGuard() {
    systemProxyGuardTask?.cancel()
    systemProxyGuardTask = nil
    systemProxyController.disableGuard()
  }

  private func restoreSystemProxyState(disableWhenNoSnapshot: Bool) async throws {
    stopSystemProxyGuard()
    if disableWhenNoSnapshot {
      try await systemProxyController.restore()
    } else {
      try await systemProxyController.restoreManagedState()
    }
    if !systemProxyController.hasManagedSystemProxyState {
      markSystemProxyManaged(false)
    }
  }

  var needsTerminationCleanup: Bool {
    startInFlight
      || isCoreRunning
      || systemProxyEnabled
      || tunEnabled
      || tunnelCoreRunning
      || systemProxyController.hasManagedSystemProxyState
      || defaults.bool(forKey: Self.systemProxyManagedDefaultsKey)
  }

  func prepareForTermination() async {
    startTask?.cancel()
    startTask = nil
    startInFlight = false
    previewTask?.cancel()
    previewTask = nil
    pendingModeTask?.cancel()
    pendingModeTask = nil
    pendingRoutingModeTask?.cancel()
    pendingRoutingModeTask = nil
    await stopRuntime()
  }

  func enterPreviewRuntime() {
    guard previewTask == nil else { return }
    guard !startInFlight else { return }
    guard !isCoreRunning else { return }
    guard profileStore.activeProfile != nil else { return }
    guard readinessIssue == nil else { return }
    guard !profilePreviewGroups.isEmpty else { return }

    previewTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard let self, !Task.isCancelled else { return }
      await self.startPreviewRuntime()
    }
  }

  func leavePreviewRuntime() async {
    previewTask?.cancel()
    previewTask = nil
    guard previewRuntimeActive else { return }
    apiClient = nil
    streamTasks.forEach { $0.cancel() }
    streamTasks.removeAll()
    coreController.stop()
    proxyGroups = []
    proxyProviders = []
    previewRuntimeActive = false
    runtimeOwner = .stopped
  }

  private func startPreviewRuntime() async {
    defer { previewTask = nil }
    do {
      let profile = try requireActiveProfile()
      let baseOverrides = overrides
      var quietOverrides = baseOverrides
      quietOverrides.secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
      quietOverrides.tunEnabled = false
      quietOverrides.mode = .direct
      quietOverrides.allowLan = false
      let runtimeConfig = try generateRuntimeConfig(
        for: profile,
        overrides: quietOverrides,
        selections: previewSelections
      )
      let client = MihomoAPIClient(baseURL: quietOverrides.endpoint.baseURL, secret: quietOverrides.secret)
      previewRuntimeActive = true
      runtimeOwner = .preview
      try Task.checkCancellation()
      try await coreController.startUserMode(
        coreURL: try bundledCoreURL(),
        configURL: runtimeConfig,
        workDirectory: paths.runtime,
        api: quietOverrides.endpoint
      )
      try Task.checkCancellation()
      apiClient = client
      try Task.checkCancellation()
      do {
        let knownDelays = proxyDelayMap(from: proxyGroups)
        let cachedRuntimeGroups = proxyGroups
        let runtimeGroups = try await client.proxyGroups()
        proxyGroups = enrichProxyGroupsWithKnownEndpoints(
          runtimeGroups,
          providers: proxyProviders,
          cachedRuntimeGroups: cachedRuntimeGroups
        ).preservingKnownDelays(knownDelays)
      } catch {
        // Best-effort initial fetch; UI still shows YAML preview if this fails.
      }
    } catch is CancellationError {
      previewRuntimeActive = false
      coreController.stop()
      apiClient = nil
      runtimeOwner = .stopped
    } catch {
      previewRuntimeActive = false
      coreController.stop()
      apiClient = nil
      runtimeOwner = .stopped
      lastError = UserFacingError.message(for: error)
    }
  }

  private func stopRuntime() async {
    apiClient = nil
    cancelPublicIPInfoRefresh(clearState: true)
    streamTasks.forEach { $0.cancel() }
    streamTasks.removeAll()
    coreController.stop()
    proxyGroups = []
    proxyProviders = []
    rules = []
    connections = []
    closingConnectionIDs = []
    closingAllConnections = false
    providerHealthChecksInFlight = []
    trafficSample = .zero
    trafficHistory = []
    if tunEnabled || tunnelCoreRunning {
      _ = try? await helperClient.stopTunnel()
    }
    tunnelCoreRunning = false
    sessionStartedAt = nil
    previewRuntimeActive = false
    runtimeOwner = .stopped
    refreshProfilePreview()
    if systemProxyEnabled {
      try? await restoreSystemProxyState(disableWhenNoSnapshot: true)
    } else if systemProxyController.hasManagedSystemProxyState {
      try? await restoreSystemProxyState(disableWhenNoSnapshot: false)
    }
    if !systemProxyController.hasManagedSystemProxyState {
      markSystemProxyManaged(false)
    }
    systemProxyEnabled = false
    tunEnabled = false
  }

  private func cancelPublicIPInfoRefresh(clearState: Bool) {
    publicIPInfoTask?.cancel()
    publicIPInfoTask = nil
    if clearState {
      publicIPInfoState = .idle
    }
  }

  private func requireActiveProfile() throws -> Profile {
    guard let profile = profileStore.activeProfile else {
      throw AppError.noActiveProfile
    }
    return profile
  }

  private func refreshProfilePreview() {
    guard let profile = profileStore.activeProfile else {
      profilePreviewGroups = []
      return
    }

    do {
      let source = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
      profilePreviewGroups = try profilePreviewBuilder.groups(from: source, profileName: profile.name)
    } catch {
      profilePreviewGroups = []
    }
  }

  private func runtimeAPIClientForProxyAction() -> (any MihomoAPIControlling)? {
    guard let apiClient else {
      lastError = proxyRuntimeActionMessage
      return nil
    }
    return apiClient
  }

  private func applySelectedProxy(groupName: String, nodeName: String) {
    updateProxyGroupCollections { groups in
      guard let index = groups.firstIndex(where: { $0.name == groupName }) else { return }
      groups[index].selected = nodeName
    }
  }

  private func applyDelay(_ delay: Int, to nodeName: String) {
    guard delay >= 0 else { return }
    updateProxyGroupCollections { groups in
      for groupIndex in groups.indices {
        for nodeIndex in groups[groupIndex].nodes.indices where groups[groupIndex].nodes[nodeIndex].name == nodeName {
          groups[groupIndex].nodes[nodeIndex].delay = delay
        }
      }
    }
  }

  private func updateRuntimeProxyGroups(_ update: (inout [ProxyGroup]) -> Void) {
    guard !proxyGroups.isEmpty else { return }
    var groups = proxyGroups
    update(&groups)
    proxyGroups = groups
  }

  private func updateProxyGroupCollections(_ update: (inout [ProxyGroup]) -> Void) {
    if !proxyGroups.isEmpty {
      var runtime = proxyGroups
      update(&runtime)
      proxyGroups = runtime
    }
    if !profilePreviewGroups.isEmpty {
      var preview = profilePreviewGroups
      update(&preview)
      profilePreviewGroups = preview
    }
  }

  private func removeConnection(id: ConnectionSnapshot.ID) {
    let remaining = connections.filter { $0.id != id }
    connectionBuffer.replace(with: remaining)
    connections = remaining
  }

  private func proxyDelayMap(from groups: [ProxyGroup]) -> [String: Int] {
    groups.reduce(into: [String: Int]()) { result, group in
      for node in group.nodes {
        if let delay = node.delay {
          result[node.name] = delay
        }
      }
    }
  }

  private func nativePingHost(for node: ProxyNode) -> String? {
    if let endpoint = proxyEndpoint(from: node) {
      return endpoint.host
    }
    let endpointMaps = [
      proxyEndpointMap(from: proxyProviders),
      proxyEndpointMap(from: profilePreviewGroups),
      proxyEndpointMap(from: proxyGroups)
    ]
    return endpointMaps.lazy.compactMap { $0[node.name]?.host }.first
  }

  private func enrichProxyGroupsWithKnownEndpoints(
    _ groups: [ProxyGroup],
    providers: [ProxyProvider],
    cachedRuntimeGroups: [ProxyGroup]
  ) -> [ProxyGroup] {
    let endpointMaps = [
      proxyEndpointMap(from: providers),
      proxyEndpointMap(from: profilePreviewGroups),
      proxyEndpointMap(from: cachedRuntimeGroups)
    ]
    return groups.map { group in
      var group = group
      group.nodes = group.nodes.map { node in
        guard proxyEndpoint(from: node) == nil,
              let endpoint = endpointMaps.lazy.compactMap({ $0[node.name] }).first
        else { return node }
        var node = node
        node.serverHost = endpoint.host
        node.serverPort = endpoint.port
        return node
      }
      return group
    }
  }

  private func proxyEndpointMap(from providers: [ProxyProvider]) -> [String: ProxyNodeEndpoint] {
    providers.reduce(into: [String: ProxyNodeEndpoint]()) { result, provider in
      for node in provider.proxies {
        guard result[node.name] == nil, let endpoint = proxyEndpoint(from: node) else { continue }
        result[node.name] = endpoint
      }
    }
  }

  private func proxyEndpointMap(from groups: [ProxyGroup]) -> [String: ProxyNodeEndpoint] {
    groups.reduce(into: [String: ProxyNodeEndpoint]()) { result, group in
      for node in group.nodes {
        guard result[node.name] == nil, let endpoint = proxyEndpoint(from: node) else { continue }
        result[node.name] = endpoint
      }
    }
  }

  private func proxyEndpoint(from node: ProxyNode) -> ProxyNodeEndpoint? {
    guard let host = node.serverHost?.trimmingCharacters(in: .whitespacesAndNewlines),
          !host.isEmpty
    else { return nil }
    return ProxyNodeEndpoint(host: host, port: node.serverPort)
  }

  private func syncExternalControllerSettings() {
    let settings = externalControllerSettings
    overrides.externalControllerHost = settings.normalizedHost
    overrides.externalControllerPort = settings.normalizedPort
    overrides.secret = settings.normalizedSecret
    overrides.externalControllerCORS = settings.runtimeCORS
  }

  private func generateRuntimeConfig(
    for profile: Profile,
    overrides: RuntimeOverrides? = nil,
    selections: [String: String] = [:]
  ) throws -> URL {
    let effectiveOverrides = overrides ?? self.overrides
    let source = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
    let providerContentPath: String?
    if try ProfileConfigInspector.format(of: source) == .proxyProviderContent {
      let providerContentURL = paths.runtimeProviderContentURL(for: profile)
      try source.write(to: providerContentURL, atomically: true, encoding: .utf8)
      providerContentPath = providerContentURL.path
    } else {
      providerContentPath = nil
    }
    let output = try normalizer.runtimeConfig(
      from: source,
      providerContentPath: providerContentPath,
      profileName: profile.name,
      overrides: effectiveOverrides,
      selectionOverrides: selections
    )
    let url = paths.runtimeConfigURL(for: profile)
    try output.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func bundledCoreURL() throws -> URL {
    let architecture = ProcessInfo.processInfo.machineHardwareName.contains("x86") ? "amd64" : "arm64"
    let candidates = [
      AppConstants.bundledCoreRoot.appendingPathComponent("mihomo-darwin-\(architecture)"),
      AppConstants.bundledCoreRoot.appendingPathComponent("mihomo")
    ]
    guard let core = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      throw AppError.missingBundledCore
    }
    return core
  }

  private func startStreams(client: any MihomoAPIControlling) {
    streamTasks.forEach { $0.cancel() }
    let logLevel = overrides.logLevel
    streamTasks = [
      Task { [weak self] in
        do {
          for try await sample in client.trafficStream() {
            await MainActor.run {
              self?.trafficSample = sample
              self?.appendTrafficSample(sample)
            }
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await entry in client.logStream(level: logLevel) {
            await MainActor.run {
              self?.logBuffer.append(entry)
              self?.logs = self?.logBuffer.elements ?? []
            }
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await snapshot in client.connectionStream(interval: 1000) {
            await MainActor.run {
              self?.connectionBuffer.replace(with: snapshot)
              self?.connections = self?.connectionBuffer.elements ?? []
            }
          }
        } catch {}
      }
    ]
    reloadRuntimeData()
  }

  private func appendTrafficSample(_ sample: TrafficSample) {
    trafficHistory.append(sample)
    if trafficHistory.count > 72 {
      trafficHistory.removeFirst(trafficHistory.count - 72)
    }
  }

  private func appendAppLog(level: String, message: String) {
    logBuffer.append(LogEntry(level: level, message: message))
    logs = logBuffer.elements
  }

  private func publishStartupDiagnostics(level: String = "info") {
    for diagnostic in coreController.startupDiagnostics {
      appendAppLog(level: level, message: diagnostic)
    }
    if !coreController.recentCoreLog.isEmpty {
      appendAppLog(level: "error", message: "Core tail: \(coreController.recentCoreLog)")
    }
  }

  private func startupDiagnosticsSummary() -> String {
    var lines = coreController.startupDiagnostics
    if !coreController.recentCoreLog.isEmpty {
      lines.append("Core tail:\n\(coreController.recentCoreLog)")
    }
    return lines.joined(separator: "\n")
  }

  private func mergedPreviewSelections(into groups: [ProxyGroup]) -> [ProxyGroup] {
    guard !previewSelections.isEmpty else { return groups }
    return groups.map { group in
      var group = group
      if let chosen = previewSelections[group.name],
         group.nodes.contains(where: { $0.name == chosen }) {
        group.selected = chosen
      }
      return group
    }
  }

  private func loadPreviewSelectionsForActiveProfile() {
    guard let id = profileStore.activeProfileID else {
      previewSelections = [:]
      return
    }
    let store = defaults.dictionary(forKey: Self.previewSelectionsDefaultsKey) as? [String: [String: String]] ?? [:]
    previewSelections = store[id.uuidString] ?? [:]
  }

  private func saveCurrentPreviewSelections(forProfileID overrideID: Profile.ID? = nil) {
    let id = overrideID ?? profileStore.activeProfileID
    guard let id else { return }
    var store = defaults.dictionary(forKey: Self.previewSelectionsDefaultsKey) as? [String: [String: String]] ?? [:]
    if previewSelections.isEmpty {
      store.removeValue(forKey: id.uuidString)
    } else {
      store[id.uuidString] = previewSelections
    }
    defaults.set(store, forKey: Self.previewSelectionsDefaultsKey)
  }

  private func markSystemProxyManaged(_ isManaged: Bool) {
    defaults.set(isManaged, forKey: Self.systemProxyManagedDefaultsKey)
  }

  private func recoverDanglingSystemProxyIfNeeded() {
    guard defaults.bool(forKey: Self.systemProxyManagedDefaultsKey) else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let didChange = try await systemProxyController.disableMatchingProxy(
          hosts: Self.localProxyHosts(for: systemProxySettings),
          ports: [overrides.mixedPort]
        )
        markSystemProxyManaged(false)
        if didChange {
          appendAppLog(level: "info", message: "Cleared stale System Proxy settings left by a previous ClashMax session.")
        }
      } catch {
        lastError = "Could not verify stale System Proxy settings from a previous ClashMax session: \(UserFacingError.message(for: error))"
      }
    }
  }

  private static func localProxyHosts(for settings: SystemProxySettings) -> Set<String> {
    Set([settings.normalizedProxyHost, "127.0.0.1", "localhost", "::1"].map { $0.lowercased() })
  }

  private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
    guard let data = try? JSONEncoder().encode(value) else { return }
    defaults.set(data, forKey: key)
  }

  private static func loadCodable<T: Decodable>(_ type: T.Type, forKey key: String, defaults: UserDefaults) -> T? {
    guard let data = defaults.data(forKey: key) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }

  private static func isLoginItemRegistered(_ status: SMAppService.Status) -> Bool {
    switch status {
    case .enabled, .requiresApproval:
      return true
    case .notRegistered, .notFound:
      return false
    @unknown default:
      return false
    }
  }

  private static func loginItemStatusMessage(for status: SMAppService.Status) -> String {
    switch status {
    case .enabled:
      return "ClashMax will launch when you log in."
    case .requiresApproval:
      return "Approve ClashMax in System Settings > General > Login Items & Extensions."
    case .notRegistered:
      return "Launch at login is not registered."
    case .notFound:
      return "macOS could not find the ClashMax login item service."
    @unknown default:
      return "macOS reported an unknown login item state."
    }
  }
}

private enum DelayTestError: LocalizedError {
  case missingServerHost(String)
  case noResult(String)

  var errorDescription: String? {
    switch self {
    case let .missingServerHost(nodeName):
      return "Native ping needs a server host for \(nodeName). Refresh runtime data or switch to Mihomo URL Delay."
    case let .noResult(nodeName):
      return "Delay test for \(nodeName) finished without a result."
    }
  }
}

private struct ProxyNodeEndpoint {
  var host: String
  var port: Int?
}

@MainActor
protocol LoginItemManaging: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() async throws
  func openSystemSettingsLoginItems()
}

final class MainAppLoginItemService: LoginItemManaging {
  private let service: SMAppService

  init(service: SMAppService = .mainApp) {
    self.service = service
  }

  var status: SMAppService.Status {
    service.status
  }

  func register() throws {
    try service.register()
  }

  func unregister() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      service.unregister { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func openSystemSettingsLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

private extension ProcessInfo {
  var machineHardwareName: String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    return mirror.children.reduce(into: "") { result, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      result.append(Character(UnicodeScalar(UInt8(value))))
    }
  }
}

extension UTType {
  static var yaml: UTType {
    UTType(filenameExtension: "yaml") ?? .text
  }

  static var yml: UTType {
    UTType(filenameExtension: "yml") ?? .text
  }
}

private extension Array where Element == ProxyGroup {
  func preservingKnownDelays(_ knownDelays: [String: Int]) -> [ProxyGroup] {
    map { group in
      var group = group
      group.nodes = group.nodes.map { node in
        guard node.delay == nil, let delay = knownDelays[node.name] else {
          return node
        }
        var node = node
        node.delay = delay
        return node
      }
      return group
    }
  }
}
