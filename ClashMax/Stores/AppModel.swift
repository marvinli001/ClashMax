import AppKit
import Combine
import Foundation
import ServiceManagement
import UniformTypeIdentifiers

private enum AppStartupAbort: Error {
  case waitingForTunHelper
}

private enum RuntimeStopPurpose {
  case userInitiated
  case safetyShutdown
  case termination

  var continuesAfterNetworkExtensionStopFailure: Bool {
    self == .termination
  }

  var schedulesPreviewRestart: Bool {
    self == .userInitiated
  }
}

private struct RuntimeStopResult {
  var coreStopError: Error?
  var helperStopError: Error?
  var networkExtensionStopError: Error?
  var networkExtensionDNSRestoreError: Error?
  var tunDNSRestoreError: Error?
  var systemProxyRestoreError: Error?
  var didRunLocalCleanup = false

  static let success = RuntimeStopResult(didRunLocalCleanup: true)

  var succeeded: Bool {
    coreStopError == nil
      && helperStopError == nil
      && networkExtensionStopError == nil
      && networkExtensionDNSRestoreError == nil
      && tunDNSRestoreError == nil
      && systemProxyRestoreError == nil
  }

  var localCleanupSucceeded: Bool {
    didRunLocalCleanup
      && coreStopError == nil
      && helperStopError == nil
      && networkExtensionDNSRestoreError == nil
      && tunDNSRestoreError == nil
      && systemProxyRestoreError == nil
  }

  var userFacingMessage: String? {
    if let networkExtensionDNSRestoreError {
      return "Could not restore Network Extension DNS settings: \(UserFacingError.message(for: networkExtensionDNSRestoreError))"
    }
    if let tunDNSRestoreError {
      return "Could not restore TUN DNS settings: \(UserFacingError.message(for: tunDNSRestoreError))"
    }
    if let systemProxyRestoreError {
      return "Could not restore System Proxy settings: \(UserFacingError.message(for: systemProxyRestoreError))"
    }
    if let helperStopError {
      return "Could not stop TUN helper cleanly: \(UserFacingError.message(for: helperStopError))"
    }
    if let networkExtensionStopError {
      return "Could not stop Network Extension cleanly: \(UserFacingError.message(for: networkExtensionStopError))"
    }
    if let coreStopError {
      return "Could not stop Mihomo cleanly: \(UserFacingError.message(for: coreStopError))"
    }
    return nil
  }

}

private struct NetworkExtensionStopCleanupResult {
  var transparentProxyStopError: Error?
  var dnsRestoreError: Error?
}

private extension TunDiagnosticsSnapshot {
  private static let repairableRoutingIssueIDs: Set<String> = [
    "interface",
    "default-route",
    "route-exclude",
    "dns-hijack"
  ]

  var repairableRoutingIssue: TunDiagnosticCheck? {
    checks.first { check in
      check.status == .fail && Self.repairableRoutingIssueIDs.contains(check.id)
    } ?? checks.first { check in
      check.status == .warn && Self.repairableRoutingIssueIDs.contains(check.id)
    }
  }

  var hasRepairableRoutingIssue: Bool {
    repairableRoutingIssue != nil
  }

  var repairableRoutingIssueMessage: String {
    guard let issue = repairableRoutingIssue else {
      return "TUN routing diagnostics still report a repairable issue."
    }
    return "\(issue.title): \(issue.message)"
  }
}

private enum LastErrorOrigin {
  case networkExtension
}

enum SystemDNSOverrideState: Equatable, Sendable {
  case inactive
  case applying
  case applied(serviceCount: Int)
  case restoring
  case restored
  case applyFailed(String)
  case restoreFailed(String)

  var displayName: String {
    switch self {
    case .inactive:
      return String(localized: "Inactive")
    case .applying:
      return String(localized: "Applying")
    case let .applied(serviceCount):
      return serviceCount > 0
        ? String(format: String(localized: "Applied (%lld)"), serviceCount)
        : String(localized: "Applied")
    case .restoring:
      return String(localized: "Restoring")
    case .restored:
      return String(localized: "Restored")
    case .applyFailed:
      return String(localized: "Apply Failed")
    case .restoreFailed:
      return String(localized: "Restore Failed")
    }
  }

  var errorMessage: String? {
    switch self {
    case let .applyFailed(message), let .restoreFailed(message):
      return message
    case .inactive, .applying, .applied, .restoring, .restored:
      return nil
    }
  }
}

typealias NetworkExtensionSystemDNSState = SystemDNSOverrideState

private extension SystemDNSOverrideState {
  var diagnosticsApplied: Bool {
    if case .applied = self {
      return true
    }
    return false
  }

  var diagnosticsStatus: String {
    switch self {
    case .inactive:
      return "inactive"
    case .applying:
      return "applying"
    case .applied:
      return "applied"
    case .restoring:
      return "restoring"
    case .restored:
      return "restored"
    case .applyFailed:
      return "apply_failed"
    case .restoreFailed:
      return "restore_failed"
    }
  }
}

struct AppNotice: Equatable {
  enum Tone: Equatable {
    case info
    case success
  }

  var message: String
  var tone: Tone

  var symbolName: String {
    switch tone {
    case .info:
      return "info.circle.fill"
    case .success:
      return "checkmark.circle.fill"
    }
  }
}

struct RuntimeDiagnosticsReport: Equatable, Sendable {
  static let redactedSecret = "<redacted>"

  var generatedAt: Date
  var statusSummary: String
  var profileName: String
  var runtimeOwner: RuntimeOwner
  var routingMode: ProxyRoutingMode
  var runMode: RunMode
  var controllerHost: String
  var controllerPort: Int
  var controllerSecret: String
  var coreStatus: String
  var systemProxyEnabled: Bool
  var tunEnabled: Bool
  var networkExtensionEnabled: Bool
  var tunSystemDNS: String
  var networkExtensionSystemDNS: String
  var tunDNSMode: String
  var ruleOverlaySummary: String
  var helperDetail: TunnelHelperStatusDetail
  var tunDiagnostics: TunDiagnosticsSnapshot
  var networkExtensionDiagnostics: NetworkExtensionDiagnosticsSnapshot
  var readinessIssue: String?
  var lastError: String?
  var recentLogs: [String]
  var helperLogs: [String]

  var plainText: String {
    let lines = rawLines().map(redacted)
    return lines.joined(separator: "\n")
  }

  private func rawLines() -> [String] {
    var lines = [
      "ClashMax Runtime Diagnostics",
      "Generated: \(generatedAt.formatted(date: .numeric, time: .standard))",
      "Status: \(statusSummary)",
      "Profile: \(profileName)",
      "Runtime Owner: \(runtimeOwner.rawValue)",
      "Routing Mode: \(routingMode.displayName)",
      "Run Mode: \(runMode.displayName)",
      "Controller: \(controllerHost):\(controllerPort)",
      "Controller Secret: \(controllerSecret)",
      "Core: \(coreStatus)",
      "System Proxy: \(systemProxyEnabled ? "enabled" : "disabled")",
      "TUN: \(tunEnabled ? "enabled" : "disabled")",
      "NE Proxy: \(networkExtensionEnabled ? "enabled" : "disabled")",
      "TUN DNS: \(tunSystemDNS) / \(tunDNSMode)",
      "NE System DNS: \(networkExtensionSystemDNS)",
      "Rule Overlay: \(ruleOverlaySummary)",
      "Helper Service: \(helperDetail.serviceStatus.displayName)",
      "Helper Fingerprint: \(helperFingerprintSummary)",
      "Helper Protocol: \(helperDetail.protocolVersion.map { "v\($0)" } ?? "unknown")",
      "Helper Build: \(helperDetail.helperBuildVersion ?? "unknown")",
      "Helper Running: \(helperDetail.pid.map { "pid \($0)" } ?? (helperDetail.running ? "yes" : "no"))",
      "Helper Safe Paths: helper validates bundled core, runtime config, and work directory before launch",
      "Helper Status: \(helperDetail.message)",
      "TUN Diagnostics: \(tunDiagnostics.summaryLabel)",
      "NE Diagnostics: TCP \(networkExtensionDiagnostics.activeTCPBridgeCount), UDP \(networkExtensionDiagnostics.activeUDPBridgeCount), DNS \(networkExtensionDiagnostics.dnsCaptureCount)",
    ]
    if let readinessIssue {
      lines.append("Readiness: \(readinessIssue)")
    }
    if let lastError {
      lines.append("Last Error: \(lastError)")
    }
    if !tunDiagnostics.checks.isEmpty {
      lines.append("TUN Checks:")
      lines.append(contentsOf: tunDiagnostics.checks.map { "- \($0.title): \($0.status.displayName) - \($0.message)" })
    }
    if !helperLogs.isEmpty {
      lines.append("Helper Logs:")
      lines.append(contentsOf: helperLogs.suffix(8).map { "- \($0)" })
    }
    if !recentLogs.isEmpty {
      lines.append("Runtime Logs:")
      lines.append(contentsOf: recentLogs.suffix(12).map { "- \($0)" })
    }
    return lines
  }

  private var helperFingerprintSummary: String {
    guard helperDetail.fingerprintRecorded else {
      return "not recorded"
    }
    switch helperDetail.fingerprintMatches {
    case true:
      return "match"
    case false:
      return "mismatch"
    case nil:
      return "unknown"
    }
  }

  private func redacted(_ value: String) -> String {
    let trimmedSecret = controllerSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedSecret.isEmpty else {
      return value.replacingOccurrences(of: "Controller Secret: ", with: "Controller Secret: \(Self.redactedSecret)")
    }
    return value
      .replacingOccurrences(of: "Bearer \(trimmedSecret)", with: "Bearer \(Self.redactedSecret)")
      .replacingOccurrences(of: trimmedSecret, with: Self.redactedSecret)
  }
}

@MainActor
final class AppModel: ObservableObject {
  @Published var selectedSection: AppSection = .home
  var overrides: RuntimeOverrides {
    get { settings.overrides }
    set { settings.overrides = newValue }
  }
  var proxyRoutingMode: ProxyRoutingMode {
    get { settings.proxyRoutingMode }
    set { settings.proxyRoutingMode = newValue }
  }
  var systemProxySettings: SystemProxySettings {
    get { settings.systemProxySettings }
    set { settings.systemProxySettings = newValue }
  }
  var ipv6Enabled: Bool {
    get { settings.ipv6Enabled }
    set { setIPv6Enabled(newValue) }
  }
  var tunSettings: TunSettings {
    get { settings.tunSettings }
    set { settings.tunSettings = newValue }
  }
  var networkExtensionRoutingSettings: NetworkExtensionRoutingSettings {
    get { settings.networkExtensionRoutingSettings }
    set { settings.networkExtensionRoutingSettings = newValue }
  }
  var ruleOverlaySettings: RuleOverlaySettings {
    get { settings.ruleOverlaySettings }
    set { settings.ruleOverlaySettings = newValue }
  }
  var delayTestSettings: DelayTestSettings {
    get { settings.delayTestSettings }
    set { settings.delayTestSettings = newValue }
  }
  var appTheme: AppTheme {
    get { settings.appTheme }
    set { settings.appTheme = newValue }
  }
  var externalControllerSettings: ExternalControllerSettings {
    get { settings.externalControllerSettings }
    set { settings.externalControllerSettings = newValue }
  }
  var launchSettings: LaunchSettings { settings.launchSettings }
  var developerMode: Bool {
    get { settings.developerMode }
    set { setDeveloperMode(newValue) }
  }
  @Published private(set) var runtimeOwner: RuntimeOwner = .stopped
  var systemProxyEnabled: Bool {
    get { systemProxy.enabled }
    set { systemProxy.enabled = newValue }
  }
  @Published var tunEnabled = false
  @Published private(set) var tunHelperPID: Int?
  var networkExtensionEnabled: Bool {
    runtimeOwner == .networkExtension && networkExtensionController.vpnStatus.isActive
  }
  var canRepairNetworkExtensionDNS: Bool {
    runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
      || systemProxyController.hasManagedSystemDNSState
  }
  var canRepairTunDNS: Bool {
    runtimeOwner == .tunnel
      || tunEnabled
      || tunnelCoreRunning
      || systemProxyController.hasManagedSystemDNSState
  }
  var canRepairTunRouting: Bool {
    runtimeOwner == .tunnel
      || tunEnabled
      || tunnelCoreRunning
      || tunDiagnostics.primaryIssue != nil
      || systemProxyController.hasManagedSystemDNSState
  }
  @Published var tunnelCoreRunning = false
  @Published private(set) var networkExtensionSystemDNSState: SystemDNSOverrideState = .inactive
  @Published private(set) var tunSystemDNSState: SystemDNSOverrideState = .inactive
  @Published private(set) var tunDiagnostics: TunDiagnosticsSnapshot = .empty
  @Published private(set) var tunHelperPreparationState: TunHelperPreparationState = .idle
  @Published private(set) var tunHelperStatusDetail: TunnelHelperStatusDetail = .unknown
  var isAddingSubscription: Bool { profileOperations.isAddingSubscription }
  @Published private(set) var startInFlight = false
  @Published private(set) var runtimeDataLoading = false
  @Published private(set) var sessionStartedAt: Date?
  @Published private var networkExtensionCoreCrashMessage: String?
  var proxyGroups: [ProxyGroup] {
    get { runtimeData.proxyGroups }
    set { runtimeData.proxyGroups = newValue }
  }
  var proxyProviders: [ProxyProvider] {
    get { runtimeData.proxyProviders }
    set { runtimeData.proxyProviders = newValue }
  }
  var ruleProviders: [RuleProvider] {
    get { runtimeData.ruleProviders }
    set { runtimeData.ruleProviders = newValue }
  }
  var rules: [String] {
    get { runtimeData.rules }
    set { runtimeData.rules = newValue }
  }
  var connections: [ConnectionSnapshot] {
    get { runtimeData.connections }
    set { runtimeData.replaceConnections(newValue) }
  }
  var logs: [LogEntry] {
    get { runtimeData.logs }
  }
  @Published var helperLogs: [String] = []
  var trafficSample: TrafficSample {
    get { runtimeData.trafficSample }
    set { runtimeData.trafficSample = newValue }
  }
  var trafficHistory: [TrafficSample] {
    get { runtimeData.trafficHistory }
    set { runtimeData.trafficHistory = newValue }
  }
  var publicIPInfoState: PublicIPInfoState { publicIP.state }
  @Published private(set) var appNotice: AppNotice?
  private var lastErrorOrigin: LastErrorOrigin?
  private var isPublishingNetworkExtensionLastError = false
  @Published var lastError: String? {
    didSet {
      if !isPublishingNetworkExtensionLastError {
        lastErrorOrigin = nil
      }
    }
  }
  var updatingProfileIDs: Set<Profile.ID> { profileOperations.updatingProfileIDs }
  var profileOperationMessage: String? { profileOperations.message }
  var profilePreviewGroups: [ProxyGroup] {
    get { proxyPreview.profilePreviewGroups }
    set { proxyPreview.profilePreviewGroups = newValue }
  }
  var previewRuntimeActive: Bool {
    get { proxyPreview.previewRuntimeActive }
    set { proxyPreview.previewRuntimeActive = newValue }
  }
  var previewSelections: [String: String] {
    get { proxyPreview.previewSelections }
    set { proxyPreview.previewSelections = newValue }
  }
  var providerHealthChecksInFlight: Set<ProxyProvider.ID> { runtimeData.providerHealthChecksInFlight }
  var proxyProviderUpdatesInFlight: Set<ProxyProvider.ID> { runtimeData.proxyProviderUpdatesInFlight }
  var ruleProviderUpdatesInFlight: Set<RuleProvider.ID> { runtimeData.ruleProviderUpdatesInFlight }
  var closingConnectionIDs: Set<ConnectionSnapshot.ID> { runtimeData.closingConnectionIDs }
  var closingAllConnections: Bool {
    get { runtimeData.closingAllConnections }
    set { runtimeData.closingAllConnections = newValue }
  }

