import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
  @Published var selectedSection: AppSection = .home
  @Published var overrides = RuntimeOverrides.defaultForLaunch()
  @Published var proxyRoutingMode: ProxyRoutingMode = .systemProxy
  @Published var systemProxyEnabled = false
  @Published var tunEnabled = false
  @Published var tunnelCoreRunning = false
  @Published private(set) var isAddingSubscription = false
  @Published private(set) var startInFlight = false
  @Published private(set) var sessionStartedAt: Date?
  @Published var proxyGroups: [ProxyGroup] = []
  @Published var rules: [String] = []
  @Published var connections: [ConnectionSnapshot] = []
  @Published var logs: [LogEntry] = []
  @Published var helperLogs: [String] = []
  @Published var trafficSample: TrafficSample = .zero
  @Published var trafficHistory: [TrafficSample] = []
  @Published var lastError: String?
  @Published private(set) var updatingProfileIDs: Set<Profile.ID> = []
  @Published private(set) var profileOperationMessage: String?
  @Published private(set) var profilePreviewGroups: [ProxyGroup] = []
  @Published private(set) var previewRuntimeActive = false
  @Published private(set) var previewSelections: [String: String] = [:]

  let profileStore: ProfileStore
  let coreController: CoreProcessController
  let systemProxyController: SystemProxyController
  let helperClient: TunnelHelperClient
  private let paths: RuntimePaths
  private let normalizer = ConfigNormalizer()
  private let profilePreviewBuilder = ProfilePreviewBuilder()
  private var apiClient: (any MihomoAPIControlling)?
  private var startTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var pendingModeTask: Task<Void, Never>?
  private var streamTasks: [Task<Void, Never>] = []
  private var logBuffer = BoundedBuffer<LogEntry>(limit: AppConstants.retainedLogLimit)
  private var connectionBuffer = BoundedBuffer<ConnectionSnapshot>(limit: AppConstants.retainedConnectionLimit)
  private let defaults: UserDefaults
  private static let previewSelectionsDefaultsKey = "io.github.clashmax.previewSelections"
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
    apiClient: (any MihomoAPIControlling)? = nil,
    defaults: UserDefaults = .standard
  ) {
    self.paths = paths
    self.profileStore = profileStore ?? ProfileStore(paths: paths)
    self.coreController = coreController
    self.systemProxyController = systemProxyController
    self.helperClient = helperClient
    self.apiClient = apiClient
    self.defaults = defaults
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
  func addSubscription(name: String, urlString: String, session: URLSession = .shared) async -> Bool {
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
      await stopRuntime()
      lastError = "ClashMax could not start within \(Int(error.seconds))s. Check Network preferences for a stuck networksetup, or review the latest mihomo log."
    } catch {
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
    overrides.secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    overrides.tunEnabled = shouldUseTun
    systemProxyEnabled = false
    tunEnabled = false
    let runtimeConfig = try generateRuntimeConfig(for: profile, selections: previewSelections)
    let client = MihomoAPIClient(baseURL: overrides.endpoint.baseURL, secret: overrides.secret)
    apiClient = client
    try Task.checkCancellation()

    if shouldUseTun {
      try helperClient.register()
      let response = try await helperClient.startTunnel(
        coreURL: try bundledCoreURL(),
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
      tunnelCoreRunning = response.running
      tunEnabled = true
      coreController.stop()
    } else {
      tunnelCoreRunning = false
      try await coreController.startUserMode(
        coreURL: try bundledCoreURL(),
        configURL: runtimeConfig,
        workDirectory: paths.runtime,
        api: overrides.endpoint
      )
    }
    try Task.checkCancellation()

    if routingMode == .systemProxy {
      try await systemProxyController.apply(host: overrides.externalControllerHost, port: overrides.mixedPort)
      systemProxyEnabled = true
    }
    try Task.checkCancellation()
    sessionStartedAt = Date()
    refreshProfilePreview()
    startStreams(client: client)
    reloadRuntimeData(clearAfterConfirmation: !previewSelections.isEmpty)
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

  func reloadRuntimeData(clearAfterConfirmation: Bool = false) {
    guard isCoreRunning, let apiClient else {
      proxyGroups = []
      rules = []
      connections = []
      refreshProfilePreview()
      return
    }
    Task {
      do {
        let knownDelays = proxyDelayMap(from: proxyGroups)
        let runtimeGroups = try await apiClient.proxyGroups()
        proxyGroups = runtimeGroups.preservingKnownDelays(knownDelays)
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
        self.helperClient.statusMessage = "Helper not responding. Register it from System Settings or switch to System Proxy."
      } catch {
        self.helperClient.statusMessage = "Helper unavailable: \(error.localizedDescription)"
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
        self.helperClient.statusMessage = "Helper not responding. Register it from System Settings or switch to System Proxy."
      } catch {
        self.lastError = UserFacingError.message(for: error)
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
    Task {
      do {
        let delay = try await apiClient.testDelay(proxy: node.name, testURL: AppConstants.defaultDelayTestURL, timeout: 5000)
        applyDelay(delay, to: node.name)
        reloadRuntimeData()
      } catch {
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func setSystemProxyEnabled(_ enabled: Bool) {
    Task { [self] in
      do {
        if enabled {
          proxyRoutingMode = .systemProxy
          try await systemProxyController.apply(host: overrides.externalControllerHost, port: overrides.mixedPort)
          systemProxyEnabled = true
        } else {
          try await systemProxyController.restore()
          systemProxyEnabled = false
        }
      } catch {
        lastError = UserFacingError.message(for: error)
      }
    }
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
    previewRuntimeActive = false
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
        let runtimeGroups = try await client.proxyGroups()
        proxyGroups = runtimeGroups.preservingKnownDelays(knownDelays)
      } catch {
        // Best-effort initial fetch; UI still shows YAML preview if this fails.
      }
    } catch is CancellationError {
      previewRuntimeActive = false
      coreController.stop()
      apiClient = nil
    } catch {
      previewRuntimeActive = false
      coreController.stop()
      apiClient = nil
      lastError = UserFacingError.message(for: error)
    }
  }

  private func stopRuntime() async {
    apiClient = nil
    streamTasks.forEach { $0.cancel() }
    streamTasks.removeAll()
    coreController.stop()
    proxyGroups = []
    rules = []
    connections = []
    trafficSample = .zero
    trafficHistory = []
    if tunEnabled || tunnelCoreRunning {
      _ = try? await helperClient.stopTunnel()
    }
    tunnelCoreRunning = false
    sessionStartedAt = nil
    previewRuntimeActive = false
    refreshProfilePreview()
    if systemProxyEnabled {
      try? await systemProxyController.restore()
    }
    systemProxyEnabled = false
    tunEnabled = false
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

  private func proxyDelayMap(from groups: [ProxyGroup]) -> [String: Int] {
    groups.reduce(into: [String: Int]()) { result, group in
      for node in group.nodes {
        if let delay = node.delay {
          result[node.name] = delay
        }
      }
    }
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