  let settings: PersistedSettingsStore
  let runtimeData = RuntimeDataStore()
  let publicIP: PublicIPCoordinator
  let profileOperations: ProfileOperationsStore
  let proxyPreview: ProxyPreviewStore
  let systemProxy: SystemProxyCoordinator
  let profileStore: ProfileStore
  let coreController: CoreProcessController
  var systemProxyController: SystemProxyController { systemProxy.controller }
  let helperClient: TunnelHelperClient
  let networkExtensionController: NetworkExtensionController
  private let tunnelReadinessProbe: CoreReadinessProbing
  private let proxyPortReadinessProbe: any ProxyPortReadinessProbing
  private let tunRuntimeInspector: any TunRuntimeInspecting
  private let pingTester: any PingTesting
  private let paths: RuntimePaths
  private let runtimeConfigMaterializer = RuntimeConfigMaterializer()
  private var apiClient: (any MihomoAPIControlling)?
  private var startTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var previewRuntimeRequested = false
  private var stopTask: Task<RuntimeStopResult, Never>?
  private var stopTaskID: UUID?
  private var stopTaskPurpose: RuntimeStopPurpose?
  private var pendingModeTask: Task<Void, Never>?
  private var pendingRoutingModeTask: Task<Void, Never>?
  private var tunHelperPreparationTask: Task<Void, Never>?
  private var didWarmTunHelperRegistrationOnLaunch = false
  private var modeUpdateTask: Task<Void, Never>?
  private var modeUpdateToken: UUID?
  private var ipv6UpdateTask: Task<Void, Never>?
  private var ipv6UpdateToken: UUID?
  private var proxySelectionTasks: [ProxyGroup.ID: Task<Void, Never>] = [:]
  private var proxySelectionTokens: [ProxyGroup.ID: UUID] = [:]
  private var delayTestTasks: [ProxyNode.ID: Task<Void, Never>] = [:]
  private var delayTestTokens: [ProxyNode.ID: UUID] = [:]
  private var providerHealthCheckTasks: [ProxyProvider.ID: Task<Void, Never>] = [:]
  private var providerHealthCheckTokens: [ProxyProvider.ID: UUID] = [:]
  private var proxyProviderUpdateTasks: [ProxyProvider.ID: Task<Void, Never>] = [:]
  private var proxyProviderUpdateTokens: [ProxyProvider.ID: UUID] = [:]
  private var ruleProviderUpdateTasks: [RuleProvider.ID: Task<Void, Never>] = [:]
  private var ruleProviderUpdateTokens: [RuleProvider.ID: UUID] = [:]
  private var proxyProviderBatchUpdateTask: Task<Void, Never>?
  private var proxyProviderBatchUpdateToken: UUID?
  private var ruleProviderBatchUpdateTask: Task<Void, Never>?
  private var ruleProviderBatchUpdateToken: UUID?
  private var connectionCloseTasks: [ConnectionSnapshot.ID: Task<Void, Never>] = [:]
  private var connectionCloseTokens: [ConnectionSnapshot.ID: UUID] = [:]
  private var closeAllConnectionsTask: Task<Void, Never>?
  private var closeAllConnectionsToken: UUID?
  private var runtimeReloadTask: Task<Void, Never>?
  private var runtimeReloadToken: UUID?
  private var runtimeReloadPending = false
  private var tunSettingsApplyTask: Task<Void, Never>?
  private var tunSettingsApplyToken: UUID?
  private var subscriptionAutoUpdateTask: Task<Void, Never>?
  private var subscriptionAutoUpdateBackoffUntil: [Profile.ID: Date] = [:]
  private var streamTasks: [Task<Void, Never>] = []
  private var networkExtensionDiagnosticsTask: Task<Void, Never>?
  private var tunDiagnosticsTask: Task<Void, Never>?
  private var publishedNetworkExtensionDiagnosticEventIDs: Set<String> = []
  private var storeCancellables: Set<AnyCancellable> = []
  static let publicIPRefreshInterval: TimeInterval = 300
  static let silentStartDefaultsKey = PersistedSettingsStore.silentStartDefaultsKey
  static let startWallClockSeconds: TimeInterval = 22
  static let subscriptionAutoUpdateRetryDelay: TimeInterval = 15 * 60
  private static let tunHelperApprovalPollingAttempts = 8
  private static let tunHelperApprovalPollingIntervalNanoseconds: UInt64 = 1_000_000_000
  private static let tunControllerCleanupTimeoutSeconds: TimeInterval = 2

  static func bootstrap() -> AppModel {
    do {
      let paths = try RuntimePaths.live()
      return AppModel(paths: paths)
    } catch {
      let fallback = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ClashMax", isDirectory: true)
      let paths = RuntimePaths(
        appSupport: fallback,
        profiles: fallback.appendingPathComponent("Profiles", isDirectory: true),
        runtime: fallback.appendingPathComponent("Runtime", isDirectory: true),
        subscriptions: fallback.appendingPathComponent("Subscriptions", isDirectory: true),
        logs: fallback.appendingPathComponent("Logs", isDirectory: true)
      )
      try? paths.prepareDirectories()
      let model = AppModel(paths: paths)
      model.lastError = UserFacingError.message(for: error)
      return model
    }
  }

  init(
    paths: RuntimePaths,
    profileStore: ProfileStore? = nil,
    coreController: CoreProcessController = CoreProcessController(),
    systemProxyController: SystemProxyController? = nil,
    helperClient: TunnelHelperClient = TunnelHelperClient(),
    networkExtensionController: NetworkExtensionController = NetworkExtensionController(),
    loginItemService: any LoginItemManaging = MainAppLoginItemService(),
    tunnelReadinessProbe: CoreReadinessProbing = MihomoCoreReadinessProbe(),
    proxyPortReadinessProbe: any ProxyPortReadinessProbing = SocksProxyReadinessProbe(),
    tunRuntimeInspector: any TunRuntimeInspecting = TunRuntimeInspector(),
    apiClient: (any MihomoAPIControlling)? = nil,
    pingTester: any PingTesting = SystemPingTester(),
    publicIPInfoClient: any PublicIPInfoFetching = PublicIPInfoClient(),
    defaults: UserDefaults = .standard
  ) {
    self.paths = paths
    self.profileStore = profileStore ?? ProfileStore(paths: paths)
    self.profileOperations = ProfileOperationsStore(profileStore: self.profileStore)
    self.proxyPreview = ProxyPreviewStore(defaults: defaults)
    self.coreController = coreController
    self.helperClient = helperClient
    self.networkExtensionController = networkExtensionController
    self.tunnelReadinessProbe = tunnelReadinessProbe
    self.proxyPortReadinessProbe = proxyPortReadinessProbe
    self.tunRuntimeInspector = tunRuntimeInspector
    self.pingTester = pingTester
    self.publicIP = PublicIPCoordinator(
      client: publicIPInfoClient,
      refreshInterval: Self.publicIPRefreshInterval
    )
    self.apiClient = apiClient
    self.systemProxy = SystemProxyCoordinator(
      controller: systemProxyController ?? SystemProxyController(snapshotDefaults: defaults),
      defaults: defaults
    )
    settings = PersistedSettingsStore(loginItemService: loginItemService, defaults: defaults)
    settings.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    settings.$subscriptionFetchSettings
      .dropFirst()
      .sink { [weak self] _ in
        self?.rescheduleSubscriptionAutoUpdates()
      }
      .store(in: &storeCancellables)
    profileOperations.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    proxyPreview.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    proxyPreview.$profilePreviewGroups
      .sink { [weak self] groups in
        self?.schedulePreviewRuntimeStartIfReady(profilePreviewGroups: groups)
      }
      .store(in: &storeCancellables)
    self.profileStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    systemProxy.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    coreController.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    coreController.$status
      .sink { [weak self] status in
        self?.handleCoreStatusChange(status)
      }
      .store(in: &storeCancellables)
    networkExtensionController.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    recoverDanglingSystemProxyIfNeeded()
    recoverDanglingManagedDNSIfNeeded()
    let needsManifestRefresh = self.profileStore.activeProfileID == nil
    refreshProfilePreview()
    loadPreviewSelectionsForActiveProfile()
    if needsManifestRefresh {
      Task { @MainActor [weak self] in
        guard let self else { return }
        await self.profileStore.waitForManifestLoad()
        await self.refreshProfilePreviewAndWait()
        self.loadPreviewSelectionsForActiveProfile()
        self.rescheduleSubscriptionAutoUpdates()
      }
    } else {
      rescheduleSubscriptionAutoUpdates()
    }
  }

  var isCoreRunning: Bool {
    if case .running = coreController.status { return true }
    return tunnelCoreRunning
  }

  var isRunning: Bool {
    isCoreRunning && !previewRuntimeActive
  }

  var canStopRuntime: Bool {
    isRunning
      || dashboardRuntimeState.isStarting
      || activeNetworkExtensionCoreCrashMessage != nil
      || runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
  }

  var dashboardRuntimeState: DashboardRuntimeState {
    if let message = activeNetworkExtensionCoreCrashMessage {
      return .crashed(message: message)
    }
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
    if let message = activeNetworkExtensionCoreCrashMessage {
      return "Crashed: \(message)"
    }
    if tunnelCoreRunning {
      return "Running TUN"
    }
    if case let .crashed(message) = coreController.status {
      return "Crashed: \(message)"
    }
    if runtimeOwner == .networkExtension {
      return "Running NE"
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
    if proxyRoutingMode == .tun, !tunHelperPreparationState.allowsStartAttempt {
      return tunHelperPreparationState.message
    }
    return nil
  }

  private var activeNetworkExtensionCoreCrashMessage: String? {
    if case let .crashed(message) = coreController.status,
       runtimeOwner == .networkExtension || networkExtensionController.vpnStatus.isActive || networkExtensionCoreCrashMessage != nil {
      return message
    }
    return networkExtensionCoreCrashMessage
  }

  private func handleCoreStatusChange(_ status: CoreStatus) {
    guard case let .crashed(message) = status else { return }
    guard runtimeOwner == .networkExtension || networkExtensionController.vpnStatus.isActive else { return }
    networkExtensionCoreCrashMessage = message
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
    isCoreRunning && apiClient != nil
  }

  var canSelectProxyOffline: Bool {
    !isCoreRunning && profileStore.activeProfile != nil && !profilePreviewGroups.isEmpty
  }

  var userVisibleLogs: [LogEntry] {
    LogVisibility.visibleEntries(in: logs, developerMode: developerMode)
  }

  func runtimeDiagnosticsReport(now: Date = Date()) -> RuntimeDiagnosticsReport {
    RuntimeDiagnosticsReport(
      generatedAt: now,
      statusSummary: statusSummary,
      profileName: profileStore.activeProfile?.name ?? "No Profile",
      runtimeOwner: runtimeOwner,
      routingMode: proxyRoutingMode,
      runMode: overrides.mode,
      controllerHost: overrides.externalControllerHost,
      controllerPort: overrides.externalControllerPort,
      controllerSecret: overrides.secret,
      coreStatus: coreDiagnosticsStatus,
      systemProxyEnabled: systemProxyEnabled,
      tunEnabled: tunEnabled,
      networkExtensionEnabled: networkExtensionEnabled,
      tunSystemDNS: tunSystemDNSState.displayName,
      networkExtensionSystemDNS: networkExtensionSystemDNSState.displayName,
      tunDNSMode: tunSettings.dnsFakeIPEnabled ? "fake-ip" : "profile",
      ruleOverlaySummary: ruleOverlaySettings.summary,
      helperDetail: tunHelperStatusDetail,
      tunDiagnostics: tunDiagnostics,
      networkExtensionDiagnostics: networkExtensionController.diagnostics,
      readinessIssue: readinessIssue,
      lastError: lastError,
      recentLogs: userVisibleLogs.map { entry in
        "\(entry.date.formatted(date: .omitted, time: .standard)) [\(entry.level)] \(entry.message)"
      },
      helperLogs: helperLogs
    )
  }

  func copyRuntimeDiagnostics() {
    let report = runtimeDiagnosticsReport()
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(report.plainText, forType: .string)
    appNotice = AppNotice(message: String(localized: "Diagnostics copied."), tone: .success)
  }

  func openRuntimeLogs() {
    selectedSection = .logs
  }

  func openLogsFolder() {
    try? paths.prepareDirectories()
    if !NSWorkspace.shared.open(paths.logs) {
      selectedSection = .logs
    }
  }

  private var coreDiagnosticsStatus: String {
    switch coreController.status {
    case .stopped:
      return "stopped"
    case .starting:
      return "starting"
    case let .running(version):
      return version.map { "running \($0)" } ?? "running"
    case let .crashed(message):
      return "crashed: \(message)"
    case .restarting:
      return "restarting"
    }
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
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        _ = try await profileOperations.importLocalProfile(from: url)
        await refreshProfilePreviewAndWait()
        loadPreviewSelectionsForActiveProfile()
        lastError = nil
      } catch {
        profileOperations.clearMessage()
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  @discardableResult
  func addSubscription(name: String = "", urlString: String, session: URLSession = .shared) async -> Bool {
    let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let resolution = SubscriptionURLResolver.resolve(rawInput: trimmedURLString) else {
      profileOperations.clearMessage()
      lastError = "Invalid subscription URL."
      return false
    }

    lastError = nil
    profileOperations.clearMessage()

    do {
      guard try await profileOperations.addSubscription(
        name: name,
        url: resolution.url,
        displayNameHint: resolution.displayNameHint,
        session: session,
        fetchOptions: subscriptionFetchOptions,
        preflightValidator: subscriptionPreflightValidator()
      ) != nil else {
        return false
      }
      await refreshProfilePreviewAndWait()
      loadPreviewSelectionsForActiveProfile()
      rescheduleSubscriptionAutoUpdates()
      return true
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func handleIncomingURL(_ url: URL) {
    guard SubscriptionURLResolver.resolve(url: url) != nil else {
      lastError = "Invalid subscription URL."
      return
    }
    selectedSection = .profiles
    Task { @MainActor [weak self] in
      _ = await self?.addSubscription(urlString: url.absoluteString)
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
    lastError = nil
    profileOperations.clearMessage()

    do {
      let updated = try await profileOperations.updateSubscription(
        profile,
        session: session,
        fetchOptions: subscriptionFetchOptions(for: profile),
        preflightValidator: subscriptionPreflightValidator()
      )
      await refreshProfilePreviewAndWait()
      rescheduleSubscriptionAutoUpdates()
      return updated
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  @discardableResult
  func updateSubscriptionSource(_ profile: Profile, urlString: String, session: URLSession = .shared) async -> Bool {
    let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let resolution = SubscriptionURLResolver.resolve(rawInput: trimmedURLString) else {
      profileOperations.clearMessage()
      lastError = "Invalid subscription URL."
      return false
    }

    lastError = nil
    profileOperations.clearMessage()

    do {
      let updated = try await profileOperations.updateSubscriptionSource(
        profile,
        url: resolution.url,
        displayNameHint: resolution.displayNameHint,
        session: session,
        fetchOptions: subscriptionFetchOptions(for: profile),
        preflightValidator: subscriptionPreflightValidator()
      )
      await refreshProfilePreviewAndWait()
      loadPreviewSelectionsForActiveProfile()
      try await reloadActiveRuntimeConfigIfNeeded(
        for: profile.id,
        logMessage: "Subscription source updated: Mihomo reloaded"
      )
      rescheduleSubscriptionAutoUpdates()
      return updated
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  @discardableResult
  func updateSubscriptionProviderOptions(
    _ profile: Profile,
    options: SubscriptionProviderOptions
  ) async -> Bool {
    lastError = nil
    profileOperations.clearMessage()

    do {
      try await profileOperations.updateSubscriptionProviderOptions(
        profile,
        options: options,
        preflightValidator: subscriptionPreflightValidator()
      )
      if profile.id == profileStore.activeProfileID {
        await refreshProfilePreviewAndWait()
        try await reloadActiveRuntimeConfigIfNeeded(
          for: profile.id,
          logMessage: "Subscription provider options updated: Mihomo reloaded"
        )
      }
      rescheduleSubscriptionAutoUpdates()
      return true
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  @discardableResult
  func updateSubscriptionSourceAndProviderOptions(
    _ profile: Profile,
    urlString: String,
    options: SubscriptionProviderOptions,
    session: URLSession = .shared
  ) async -> Bool {
    let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let resolution = SubscriptionURLResolver.resolve(rawInput: trimmedURLString) else {
      profileOperations.clearMessage()
      lastError = "Invalid subscription URL."
      return false
    }

    lastError = nil
    profileOperations.clearMessage()

    do {
      let updated = try await profileOperations.updateSubscriptionSourceAndProviderOptions(
        profile,
        url: resolution.url,
        displayNameHint: resolution.displayNameHint,
        options: options,
        session: session,
        fetchOptions: options.fetchOptions(from: subscriptionFetchOptions),
        preflightValidator: subscriptionPreflightValidator()
      )
      await refreshProfilePreviewAndWait()
      loadPreviewSelectionsForActiveProfile()
      try await reloadActiveRuntimeConfigIfNeeded(
        for: profile.id,
        logMessage: "Subscription source and provider options updated: Mihomo reloaded"
      )
      rescheduleSubscriptionAutoUpdates()
      return updated
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  private func rescheduleSubscriptionAutoUpdates(now: Date = Date()) {
    subscriptionAutoUpdateTask?.cancel()
    subscriptionAutoUpdateTask = nil

    guard settings.subscriptionFetchSettings.automaticUpdatesEnabled,
          let nextUpdateAt = nextSubscriptionAutoUpdateDate(now: now)
    else {
      return
    }

    let delay = max(1, nextUpdateAt.timeIntervalSince(now))
    subscriptionAutoUpdateTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.nanoseconds(for: delay))
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      await self.runDueSubscriptionAutoUpdates()
    }
  }

  private func runDueSubscriptionAutoUpdates() async {
    subscriptionAutoUpdateTask = nil
    guard settings.subscriptionFetchSettings.automaticUpdatesEnabled else { return }

    let now = Date()
    let dueProfiles = dueSubscriptionProfiles(now: now)
    guard !dueProfiles.isEmpty else {
      rescheduleSubscriptionAutoUpdates(now: now)
      return
    }

    var shouldRefreshPreview = false
    for profile in dueProfiles {
      do {
        let updated = try await profileOperations.updateSubscription(
          profile,
          session: .shared,
          fetchOptions: subscriptionFetchOptions(for: profile),
          preflightValidator: subscriptionPreflightValidator()
        )
        if updated {
          subscriptionAutoUpdateBackoffUntil[profile.id] = nil
          appendAppLog(level: "info", message: "Auto-updated subscription \(profile.name).")
          shouldRefreshPreview = shouldRefreshPreview || profile.id == profileStore.activeProfileID
        } else {
          subscriptionAutoUpdateBackoffUntil[profile.id] = now.addingTimeInterval(60)
        }
      } catch {
        let retryAt = Date().addingTimeInterval(Self.subscriptionAutoUpdateRetryDelay)
        subscriptionAutoUpdateBackoffUntil[profile.id] = retryAt
        appendAppLog(
          level: "warn",
          message: "Could not auto-update subscription \(profile.name): \(UserFacingError.message(for: error))"
        )
      }
    }

    if shouldRefreshPreview {
      await refreshProfilePreviewAndWait()
      loadPreviewSelectionsForActiveProfile()
    }
    rescheduleSubscriptionAutoUpdates()
  }

  private func nextSubscriptionAutoUpdateDate(now: Date) -> Date? {
    profileStore.profiles
      .compactMap { subscriptionAutoUpdateDate(for: $0, now: now) }
      .min()
  }

  private func dueSubscriptionProfiles(now: Date) -> [Profile] {
    profileStore.profiles.filter { profile in
      guard let updateAt = subscriptionAutoUpdateDate(for: profile, now: now) else { return false }
      return updateAt <= now
    }
  }

  private func subscriptionAutoUpdateDate(for profile: Profile, now: Date) -> Date? {
    guard profile.isSubscription,
          let metadata = profile.subscriptionMetadata,
          let intervalMinutes = metadata.updateIntervalMinutes,
          intervalMinutes > 0
    else {
      return nil
    }

    let baseDate = (metadata.lastFetchedAt ?? profile.updatedAt)
      .addingTimeInterval(TimeInterval(intervalMinutes * 60))
    if baseDate <= now,
       let backoffDate = subscriptionAutoUpdateBackoffUntil[profile.id],
       backoffDate > now {
      return backoffDate
    }
    return baseDate
  }

  private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
    UInt64(max(0, seconds) * 1_000_000_000)
  }

  @discardableResult
  func renameActiveProfile(to name: String) async -> Bool {
    do {
      try await profileOperations.renameActiveProfile(to: name)
      await refreshProfilePreviewAndWait()
      lastError = nil
      return true
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func renameProfile(_ profile: Profile, to name: String) {
    Task { @MainActor [weak self] in
      await self?.renameProfileAsync(profile, to: name)
    }
  }

  @discardableResult
  func renameProfileAsync(_ profile: Profile, to name: String) async -> Bool {
    do {
      try await profileOperations.renameProfile(profile, to: name)
      await refreshProfilePreviewAndWait()
      lastError = nil
      return true
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  @discardableResult
  func resetSubscriptionName(_ profile: Profile) async -> Bool {
    do {
      try await profileOperations.resetSubscriptionName(profile)
      await refreshProfilePreviewAndWait()
      lastError = nil
      return true
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func deleteActiveProfile() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let deletedID = profileStore.activeProfileID
        try await profileOperations.deleteActiveProfile()
        previewSelections = [:]
        saveCurrentPreviewSelections(forProfileID: deletedID)
        await refreshProfilePreviewAndWait()
        loadPreviewSelectionsForActiveProfile()
        rescheduleSubscriptionAutoUpdates()
        lastError = nil
      } catch {
        profileOperations.clearMessage()
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func deleteProfile(_ profile: Profile) {
    Task { @MainActor [weak self] in
      await self?.deleteProfileAsync(profile)
    }
  }

  @discardableResult
  func deleteProfileAsync(_ profile: Profile) async -> Bool {
    do {
      try await profileOperations.deleteProfile(profile)
      previewSelections = [:]
      saveCurrentPreviewSelections(forProfileID: profile.id)
      await refreshProfilePreviewAndWait()
      loadPreviewSelectionsForActiveProfile()
      rescheduleSubscriptionAutoUpdates()
      lastError = nil
      return true
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func selectProfile(_ profile: Profile) {
    Task { @MainActor [weak self] in
      await self?.selectProfileAsync(profile)
    }
  }

  @discardableResult
  func selectProfileAsync(_ profile: Profile) async -> Bool {
    let isChangingProfile = profileStore.activeProfileID != profile.id
    guard isChangingProfile else { return false }
    do {
      let shouldRestart = isRunning || startInFlight
      guard try await profileOperations.selectProfile(profile) else { return false }
      proxyGroups = []
      await refreshProfilePreviewAndWait()
      loadPreviewSelectionsForActiveProfile()
      lastError = nil
      if shouldRestart {
        restart()
      }
      return true
    } catch {
      profileOperations.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  private func setProvider(_ id: ProxyProvider.ID, healthCheckInFlight isRunning: Bool) {
    runtimeData.setProvider(id, healthCheckInFlight: isRunning)
  }

  private func setProxyProvider(_ id: ProxyProvider.ID, updateInFlight isRunning: Bool) {
    runtimeData.setProxyProvider(id, updateInFlight: isRunning)
  }

  private func setRuleProvider(_ id: RuleProvider.ID, updateInFlight isRunning: Bool) {
    runtimeData.setRuleProvider(id, updateInFlight: isRunning)
  }

  private func setConnection(_ id: ConnectionSnapshot.ID, closing isClosing: Bool) {
    runtimeData.setConnection(id, closing: isClosing)
  }

  private var subscriptionFetchOptions: SubscriptionFetchOptions {
    settings.subscriptionFetchSettings.fetchOptions(currentMixedPort: overrides.mixedPort)
  }

  private func subscriptionFetchOptions(for profile: Profile) -> SubscriptionFetchOptions {
    profile.subscriptionProviderOptions.fetchOptions(from: subscriptionFetchOptions)
  }

  private func reloadActiveRuntimeConfigIfNeeded(for profileID: Profile.ID, logMessage: String) async throws {
    guard profileID == profileStore.activeProfileID, isCoreRunning, let apiClient else {
      return
    }
    let runtimeConfig: URL
    if proxyRoutingMode == .tun {
      runtimeConfig = try await materializeTunRuntimeConfig(tunSettings)
    } else {
      runtimeConfig = try await materializeNonTunRuntimeConfig()
    }
    try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
    appendAppLog(level: "info", message: "\(logMessage) \(runtimeConfig.path).")
    reloadRuntimeData()
  }

  private func subscriptionPreflightValidator() -> any SubscriptionProfilePreflightValidating {
    MihomoSubscriptionProfilePreflightValidator(
      paths: paths,
      overrides: overrides,
      coreURLProvider: { [weak self] in
        guard let self else { throw AppError.missingBundledCore }
        return try self.bundledCoreURL()
      }
    )
  }

  func start() {
    guard startTask == nil, !startInFlight else { return }
    if profileStore.activeProfile == nil {
      lastError = "No active profile selected."
      return
    }
    if (try? bundledCoreURL()) == nil {
      lastError = AppError.missingBundledCore.description
      return
    }
    if proxyRoutingMode == .tun, !tunHelperPreparationState.allowsStartAttempt {
      if tunHelperPreparationState.isFailure {
        lastError = tunHelperPreparationState.message
      } else {
        prepareTunHelperIfNeeded(force: false)
      }
      return
    }
    cancelPendingPreviewRuntimeStart()
    startTask = Task { [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      await self.performStart()
    }
  }

  private func performStart() async {
    startInFlight = true
    networkExtensionCoreCrashMessage = nil
    lastError = nil
    appNotice = nil
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
      handleStopResult(await stopRuntimeCoordinated())
    } catch AppStartupAbort.waitingForTunHelper {
      handleStopResult(await stopRuntimeCoordinated())
    } catch let error as OperationTimedOutError {
      publishStartupDiagnostics(level: "error")
      let diagnostics = startupDiagnosticsSummary()
      handleStopResult(await stopRuntimeCoordinated())
      lastError = "ClashMax could not start within \(Int(error.seconds))s.\(diagnostics.isEmpty ? "" : "\n\(diagnostics)")"
    } catch {
      publishStartupDiagnostics(level: "error")
      handleStopResult(await stopRuntimeCoordinated())
      lastError = UserFacingError.message(for: error)
    }
  }

  private func runStartSequence() async throws {
    cancelPendingPreviewRuntimeStart()
    if previewRuntimeActive {
      let previewStopResult = await leavePreviewRuntimeResult()
      if !previewStopResult.succeeded {
        throw AppError.coreStopFailed(previewStopResult.userFacingMessage ?? "Could not stop preview runtime.")
      }
    }
    try Task.checkCancellation()
    let profile = try requireActiveProfile()
    let routingMode = proxyRoutingMode
    let shouldUseTun = routingMode == .tun
    let shouldUseNetworkExtension = routingMode == .neProxy
    let networkExtensionSettings = networkExtensionRoutingSettings
    settings.syncExternalControllerSettings()
    overrides.tunEnabled = shouldUseTun
    overrides.tunSettings = tunSettings
    let runtimeConfigOptions = RuntimeConfigOptions(
      networkExtensionRoutingSettings: shouldUseNetworkExtension ? networkExtensionSettings : nil
    )
    systemProxyEnabled = false
    tunEnabled = false
    stopTunDiagnostics(clear: true)
    let runtimeConfig = try await generateRuntimeConfig(
      for: profile,
      selections: previewSelections,
      options: runtimeConfigOptions
    )
    let coreURL = try bundledCoreURL()
    appendAppLog(level: "info", message: "Runtime config path: \(runtimeConfig.path)")
    appendAppLog(level: "info", message: "Mihomo core path: \(coreURL.path)")
    let client = MihomoAPIClient(baseURL: try overrides.endpoint.baseURL, secret: overrides.secret)
    apiClient = client
    try Task.checkCancellation()

    if shouldUseTun {
      let preparationState = await prepareTunHelperForStart()
      guard preparationState.isReady else {
        if preparationState.isFailure {
          throw AppError.helperResponse(preparationState.message)
        }
        throw AppStartupAbort.waitingForTunHelper
      }
      let response = try await helperClient.startTunnel(
        coreURL: coreURL,
        configURL: runtimeConfig,
        workDirectory: paths.runtime,
        secret: overrides.secret
      )
      try Task.checkCancellation()
      if !response.ok {
        throw AppError.helperResponse(response.userFacingMessage)
      }
      guard response.running else {
        throw AppError.helperResponse("Helper reported success but TUN is not running.")
      }
      tunHelperPID = response.pid > 0 ? response.pid : nil
      do {
        let version = try await tunnelReadinessProbe.waitUntilReady(api: overrides.endpoint)
        appendAppLog(level: "info", message: "TUN Mihomo controller ready: \(overrides.endpoint.host):\(overrides.endpoint.port), version \(version)")
        if tunSettings.systemDNSOverrideEnabled {
          try await applyTunSystemDNS(tunSettings)
        } else {
          setTunSystemDNSState(.inactive)
        }
      } catch {
        _ = try? await restoreTunSystemDNS()
        _ = try? await helperClient.stopTunnel()
        tunHelperPID = nil
        tunnelCoreRunning = false
        tunEnabled = false
        runtimeOwner = .stopped
        throw error
      }
      tunnelCoreRunning = true
      tunEnabled = true
      runtimeOwner = .tunnel
      refreshTunDiagnostics(includeExternal: true)
      let coreStopResult = await coreController.stop()
      if let error = coreStopResult.error {
        throw error
      }
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

    if shouldUseNetworkExtension {
      try await proxyPortReadinessProbe.waitUntilReady(host: "127.0.0.1", port: overrides.mixedPort)
      if networkExtensionSettings.dnsCaptureEnabled {
        try await proxyPortReadinessProbe.waitUntilOpen(
          host: NetworkExtensionRoutingSettings.defaultDNSListenHost,
          port: networkExtensionSettings.normalizedDNSListenPort,
          serviceName: "Mihomo DNS"
        )
      }
      appendAppLog(level: "info", message: "Starting NE transparent proxy; System Proxy off, TUN helper untouched.")
      try await networkExtensionController.startTransparentProxy(
        configuration: .clashMax(overrides: overrides, routingSettings: networkExtensionSettings)
      )
      if networkExtensionSettings.systemDNSOverrideEnabled {
        try await applyNetworkExtensionSystemDNS(networkExtensionSettings)
      } else {
        setNetworkExtensionSystemDNSState(.inactive)
      }
      runtimeOwner = .networkExtension
      startNetworkExtensionDiagnosticsPolling()
      appendAppLog(level: "info", message: "NE transparent proxy requested: \(networkExtensionController.vpnStatus.displayName)")
    } else if routingMode == .systemProxy {
      try await applySystemProxySettings()
      systemProxyEnabled = true
      try await activateSystemProxyGuardIfNeeded()
    }
    try Task.checkCancellation()
    sessionStartedAt = Date()
    await refreshProfilePreviewAndWait()
    startStreams(client: client)
    reloadRuntimeData(clearAfterConfirmation: !previewSelections.isEmpty)
    refreshPublicIPInfo()
  }

  func stop() {
    startTask?.cancel()
    startTask = nil
    startInFlight = false
    cancelPendingPreviewRuntimeStart()
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await stopRuntimeCoordinated()
      handleStopResult(result)
    }
  }

  func restart() {
    startTask?.cancel()
    startTask = nil
    startInFlight = false
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await stopRuntimeCoordinated()
      handleStopResult(result)
      guard result.succeeded else { return }
      start()
    }
  }

  func setProxyRoutingMode(_ mode: ProxyRoutingMode) {
    guard proxyRoutingMode != mode else { return }
    appNotice = nil
    let shouldRestart = isRunning || startInFlight
    if mode != .systemProxy, systemProxyEnabled {
      stopSystemProxyGuard()
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          _ = try await restoreSystemProxyState(disableWhenNoSnapshot: true)
          systemProxyEnabled = false
        } catch {
          lastError = UserFacingError.message(for: error)
        }
      }
    }
    proxyRoutingMode = mode
    if mode == .tun {
      if tunHelperPreparationState.allowsStartAttempt, !shouldRestart {
        lastError = nil
      } else {
        prepareTunHelperIfNeeded(force: true, restartWhenReady: shouldRestart)
      }
    } else {
      cancelTunHelperPreparation(resetState: true)
    }
    if mode != .tun, shouldRestart {
      restart()
    }
  }

  func setDeveloperMode(_ enabled: Bool) {
    settings.developerMode = enabled
    if enabled {
      appNotice = nil
    }
  }

  func setMode(_ mode: RunMode) {
    guard overrides.mode != mode else { return }
    overrides.mode = mode
    modeUpdateTask?.cancel()
    modeUpdateTask = nil
    modeUpdateToken = nil
    guard isRunning else { return }
    guard let apiClient else {
      lastError = proxyRuntimeActionMessage
      return
    }
    let token = UUID()
    modeUpdateToken = token
    modeUpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if modeUpdateToken == token {
          modeUpdateTask = nil
          modeUpdateToken = nil
        }
      }
      do {
        try await apiClient.updateMode(mode)
      } catch is CancellationError {
        return
      } catch {
        guard modeUpdateToken == token else { return }
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func setIPv6Enabled(_ enabled: Bool) {
    guard ipv6Enabled != enabled else { return }
    settings.ipv6Enabled = enabled

    guard isRunning else { return }
    ipv6UpdateTask?.cancel()
    ipv6UpdateTask = nil
    ipv6UpdateToken = nil
    if proxyRoutingMode == .tun {
      scheduleRunningTunSettingsApply(tunSettings)
      return
    }
    guard let apiClient else {
      lastError = proxyRuntimeActionMessage
      return
    }
    let token = UUID()
    ipv6UpdateToken = token
    ipv6UpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if ipv6UpdateToken == token {
          ipv6UpdateTask = nil
          ipv6UpdateToken = nil
        }
      }
      do {
        try await applyRunningIPv6Setting(enabled, apiClient: apiClient)
      } catch is CancellationError {
        return
      } catch {
        guard ipv6UpdateToken == token else { return }
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  private func applyRunningIPv6Setting(_ enabled: Bool, apiClient: any MihomoAPIControlling) async throws {
    guard runningIPv6UpdateRequiresConfigReload else {
      try await apiClient.updateIPv6(enabled)
      return
    }
    let runtimeConfig = try await materializeNonTunRuntimeConfig()
    try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
    appendAppLog(level: "info", message: "IPv6 setting updated: Mihomo reloaded \(runtimeConfig.path).")
  }

  private var runningIPv6UpdateRequiresConfigReload: Bool {
    if overrides.dnsEnabled == true {
      return true
    }
    let isNetworkExtensionRuntime = proxyRoutingMode == .neProxy
      || runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
    guard isNetworkExtensionRuntime else { return false }
    return networkExtensionRoutingSettings.dnsCaptureEnabled || networkExtensionRoutingSettings.dnsFakeIPEnabled
  }

  private func materializeNonTunRuntimeConfig() async throws -> URL {
    let profile = try requireActiveProfile()
    var runtimeOverrides = overrides
    runtimeOverrides.tunEnabled = false
    let isNetworkExtensionRuntime = proxyRoutingMode == .neProxy
      || runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
    let options = RuntimeConfigOptions(
      networkExtensionRoutingSettings: isNetworkExtensionRuntime ? networkExtensionRoutingSettings : nil
    )
    return try await generateRuntimeConfig(
      for: profile,
      overrides: runtimeOverrides,
      selections: previewSelections,
      options: options
    )
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
    prepareTunHelperIfNeeded(force: true)
  }

  func warmTunHelperRegistrationOnLaunch() {
    guard !didWarmTunHelperRegistrationOnLaunch else { return }
    didWarmTunHelperRegistrationOnLaunch = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let state = await helperClient.warmRegistration()
      await updateTunHelperStatusDetail()
      switch state {
      case .registered, .ready:
        if tunHelperPreparationState == .idle || tunHelperPreparationState == .checking {
          applyTunHelperPreparationState(state)
        }
      case .requiresApproval:
        if proxyRoutingMode == .tun {
          applyTunHelperPreparationState(state)
        }
      case .idle, .checking, .notBootstrapped, .failed:
        if proxyRoutingMode == .tun {
          applyTunHelperPreparationState(state)
        }
      }
    }
  }

  func refreshHelperRegistrationStatus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      let state = await helperClient.currentPreparationState()
      applyTunHelperPreparationState(state)
      await updateTunHelperStatusDetail()
    }
  }

  func repairHelperRegistration() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        tunHelperPreparationTask?.cancel()
        tunHelperPreparationTask = nil
        tunHelperPreparationState = .checking
        lastError = nil
        try await helperClient.repairRegistration()
        await updateTunHelperStatusDetail()
        guard proxyRoutingMode == .tun else {
          cancelTunHelperPreparation(resetState: true)
          return
        }
        let state = await helperClient.currentPreparationState()
        applyTunHelperPreparationState(state)
      } catch {
        let message = UserFacingError.message(for: error)
        helperClient.statusMessage = message
        tunHelperPreparationState = .failed(message)
        lastError = message
      }
    }
  }

  func unregisterHelper() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        tunHelperPreparationTask?.cancel()
        tunHelperPreparationTask = nil
        tunHelperPreparationState = .checking
        lastError = nil
        try await helperClient.unregister()
        tunHelperPID = nil
        if !tunEnabled && !tunnelCoreRunning {
          tunHelperPreparationState = .idle
        }
        await updateTunHelperStatusDetail()
      } catch {
        let message = UserFacingError.message(for: error)
        helperClient.statusMessage = message
        tunHelperPreparationState = .failed(message)
        lastError = message
        await updateTunHelperStatusDetail()
      }
    }
  }

  func resetHelperState() {
    helperClient.resetRegistrationState()
    if !tunEnabled && !tunnelCoreRunning {
      tunHelperPreparationState = .idle
    }
    tunHelperStatusDetail = .unknown
    refreshHelperRegistrationStatus()
  }

  func openHelperApprovalSettings() {
    helperClient.openApprovalSettings()
  }

  @discardableResult
  private func updateTunHelperStatusDetail() async -> TunnelHelperStatusDetail {
    let detail = await helperClient.statusDetail()
    tunHelperStatusDetail = detail
    return detail
  }

  func installNetworkExtension() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await networkExtensionController.activateSystemExtension()
      publishNetworkExtensionControllerError()
    }
  }

  func refreshNetworkExtensionStatus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      await networkExtensionController.refreshStatus()
      publishNetworkExtensionControllerError()
    }
  }

  func openNetworkExtensionSettings() {
    networkExtensionController.openSystemExtensionSettings()
  }

  private func publishNetworkExtensionControllerError() {
    if let error = networkExtensionController.recentError {
      setNetworkExtensionLastError(error)
    } else if lastErrorOrigin == .networkExtension {
      setNetworkExtensionLastError(nil)
    }
  }

  private func setNetworkExtensionLastError(_ message: String?) {
    isPublishingNetworkExtensionLastError = true
    lastError = message
    lastErrorOrigin = message == nil ? nil : .networkExtension
    isPublishingNetworkExtensionLastError = false
  }

  private func prepareTunHelperIfNeeded(
    openSystemSettings: Bool = true,
    force: Bool,
    restartWhenReady: Bool = false
  ) {
    guard proxyRoutingMode == .tun else {
      cancelTunHelperPreparation(resetState: true)
      return
    }
    if !force, tunHelperPreparationState == .checking {
      return
    }
    if !force, tunHelperPreparationState.allowsStartAttempt {
      if restartWhenReady {
        restart()
      }
      return
    }
    tunHelperPreparationTask?.cancel()
    tunHelperPreparationState = .checking
    lastError = nil
    tunHelperPreparationTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let firstState = await helperClient.prepareForTunnelStart(
        openSystemSettingsWhenApprovalRequired: openSystemSettings
      )
      let finalState = await applyAndPollTunHelperPreparation(firstState)
      await updateTunHelperStatusDetail()
      tunHelperPreparationTask = nil
      if finalState.isReady, restartWhenReady, proxyRoutingMode == .tun {
        restart()
      }
    }
  }

  private func prepareTunHelperForStart() async -> TunHelperPreparationState {
    tunHelperPreparationTask?.cancel()
    tunHelperPreparationTask = nil
    tunHelperPreparationState = .checking
    lastError = nil
    let state = await helperClient.prepareForTunnelStart(openSystemSettingsWhenApprovalRequired: true)
    applyTunHelperPreparationState(state)
    await updateTunHelperStatusDetail()
    if state.shouldPollForApproval {
      prepareTunHelperIfNeeded(openSystemSettings: false, force: true)
    }
    return state
  }

  private func applyAndPollTunHelperPreparation(_ initialState: TunHelperPreparationState) async -> TunHelperPreparationState {
    var state = initialState
    applyTunHelperPreparationState(state)
    guard state.shouldPollForApproval else { return state }

    for _ in 0..<Self.tunHelperApprovalPollingAttempts {
      do {
        try await Task.sleep(nanoseconds: Self.tunHelperApprovalPollingIntervalNanoseconds)
      } catch {
        return state
      }
      guard proxyRoutingMode == .tun, !Task.isCancelled else { return state }
      state = await helperClient.prepareForTunnelStart(openSystemSettingsWhenApprovalRequired: false)
      applyTunHelperPreparationState(state)
      if !state.shouldPollForApproval {
        return state
      }
    }
    return state
  }

  private func applyTunHelperPreparationState(_ state: TunHelperPreparationState) {
    tunHelperPreparationState = state
    if state.isFailure {
      lastError = state.message
    } else {
      lastError = nil
    }
  }

  private func cancelTunHelperPreparation(resetState: Bool) {
    tunHelperPreparationTask?.cancel()
    tunHelperPreparationTask = nil
    if resetState {
      switch tunHelperPreparationState {
      case .ready, .registered:
        tunHelperPreparationState = .registered(TunnelHelperClient.registeredMessage)
      case .idle, .checking, .requiresApproval, .notBootstrapped, .failed:
        tunHelperPreparationState = .idle
      }
    }
  }

  func refreshLaunchSettings() {
    settings.refreshLaunchSettings()
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
      try await settings.updateLaunchAtLogin(enabled)
      return true
    } catch {
      refreshLaunchSettings()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func setSilentStart(_ enabled: Bool) {
    settings.setSilentStart(enabled)
  }

  func openLoginItemsSettings() {
    settings.openLoginItemsSettings()
  }

  func reloadRuntimeData(clearAfterConfirmation: Bool = false) {
    guard isCoreRunning, let apiClient else {
      runtimeReloadTask?.cancel()
      runtimeReloadTask = nil
      runtimeReloadToken = nil
      runtimeReloadPending = false
      runtimeDataLoading = false
      proxyGroups = []
      proxyProviders = []
      ruleProviders = []
      rules = []
      connections = []
      refreshProfilePreview()
      return
    }
    if runtimeReloadTask != nil {
      guard clearAfterConfirmation else {
        runtimeReloadPending = true
        return
      }
      runtimeReloadPending = false
      runtimeReloadTask?.cancel()
      runtimeReloadTask = nil
      runtimeReloadToken = nil
    }
    startRuntimeReload(apiClient: apiClient, clearAfterConfirmation: clearAfterConfirmation)
  }

  private func startRuntimeReload(apiClient: any MihomoAPIControlling, clearAfterConfirmation: Bool) {
    let token = UUID()
    runtimeReloadToken = token
    runtimeDataLoading = true
    runtimeReloadTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.runtimeReloadToken == token {
          let shouldRunTrailing = self.runtimeReloadPending && self.isCoreRunning && self.apiClient != nil
          self.runtimeReloadTask = nil
          self.runtimeReloadToken = nil
          self.runtimeReloadPending = false
          if shouldRunTrailing {
            self.reloadRuntimeData()
          } else {
            self.runtimeDataLoading = false
          }
        }
      }
      do {
        let knownDelays = proxyDelayMap(from: proxyGroups)
        let cachedRuntimeGroups = proxyGroups
        let runtimeGroups = try await apiClient.proxyGroups()
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        let refreshedProviders: [ProxyProvider]
        do {
          refreshedProviders = try await apiClient.structuredProxyProviders()
        } catch {
          refreshedProviders = []
        }
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        proxyProviders = refreshedProviders
        let refreshedRuleProviders: [RuleProvider]
        do {
          refreshedRuleProviders = try await apiClient.ruleProviders()
        } catch {
          refreshedRuleProviders = []
        }
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        ruleProviders = refreshedRuleProviders
        proxyGroups = enrichProxyGroupsWithKnownEndpoints(
          runtimeGroups,
          providers: refreshedProviders,
          cachedRuntimeGroups: cachedRuntimeGroups
        ).preservingKnownDelays(knownDelays)
        rules = try await apiClient.rules()
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        connections = try await apiClient.connections()
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        if clearAfterConfirmation, let activeID = profileStore.activeProfileID {
          let confirmed = previewSelections.allSatisfy { groupName, nodeName in
            proxyGroups.first(where: { $0.name == groupName })?.selected == nodeName
          }
          if confirmed {
            previewSelections = [:]
            saveCurrentPreviewSelections(forProfileID: activeID)
          }
        }
      } catch is CancellationError {
        return
      } catch {
        guard runtimeReloadToken == token else { return }
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func publicIPInfoNeedsRefresh(now: Date = Date()) -> Bool {
    publicIP.needsRefresh(isCoreRunning: isCoreRunning, now: now)
  }

  func refreshPublicIPInfo(force: Bool = false, now: Date = Date()) {
    publicIP.refresh(isCoreRunning: isCoreRunning, force: force, now: now)
  }

  func refreshTunDiagnostics(includeExternal: Bool = true) {
    tunDiagnosticsTask?.cancel()
    guard runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning else {
      tunDiagnostics = .empty
      tunDiagnosticsTask = nil
      return
    }

    let api = overrides.endpoint
    let settings = tunSettings
    let dnsState = tunSystemDNSState
    let helperClient = helperClient
    let inspector = tunRuntimeInspector
    tunDiagnosticsTask = Task { @MainActor [weak self] in
      let helperStatus = await self?.liveTunHelperStatus(using: helperClient)
        ?? (pid: Optional<Int>.none, message: Optional<String>.none)
      guard !Task.isCancelled else { return }
      self?.tunHelperPID = helperStatus.pid
      let configuration = TunRuntimeInspectionConfiguration(
        api: api,
        tunSettings: settings,
        helperPID: helperStatus.pid,
        helperStatusMessage: helperStatus.message,
        systemDNSState: dnsState,
        includeExternal: includeExternal
      )
      let snapshot = await inspector.inspect(configuration)
      guard !Task.isCancelled, let self else { return }
      tunDiagnostics = snapshot
      tunDiagnosticsTask = nil
    }
  }

  private func liveTunHelperStatus(using helperClient: TunnelHelperClient) async -> (pid: Int?, message: String?) {
    do {
      let response = try await withTimeout(seconds: 2.5) { @Sendable [helperClient] in
        try await helperClient.status()
      }
      let pid = response.running && response.pid > 0 ? response.pid : nil
      if let pid {
        return (pid, nil)
      }
      if response.ok {
        return (nil, "Helper responded but did not report a running Mihomo process.")
      }
      let message = response.userFacingMessage.trimmingCharacters(in: .whitespacesAndNewlines)
      return (
        nil,
        message.isEmpty
          ? "Helper responded but did not report a running Mihomo process."
          : message
      )
    } catch {
      return (
        nil,
        "Helper status probe failed: \(UserFacingError.message(for: error))"
      )
    }
  }

  private func stopTunDiagnostics(clear: Bool) {
    tunDiagnosticsTask?.cancel()
    tunDiagnosticsTask = nil
    if clear {
      tunDiagnostics = .empty
    }
  }

  func refreshHelperStatus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      tunHelperPreparationTask?.cancel()
      tunHelperPreparationTask = nil
      tunHelperPreparationState = .checking
      lastError = nil
      do {
        let state = try await withTimeout(seconds: 2.5) { @Sendable [helperClient] in
          await helperClient.currentPreparationState()
        }
        self.applyTunHelperPreparationState(state)
        await self.updateTunHelperStatusDetail()
      } catch is OperationTimedOutError {
        let message = TunnelHelperClient.notBootstrappedMessage
        self.helperClient.statusMessage = message
        self.tunHelperPreparationState = .notBootstrapped(message)
        self.lastError = message
        await self.updateTunHelperStatusDetail()
        if self.developerMode {
          self.helperLogs = await self.helperLaunchdDiagnostics()
        }
      } catch {
        let message = UserFacingError.message(for: error)
        self.helperClient.statusMessage = message
        self.tunHelperPreparationState = .notBootstrapped(message)
        self.lastError = message
        await self.updateTunHelperStatusDetail()
        if self.developerMode {
          self.helperLogs = await self.helperLaunchdDiagnostics()
        }
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
        await self.updateTunHelperStatusDetail()
      } catch is OperationTimedOutError {
        let message = TunnelHelperClient.notBootstrappedMessage
        self.helperClient.statusMessage = message
        self.helperLogs = await self.helperLaunchdDiagnostics()
        self.lastError = message
        await self.updateTunHelperStatusDetail()
      } catch {
        let message = UserFacingError.message(for: error)
        self.helperClient.statusMessage = message
        if self.developerMode {
          self.helperLogs = await self.helperLaunchdDiagnostics()
        }
        self.lastError = message
        await self.updateTunHelperStatusDetail()
      }
    }
  }

  private func helperLaunchdDiagnostics() async -> [String] {
    do {
      let output = try await ProcessCommandRunner(timeout: 2).run(
        "/bin/launchctl",
        ["print", "system/\(clashMaxHelperMachServiceName)"]
      )
      let diagnosticPrefixes = [
        "state =",
        "job state =",
        "last exit code =",
        "program identifier =",
        "parent bundle version =",
        "path ="
      ]
      let lines = output
        .split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { line in diagnosticPrefixes.contains { line.hasPrefix($0) } }
      return lines.isEmpty
        ? ["launchctl did not return helper diagnostics."]
        : lines
    } catch {
      return ["launchctl helper diagnostics unavailable: \(UserFacingError.message(for: error))"]
    }
  }

  func selectProxy(group: ProxyGroup, node: ProxyNode) {
    guard node.isSelectable else {
      lastError = "\(node.name) cannot be selected from the runtime."
      return
    }
    guard group.allowsManualProxySelection else {
      lastError = "\(group.name) is managed automatically by Mihomo."
      return
    }
    if isCoreRunning, let apiClient {
      let groupID = group.id
      if previewRuntimeActive {
        persistSelectedProxy(groupName: group.name, nodeName: node.name)
        applySelectedProxy(groupName: group.name, nodeName: node.name)
        lastError = nil
      }
      proxySelectionTasks[groupID]?.cancel()
      let token = UUID()
      proxySelectionTokens[groupID] = token
      proxySelectionTasks[groupID] = Task { @MainActor [weak self] in
        guard let self else { return }
        defer {
          if proxySelectionTokens[groupID] == token {
            proxySelectionTasks[groupID] = nil
            proxySelectionTokens[groupID] = nil
          }
        }
        do {
          try await apiClient.selectProxy(group: group.name, proxy: node.name)
          guard proxySelectionTokens[groupID] == token, !Task.isCancelled else { return }
          if !previewRuntimeActive {
            persistSelectedProxy(groupName: group.name, nodeName: node.name)
          }
          applySelectedProxy(groupName: group.name, nodeName: node.name)
          lastError = nil
          reloadRuntimeData()
        } catch is CancellationError {
          return
        } catch {
          guard proxySelectionTokens[groupID] == token else { return }
          lastError = UserFacingError.message(for: error)
        }
      }
    } else if canSelectProxyOffline {
      persistSelectedProxy(groupName: group.name, nodeName: node.name)
      applySelectedProxy(groupName: group.name, nodeName: node.name)
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
    let nodeID = node.id
    delayTestTasks[nodeID]?.cancel()
    let token = UUID()
    delayTestTokens[nodeID] = token
    delayTestTasks[nodeID] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if delayTestTokens[nodeID] == token {
          delayTestTasks[nodeID] = nil
          delayTestTokens[nodeID] = nil
        }
      }
      do {
        let delay = try await measureDelay(for: node, apiClient: apiClient, settings: settings)
        guard delayTestTokens[nodeID] == token, !Task.isCancelled else { return }
        applyDelay(delay, to: node.name)
        reloadRuntimeData()
      } catch is CancellationError {
        return
      } catch {
        guard delayTestTokens[nodeID] == token else { return }
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func healthCheckProvider(_ provider: ProxyProvider) {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard !providerHealthChecksInFlight.contains(provider.id),
          providerHealthCheckTasks[provider.id] == nil,
          providerHealthCheckTokens[provider.id] == nil
    else { return }
    setProvider(provider.id, healthCheckInFlight: true)
    let token = UUID()
    providerHealthCheckTokens[provider.id] = token
    providerHealthCheckTasks[provider.id] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.providerHealthCheckTokens[provider.id] == token {
          self.providerHealthCheckTasks[provider.id] = nil
          self.providerHealthCheckTokens[provider.id] = nil
          self.setProvider(provider.id, healthCheckInFlight: false)
        }
      }
      do {
        try await apiClient.healthCheckProvider(named: provider.name)
        guard self.providerHealthCheckTokens[provider.id] == token, !Task.isCancelled else { return }
        self.reloadRuntimeData()
      } catch is CancellationError {
        return
      } catch {
        guard self.providerHealthCheckTokens[provider.id] == token, !Task.isCancelled else { return }
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  func updateProxyProvider(_ provider: ProxyProvider) {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard !proxyProviderUpdatesInFlight.contains(provider.id),
          proxyProviderUpdateTasks[provider.id] == nil,
          proxyProviderUpdateTokens[provider.id] == nil
    else { return }
    setProxyProvider(provider.id, updateInFlight: true)
    let token = UUID()
    proxyProviderUpdateTokens[provider.id] = token
    proxyProviderUpdateTasks[provider.id] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.proxyProviderUpdateTokens[provider.id] == token {
          self.proxyProviderUpdateTasks[provider.id] = nil
          self.proxyProviderUpdateTokens[provider.id] = nil
          self.setProxyProvider(provider.id, updateInFlight: false)
        }
      }
      do {
        try await apiClient.updateProxyProvider(named: provider.name)
        guard self.proxyProviderUpdateTokens[provider.id] == token, !Task.isCancelled else { return }
        self.reloadRuntimeData()
      } catch is CancellationError {
        return
      } catch {
        guard self.proxyProviderUpdateTokens[provider.id] == token, !Task.isCancelled else { return }
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  func updateAllProxyProviders() {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard proxyProviderBatchUpdateTask == nil else { return }
    let providers = proxyProviders.filter { provider in
      !proxyProviderUpdatesInFlight.contains(provider.id)
        && proxyProviderUpdateTasks[provider.id] == nil
        && proxyProviderUpdateTokens[provider.id] == nil
    }
    guard !providers.isEmpty else { return }
    let token = UUID()
    proxyProviderBatchUpdateToken = token
    providers.forEach { setProxyProvider($0.id, updateInFlight: true) }
    proxyProviderBatchUpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var failures: [(String, String)] = []
      defer {
        if self.proxyProviderBatchUpdateToken == token {
          self.proxyProviderBatchUpdateTask = nil
          self.proxyProviderBatchUpdateToken = nil
          providers.forEach { self.setProxyProvider($0.id, updateInFlight: false) }
        }
      }
      for provider in providers {
        do {
          try await apiClient.updateProxyProvider(named: provider.name)
        } catch is CancellationError {
          return
        } catch {
          failures.append((provider.name, UserFacingError.message(for: error)))
        }
      }
      guard self.proxyProviderBatchUpdateToken == token, !Task.isCancelled else { return }
      if !failures.isEmpty {
        self.lastError = Self.providerUpdateFailureSummary(kind: "proxy provider", failures: failures)
      }
      self.reloadRuntimeData()
    }
  }

  func updateRuleProvider(_ provider: RuleProvider) {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard !ruleProviderUpdatesInFlight.contains(provider.id),
          ruleProviderUpdateTasks[provider.id] == nil,
          ruleProviderUpdateTokens[provider.id] == nil
    else { return }
    setRuleProvider(provider.id, updateInFlight: true)
    let token = UUID()
    ruleProviderUpdateTokens[provider.id] = token
    ruleProviderUpdateTasks[provider.id] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.ruleProviderUpdateTokens[provider.id] == token {
          self.ruleProviderUpdateTasks[provider.id] = nil
          self.ruleProviderUpdateTokens[provider.id] = nil
          self.setRuleProvider(provider.id, updateInFlight: false)
        }
      }
      do {
        try await apiClient.updateRuleProvider(named: provider.name)
        guard self.ruleProviderUpdateTokens[provider.id] == token, !Task.isCancelled else { return }
        self.reloadRuntimeData()
      } catch is CancellationError {
        return
      } catch {
        guard self.ruleProviderUpdateTokens[provider.id] == token, !Task.isCancelled else { return }
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  func updateAllRuleProviders() {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard ruleProviderBatchUpdateTask == nil else { return }
    let providers = ruleProviders.filter { provider in
      !ruleProviderUpdatesInFlight.contains(provider.id)
        && ruleProviderUpdateTasks[provider.id] == nil
        && ruleProviderUpdateTokens[provider.id] == nil
    }
    guard !providers.isEmpty else { return }
    let token = UUID()
    ruleProviderBatchUpdateToken = token
    providers.forEach { setRuleProvider($0.id, updateInFlight: true) }
    ruleProviderBatchUpdateTask = Task { @MainActor [weak self] in
      guard let self else { return }
      var failures: [(String, String)] = []
      defer {
        if self.ruleProviderBatchUpdateToken == token {
          self.ruleProviderBatchUpdateTask = nil
          self.ruleProviderBatchUpdateToken = nil
          providers.forEach { self.setRuleProvider($0.id, updateInFlight: false) }
        }
      }
      for provider in providers {
        do {
          try await apiClient.updateRuleProvider(named: provider.name)
        } catch is CancellationError {
          return
        } catch {
          failures.append((provider.name, UserFacingError.message(for: error)))
        }
      }
      guard self.ruleProviderBatchUpdateToken == token, !Task.isCancelled else { return }
      if !failures.isEmpty {
        self.lastError = Self.providerUpdateFailureSummary(kind: "rule provider", failures: failures)
      }
      self.reloadRuntimeData()
    }
  }

  private static func providerUpdateFailureSummary(kind: String, failures: [(String, String)]) -> String {
    let prefix = failures.count == 1
      ? "Failed to update 1 \(kind)"
      : "Failed to update \(failures.count) \(kind)s"
    let details = failures
      .prefix(3)
      .map { "\($0.0): \($0.1)" }
      .joined(separator: "; ")
    let suffix = failures.count > 3 ? "; ..." : ""
    return "\(prefix): \(details)\(suffix)"
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
    guard !closingConnectionIDs.contains(connection.id),
          connectionCloseTasks[connection.id] == nil,
          connectionCloseTokens[connection.id] == nil
    else { return }
    setConnection(connection.id, closing: true)
    let token = UUID()
    connectionCloseTokens[connection.id] = token
    connectionCloseTasks[connection.id] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.connectionCloseTokens[connection.id] == token {
          self.connectionCloseTasks[connection.id] = nil
          self.connectionCloseTokens[connection.id] = nil
          self.setConnection(connection.id, closing: false)
        }
      }
      do {
        try await apiClient.closeConnection(id: connection.id)
        guard self.connectionCloseTokens[connection.id] == token, !Task.isCancelled else { return }
        self.removeConnection(id: connection.id)
      } catch is CancellationError {
        return
      } catch {
        guard self.connectionCloseTokens[connection.id] == token, !Task.isCancelled else { return }
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  func closeAllRuntimeConnections() {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard !closingAllConnections else { return }
    connectionCloseTasks.values.forEach { $0.cancel() }
    connectionCloseTasks.removeAll()
    connectionCloseTokens.removeAll()
    for id in closingConnectionIDs {
      setConnection(id, closing: false)
    }
    closingAllConnections = true
    let token = UUID()
    closeAllConnectionsToken = token
    closeAllConnectionsTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.closeAllConnectionsToken == token {
          self.closeAllConnectionsTask = nil
          self.closeAllConnectionsToken = nil
          self.closingAllConnections = false
        }
      }
      do {
        try await apiClient.closeAllConnections()
        guard self.closeAllConnectionsToken == token, !Task.isCancelled else { return }
        self.runtimeData.replaceConnections([])
      } catch is CancellationError {
        return
      } catch {
        guard self.closeAllConnectionsToken == token else { return }
        self.lastError = UserFacingError.message(for: error)
      }
    }
  }

  func setSystemProxyEnabled(_ enabled: Bool) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if enabled {
          proxyRoutingMode = .systemProxy
          try await applySystemProxySettings()
          systemProxyEnabled = true
          try await activateSystemProxyGuardIfNeeded()
        } else {
          _ = try await restoreSystemProxyState(disableWhenNoSnapshot: true)
          systemProxyEnabled = false
        }
      } catch {
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

  @discardableResult
  func updateTunSettings(_ settings: TunSettings) -> Bool {
    if let validationError = settings.validationError {
      lastError = validationError
      return false
    }
    tunSettings = settings
    if proxyRoutingMode == .tun, isRunning {
      scheduleRunningTunSettingsApply(settings)
    }
    return true
  }

  private func scheduleRunningTunSettingsApply(_ settings: TunSettings) {
    tunSettingsApplyTask?.cancel()
    let token = UUID()
    tunSettingsApplyToken = token
    tunSettingsApplyTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.tunSettingsApplyToken == token {
          self.tunSettingsApplyTask = nil
          self.tunSettingsApplyToken = nil
        }
      }
      do {
        try await applyRunningTunSettings(settings, reason: "TUN settings updated")
        guard self.tunSettingsApplyToken == token, !Task.isCancelled else { return }
        lastError = nil
      } catch is CancellationError {
        return
      } catch {
        guard self.tunSettingsApplyToken == token else { return }
        lastError = "Could not apply TUN settings without restart: \(UserFacingError.message(for: error))"
      }
    }
  }

  private func applyRunningTunSettings(_ settings: TunSettings, reason: String) async throws {
    guard runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning else { return }
    let runtimeConfig = try await materializeTunRuntimeConfig(settings)
    var didRestartHelper = false
    if let apiClient {
      do {
        try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
        appendAppLog(level: "info", message: "\(reason): Mihomo reloaded \(runtimeConfig.path).")
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        appendAppLog(
          level: "warn",
          message: "\(reason): Mihomo reload failed, restarting helper instead: \(UserFacingError.message(for: error))"
        )
        try await restartRunningTunHelper(runtimeConfig: runtimeConfig, settings: settings, reason: reason)
        didRestartHelper = true
      }
    } else {
      appendAppLog(level: "warn", message: "\(reason): controller unavailable, restarting helper instead.")
      try await restartRunningTunHelper(runtimeConfig: runtimeConfig, settings: settings, reason: reason)
      didRestartHelper = true
    }
    didRestartHelper = try await verifyRunningTunFacts(
      runtimeConfig: runtimeConfig,
      settings: settings,
      reason: reason,
      didRestartHelper: didRestartHelper
    )
    if !didRestartHelper {
      try await reconcileTunSystemDNS(for: settings)
    }
    refreshTunDiagnostics(includeExternal: false)
    reloadRuntimeData()
  }

  private func materializeTunRuntimeConfig(_ settings: TunSettings) async throws -> URL {
    let profile = try requireActiveProfile()
    var runtimeOverrides = overrides
    runtimeOverrides.tunEnabled = true
    runtimeOverrides.tunSettings = settings
    return try await generateRuntimeConfig(
      for: profile,
      overrides: runtimeOverrides,
      selections: previewSelections
    )
  }

  private func restartRunningTunHelper(
    runtimeConfig: URL,
    settings: TunSettings,
    reason: String
  ) async throws {
    let response = try await helperClient.restartTunnel(
      coreURL: try bundledCoreURL(),
      configURL: runtimeConfig,
      workDirectory: paths.runtime,
      secret: overrides.secret
    )
    if !response.ok {
      throw AppError.helperResponse(response.userFacingMessage)
    }
    guard response.running else {
      throw AppError.helperResponse("Helper reported restart success but TUN is not running.")
    }
    tunHelperPID = response.pid > 0 ? response.pid : nil
    let version = try await tunnelReadinessProbe.waitUntilReady(api: overrides.endpoint)
    appendAppLog(level: "info", message: "\(reason): TUN helper restarted, controller ready with version \(version).")
    try await reconcileTunSystemDNS(for: settings)
    tunnelCoreRunning = true
    tunEnabled = true
    runtimeOwner = .tunnel
  }

  private func verifyRunningTunFacts(
    runtimeConfig: URL,
    settings: TunSettings,
    reason: String,
    didRestartHelper: Bool
  ) async throws -> Bool {
    var didRestartHelper = didRestartHelper
    let postReloadSnapshot = await inspectTunRuntimeNow(includeExternal: false)
    guard postReloadSnapshot.hasRepairableRoutingIssue else {
      return didRestartHelper
    }

    if !didRestartHelper {
      appendAppLog(
        level: "warn",
        message: "\(reason): runtime diagnostics still report \(postReloadSnapshot.repairableRoutingIssueMessage), restarting helper instead."
      )
      try await restartRunningTunHelper(runtimeConfig: runtimeConfig, settings: settings, reason: reason)
      didRestartHelper = true
      let postRestartSnapshot = await inspectTunRuntimeNow(includeExternal: false)
      if postRestartSnapshot.hasRepairableRoutingIssue {
        throw AppError.helperResponse(
          "\(reason): TUN runtime diagnostics still report \(postRestartSnapshot.repairableRoutingIssueMessage) after helper restart."
        )
      }
      return didRestartHelper
    }

    throw AppError.helperResponse(
      "\(reason): TUN runtime diagnostics still report \(postReloadSnapshot.repairableRoutingIssueMessage) after helper restart."
    )
  }

  func updateNetworkExtensionRoutingSettings(_ settings: NetworkExtensionRoutingSettings) -> Bool {
    if let validationError = settings.validationError {
      lastError = validationError
      return false
    }
    networkExtensionRoutingSettings = settings
    if runtimeOwner == .networkExtension || networkExtensionController.vpnStatus.isActive {
      restart()
    }
    return true
  }

  private func applyNetworkExtensionSystemDNS(
    _ settings: NetworkExtensionRoutingSettings,
    restoreOnFailure: Bool = true
  ) async throws {
    setNetworkExtensionSystemDNSState(.applying)
    do {
      let result = try await systemProxyController.applyDNS(
        servers: settings.effectiveSystemDNSServers,
        restoreOnFailure: restoreOnFailure
      )
      setNetworkExtensionSystemDNSState(.applied(serviceCount: result.appliedServiceCount))
      appendAppLog(
        level: "info",
        message: "NE system DNS override applied to \(result.appliedServiceCount) service(s): \(settings.effectiveSystemDNSServers.joined(separator: ", "))"
      )
    } catch {
      let message = UserFacingError.message(for: error)
      setNetworkExtensionSystemDNSState(.applyFailed(message))
      throw error
    }
  }

  private func applyTunSystemDNS(_ settings: TunSettings, restoreOnFailure: Bool = true) async throws {
    setTunSystemDNSState(.applying)
    do {
      let result = try await systemProxyController.applyDNS(
        servers: settings.effectiveSystemDNSServers,
        restoreOnFailure: restoreOnFailure
      )
      setTunSystemDNSState(.applied(serviceCount: result.appliedServiceCount))
      appendAppLog(
        level: "info",
        message: "TUN system DNS override applied to \(result.appliedServiceCount) service(s): \(settings.effectiveSystemDNSServers.joined(separator: ", "))"
      )
    } catch {
      let message = UserFacingError.message(for: error)
      setTunSystemDNSState(.applyFailed(message))
      throw error
    }
  }

  @discardableResult
  private func restoreNetworkExtensionSystemDNS() async throws -> SystemDNSRestoreResult {
    setNetworkExtensionSystemDNSState(.restoring)
    do {
      let result = try await systemProxyController.restoreDNS()
      setNetworkExtensionSystemDNSState(result.restoredSnapshotCount > 0 ? .restored : .inactive)
      if result.restoredSnapshotCount > 0 {
        appendAppLog(level: "info", message: "NE system DNS restored for \(result.restoredSnapshotCount) service(s).")
      }
      return result
    } catch {
      let message = UserFacingError.message(for: error)
      setNetworkExtensionSystemDNSState(.restoreFailed(message))
      throw error
    }
  }

  @discardableResult
  private func restoreTunSystemDNS() async throws -> SystemDNSRestoreResult {
    setTunSystemDNSState(.restoring)
    do {
      let result = try await systemProxyController.restoreDNS()
      setTunSystemDNSState(result.restoredSnapshotCount > 0 ? .restored : .inactive)
      if result.restoredSnapshotCount > 0 {
        appendAppLog(level: "info", message: "TUN system DNS restored for \(result.restoredSnapshotCount) service(s).")
      }
      return result
    } catch {
      let message = UserFacingError.message(for: error)
      setTunSystemDNSState(.restoreFailed(message))
      throw error
    }
  }

  private func reconcileTunSystemDNS(for settings: TunSettings) async throws {
    if settings.systemDNSOverrideEnabled {
      try await applyTunSystemDNS(settings, restoreOnFailure: false)
    } else if systemProxyController.hasManagedSystemDNSState {
      _ = try await restoreTunSystemDNS()
    } else {
      setTunSystemDNSState(.inactive)
    }
  }

  private func setNetworkExtensionSystemDNSState(_ state: SystemDNSOverrideState) {
    networkExtensionSystemDNSState = state
    networkExtensionController.updateSystemDNSOverrideDiagnostics(
      applied: state.diagnosticsApplied,
      status: state.diagnosticsStatus
    )
  }

  private func setTunSystemDNSState(_ state: SystemDNSOverrideState) {
    tunSystemDNSState = state
  }

  func repairNetworkExtensionDNS() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if runtimeOwner == .networkExtension || networkExtensionController.vpnStatus.isActive {
          if networkExtensionRoutingSettings.systemDNSOverrideEnabled {
            try await applyNetworkExtensionSystemDNS(networkExtensionRoutingSettings, restoreOnFailure: false)
          } else if systemProxyController.hasManagedSystemDNSState {
            _ = try await restoreNetworkExtensionSystemDNS()
          } else {
            setNetworkExtensionSystemDNSState(.inactive)
          }
        } else if systemProxyController.hasManagedSystemDNSState {
          _ = try await restoreNetworkExtensionSystemDNS()
        } else {
          setNetworkExtensionSystemDNSState(.inactive)
        }
        lastError = nil
      } catch {
        lastError = "Could not repair Network Extension DNS settings: \(UserFacingError.message(for: error))"
      }
    }
  }

  func repairTunDNS() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning {
          try await reconcileTunSystemDNS(for: tunSettings)
        } else if systemProxyController.hasManagedSystemDNSState {
          _ = try await restoreTunSystemDNS()
        } else {
          setTunSystemDNSState(.inactive)
        }
        refreshTunDiagnostics(includeExternal: false)
        lastError = nil
      } catch {
        lastError = "Could not repair TUN DNS settings: \(UserFacingError.message(for: error))"
      }
    }
  }

  func repairTunRouting() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        if runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning {
          try await reconcileTunSystemDNS(for: tunSettings)
          let runtimeConfig = try await materializeTunRuntimeConfig(tunSettings)
          var didRestartHelper = false
          if let apiClient {
            do {
              try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
              appendAppLog(level: "info", message: "TUN routing repair reloaded \(runtimeConfig.path).")
            } catch is CancellationError {
              throw CancellationError()
            } catch {
              appendAppLog(
                level: "warn",
                message: "TUN routing repair reload failed, restarting helper instead: \(UserFacingError.message(for: error))"
              )
              try await restartRunningTunHelper(
                runtimeConfig: runtimeConfig,
                settings: tunSettings,
                reason: "TUN routing repair"
              )
              didRestartHelper = true
            }
          } else {
            try await restartRunningTunHelper(
              runtimeConfig: runtimeConfig,
              settings: tunSettings,
              reason: "TUN routing repair"
            )
            didRestartHelper = true
          }

          let postReloadSnapshot = await inspectTunRuntimeNow(includeExternal: false)
          if !didRestartHelper, postReloadSnapshot.hasRepairableRoutingIssue {
            try await restartRunningTunHelper(
              runtimeConfig: runtimeConfig,
              settings: tunSettings,
              reason: "TUN routing repair"
            )
            didRestartHelper = true
            let postRestartSnapshot = await inspectTunRuntimeNow(includeExternal: false)
            if postRestartSnapshot.hasRepairableRoutingIssue {
              throw AppError.helperResponse(
                "TUN routing repair still reports \(postRestartSnapshot.repairableRoutingIssueMessage) after helper restart."
              )
            }
          } else if didRestartHelper, postReloadSnapshot.hasRepairableRoutingIssue {
            throw AppError.helperResponse(
              "TUN routing repair still reports \(postReloadSnapshot.repairableRoutingIssueMessage) after helper restart."
            )
          }
          reloadRuntimeData()
        } else if systemProxyController.hasManagedSystemDNSState {
          _ = try await restoreTunSystemDNS()
          tunDiagnostics = .empty
        } else {
          setTunSystemDNSState(.inactive)
          tunDiagnostics = .empty
        }
        lastError = nil
      } catch is CancellationError {
        return
      } catch {
        let repairMessage = UserFacingError.message(for: error)
        appendAppLog(level: "warn", message: "TUN routing repair failed: \(repairMessage)")
        let result = await stopRuntimeCoordinated(.safetyShutdown)
        handleStopResult(result)
        if result.succeeded {
          lastError = "TUN routing repair could not complete, so ClashMax stopped TUN safely: \(repairMessage)"
        } else {
          lastError = "Could not repair TUN routing: \(repairMessage)"
        }
      }
    }
  }

  private func inspectTunRuntimeNow(includeExternal: Bool) async -> TunDiagnosticsSnapshot {
    guard runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning else {
      tunDiagnostics = .empty
      return .empty
    }
    stopTunDiagnostics(clear: false)
    let helperStatus = await liveTunHelperStatus(using: helperClient)
    tunHelperPID = helperStatus.pid
    let snapshot = await tunRuntimeInspector.inspect(
      TunRuntimeInspectionConfiguration(
        api: overrides.endpoint,
        tunSettings: tunSettings,
        helperPID: helperStatus.pid,
        helperStatusMessage: helperStatus.message,
        systemDNSState: tunSystemDNSState,
        includeExternal: includeExternal
      )
    )
    tunDiagnostics = snapshot
    return snapshot
  }

  private func applySystemProxySettings() async throws {
    try await systemProxy.apply(settings: systemProxySettings, mixedPort: overrides.mixedPort)
  }

  private func activateSystemProxyGuardIfNeeded() async throws {
    try await systemProxy.activateGuardIfNeeded(
      settings: systemProxySettings,
      mixedPort: overrides.mixedPort,
      onWarning: { [weak self] warning in
        self?.appendAppLog(level: "warn", message: warning)
      },
      onError: { [weak self] error in
        self?.lastError = UserFacingError.message(for: error)
      }
    )
  }

  private func stopSystemProxyGuard() {
    systemProxy.stopGuard()
  }

  private func recoverDanglingManagedDNSIfNeeded() {
    guard systemProxyController.hasManagedSystemDNSState else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      setNetworkExtensionSystemDNSState(.restoring)
      setTunSystemDNSState(.restoring)
      do {
        let result = try await systemProxyController.restoreDNS()
        let restoredState: SystemDNSOverrideState = result.restoredSnapshotCount > 0 ? .restored : .inactive
        setNetworkExtensionSystemDNSState(restoredState)
        setTunSystemDNSState(restoredState)
        if result.restoredSnapshotCount > 0 {
          appendAppLog(level: "info", message: "Managed system DNS restored from a previous run for \(result.restoredSnapshotCount) service(s).")
        }
      } catch {
        let message = UserFacingError.message(for: error)
        setNetworkExtensionSystemDNSState(.restoreFailed(message))
        setTunSystemDNSState(.restoreFailed(message))
        lastError = "Could not restore managed DNS settings from a previous run: \(message)"
      }
    }
  }

  private var shouldStopNetworkExtensionRuntime: Bool {
    runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
      || networkExtensionCoreCrashMessage != nil
  }

  private var shouldRestoreNetworkExtensionDNS: Bool {
    shouldStopNetworkExtensionRuntime && systemProxyController.hasManagedSystemDNSState
  }

  private var shouldRestoreTunDNS: Bool {
    (runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning)
      && systemProxyController.hasManagedSystemDNSState
  }

  private func disableRunningTunBeforeStop() async {
    guard let apiClient else { return }
    do {
      try await withTimeout(seconds: Self.tunControllerCleanupTimeoutSeconds) { @Sendable [apiClient] in
        try await apiClient.setTunEnabled(false)
      }
      appendAppLog(level: "info", message: "Requested Mihomo to disable TUN before stopping the helper.")
    } catch is CancellationError {
      return
    } catch {
      appendAppLog(
        level: "warn",
        message: "Could not disable Mihomo TUN before helper stop: \(UserFacingError.message(for: error))"
      )
    }
  }

  private func stopNetworkExtensionIfNeeded() async -> NetworkExtensionStopCleanupResult {
    var result = NetworkExtensionStopCleanupResult()
    let shouldRestoreDNS = shouldRestoreNetworkExtensionDNS
    guard shouldStopNetworkExtensionRuntime else {
      if shouldRestoreDNS {
        do {
          _ = try await restoreNetworkExtensionSystemDNS()
        } catch {
          result.dnsRestoreError = error
        }
      }
      return result
    }
    do {
      _ = try await networkExtensionController.stopTransparentProxy()
      stopNetworkExtensionDiagnosticsPolling()
      publishNetworkExtensionControllerError()
    } catch {
      result.transparentProxyStopError = error
      return result
    }
    if shouldRestoreDNS {
      do {
        _ = try await restoreNetworkExtensionSystemDNS()
      } catch {
        result.dnsRestoreError = error
      }
    }
    return result
  }

  private func startNetworkExtensionDiagnosticsPolling() {
    networkExtensionDiagnosticsTask?.cancel()
    publishedNetworkExtensionDiagnosticEventIDs = []
    networkExtensionController.refreshDiagnostics()
    publishNetworkExtensionDiagnostics()

    networkExtensionDiagnosticsTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        guard self.runtimeOwner == .networkExtension || self.networkExtensionController.vpnStatus.isActive else {
          return
        }
        self.networkExtensionController.refreshDiagnostics()
        self.publishNetworkExtensionDiagnostics()
        do {
          try await Task.sleep(nanoseconds: 1_000_000_000)
        } catch {
          return
        }
      }
    }
  }

  private func stopNetworkExtensionDiagnosticsPolling() {
    networkExtensionDiagnosticsTask?.cancel()
    networkExtensionDiagnosticsTask = nil
  }

  private func publishNetworkExtensionDiagnostics() {
    let diagnostics = networkExtensionController.diagnostics
    for event in diagnostics.recentBypasses where publishedNetworkExtensionDiagnosticEventIDs.insert(event.id).inserted {
      appendAppLog(level: "debug", message: networkExtensionDiagnosticLogMessage(prefix: "NE bypass", event: event))
    }
    for event in diagnostics.recentErrors where publishedNetworkExtensionDiagnosticEventIDs.insert(event.id).inserted {
      appendAppLog(level: "error", message: networkExtensionDiagnosticLogMessage(prefix: "NE error", event: event))
    }
    if publishedNetworkExtensionDiagnosticEventIDs.count > 80 {
      let retainedIDs = Set((diagnostics.recentBypasses + diagnostics.recentErrors).map(\.id))
      publishedNetworkExtensionDiagnosticEventIDs = publishedNetworkExtensionDiagnosticEventIDs.intersection(retainedIDs)
    }
  }

  private func networkExtensionDiagnosticLogMessage(prefix: String, event: NetworkExtensionDiagnosticEvent) -> String {
    let context = [
      event.flowProtocol?.displayName,
      event.remoteEndpoint,
      event.sourceAppSigningIdentifier.map { "source=\($0)" }
    ]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
      .joined(separator: " ")
    if !context.isEmpty {
      return "\(prefix): \(event.message) \(context)"
    }
    return "\(prefix): \(event.message)"
  }

  @discardableResult
  private func restoreSystemProxyState(disableWhenNoSnapshot: Bool) async throws -> SystemProxyRestoreResult {
    try await systemProxy.restore(
      settings: systemProxySettings,
      mixedPort: overrides.mixedPort,
      disableWhenNoSnapshot: disableWhenNoSnapshot
    )
  }

  var needsTerminationCleanup: Bool {
    startInFlight
      || isCoreRunning
      || tunEnabled
      || tunnelCoreRunning
      || runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
      || systemProxyController.hasManagedSystemDNSState
      || systemProxy.needsTerminationCleanup
  }

  @discardableResult
  func prepareForTermination() async -> Bool {
    previewRuntimeRequested = false
    startTask?.cancel()
    startTask = nil
    startInFlight = false
    cancelPendingPreviewRuntimeStart()
    pendingModeTask?.cancel()
    pendingModeTask = nil
    pendingRoutingModeTask?.cancel()
    pendingRoutingModeTask = nil
    subscriptionAutoUpdateTask?.cancel()
    subscriptionAutoUpdateTask = nil
    cancelRuntimeActionTasks()
    cancelTunHelperPreparation(resetState: false)
    let result = await stopRuntimeCoordinated(.termination)
    handleStopResult(result)
    return result.localCleanupSucceeded
  }

  func enterPreviewRuntime() {
    previewRuntimeRequested = true
    schedulePreviewRuntimeStartIfReady()
  }

  private func schedulePreviewRuntimeStartIfReady(profilePreviewGroups groups: [ProxyGroup]? = nil) {
    guard previewTask == nil else { return }
    guard canStartPreviewRuntime(profilePreviewGroups: groups) else { return }

    previewTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard let self, !Task.isCancelled else { return }
      guard self.canStartPreviewRuntime() else {
        self.previewTask = nil
        return
      }
      await self.startPreviewRuntime()
    }
  }

  private func canStartPreviewRuntime(profilePreviewGroups groups: [ProxyGroup]? = nil) -> Bool {
    previewRuntimeRequested
      && !startInFlight
      && !isCoreRunning
      && profileStore.activeProfile != nil
      && readinessIssue == nil
      && !(groups ?? profilePreviewGroups).isEmpty
  }

  private func cancelPendingPreviewRuntimeStart() {
    previewTask?.cancel()
    previewTask = nil
  }

  func leavePreviewRuntime() async {
    previewRuntimeRequested = false
    _ = await leavePreviewRuntimeResult()
  }

  private func leavePreviewRuntimeResult() async -> RuntimeStopResult {
    var result = RuntimeStopResult()
    cancelPendingPreviewRuntimeStart()
    guard previewRuntimeActive else { return result }
    cancelRuntimeActionTasks()
    stopTunDiagnostics(clear: true)
    runtimeData.flushPendingLogs()
    let networkExtensionStopResult = await stopNetworkExtensionIfNeeded()
    if let error = networkExtensionStopResult.transparentProxyStopError {
      result.networkExtensionStopError = error
      handleStopResult(result)
      return result
    }
    result.networkExtensionDNSRestoreError = networkExtensionStopResult.dnsRestoreError
    apiClient = nil
    streamTasks.forEach { $0.cancel() }
    streamTasks.removeAll()
    let coreStopResult = await coreController.stop()
    if let error = coreStopResult.error {
      result.coreStopError = error
      handleStopResult(result)
      return result
    }
    proxyGroups = []
    proxyProviders = []
    previewRuntimeActive = false
    runtimeOwner = .stopped
    return result
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
      let runtimeConfig = try await generateRuntimeConfig(
        for: profile,
        overrides: quietOverrides,
        selections: previewSelections
      )
      let client = MihomoAPIClient(baseURL: try quietOverrides.endpoint.baseURL, secret: quietOverrides.secret)
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
      let stopResult = await coreController.stop()
      if let error = stopResult.error {
        appendAppLog(level: "error", message: UserFacingError.message(for: error))
      }
      apiClient = nil
      runtimeOwner = .stopped
    } catch {
      previewRuntimeActive = false
      let stopResult = await coreController.stop()
      if let stopError = stopResult.error {
        appendAppLog(level: "error", message: UserFacingError.message(for: stopError))
      }
      apiClient = nil
      runtimeOwner = .stopped
      appendAppLog(level: "debug", message: "Preview runtime unavailable: \(UserFacingError.message(for: error))")
    }
  }

  private func stopRuntimeCoordinated(_ purpose: RuntimeStopPurpose = .userInitiated) async -> RuntimeStopResult {
    if let activeStopTask = stopTask {
      let inFlightPurpose = stopTaskPurpose
      let result = await activeStopTask.value
      guard purpose == .termination,
            inFlightPurpose != .termination,
            result.networkExtensionStopError != nil,
            !result.didRunLocalCleanup,
            needsTerminationCleanup else {
        return result
      }
      stopTask = nil
      stopTaskID = nil
      stopTaskPurpose = nil
      return await runStopRuntimeTask(purpose: .termination)
    }
    return await runStopRuntimeTask(purpose: purpose)
  }

  private func runStopRuntimeTask(purpose: RuntimeStopPurpose) async -> RuntimeStopResult {
    let taskID = UUID()
    let task = Task { @MainActor [weak self] in
      guard let self else { return RuntimeStopResult.success }
      return await self.stopRuntime(purpose: purpose)
    }
    stopTask = task
    stopTaskID = taskID
    stopTaskPurpose = purpose
    let result = await task.value
    if stopTaskID == taskID {
      stopTask = nil
      stopTaskID = nil
      stopTaskPurpose = nil
    }
    return result
  }

  private func handleStopResult(_ result: RuntimeStopResult) {
    guard !result.succeeded, let message = result.userFacingMessage else { return }
    if result.systemProxyRestoreError == nil,
       result.helperStopError == nil,
       result.networkExtensionStopError != nil {
      setNetworkExtensionLastError(message)
    } else {
      lastError = message
    }
    appendAppLog(level: "error", message: message)
  }

  private func cancelRuntimeActionTasks() {
    modeUpdateTask?.cancel()
    modeUpdateTask = nil
    modeUpdateToken = nil

    ipv6UpdateTask?.cancel()
    ipv6UpdateTask = nil
    ipv6UpdateToken = nil

    proxySelectionTasks.values.forEach { $0.cancel() }
    proxySelectionTasks.removeAll()
    proxySelectionTokens.removeAll()

    delayTestTasks.values.forEach { $0.cancel() }
    delayTestTasks.removeAll()
    delayTestTokens.removeAll()

    providerHealthCheckTasks.values.forEach { $0.cancel() }
    providerHealthCheckTasks.removeAll()
    providerHealthCheckTokens.removeAll()
    for id in providerHealthChecksInFlight {
      setProvider(id, healthCheckInFlight: false)
    }

    proxyProviderUpdateTasks.values.forEach { $0.cancel() }
    proxyProviderUpdateTasks.removeAll()
    proxyProviderUpdateTokens.removeAll()
    proxyProviderBatchUpdateTask?.cancel()
    proxyProviderBatchUpdateTask = nil
    proxyProviderBatchUpdateToken = nil
    for id in proxyProviderUpdatesInFlight {
      setProxyProvider(id, updateInFlight: false)
    }

    ruleProviderUpdateTasks.values.forEach { $0.cancel() }
    ruleProviderUpdateTasks.removeAll()
    ruleProviderUpdateTokens.removeAll()
    ruleProviderBatchUpdateTask?.cancel()
    ruleProviderBatchUpdateTask = nil
    ruleProviderBatchUpdateToken = nil
    for id in ruleProviderUpdatesInFlight {
      setRuleProvider(id, updateInFlight: false)
    }

    connectionCloseTasks.values.forEach { $0.cancel() }
    connectionCloseTasks.removeAll()
    connectionCloseTokens.removeAll()
    for id in closingConnectionIDs {
      setConnection(id, closing: false)
    }

    closeAllConnectionsTask?.cancel()
    closeAllConnectionsTask = nil
    closeAllConnectionsToken = nil
    closingAllConnections = false

    runtimeReloadTask?.cancel()
    runtimeReloadTask = nil
    runtimeReloadToken = nil
    runtimeReloadPending = false
    runtimeDataLoading = false

    tunSettingsApplyTask?.cancel()
    tunSettingsApplyTask = nil
    tunSettingsApplyToken = nil
  }

  private func stopRuntime(purpose: RuntimeStopPurpose) async -> RuntimeStopResult {
    var result = RuntimeStopResult()
    cancelRuntimeActionTasks()
    stopTunDiagnostics(clear: true)
    runtimeData.flushPendingLogs()
    let networkExtensionStopResult = await stopNetworkExtensionIfNeeded()
    result.networkExtensionDNSRestoreError = networkExtensionStopResult.dnsRestoreError
    if let error = networkExtensionStopResult.transparentProxyStopError {
      result.networkExtensionStopError = error
      guard purpose.continuesAfterNetworkExtensionStopFailure else {
        return result
      }
    }
    if runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning {
      await disableRunningTunBeforeStop()
    }
    if shouldRestoreTunDNS {
      do {
        _ = try await restoreTunSystemDNS()
      } catch {
        result.tunDNSRestoreError = error
      }
    }
    if result.networkExtensionStopError == nil,
       result.networkExtensionDNSRestoreError == nil,
       result.tunDNSRestoreError == nil,
       systemProxyController.hasManagedSystemDNSState {
      do {
        let dnsResult = try await systemProxyController.restoreDNS()
        let restoredState: SystemDNSOverrideState = dnsResult.restoredSnapshotCount > 0 ? .restored : .inactive
        setNetworkExtensionSystemDNSState(restoredState)
        setTunSystemDNSState(restoredState)
      } catch {
        result.tunDNSRestoreError = error
      }
    }
    result.didRunLocalCleanup = true
    apiClient = nil
    cancelPublicIPInfoRefresh(clearState: true)
    streamTasks.forEach { $0.cancel() }
    streamTasks.removeAll()
    stopNetworkExtensionDiagnosticsPolling()
    let coreStopResult = await coreController.stop()
    if let error = coreStopResult.error {
      result.coreStopError = error
    }
    runtimeData.clearRuntimeCollections()
    if tunEnabled || tunnelCoreRunning {
      do {
        _ = try await helperClient.stopTunnel()
      } catch {
        result.helperStopError = error
      }
    }
    tunHelperPID = nil
    tunnelCoreRunning = false
    await updateTunHelperStatusDetail()
    sessionStartedAt = nil
    previewRuntimeActive = false
    runtimeOwner = .stopped
    networkExtensionCoreCrashMessage = nil
    await refreshProfilePreviewAndWait()
    if systemProxy.needsTerminationCleanup {
      do {
        _ = try await restoreSystemProxyState(disableWhenNoSnapshot: systemProxyEnabled)
      } catch {
        result.systemProxyRestoreError = error
      }
    }
    tunEnabled = false
    if result.succeeded, purpose.schedulesPreviewRestart {
      schedulePreviewRuntimeStartIfReady()
    }
    return result
  }

  private func cancelPublicIPInfoRefresh(clearState: Bool) {
    publicIP.cancel(clearState: clearState)
  }

  private func requireActiveProfile() throws -> Profile {
    guard let profile = profileStore.activeProfile else {
      throw AppError.noActiveProfile
    }
    return profile
  }

  @discardableResult
  private func refreshProfilePreview() -> Task<Void, Never>? {
    proxyPreview.refreshPreview(for: profileStore.activeProfile)
  }

  private func refreshProfilePreviewAndWait() async {
    await refreshProfilePreview()?.value
  }

  func waitForProfilePreviewRefresh() async {
    await proxyPreview.waitForRefresh()
  }

  private func runtimeAPIClientForProxyAction() -> (any MihomoAPIControlling)? {
    guard canControlRuntimeProxies, let apiClient else {
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

  private func persistSelectedProxy(groupName: String, nodeName: String) {
    previewSelections[groupName] = nodeName
    saveCurrentPreviewSelections()
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
    runtimeData.replaceConnections(remaining)
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
    settings.syncExternalControllerSettings()
  }

  private func generateRuntimeConfig(
    for profile: Profile,
    overrides: RuntimeOverrides? = nil,
    selections: [String: String] = [:],
    options: RuntimeConfigOptions = .default
  ) async throws -> URL {
    let effectiveOverrides = overrides ?? self.overrides
    var effectiveOptions = options
    effectiveOptions.subscriptionProviderOptions = profile.subscriptionProviderOptions
    return try await runtimeConfigMaterializer.materialize(
      RuntimeConfigMaterializationRequest(
        profileName: profile.name,
        sourcePath: profile.originalConfigPath,
        runtimeConfigURL: paths.runtimeConfigURL(for: profile),
        providerContentURL: paths.runtimeProviderContentURL(for: profile),
        overrides: effectiveOverrides,
        selectionOverrides: selections,
        options: effectiveOptions
      )
    )
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
              self?.appendTrafficSample(sample)
            }
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await entry in client.logStream(level: logLevel) {
            await MainActor.run {
              self?.runtimeData.appendLog(entry)
            }
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await snapshot in client.connectionStream(interval: 1000) {
            await MainActor.run {
              self?.runtimeData.replaceConnections(snapshot)
            }
          }
        } catch {}
      }
    ]
    reloadRuntimeData()
  }

  private func appendTrafficSample(_ sample: TrafficSample) {
    runtimeData.appendTrafficSample(sample)
  }

  private func appendAppLog(level: String, message: String) {
    runtimeData.appendLog(level: level, message: message)
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
    proxyPreview.mergedPreviewSelections(into: groups)
  }

  private func loadPreviewSelectionsForActiveProfile() {
    proxyPreview.loadSelections(for: profileStore.activeProfileID)
  }

  private func saveCurrentPreviewSelections(forProfileID overrideID: Profile.ID? = nil) {
    proxyPreview.saveSelections(for: overrideID ?? profileStore.activeProfileID)
  }

  private func recoverDanglingSystemProxyIfNeeded() {
    systemProxy.recoverDanglingIfNeeded(
      settingsProvider: { [weak self] in
        guard let self else {
          return (.default, RuntimeOverrides.defaultForLaunch().mixedPort)
        }
        return (systemProxySettings, overrides.mixedPort)
      },
      onRecovered: { [weak self] in
        self?.appendAppLog(level: "info", message: "Cleared stale System Proxy settings left by a previous ClashMax session after restore verification.")
      },
      onError: { [weak self] error in
        self?.lastError = "Could not verify stale System Proxy settings from a previous ClashMax session: \(UserFacingError.message(for: error))"
      }
    )
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
