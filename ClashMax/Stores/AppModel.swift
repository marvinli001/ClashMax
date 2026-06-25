import AppKit
import Combine
import CoreWLAN
import Foundation
@preconcurrency import UserNotifications
import ServiceManagement
import UniformTypeIdentifiers

protocol CurrentNetworkProviding {
  func currentSSID() -> String?
}

struct CoreWLANCurrentNetworkProvider: CurrentNetworkProviding {
  func currentSSID() -> String? {
    CWWiFiClient.shared().interface()?.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
  }
}

private extension String {
  var nonEmptyString: String? {
    isEmpty ? nil : self
  }
}

private enum AppStartupAbort: Error {
  case waitingForTunHelper
}

private enum RuntimeSettingsApplyFailure: Error {
  case followUpFailed(String)
}

private enum RuntimeStopPurpose {
  case userInitiated
  case safetyShutdown
  case settingsApplyRestart
  case termination

  var continuesAfterNetworkExtensionStopFailure: Bool {
    self == .termination
  }

  var schedulesPreviewRestart: Bool {
    self == .userInitiated
  }

  var preservesRuntimeSettingsApplyTask: Bool {
    self == .settingsApplyRestart
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

struct InitialTunHelperPrompt: Equatable {
  enum PrimaryAction: Equatable {
    case install
    case openSettings
  }

  var primaryAction: PrimaryAction
  var statusMessage: String

  var primaryButtonTitle: String {
    switch primaryAction {
    case .install:
      return String(localized: "Install Helper")
    case .openSettings:
      return String(localized: "Open Settings")
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
  var publicIPInfo: PublicIPInfo? = nil
  var probeHost: String = ""
  var proxyEffect: ProxyEffectDiagnosticsSnapshot? = nil

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
    lines.append(contentsOf: proxyEffectReportLines())
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

  private func proxyEffectReportLines() -> [String] {
    var lines = [
      "Public IP: \(publicIPSummary)",
      "Public IP Region: \(publicIPRegionSummary)",
      "Probe Host: \(probeHost.isEmpty ? "—" : probeHost)",
    ]
    if let proxyEffect {
      lines.append("Current Node: \(proxyEffect.currentNodeSummary)")
      lines.append("Rule Policy: \(proxyEffect.probePolicy ?? "—")")
      lines.append("Rule Probe: \(proxyEffect.ruleProbeSummary)")
      lines.append("Proxy Effect: \(proxyEffect.statusLabel) - \(proxyEffect.reason)")
      if !proxyEffect.recoveryActions.isEmpty {
        lines.append("Recovery Actions:")
        lines.append(contentsOf: proxyEffect.recoveryActions.map { "- \($0)" })
      }
    }
    return lines
  }

  private var publicIPSummary: String {
    // The full egress IP is sensitive-by-default; the shared report only carries a masked form.
    publicIPInfo?.maskedAddress ?? "Unavailable"
  }

  private var publicIPRegionSummary: String {
    proxyEffect?.publicIPRegion ?? "Unknown"
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

private enum EffectiveRuntimeConfigValidationIntent: Equatable {
  case disabled
  case validateOptionalCore
  case requireCore
}

struct ProviderSideLoadPreflightResult: Equatable, Sendable {
  var profileID: Profile.ID
  var fileName: String
  var checkedAt: Date
  var message: String?
}

enum ProviderSideLoadPreflightStatus: Equatable {
  case idle
  case running(ProviderSideLoadPreflightResult)
  case succeeded(ProviderSideLoadPreflightResult)
  case failed(ProviderSideLoadPreflightResult)

  func message(for profileID: Profile.ID) -> String? {
    switch self {
    case .idle:
      return nil
    case let .running(result):
      guard result.profileID == profileID else { return nil }
      return String(format: String(localized: "Preflighting provider file %@..."), result.fileName)
    case let .succeeded(result):
      guard result.profileID == profileID else { return nil }
      return String(format: String(localized: "Provider side-load preflight passed for %@."), result.fileName)
    case let .failed(result):
      guard result.profileID == profileID else { return nil }
      if let message = result.message, !message.isEmpty {
        return String(
          format: String(localized: "Provider side-load preflight failed for %@: %@"),
          result.fileName,
          message
        )
      }
      return String(format: String(localized: "Provider side-load preflight failed for %@."), result.fileName)
    }
  }

  func isRunning(for profileID: Profile.ID) -> Bool {
    guard case let .running(result) = self else { return false }
    return result.profileID == profileID
  }
}

enum ProxyGroupProfileOrdering {
  /// Restores the configured proxy-group order on runtime groups.
  ///
  /// Mihomo's `/proxies` response is a JSON object with no reliable ordering, so
  /// runtime groups are reordered to follow `profileOrder` (the profile preview
  /// groups parsed from the YAML `proxy-groups` list). Groups missing from
  /// `profileOrder` keep their original runtime order and are appended after the
  /// configuration-ordered groups.
  static func ordered(_ runtimeGroups: [ProxyGroup], matching profileOrder: [ProxyGroup]) -> [ProxyGroup] {
    guard !profileOrder.isEmpty else { return runtimeGroups }
    var rank: [String: Int] = [:]
    for (index, group) in profileOrder.enumerated() where rank[group.name] == nil {
      rank[group.name] = index
    }
    return runtimeGroups.enumerated().sorted { lhs, rhs in
      switch (rank[lhs.element.name], rank[rhs.element.name]) {
      case let (left?, right?):
        return left == right ? lhs.offset < rhs.offset : left < right
      case (.some, .none):
        return true
      case (.none, .some):
        return false
      case (.none, .none):
        return lhs.offset < rhs.offset
      }
    }
    .map(\.element)
  }
}

@MainActor
protocol ProviderSideLoadPreflightRunning {
  func preflight(
    profile: Profile,
    providerFileURL: URL,
    paths: RuntimePaths,
    overrides: RuntimeOverrides,
    selectionOverrides: [String: String],
    runtimeSnippets: [RuntimeSnippet],
    coreURL: URL
  ) async throws
}

@MainActor
struct MihomoProviderSideLoadPreflightRunner: ProviderSideLoadPreflightRunning {
  var materializer: RuntimeConfigMaterializer
  var runtimeConfigValidator: any RuntimeConfigValidating

  init(
    materializer: RuntimeConfigMaterializer = RuntimeConfigMaterializer(),
    runtimeConfigValidator: any RuntimeConfigValidating = MihomoRuntimeConfigValidator()
  ) {
    self.materializer = materializer
    self.runtimeConfigValidator = runtimeConfigValidator
  }

  func preflight(
    profile: Profile,
    providerFileURL: URL,
    paths: RuntimePaths,
    overrides: RuntimeOverrides,
    selectionOverrides: [String: String],
    runtimeSnippets: [RuntimeSnippet],
    coreURL: URL
  ) async throws {
    let preflightDirectory = paths.runtime.appendingPathComponent(
      "provider-side-load-preflight-\(UUID().uuidString)",
      isDirectory: true
    )
    try SecureFileIO.createPrivateDirectory(at: preflightDirectory)
    defer {
      try? FileManager.default.removeItem(at: preflightDirectory)
    }

    var preflightOverrides = overrides
    preflightOverrides.tunEnabled = false
    var options = RuntimeConfigOptions.default
    options.subscriptionProviderOptions = profile.subscriptionProviderOptions
    options.runtimeSnippets = runtimeSnippets
    let materialization = try await materializer.materializeResult(
      RuntimeConfigMaterializationRequest(
        profileName: profile.name,
        sourcePath: profile.originalConfigPath,
        runtimeConfigURL: preflightDirectory.appendingPathComponent("runtime.yaml"),
        providerContentURL: preflightDirectory.appendingPathComponent("provider.txt"),
        overrides: preflightOverrides,
        selectionOverrides: selectionOverrides,
        options: options,
        retainedGenerationCount: 0,
        sideLoadedProviderContentPath: providerFileURL.path
      )
    )
    try await runtimeConfigValidator.validate(
      coreURL: coreURL,
      configURL: materialization.runtimeConfigURL,
      workDirectory: preflightDirectory
    )
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
  var proxyPageSettings: ProxyPageSettings {
    get { settings.proxyPageSettings }
    set { settings.proxyPageSettings = newValue }
  }
  var appTheme: AppTheme {
    get { settings.appTheme }
    set { settings.appTheme = newValue }
  }
  var externalControllerSettings: ExternalControllerSettings {
    get { settings.externalControllerSettings }
    set { settings.externalControllerSettings = newValue }
  }
  var menuBarPinnedGroupSettings: MenuBarPinnedGroupSettings {
    get { settings.menuBarPinnedGroupSettings }
    set { settings.menuBarPinnedGroupSettings = newValue }
  }
  var globalShortcutSettings: GlobalShortcutSettings {
    get { settings.globalShortcutSettings }
    set { settings.globalShortcutSettings = newValue }
  }
  var externalDashboardProfiles: [ExternalDashboardProfile] {
    get { settings.externalDashboardProfiles }
    set { settings.externalDashboardProfiles = newValue }
  }
  var networkPolicySettings: NetworkPolicySettings {
    get { settings.networkPolicySettings }
    set { settings.networkPolicySettings = newValue }
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
  var isAddingSubscription: Bool { profileCoordinator.isAddingSubscription }
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
  var rules: [RuntimeRule] {
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
  @Published private(set) var initialTunHelperPrompt: InitialTunHelperPrompt?
  @Published private(set) var initialTunHelperPromptActionInFlight = false
  @Published private(set) var shortcutRegistrationStatus: GlobalShortcutRegistrationStatus?
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
  @Published private(set) var runtimeSettingsApplyState: RuntimeSettingsApplyState = .idle
  @Published private(set) var effectiveRuntimeConfigState: EffectiveRuntimeConfigState = .idle
  var hasLoadedEffectiveRuntimeConfigForActiveProfile: Bool {
    effectiveRuntimeConfigSnapshotForActiveProfile != nil
  }
  @Published private(set) var providerSideLoadPreflightStatus: ProviderSideLoadPreflightStatus = .idle
  @Published private(set) var proxyDelayBatchProgress: ProxyDelayBatchProgress?
  @Published var routingSimulationRequest: RoutingSimulationRequest?
  private var lastErrorOrigin: LastErrorOrigin?
  private var isPublishingNetworkExtensionLastError = false
  private var isPublishingLastErrorWithDetails = false
  @Published var lastError: String? {
    didSet {
      if !isPublishingNetworkExtensionLastError {
        lastErrorOrigin = nil
      }
      if !isPublishingLastErrorWithDetails {
        lastErrorDetails = nil
      }
    }
  }
  @Published private(set) var lastErrorDetails: String?

  func publishSubscriptionFailure(_ error: Error) {
    let preflightError = error as? SubscriptionPreflightValidationError
    // The preflight wrapper already carries the extracted short summary; using it
    // avoids re-truncating to the benign Mihomo log head (issue #7).
    let summary = preflightError?.message ?? UserFacingError.message(for: error)
    let details = preflightError?.fullMessage
    isPublishingLastErrorWithDetails = true
    lastError = summary
    isPublishingLastErrorWithDetails = false
    lastErrorDetails = details
  }
  @Published private(set) var currentNetworkSSID: String?
  @Published private(set) var networkPolicyStatusMessage: String?
  @Published private(set) var lastAppliedNetworkPolicyID: NetworkPolicyRule.ID?
  @Published private(set) var backupRestoreStatusMessage: String?
  @Published private(set) var pendingBackupRestorePreview: BackupRestorePreview?
  var updatingProfileIDs: Set<Profile.ID> { profileCoordinator.updatingProfileIDs }
  var profileOperationMessage: String? { profileCoordinator.message }
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
  let proxyPreview: ProxyPreviewStore
  let profileCoordinator: ProfileCoordinator
  let systemProxy: SystemProxyCoordinator
  let profileStore: ProfileStore
  let providerAnalytics: ProviderAnalyticsStore
  let coreController: CoreProcessController
  var systemProxyController: SystemProxyController { systemProxy.controller }
  let helperClient: TunnelHelperClient
  let networkExtensionController: NetworkExtensionController
  let runtimeSnippetLibrary: RuntimeSnippetLibraryStore
  private let tunnelReadinessProbe: CoreReadinessProbing
  private let proxyPortReadinessProbe: any ProxyPortReadinessProbing
  private let tunRuntimeInspector: any TunRuntimeInspecting
  private let pingTester: any PingTesting
  private let paths: RuntimePaths
  private let runtimeConfigMaterializer = RuntimeConfigMaterializer()
  private var activeRuntimeConfigMaterialization: RuntimeConfigMaterializationResult?
  private var apiClient: (any MihomoAPIControlling)?
  private var startTask: Task<Void, Never>?
  private var previewTask: Task<Void, Never>?
  private var previewRuntimeRequested = false
  private var previewRuntimeOverrides: RuntimeOverrides?
  private var stopTask: Task<RuntimeStopResult, Never>?
  private var stopTaskID: UUID?
  private var stopTaskPurpose: RuntimeStopPurpose?
  private var pendingModeTask: Task<Void, Never>?
  private var pendingRoutingModeTask: Task<Void, Never>?
  private var tunHelperPreparationTask: Task<Void, Never>?
  private var didWarmTunHelperRegistrationOnLaunch = false
  private var initialTunHelperPromptDeferredDuringSilentStart = false
  private var didResumeInitialTunHelperPromptAfterUserOpen = false
  private var didWarmPreviewRuntimeOnLaunch = false
  private var modeUpdateTask: Task<Void, Never>?
  private var modeUpdateToken: UUID?
  private var ipv6UpdateTask: Task<Void, Never>?
  private var ipv6UpdateToken: UUID?
  private var runtimeSettingsApplyTask: Task<Void, Never>?
  private var runtimeSettingsApplyToken: UUID?
  private var proxySelectionTasks: [ProxyGroup.ID: Task<Void, Never>] = [:]
  private var proxySelectionTokens: [ProxyGroup.ID: UUID] = [:]
  private var delayTestTasks: [ProxyNodeKey: Task<Void, Never>] = [:]
  private var delayTestTokens: [ProxyNodeKey: UUID] = [:]
  private var delayStateCache: [ProxyNodeKey: ProxyDelayCacheEntry] = [:]
  private var proxyDelayBatchTask: Task<Void, Never>?
  private var proxyDelayBatchToken: UUID?
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
  private var networkPolicyApplyTask: Task<Void, Never>?
  private var networkPolicyApplyToken: UUID?
  private var networkPolicyRestoreSnapshot: NetworkPolicyRestoreSnapshot?
  private var networkEnvironmentTask: Task<Void, Never>?
  private var networkEnvironmentDebounceTask: Task<Void, Never>?
  private var runtimeReloadTask: Task<Void, Never>?
  private var runtimeReloadToken: UUID?
  private var runtimeReloadPending = false
  private var tunSettingsApplyTask: Task<Void, Never>?
  private var tunSettingsApplyToken: UUID?
  private var streamTasks: [Task<Void, Never>] = []
  private var networkExtensionDiagnosticsTask: Task<Void, Never>?
  private var tunDiagnosticsTask: Task<Void, Never>?
  private var publishedNetworkExtensionDiagnosticEventIDs: Set<String> = []
  private var storeCancellables: Set<AnyCancellable> = []
  private let externalDashboardSecretStore: any SecretStoring
  private let currentNetworkProvider: any CurrentNetworkProviding
  private let networkEnvironmentMonitor: (any NetworkEnvironmentMonitoring)?
  private let globalShortcutManager: GlobalShortcutManager
  private let backupRestoreService = BackupRestoreService()
  private var providerSideLoadPreflightRunner: any ProviderSideLoadPreflightRunning = MihomoProviderSideLoadPreflightRunner()
  private let bundledCoreURLProvider: () throws -> URL
  private let delayStateCacheTTL: TimeInterval
  static let publicIPRefreshInterval: TimeInterval = 300
  static let silentStartDefaultsKey = PersistedSettingsStore.silentStartDefaultsKey
  static let startWallClockSeconds: TimeInterval = 22
  private static let previewRuntimeMixedPort = 17_890
  private static let previewRuntimeControllerPort = 19_097
  private static let proxyDelayBatchConcurrencyLimit = 6
  // Issue #11: batch delay results are coalesced before touching `@Published` state. A flush
  // happens once `proxyDelayBatchFlushCount` results have accumulated or once
  // `proxyDelayBatchFlushIntervalMs` has elapsed since the last flush, whichever comes first
  // (the very first result flushes immediately so results start appearing without delay).
  private static let proxyDelayBatchFlushCount = 24
  private static let proxyDelayBatchFlushIntervalMs: Double = 120
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
    defaults: UserDefaults = .standard,
    delayStateCacheTTL: TimeInterval = 600,
    externalDashboardSecretStore: any SecretStoring = KeychainStore(service: "\(AppConstants.bundleIdentifier).external-dashboards"),
    runtimeSnippetLibrary: RuntimeSnippetLibraryStore? = nil,
    providerAnalytics: ProviderAnalyticsStore? = nil,
    currentNetworkProvider: any CurrentNetworkProviding = CoreWLANCurrentNetworkProvider(),
    networkEnvironmentMonitor: (any NetworkEnvironmentMonitoring)? = nil,
    globalShortcutRegistrar: (any GlobalShortcutRegistering)? = nil,
    bundledCoreURLProvider: (() throws -> URL)? = nil,
    providerSideLoadPreflightRunner: any ProviderSideLoadPreflightRunning = MihomoProviderSideLoadPreflightRunner()
  ) {
    self.paths = paths
    self.delayStateCacheTTL = delayStateCacheTTL
    self.externalDashboardSecretStore = externalDashboardSecretStore
    self.currentNetworkProvider = currentNetworkProvider
    self.networkEnvironmentMonitor = networkEnvironmentMonitor ?? NetworkEnvironmentMonitor(currentNetworkProvider: currentNetworkProvider)
    self.globalShortcutManager = GlobalShortcutManager(registrar: globalShortcutRegistrar ?? CarbonGlobalShortcutRegistrar())
    self.providerSideLoadPreflightRunner = providerSideLoadPreflightRunner
    self.bundledCoreURLProvider = bundledCoreURLProvider ?? Self.resolveBundledCoreURL
    self.profileStore = profileStore ?? ProfileStore(paths: paths)
    self.runtimeSnippetLibrary = runtimeSnippetLibrary ?? RuntimeSnippetLibraryStore(paths: paths)
    self.providerAnalytics = providerAnalytics ?? ProviderAnalyticsStore(paths: paths)
    self.proxyPreview = ProxyPreviewStore(defaults: defaults)
    self.profileCoordinator = ProfileCoordinator(profileStore: self.profileStore, proxyPreview: self.proxyPreview)
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
    profileCoordinator.configureRuntimeHooks(
      automaticSubscriptionUpdatesEnabled: { [weak self] in
        self?.settings.subscriptionFetchSettings.automaticUpdatesEnabled ?? false
      },
      subscriptionUpdateSettings: { [weak self] in
        self?.settings.subscriptionFetchSettings ?? .default
      },
      subscriptionFetchOptions: { [weak self] profile in
        guard let self else { return SubscriptionFetchOptions() }
        if let profile {
          return self.subscriptionFetchOptions(for: profile)
        }
        return self.subscriptionFetchOptions
      },
      preflightValidator: { [weak self] in
        guard let self else { return NoopSubscriptionProfilePreflightValidator() }
        return self.subscriptionPreflightValidator()
      },
      reloadActiveRuntimeConfigIfNeeded: { [weak self] profileID, logMessage in
        guard let self else { return }
        try await self.reloadActiveRuntimeConfigIfNeeded(for: profileID, logMessage: logMessage)
      },
      appendAppLog: { [weak self] level, message in
        self?.appendAppLog(level: level, message: message)
      },
      notifySubscriptionUpdateFailure: { [weak self] profileName, message in
        self?.notifySubscriptionUpdateFailure(profileName: profileName, message: message)
      },
      clearRuntimeProxyGroups: { [weak self] in
        self?.proxyGroups = []
      },
      shouldSyncRuntimeAfterProfileChange: { [weak self] in
        guard let self else { return false }
        return self.isRunning || self.startInFlight
      },
      restartRuntime: { [weak self] in
        self?.restart()
      },
      stopRuntime: { [weak self] in
        self?.stop()
      }
    )
    settings.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    settings.$subscriptionFetchSettings
      .dropFirst()
      .sink { [weak self] _ in
        self?.profileCoordinator.rescheduleSubscriptionAutoUpdates()
      }
      .store(in: &storeCancellables)
    settings.$globalShortcutSettings
      .sink { [weak self] settings in
        self?.installGlobalShortcuts(settings)
      }
      .store(in: &storeCancellables)
    profileCoordinator.objectWillChange
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
    self.profileStore.$profiles
      .dropFirst()
      .sink { [weak self] profiles in
        Task { [weak self] in
          await self?.pruneRuntimeSnippetProfileBindings(validProfileIDs: Set(profiles.map(\.id)))
          await MainActor.run {
            self?.providerAnalytics.prune(validProfileIDs: Set(profiles.map(\.id)))
          }
        }
      }
      .store(in: &storeCancellables)
    let providerAnalyticsStore = self.providerAnalytics
    providerAnalyticsStore.objectWillChange
      .sink { [weak self] _ in self?.objectWillChange.send() }
      .store(in: &storeCancellables)
    self.runtimeSnippetLibrary.objectWillChange
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
        self.profileCoordinator.rescheduleSubscriptionAutoUpdates()
      }
    } else {
      profileCoordinator.rescheduleSubscriptionAutoUpdates()
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

  var runtimeSettingsApplyStatusMessage: String? {
    switch runtimeSettingsApplyState {
    case .idle:
      return nil
    case .pending:
      return String(localized: "Runtime settings pending.")
    case .applying:
      return String(localized: "Applying runtime settings.")
    case let .failed(message):
      return String(format: String(localized: "Runtime settings saved but not applied: %@"), message)
    case let .appliedWithFollowUpFailure(message):
      return String(
        format: String(localized: "Runtime settings applied, but proxy readiness or system proxy setup failed: %@"),
        message
      )
    }
  }

  var currentRuntimeOverrides: RuntimeOverrides {
    if isRunning, let snapshot = settings.appliedRuntimeSettingsSnapshot {
      return snapshot.overrides
    }
    return overrides
  }

  private var currentRuntimeMixedPort: Int {
    currentRuntimeOverrides.mixedPort
  }

  private var canApplyRuntimeSettingsToCurrentRuntime: Bool {
    guard !previewRuntimeActive else { return false }
    return isRunning
      || tunnelCoreRunning
      || tunEnabled
      || runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
      || apiClient != nil
  }

  private var effectiveRuntimeOwnerForSettingsSnapshot: RuntimeOwner {
    if runtimeOwner != .stopped {
      return runtimeOwner
    }
    if tunnelCoreRunning || tunEnabled {
      return .tunnel
    }
    if networkExtensionController.vpnStatus.isActive || proxyRoutingMode == .neProxy {
      return .networkExtension
    }
    if apiClient != nil {
      return .user
    }
    if isCoreRunning {
      return .user
    }
    return .stopped
  }

  private func runtimeOverridesForSettingsSnapshot(owner: RuntimeOwner? = nil) -> RuntimeOverrides {
    let owner = owner ?? effectiveRuntimeOwnerForSettingsSnapshot
    var runtimeOverrides = overrides
    runtimeOverrides.tunEnabled = owner == .tunnel || proxyRoutingMode == .tun
    runtimeOverrides.tunSettings = tunSettings
    return runtimeOverrides
  }

  private func makeRuntimeSettingsSnapshot(owner: RuntimeOwner? = nil) -> AppliedRuntimeSettingsSnapshot {
    let owner = owner ?? effectiveRuntimeOwnerForSettingsSnapshot
    return AppliedRuntimeSettingsSnapshot(
      overrides: runtimeOverridesForSettingsSnapshot(owner: owner),
      proxyRoutingMode: proxyRoutingMode,
      systemProxySettings: systemProxySettings,
      networkExtensionRoutingSettings: networkExtensionRoutingSettings,
      runtimeOwner: owner,
      appliedAt: Date()
    )
  }

  private func seedAppliedRuntimeSettingsSnapshotIfNeeded() {
    guard settings.appliedRuntimeSettingsSnapshot == nil else { return }
    guard canApplyRuntimeSettingsToCurrentRuntime || startInFlight || systemProxyEnabled else { return }
    settings.recordAppliedRuntimeSettingsSnapshot(makeRuntimeSettingsSnapshot())
  }

  private func recordAppliedRuntimeSettingsSnapshot(_ snapshot: AppliedRuntimeSettingsSnapshot) {
    var snapshot = snapshot
    snapshot.appliedAt = Date()
    settings.recordAppliedRuntimeSettingsSnapshot(snapshot)
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
    if previewRuntimeActive && proxyGroups.isEmpty && !profilePreviewGroups.isEmpty {
      return mergedPreviewSelections(into: profilePreviewGroups)
    }
    if isCoreRunning {
      let ordered = ProxyGroupProfileOrdering.ordered(proxyGroups, matching: profilePreviewGroups)
      return mergedPreviewSelections(into: ordered)
    }
    return mergedPreviewSelections(into: profilePreviewGroups)
  }

  /// Single source of truth for the proxy-search/resolve pipeline shared by the Proxies page and the
  /// dashboard Current Node card. Both consume `visibleProxyGroups` (profile order + preview
  /// selections) plus `proxyProviders` so the dashboard resolves provider-backed members exactly like
  /// the Proxies page instead of reading the raw, unexpanded `runtimeData.proxyGroups` (issue #14).
  func proxySearchInput(searchText: String) -> ProxySearchPipeline.Input {
    ProxySearchPipeline.Input(
      groups: visibleProxyGroups,
      providers: proxyProviders,
      sortOrder: proxyPageSettings.sortOrder,
      searchText: searchText
    )
  }

  var isShowingProxyPreview: Bool {
    !isCoreRunning && !profilePreviewGroups.isEmpty
  }

  var canControlRuntimeProxies: Bool {
    isCoreRunning && apiClient != nil
  }

  var isProxyDelayBatchRunning: Bool {
    proxyDelayBatchProgress?.isRunning == true
  }

  var canSelectProxyOffline: Bool {
    !isCoreRunning && profileStore.activeProfile != nil && !profilePreviewGroups.isEmpty
  }

  var userVisibleLogs: [LogEntry] {
    LogVisibility.visibleEntries(in: logs, developerMode: developerMode)
  }

  /// The GeoIP host whose routing is simulated to detect an IP-check target that is sent to DIRECT.
  /// Uses the host of the most recent public-IP result, falling back to the default provider host.
  var proxyEffectProbeHost: String {
    if let host = publicIPInfoState.info?.sourceHost?.trimmingCharacters(in: .whitespacesAndNewlines),
       !host.isEmpty {
      return host
    }
    return ProxyEffectDiagnosticsInput.defaultProbeHost
  }

  /// Classifies whether the proxy is actually taking over outbound traffic (issue #13). The caller
  /// supplies the already-resolved current group/node so the dashboard reuses its shared off-main
  /// proxy-resolution pipeline instead of re-expanding providers here.
  func proxyEffectDiagnostics(
    currentGroup: ProxyGroup?,
    currentNode: ProxyNode?,
    hasMissingSelection: Bool
  ) -> ProxyEffectDiagnosticsSnapshot {
    ProxyEffectDiagnosticsBuilder.build(
      ProxyEffectDiagnosticsInput(
        publicIPInfo: publicIPInfoState.info,
        isCoreRunning: isCoreRunning,
        routingMode: proxyRoutingMode,
        runMode: currentRuntimeOverrides.mode,
        systemProxyEnabled: systemProxyEnabled,
        tunEnabled: tunEnabled,
        networkExtensionEnabled: networkExtensionEnabled,
        tunDiagnostics: tunDiagnostics,
        networkExtensionDiagnostics: networkExtensionController.diagnostics,
        currentGroupName: currentGroup?.name,
        currentNodeName: currentNode?.name ?? currentGroup?.selected,
        currentNodeType: currentNode?.type,
        hasMissingSelection: hasMissingSelection,
        runtimeRules: runtimeData.rules,
        probeHost: proxyEffectProbeHost
      )
    )
  }

  func runtimeDiagnosticsReport(now: Date = Date()) -> RuntimeDiagnosticsReport {
    let diagnosticOverrides = previewRuntimeActive ? (previewRuntimeOverrides ?? overrides) : overrides
    // Resolve the dashboard's current group/node through the same provider-expansion pipeline the
    // Current Node card uses. Copy Diagnostics is user-initiated, so a synchronous value-pipeline run
    // is acceptable here and keeps provider-backed selections from being reported as unavailable.
    let resolvedGroups = ProxySearchPipeline.run(proxySearchInput(searchText: "")).unfilteredGroups
    let selectableGroups = DashboardProxySelectionState.selectableGroups(from: resolvedGroups)
    let currentGroup = DashboardProxySelectionState.resolvedGroup(from: selectableGroups, preferredName: nil)
    let currentNode = currentGroup.flatMap(DashboardProxySelectionState.currentNode)
    let hasMissingSelection = currentGroup.map(DashboardProxySelectionState.hasMissingSelection) ?? false
    let proxyEffect = proxyEffectDiagnostics(
      currentGroup: currentGroup,
      currentNode: currentNode,
      hasMissingSelection: hasMissingSelection
    )
    return RuntimeDiagnosticsReport(
      generatedAt: now,
      statusSummary: statusSummary,
      profileName: profileStore.activeProfile?.name ?? "No Profile",
      runtimeOwner: runtimeOwner,
      routingMode: proxyRoutingMode,
      runMode: diagnosticOverrides.mode,
      controllerHost: diagnosticOverrides.externalControllerHost,
      controllerPort: diagnosticOverrides.externalControllerPort,
      controllerSecret: diagnosticOverrides.secret,
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
      helperLogs: helperLogs,
      publicIPInfo: publicIPInfoState.info,
      probeHost: proxyEffectProbeHost,
      proxyEffect: proxyEffect
    )
  }

  func copyRuntimeDiagnostics() {
    let report = runtimeDiagnosticsReport()
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(report.plainText, forType: .string)
    appNotice = AppNotice(message: String(localized: "Diagnostics copied."), tone: .success)
  }

  func refreshEffectiveRuntimeConfigPreview(draftSnippet: RuntimeSnippet? = nil) async {
    guard let profile = profileStore.activeProfile else {
      effectiveRuntimeConfigState = .unavailable(String(localized: "No active profile selected."))
      return
    }
    effectiveRuntimeConfigState = .loading
    do {
      let snippets = await effectiveRuntimeSnippets(for: profile.id, draftSnippet: draftSnippet)
      let snapshot = try await makeEffectiveRuntimeConfigSnapshot(
        profile: profile,
        overrides: overrides,
        runtimeSnippets: snippets,
        preflight: .validateOptionalCore
      )
      guard profileStore.activeProfile?.id == profile.id else {
        resetEffectiveRuntimeConfigPreview()
        return
      }
      effectiveRuntimeConfigState = .loaded(snapshot)
      lastError = snapshot.preflightStatus.message
    } catch {
      let message = UserFacingError.message(for: error)
      effectiveRuntimeConfigState = .failed(message)
      lastError = message
    }
  }

  func copyEffectiveRuntimeConfigRedacted() {
    guard let snapshot = effectiveRuntimeConfigSnapshotForActiveProfile else {
      appNotice = AppNotice(message: String(localized: "Generate Effective Config before copying."), tone: .info)
      return
    }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(snapshot.redactedReportText, forType: .string)
    appNotice = AppNotice(message: String(localized: "Effective config copied."), tone: .success)
  }

  func exportEffectiveRuntimeConfigRedacted() {
    guard let snapshot = effectiveRuntimeConfigSnapshotForActiveProfile else {
      appNotice = AppNotice(message: String(localized: "Generate Effective Config before exporting."), tone: .info)
      return
    }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "clashmax-effective-runtime-config-redacted.txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try snapshot.redactedReportText.write(to: url, atomically: true, encoding: .utf8)
      appNotice = AppNotice(message: String(localized: "Effective config exported."), tone: .success)
    } catch {
      lastError = UserFacingError.message(for: error)
    }
  }

  private var effectiveRuntimeConfigSnapshotForActiveProfile: EffectiveRuntimeConfigSnapshot? {
    guard case let .loaded(snapshot) = effectiveRuntimeConfigState,
          snapshot.profileID == profileStore.activeProfile?.id
    else { return nil }
    return snapshot
  }

  private func resetEffectiveRuntimeConfigPreview() {
    if profileStore.activeProfile == nil {
      effectiveRuntimeConfigState = .unavailable(String(localized: "No active profile selected."))
    } else {
      effectiveRuntimeConfigState = .idle
    }
  }

  private func resetEffectiveRuntimeConfigPreviewIfNeeded(invalidatedProfileID: Profile.ID? = nil) {
    switch effectiveRuntimeConfigState {
    case .loading:
      resetEffectiveRuntimeConfigPreview()
    case let .loaded(snapshot)
      where snapshot.profileID == invalidatedProfileID || snapshot.profileID != profileStore.activeProfile?.id:
      resetEffectiveRuntimeConfigPreview()
    default:
      break
    }
  }

  func openRuntimeLogs() {
    selectedSection = .logs
  }

  func openRoutingExplanation(for connection: ConnectionSnapshot) {
    let explanation = RuleExplanationBuilder().explanation(for: connection, rules: runtimeData.rules)
    routingSimulationRequest = RoutingSimulationRequest(
      connectionID: connection.id,
      target: explanation.target,
      input: explanation.simulationInput,
      explanation: explanation
    )
    selectedSection = .routing
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
        _ = try await profileCoordinator.importLocalProfile(from: url)
        restartPreviewRuntimeIfNeeded(reason: "profile import")
        lastError = nil
      } catch {
        profileCoordinator.clearMessage()
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func providerSideLoadPreflightUnsupportedReason(for profile: Profile) -> String? {
    guard developerMode else {
      return String(localized: "Provider side-load preflight requires Developer Mode.")
    }
    guard profile.isSubscription else {
      return String(localized: "Provider side-load preflight requires a subscription profile.")
    }
    guard profile.id == profileStore.activeProfileID else {
      return String(localized: "Select this profile before running provider side-load preflight.")
    }
    do {
      let source = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)
      guard try ProfileConfigInspector.format(of: source) == .proxyProviderContent else {
        return String(localized: "Provider side-load preflight is only available for app-managed provider subscriptions.")
      }
      return nil
    } catch {
      return UserFacingError.message(for: error)
    }
  }

  func chooseProviderSideLoadPreflightFile(for profile: Profile) {
    if let reason = providerSideLoadPreflightUnsupportedReason(for: profile) {
      lastError = reason
      providerSideLoadPreflightStatus = .failed(
        ProviderSideLoadPreflightResult(
          profileID: profile.id,
          fileName: String(localized: "Provider file"),
          checkedAt: Date(),
          message: reason
        )
      )
      return
    }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.yaml, .yml, .text]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { @MainActor [weak self] in
      guard let self else { return }
      await preflightSideLoadedProviderContent(for: profile, providerFileURL: url)
    }
  }

  @discardableResult
  func preflightSideLoadedProviderContent(for profile: Profile, providerFileURL: URL) async -> Bool {
    let fileName = providerFileURL.lastPathComponent
    let targetProfile = profileStore.profiles.first { $0.id == profile.id } ?? profile
    if let reason = providerSideLoadPreflightUnsupportedReason(for: targetProfile) {
      providerSideLoadPreflightStatus = .failed(
        ProviderSideLoadPreflightResult(
          profileID: targetProfile.id,
          fileName: fileName,
          checkedAt: Date(),
          message: reason
        )
      )
      lastError = reason
      return false
    }

    providerSideLoadPreflightStatus = .running(
      ProviderSideLoadPreflightResult(
        profileID: targetProfile.id,
        fileName: fileName,
        checkedAt: Date(),
        message: nil
      )
    )
    lastError = nil
    await runtimeSnippetLibrary.waitForLoad()
    do {
      try await providerSideLoadPreflightRunner.preflight(
        profile: targetProfile,
        providerFileURL: providerFileURL,
        paths: paths,
        overrides: overrides,
        selectionOverrides: previewSelections,
        runtimeSnippets: runtimeSnippetLibrary.snippets(applyingTo: targetProfile.id),
        coreURL: try bundledCoreURL()
      )
      providerSideLoadPreflightStatus = .succeeded(
        ProviderSideLoadPreflightResult(
          profileID: targetProfile.id,
          fileName: fileName,
          checkedAt: Date(),
          message: nil
        )
      )
      appendAppLog(
        level: "info",
        message: "Provider side-load preflight passed for \(targetProfile.name) using \(fileName)."
      )
      return true
    } catch {
      let message = UserFacingError.message(for: error)
      providerSideLoadPreflightStatus = .failed(
        ProviderSideLoadPreflightResult(
          profileID: targetProfile.id,
          fileName: fileName,
          checkedAt: Date(),
          message: message
        )
      )
      lastError = message
      appendAppLog(
        level: "warn",
        message: "Provider side-load preflight failed for \(targetProfile.name) using \(fileName): \(message)"
      )
      return false
    }
  }

  func exportBackup(includeSecrets: Bool, password: String?, passwordConfirmation: String?) {
    if includeSecrets {
      guard let password, !password.isEmpty else {
        lastError = BackupRestoreError.passwordRequired.localizedDescription
        return
      }
      guard password == passwordConfirmation else {
        lastError = BackupRestoreError.passwordConfirmationMismatch.localizedDescription
        return
      }
    }

    let panel = NSSavePanel()
    panel.allowedContentTypes = [.clashMaxBackup]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = Self.defaultBackupFileName()
    guard panel.runModal() == .OK, let url = panel.url else { return }

    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let summary = try await backupRestoreService.exportBackup(
          to: url,
          profileStore: profileStore,
          settings: settings,
          proxyPreview: proxyPreview,
          runtimeSnippetLibrary: runtimeSnippetLibrary,
          includeSecrets: includeSecrets,
          password: password
        )
        backupRestoreStatusMessage = Self.exportBackupStatusMessage(summary: summary, fileName: url.lastPathComponent)
        lastError = nil
      } catch {
        backupRestoreStatusMessage = nil
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  func chooseBackupForRestore() {
    guard !isCoreRunning else {
      lastError = BackupRestoreError.cannotRestoreWhileRunning.localizedDescription
      return
    }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.clashMaxBackup, .json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      pendingBackupRestorePreview = try backupRestoreService.previewBackup(at: url)
      backupRestoreStatusMessage = nil
      lastError = nil
    } catch {
      pendingBackupRestorePreview = nil
      backupRestoreStatusMessage = nil
      lastError = UserFacingError.message(for: error)
    }
  }

  func clearPendingBackupRestore() {
    pendingBackupRestorePreview = nil
  }

  @discardableResult
  func restorePendingBackup(password: String?) async -> Bool {
    guard !isCoreRunning else {
      lastError = BackupRestoreError.cannotRestoreWhileRunning.localizedDescription
      return false
    }
    guard let preview = pendingBackupRestorePreview else { return false }

    do {
      let summary = try await backupRestoreService.restoreBackup(
        from: preview.url,
        password: password,
        profileStore: profileStore,
        settings: settings,
        proxyPreview: proxyPreview,
        runtimeSnippetLibrary: runtimeSnippetLibrary
      )
      profileCoordinator.clearMessage()
      proxyGroups = []
      await refreshProfilePreviewAndWait()
      loadPreviewSelectionsForActiveProfile()
      profileCoordinator.rescheduleSubscriptionAutoUpdates()
      pendingBackupRestorePreview = nil
      backupRestoreStatusMessage = Self.restoreBackupStatusMessage(summary: summary, fileName: preview.fileName)
      lastError = nil
      return true
    } catch {
      backupRestoreStatusMessage = nil
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  private static func defaultBackupFileName(now: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let stamp = formatter.string(from: now)
      .replacingOccurrences(of: ":", with: "-")
    return "ClashMax-\(stamp).clashmax-backup"
  }

  private static func exportBackupStatusMessage(summary: BackupRestoreSummary, fileName: String) -> String {
    if summary.skippedSecretCount > 0 {
      return String(
        format: String(localized: "Exported %@ with %lld profile(s). %lld secret(s) were not included."),
        fileName,
        Int64(summary.importedProfileCount),
        Int64(summary.skippedSecretCount)
      )
    }
    return String(
      format: String(localized: "Exported %@ with %lld profile(s)."),
      fileName,
      Int64(summary.importedProfileCount)
    )
  }

  private static func restoreBackupStatusMessage(summary: BackupRestoreSummary, fileName: String) -> String {
    if summary.skippedSecretCount > 0 {
      return String(
        format: String(localized: "Restored %@ with %lld profile(s). %lld secret(s) were skipped."),
        fileName,
        Int64(summary.importedProfileCount),
        Int64(summary.skippedSecretCount)
      )
    }
    return String(
      format: String(localized: "Restored %@ with %lld profile(s)."),
      fileName,
      Int64(summary.importedProfileCount)
    )
  }

  @discardableResult
  func addSubscription(
    name: String = "",
    urlString: String,
    providerOptions: SubscriptionProviderOptions = .default,
    updatePolicy: SubscriptionUpdatePolicy = .default,
    session: URLSession = .shared
  ) async -> Bool {
    let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let resolution = SubscriptionURLResolver.resolve(rawInput: trimmedURLString) else {
      profileCoordinator.clearMessage()
      lastError = "Invalid subscription URL."
      return false
    }

    lastError = nil
    profileCoordinator.clearMessage()

    do {
      guard try await profileCoordinator.addSubscription(
        name: name,
        url: resolution.url,
        displayNameHint: resolution.displayNameHint,
        providerOptions: providerOptions,
        updatePolicy: updatePolicy,
        session: session,
        fetchOptions: providerOptions.fetchOptions(from: subscriptionFetchOptions),
        preflightValidator: subscriptionPreflightValidator()
      ) != nil else {
        return false
      }
      restartPreviewRuntimeIfNeeded(reason: "subscription import")
      return true
    } catch {
      profileCoordinator.clearMessage()
      publishSubscriptionFailure(error)
      return false
    }
  }

  func handleIncomingURL(_ url: URL) {
    if handleCommandURL(url) {
      return
    }
    guard SubscriptionURLResolver.resolve(url: url) != nil else {
      lastError = "Invalid subscription URL."
      return
    }
    selectedSection = .profiles
    Task { @MainActor [weak self] in
      _ = await self?.addSubscription(urlString: url.absoluteString)
    }
  }

  private func handleCommandURL(_ url: URL) -> Bool {
    guard url.scheme?.localizedCaseInsensitiveCompare("clashmax") == .orderedSame else {
      return false
    }
    let action = commandURLAction(from: url)
    switch action {
    case "start":
      start()
    case "stop":
      stop()
    case "restart":
      restart()
    case "toggle-system-proxy":
      setSystemProxyEnabled(!systemProxyEnabled)
    case "system-proxy-on":
      setSystemProxyEnabled(true)
    case "system-proxy-off":
      setSystemProxyEnabled(false)
    case "routing-system-proxy":
      requestProxyRoutingMode(.systemProxy)
    case "routing-tun":
      requestProxyRoutingMode(.tun)
    case "routing-ne-proxy":
      requestProxyRoutingMode(.neProxy)
    case "update-due-subscriptions":
      selectedSection = .profiles
      updateDueSubscriptions()
    case "update-all-subscriptions":
      selectedSection = .profiles
      updateAllSubscriptions()
    case "apply-current-network-policy":
      selectedSection = .settings
      applyMatchingNetworkPolicyForCurrentNetwork()
    default:
      lastError = "Unsupported ClashMax command URL."
    }
    return true
  }

  private func installGlobalShortcuts(_ settings: GlobalShortcutSettings) {
    guard developerMode else {
      globalShortcutManager.stop()
      shortcutRegistrationStatus = nil
      return
    }
    guard settings.validationError == nil else {
      globalShortcutManager.stop()
      shortcutRegistrationStatus = nil
      return
    }
    let registrationCount = settings.enabledBindings.count
    let failures = globalShortcutManager.apply(settings) { [weak self] action in
      self?.performGlobalShortcutAction(action)
    }
    shortcutRegistrationStatus = GlobalShortcutRegistrationStatus(
      registeredCount: max(0, registrationCount - failures.count),
      failures: failures
    )
  }

  func performGlobalShortcutAction(_ action: GlobalShortcutAction) {
    switch action {
    case .startStop:
      canStopRuntime ? stop() : start()
    case .start:
      start()
    case .stop:
      stop()
    case .restart:
      restart()
    case .ruleMode:
      requestMode(.rule)
    case .globalMode:
      requestMode(.global)
    case .directMode:
      requestMode(.direct)
    case .toggleSystemProxy:
      setSystemProxyEnabled(!systemProxyEnabled)
    case .systemProxyRouting:
      requestProxyRoutingMode(.systemProxy)
    case .tunRouting:
      requestProxyRoutingMode(.tun)
    case .neProxyRouting:
      requestProxyRoutingMode(.neProxy)
    case .updateAllSubscriptions:
      selectedSection = .profiles
      updateAllSubscriptions()
    case .applyCurrentNetworkPolicy:
      selectedSection = .settings
      applyMatchingNetworkPolicyForCurrentNetwork()
    case .openMainWindow:
      AppDelegate.showMainWindow()
    }
  }

  private func commandURLAction(from url: URL) -> String {
    if let host = url.host(percentEncoded: false)?.trimmingCharacters(in: .whitespacesAndNewlines),
       !host.isEmpty {
      return host
    }
    return url.pathComponents
      .dropFirst()
      .first?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func updateActiveSubscription() {
    guard let profile = profileStore.activeProfile else { return }
    Task {
      await updateSubscription(profile)
    }
  }

  func updateDueSubscriptions() {
    profileCoordinator.updateDueSubscriptions()
  }

  func updateAllSubscriptions() {
    profileCoordinator.updateAllSubscriptions()
  }

  @discardableResult
  func updateSubscriptionPolicy(_ profile: Profile, policy: SubscriptionUpdatePolicy) async -> Bool {
    do {
      try await profileStore.updateSubscriptionUpdatePolicy(profile, policy: policy)
      profileCoordinator.rescheduleSubscriptionAutoUpdates()
      lastError = nil
      return true
    } catch {
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func toggleMenuBarPinnedGroup(_ group: ProxyGroup) {
    var settings = menuBarPinnedGroupSettings
    settings.toggle(group.name)
    menuBarPinnedGroupSettings = settings
  }

  var pinnedMenuBarProxyGroups: [ProxyGroup] {
    let names = menuBarPinnedGroupSettings.groupNames
    guard !names.isEmpty else { return [] }
    return names.compactMap { name in
      visibleProxyGroups.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
  }

  @discardableResult
  func saveExternalDashboardProfile(_ profile: ExternalDashboardProfile, secret: String?) -> Bool {
    var nextProfile = profile
    let trimmedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if nextProfile.readOnly {
        if let account = nextProfile.secretAccount {
          try externalDashboardSecretStore.delete(account: account)
        }
        nextProfile.secretAccount = nil
        nextProfile.trustedForSecretAutofill = false
      } else if let trimmedSecret, !trimmedSecret.isEmpty {
        let account = nextProfile.secretAccount ?? "external-dashboard-\(nextProfile.id.uuidString)"
        try externalDashboardSecretStore.save(trimmedSecret, account: account)
        nextProfile.secretAccount = account
      } else if secret != nil, let account = nextProfile.secretAccount {
        try externalDashboardSecretStore.delete(account: account)
        nextProfile.secretAccount = nil
      }

      guard syncControllerCORSForAutomaticSecretIfNeeded(nextProfile) else {
        return false
      }

      var profiles = externalDashboardProfiles
      if let index = profiles.firstIndex(where: { $0.id == nextProfile.id }) {
        profiles[index] = nextProfile
      } else {
        profiles.append(nextProfile)
      }
      externalDashboardProfiles = profiles
      lastError = nil
      return true
    } catch {
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  private func syncControllerCORSForAutomaticSecretIfNeeded(_ profile: ExternalDashboardProfile) -> Bool {
    guard let origin = Self.corsOriginForAutomaticSecretDashboard(profile) else { return true }
    var controllerSettings = externalControllerSettings
    let origins = ExternalControllerCORSSettings.normalizedOrigins(
      controllerSettings.cors.allowedOrigins + [origin]
    )
    guard origins != controllerSettings.cors.allowedOrigins else { return true }
    controllerSettings.cors.allowedOrigins = origins
    return updateExternalControllerSettings(controllerSettings)
  }

  private static func corsOriginForAutomaticSecretDashboard(_ profile: ExternalDashboardProfile) -> String? {
    guard !profile.readOnly,
          profile.trustedForSecretAutofill || isLocalDashboardURL(profile.url)
    else { return nil }
    return ExternalControllerCORSSettings.origin(forDashboardURL: profile.url)
  }

  func deleteExternalDashboardProfile(_ profile: ExternalDashboardProfile) {
    if let account = profile.secretAccount {
      try? externalDashboardSecretStore.delete(account: account)
    }
    externalDashboardProfiles.removeAll { $0.id == profile.id }
  }

  func externalDashboardOpenPlan(for profile: ExternalDashboardProfile) -> ExternalDashboardOpenPlan {
    let secret = profile.readOnly
      ? nil
      : profile.secretAccount.flatMap { try? externalDashboardSecretStore.load(account: $0) }
        ?? externalControllerSettings.normalizedSecret
    return Self.dashboardOpenPlan(
      baseURL: profile.url,
      controllerHost: externalControllerSettings.normalizedHost,
      controllerPort: externalControllerSettings.normalizedPort,
      readOnly: profile.readOnly,
      trustedForSecretAutofill: profile.trustedForSecretAutofill,
      secret: secret
    )
  }

  func externalDashboardURL(for profile: ExternalDashboardProfile) -> URL {
    externalDashboardOpenPlan(for: profile).url
  }

  static func dashboardOpenPlan(
    baseURL: URL,
    controllerHost: String,
    controllerPort: Int,
    readOnly: Bool,
    trustedForSecretAutofill: Bool,
    secret: String?
  ) -> ExternalDashboardOpenPlan {
    let trimmedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveSecret = trimmedSecret?.isEmpty == false ? trimmedSecret : nil
    let shouldAutofillSecret = !readOnly
      && effectiveSecret != nil
      && (trustedForSecretAutofill || isLocalDashboardURL(baseURL))

    if shouldAutofillSecret, let effectiveSecret {
      return ExternalDashboardOpenPlan(
        url: dashboardURL(
          baseURL: baseURL,
          controllerHost: controllerHost,
          controllerPort: controllerPort,
          secret: effectiveSecret
        ),
        secretDelivery: .fragment,
        secretForManualCopy: nil
      )
    }

    return sanitizedDashboardOpenPlan(
      baseURL: baseURL,
      controllerHost: controllerHost,
      controllerPort: controllerPort,
      secretForManualCopy: !readOnly ? effectiveSecret : nil
    )
  }

  private static func isLocalDashboardURL(_ url: URL) -> Bool {
    if url.isFileURL {
      return true
    }
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    else {
      return false
    }
    return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
  }

  private static func sanitizedDashboardOpenPlan(
    baseURL: URL,
    controllerHost: String,
    controllerPort: Int,
    secretForManualCopy: String?
  ) -> ExternalDashboardOpenPlan {
    ExternalDashboardOpenPlan(
      url: dashboardURL(
        baseURL: baseURL,
        controllerHost: controllerHost,
        controllerPort: controllerPort,
        secret: nil
      ),
      secretDelivery: secretForManualCopy == nil ? .none : .manualCopy,
      secretForManualCopy: secretForManualCopy
    )
  }

  static func dashboardURL(
    baseURL: URL,
    controllerHost: String,
    controllerPort: Int,
    secret: String?
  ) -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return baseURL
    }
    var items = components.queryItems ?? []
    let fixedValues = [
      URLQueryItem(name: "hostname", value: controllerHost),
      URLQueryItem(name: "port", value: "\(controllerPort)")
    ]
    for value in fixedValues {
      items.removeAll { $0.name.caseInsensitiveCompare(value.name) == .orderedSame }
      items.append(value)
    }
    items.removeAll { $0.name.caseInsensitiveCompare("secret") == .orderedSame }
    components.queryItems = items.isEmpty ? nil : items
    components.percentEncodedFragment = fragmentByUpdatingSecret(secret, in: components.fragment)
    return components.url ?? baseURL
  }

  private static func fragmentByUpdatingSecret(_ secret: String?, in fragment: String?) -> String? {
    let trimmedSecret = secret?.trimmingCharacters(in: .whitespacesAndNewlines)
    let effectiveSecret = trimmedSecret?.isEmpty == false ? trimmedSecret : nil
    guard let fragment, !fragment.isEmpty else {
      return effectiveSecret.map { queryByUpdatingSecret($0, in: "") ?? "secret=\($0)" }
    }

    if let separator = fragment.firstIndex(of: "?") {
      let prefix = String(fragment[..<separator])
      let query = String(fragment[fragment.index(after: separator)...])
      guard let updatedQuery = queryByUpdatingSecret(effectiveSecret, in: query), !updatedQuery.isEmpty else {
        let encodedPrefix = percentEncodedFragmentPrefix(prefix)
        return encodedPrefix.isEmpty ? nil : encodedPrefix
      }
      let encodedPrefix = percentEncodedFragmentPrefix(prefix)
      return encodedPrefix.isEmpty ? updatedQuery : "\(encodedPrefix)?\(updatedQuery)"
    }

    if fragment.contains("=") || fragment.contains("&") {
      return queryByUpdatingSecret(effectiveSecret, in: fragment)
    }

    guard let effectiveSecret else {
      return percentEncodedFragmentPrefix(fragment)
    }
    let query = queryByUpdatingSecret(effectiveSecret, in: "") ?? "secret=\(effectiveSecret)"
    return "\(percentEncodedFragmentPrefix(fragment))?\(query)"
  }

  private static func queryByUpdatingSecret(_ secret: String?, in query: String) -> String? {
    var components = URLComponents()
    components.query = query.isEmpty ? nil : query
    var items = components.queryItems ?? []
    items.removeAll { $0.name.caseInsensitiveCompare("secret") == .orderedSame }
    if let secret {
      items.append(URLQueryItem(name: "secret", value: secret))
    }
    components.queryItems = items.isEmpty ? nil : items
    return components.percentEncodedQuery
  }

  private static func percentEncodedFragmentPrefix(_ value: String) -> String {
    var allowed = CharacterSet.urlFragmentAllowed
    allowed.remove(charactersIn: "%?")
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
  }

  @discardableResult
  func updateGlobalRuleOverlay(_ overlay: RuleOverlaySettings) async -> Bool {
    if let validationError = overlay.validationError {
      lastError = validationError
      return false
    }
    if let activeProfile = profileStore.activeProfile {
      do {
        var preflightOverrides = overrides
        preflightOverrides.ruleOverlay = overlay
        try await preflightEffectiveRuntimeConfig(
          profile: activeProfile,
          overrides: preflightOverrides
        )
      } catch {
        lastError = UserFacingError.message(for: error)
        return false
      }
    }
    ruleOverlaySettings = overlay
    guard let profileID = profileStore.activeProfileID, isRunning else {
      lastError = nil
      return true
    }
    do {
      try await reloadActiveRuntimeConfigIfNeeded(for: profileID, logMessage: "Rule overlay updated")
      lastError = nil
      return true
    } catch {
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  @discardableResult
  func saveRuntimeSnippet(_ snippet: RuntimeSnippet) async -> Bool {
    await runtimeSnippetLibrary.waitForLoad()
    if let validationError = snippet.validationError {
      lastError = validationError
      return false
    }
    var proposedSnippets = runtimeSnippetLibrary.snippets
    if let index = proposedSnippets.firstIndex(where: { $0.id == snippet.id }) {
      proposedSnippets[index] = snippet
    } else {
      proposedSnippets.append(snippet)
    }
    return await mutateRuntimeSnippetLibrary(logMessage: "Runtime snippet updated") {
      try await runtimeSnippetLibrary.saveSnippet(snippet)
    } proposedSnippets: {
      proposedSnippets
    }
  }

  @discardableResult
  func deleteRuntimeSnippet(_ snippet: RuntimeSnippet) async -> Bool {
    await runtimeSnippetLibrary.waitForLoad()
    let proposedSnippets = runtimeSnippetLibrary.snippets.filter { $0.id != snippet.id }
    return await mutateRuntimeSnippetLibrary(logMessage: "Runtime snippet deleted") {
      try await runtimeSnippetLibrary.deleteSnippet(id: snippet.id)
    } proposedSnippets: {
      proposedSnippets
    }
  }

  @discardableResult
  func setRuntimeSnippet(_ snippet: RuntimeSnippet, enabled: Bool) async -> Bool {
    await runtimeSnippetLibrary.waitForLoad()
    var proposedSnippets = runtimeSnippetLibrary.snippets
    if let index = proposedSnippets.firstIndex(where: { $0.id == snippet.id }) {
      proposedSnippets[index].enabled = enabled
      if let validationError = proposedSnippets[index].validationError {
        lastError = validationError
        return false
      }
    }
    return await mutateRuntimeSnippetLibrary(logMessage: "Runtime snippet toggled") {
      try await runtimeSnippetLibrary.setSnippetEnabled(id: snippet.id, enabled: enabled)
    } proposedSnippets: {
      proposedSnippets
    }
  }

  @discardableResult
  func moveRuntimeSnippet(fromOffsets source: IndexSet, toOffset destination: Int) async -> Bool {
    await runtimeSnippetLibrary.waitForLoad()
    var proposedSnippets = runtimeSnippetLibrary.snippets
    moveSnippets(&proposedSnippets, fromOffsets: source, toOffset: destination)
    return await mutateRuntimeSnippetLibrary(logMessage: "Runtime snippets reordered") {
      try await runtimeSnippetLibrary.moveSnippet(fromOffsets: source, toOffset: destination)
    } proposedSnippets: {
      proposedSnippets
    }
  }

  private func mutateRuntimeSnippetLibrary(
    logMessage: String,
    mutation: () async throws -> Void,
    proposedSnippets proposedSnippetsProvider: () -> [RuntimeSnippet]
  ) async -> Bool {
    await runtimeSnippetLibrary.waitForLoad()
    let activeProfileID = profileStore.activeProfileID
    let beforeSnippets = runtimeSnippetLibrary.snippets
    let beforeActiveSnippets = activeProfileID.map { runtimeSnippetLibrary.snippets(applyingTo: $0) } ?? []
    do {
      if let activeProfile = profileStore.activeProfile {
        let afterActiveSnippets = proposedSnippetsProvider().filter { $0.enabled && $0.applies(to: activeProfile.id) }
        if beforeActiveSnippets != afterActiveSnippets {
          try await preflightEffectiveRuntimeConfig(
            profile: activeProfile,
            runtimeSnippets: afterActiveSnippets
          )
        }
      }
      try await mutation()
      let afterActiveSnippets = activeProfileID.map { runtimeSnippetLibrary.snippets(applyingTo: $0) } ?? []
      if isRunning, let activeProfileID, beforeActiveSnippets != afterActiveSnippets {
        do {
          try await reloadActiveRuntimeConfigIfNeeded(for: activeProfileID, logMessage: logMessage)
        } catch {
          do {
            try await runtimeSnippetLibrary.replaceSnippets(beforeSnippets)
          } catch {
            appendAppLog(
              level: "error",
              message: "Runtime snippet rollback failed: \(UserFacingError.message(for: error))"
            )
          }
          throw error
        }
      }
      if beforeActiveSnippets != afterActiveSnippets {
        resetEffectiveRuntimeConfigPreviewIfNeeded(invalidatedProfileID: activeProfileID)
      }
      lastError = nil
      return true
    } catch {
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  private func moveSnippets(_ snippets: inout [RuntimeSnippet], fromOffsets source: IndexSet, toOffset destination: Int) {
    let indexed = Array(snippets.enumerated())
    let moving = indexed.filter { source.contains($0.offset) }.map(\.element)
    guard !moving.isEmpty else { return }
    var remaining = indexed.filter { !source.contains($0.offset) }.map(\.element)
    let removedBeforeDestination = source.filter { $0 < destination }.count
    let insertionIndex = min(max(destination - removedBeforeDestination, 0), remaining.count)
    remaining.insert(contentsOf: moving, at: insertionIndex)
    snippets = remaining
  }

  private func pruneRuntimeSnippetProfileBindings(validProfileIDs: Set<Profile.ID>) async {
    await runtimeSnippetLibrary.waitForLoad()
    do {
      _ = try await runtimeSnippetLibrary.removeMissingProfileBindings(validProfileIDs: validProfileIDs)
    } catch {
      appendAppLog(level: "warn", message: "Runtime snippet profile binding cleanup failed: \(UserFacingError.message(for: error))")
    }
  }

  @discardableResult
  func updateSubscription(_ profile: Profile, session: URLSession = .shared) async -> Bool {
    lastError = nil
    profileCoordinator.clearMessage()

    do {
      let updated = try await profileCoordinator.updateSubscription(
        profile,
        session: session,
        fetchOptions: subscriptionFetchOptions(for: profile),
        preflightValidator: subscriptionPreflightValidator()
      )
      if updated, profile.id == profileStore.activeProfileID {
        resetEffectiveRuntimeConfigPreviewIfNeeded(invalidatedProfileID: profile.id)
        restartPreviewRuntimeIfNeeded(reason: "subscription update")
      }
      return updated
    } catch {
      profileCoordinator.clearMessage()
      publishSubscriptionFailure(error)
      return false
    }
  }

  @discardableResult
  func updateSubscriptionSource(_ profile: Profile, urlString: String, session: URLSession = .shared) async -> Bool {
    let trimmedURLString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let resolution = SubscriptionURLResolver.resolve(rawInput: trimmedURLString) else {
      profileCoordinator.clearMessage()
      lastError = "Invalid subscription URL."
      return false
    }

    lastError = nil
    profileCoordinator.clearMessage()

    do {
      let updated = try await profileCoordinator.updateSubscriptionSource(
        profile,
        url: resolution.url,
        displayNameHint: resolution.displayNameHint,
        session: session,
        fetchOptions: subscriptionFetchOptions(for: profile),
        preflightValidator: subscriptionPreflightValidator()
      )
      if updated {
        resetEffectiveRuntimeConfigPreviewIfNeeded(invalidatedProfileID: profile.id)
      }
      return updated
    } catch {
      profileCoordinator.clearMessage()
      publishSubscriptionFailure(error)
      return false
    }
  }

  @discardableResult
  func updateSubscriptionProviderOptions(
    _ profile: Profile,
    options: SubscriptionProviderOptions
  ) async -> Bool {
    lastError = nil
    profileCoordinator.clearMessage()

    do {
      try await profileCoordinator.updateSubscriptionProviderOptions(
        profile,
        options: options,
        preflightValidator: subscriptionPreflightValidator()
      )
      resetEffectiveRuntimeConfigPreviewIfNeeded(invalidatedProfileID: profile.id)
      return true
    } catch {
      profileCoordinator.clearMessage()
      publishSubscriptionFailure(error)
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
      profileCoordinator.clearMessage()
      lastError = "Invalid subscription URL."
      return false
    }

    lastError = nil
    profileCoordinator.clearMessage()

    do {
      let updated = try await profileCoordinator.updateSubscriptionSourceAndProviderOptions(
        profile,
        url: resolution.url,
        displayNameHint: resolution.displayNameHint,
        options: options,
        session: session,
        fetchOptions: options.fetchOptions(from: subscriptionFetchOptions),
        preflightValidator: subscriptionPreflightValidator()
      )
      if updated {
        resetEffectiveRuntimeConfigPreviewIfNeeded(invalidatedProfileID: profile.id)
      }
      return updated
    } catch {
      profileCoordinator.clearMessage()
      publishSubscriptionFailure(error)
      return false
    }
  }

  @discardableResult
  func renameActiveProfile(to name: String) async -> Bool {
    do {
      try await profileCoordinator.renameActiveProfile(to: name)
      lastError = nil
      return true
    } catch {
      profileCoordinator.clearMessage()
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
      try await profileCoordinator.renameProfile(profile, to: name)
      lastError = nil
      return true
    } catch {
      profileCoordinator.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  @discardableResult
  func resetSubscriptionName(_ profile: Profile) async -> Bool {
    do {
      try await profileCoordinator.resetSubscriptionName(profile)
      lastError = nil
      return true
    } catch {
      profileCoordinator.clearMessage()
      lastError = UserFacingError.message(for: error)
      return false
    }
  }

  func deleteActiveProfile() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await profileCoordinator.deleteActiveProfile()
        restartPreviewRuntimeIfNeeded(reason: "active profile deletion")
        lastError = nil
      } catch {
        profileCoordinator.clearMessage()
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
      try await profileCoordinator.deleteProfile(profile)
      resetEffectiveRuntimeConfigPreviewIfNeeded(invalidatedProfileID: profile.id)
      restartPreviewRuntimeIfNeeded(reason: "profile deletion")
      lastError = nil
      return true
    } catch {
      profileCoordinator.clearMessage()
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
    do {
      guard try await profileCoordinator.selectProfile(profile) else { return false }
      resetEffectiveRuntimeConfigPreview()
      restartPreviewRuntimeIfNeeded(reason: "profile selection")
      lastError = nil
      return true
    } catch {
      profileCoordinator.clearMessage()
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

  private let bundledCoreInfo = BundledCoreInfo()

  private var subscriptionFetchOptions: SubscriptionFetchOptions {
    settings.subscriptionFetchSettings.fetchOptions(
      currentMixedPort: currentRuntimeMixedPort,
      compatibilityUserAgent: bundledCoreInfo.subscriptionCompatibilityUserAgent
    )
  }

  private func subscriptionFetchOptions(for profile: Profile) -> SubscriptionFetchOptions {
    profile.subscriptionProviderOptions.fetchOptions(from: subscriptionFetchOptions)
  }

  private func reloadActiveRuntimeConfigIfNeeded(for profileID: Profile.ID, logMessage: String) async throws {
    guard profileID == profileStore.activeProfileID, let apiClient else {
      return
    }
    if previewRuntimeActive {
      do {
        try await reloadPreviewRuntimeConfig(apiClient: apiClient, logMessage: logMessage)
      } catch {
        appendAppLog(level: "debug", message: "Preview runtime reload unavailable: \(UserFacingError.message(for: error))")
      }
      return
    }
    guard isCoreRunning else { return }
    let materialization: RuntimeConfigMaterializationResult
    if proxyRoutingMode == .tun {
      materialization = try await materializeTunRuntimeConfig(tunSettings)
    } else {
      materialization = try await materializeNonTunRuntimeConfig()
    }
    let runtimeConfig = materialization.runtimeConfigURL
    try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
    activateRuntimeArtifacts(materialization)
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
      },
      runtimeSnippetsProvider: { [weak self] profileID in
        guard let self, let profileID else { return [] }
        await self.runtimeSnippetLibrary.waitForLoad()
        return self.runtimeSnippetLibrary.snippets(applyingTo: profileID)
      }
    )
  }

  func start() {
    start(userInitiated: true)
  }

  private func startFromNetworkPolicy() {
    start(userInitiated: false)
  }

  private func start(userInitiated: Bool) {
    if userInitiated {
      clearNetworkPolicyRestoreSnapshotForUserChange()
    }
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
    let runtimeOwnerForStart: RuntimeOwner = shouldUseTun ? .tunnel : (shouldUseNetworkExtension ? .networkExtension : .user)
    var runtimeOverrides = overrides
    runtimeOverrides.tunEnabled = shouldUseTun
    runtimeOverrides.tunSettings = tunSettings
    let startSnapshot = AppliedRuntimeSettingsSnapshot(
      overrides: runtimeOverrides,
      proxyRoutingMode: routingMode,
      systemProxySettings: systemProxySettings,
      networkExtensionRoutingSettings: networkExtensionSettings,
      runtimeOwner: runtimeOwnerForStart,
      appliedAt: Date()
    )
    let runtimeConfigOptions = RuntimeConfigOptions(
      networkExtensionRoutingSettings: shouldUseNetworkExtension ? networkExtensionSettings : nil
    )
    systemProxyEnabled = false
    tunEnabled = false
    stopTunDiagnostics(clear: true)
    let materialization = try await generateRuntimeConfig(
      for: profile,
      overrides: startSnapshot.overrides,
      selections: previewSelections,
      options: runtimeConfigOptions
    )
    let runtimeConfig = materialization.runtimeConfigURL
    let coreURL = try bundledCoreURL()
    appendAppLog(level: "info", message: "Runtime config path: \(runtimeConfig.path)")
    appendAppLog(level: "info", message: "Mihomo core path: \(coreURL.path)")
    let client = MihomoAPIClient(baseURL: try startSnapshot.overrides.endpoint.baseURL, secret: startSnapshot.overrides.secret)
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
        secret: startSnapshot.overrides.secret
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
        let version = try await tunnelReadinessProbe.waitUntilReady(api: startSnapshot.overrides.endpoint)
        appendAppLog(level: "info", message: "TUN Mihomo controller ready: \(startSnapshot.overrides.endpoint.host):\(startSnapshot.overrides.endpoint.port), version \(version)")
        if startSnapshot.overrides.tunSettings.systemDNSOverrideEnabled {
          try await applyTunSystemDNS(startSnapshot.overrides.tunSettings)
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
      activateRuntimeArtifacts(materialization)
      refreshTunDiagnostics(includeExternal: true, runtimeOverrides: startSnapshot.overrides)
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
        api: startSnapshot.overrides.endpoint,
        proxyPort: startSnapshot.overrides.mixedPort
      )
      activateRuntimeArtifacts(materialization)
      runtimeOwner = .user
      publishStartupDiagnostics()
    }
    try Task.checkCancellation()

    if shouldUseNetworkExtension {
      try await proxyPortReadinessProbe.waitUntilReady(host: "127.0.0.1", port: startSnapshot.overrides.mixedPort)
      if networkExtensionSettings.dnsCaptureEnabled {
        try await proxyPortReadinessProbe.waitUntilOpen(
          host: NetworkExtensionRoutingSettings.defaultDNSListenHost,
          port: networkExtensionSettings.normalizedDNSListenPort,
          serviceName: "Mihomo DNS"
        )
      }
      appendAppLog(level: "info", message: "Starting NE transparent proxy; System Proxy off, TUN helper untouched.")
      try await networkExtensionController.startTransparentProxy(
        configuration: .clashMax(overrides: startSnapshot.overrides, routingSettings: networkExtensionSettings)
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
      try await applySystemProxySettings(startSnapshot)
      systemProxyEnabled = true
      try await activateSystemProxyGuardIfNeeded(startSnapshot)
    }
    try Task.checkCancellation()
    sessionStartedAt = Date()
    await refreshProfilePreviewAndWait()
    recordAppliedRuntimeSettingsSnapshot(startSnapshot)
    runtimeSettingsApplyState = .idle
    startStreams(client: client, logLevel: startSnapshot.overrides.logLevel)
    reloadRuntimeData(clearAfterConfirmation: !previewSelections.isEmpty)
    refreshPublicIPInfo()
  }

  func stop() {
    clearNetworkPolicyRestoreSnapshotForUserChange()
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
    restart(preserveNetworkPolicyRestoreSnapshot: false)
  }

  private func restart(preserveNetworkPolicyRestoreSnapshot: Bool) {
    if !preserveNetworkPolicyRestoreSnapshot {
      clearNetworkPolicyRestoreSnapshotForUserChange()
    }
    startTask?.cancel()
    startTask = nil
    startInFlight = false
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await stopRuntimeCoordinated()
      handleStopResult(result)
      guard result.succeeded else { return }
      start(userInitiated: !preserveNetworkPolicyRestoreSnapshot)
    }
  }

  func setProxyRoutingMode(
    _ mode: ProxyRoutingMode,
    preserveNetworkPolicyRestoreSnapshotOnRestart: Bool = false
  ) {
    guard proxyRoutingMode != mode else { return }
    appNotice = nil
    let shouldRestart = isRunning || startInFlight
    if mode != .systemProxy, systemProxyEnabled {
      stopSystemProxyGuard()
      // Serialize System Proxy teardown ahead of the runtime transition: only
      // switch mode / start / restart the runtime once restoration SUCCEEDS. If
      // it fails we stay in System Proxy (handled below) — otherwise (issue #19)
      // TUN can come up while macOS still points HTTP/HTTPS at a dead ClashMax
      // port and apps time out.
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          _ = try await restoreSystemProxyState(disableWhenNoSnapshot: true)
        } catch {
          // Restore failed: macOS may still route through a ClashMax local port.
          // Do NOT switch modes or start/restart the runtime — that would bring
          // TUN/core up behind a dead System Proxy (issue #19). Stay in the
          // current System Proxy state (re-arm its guard) and surface the failure.
          try? await activateSystemProxyGuardIfNeeded()
          let detail = UserFacingError.message(for: error)
          lastError = detail
          appNotice = AppNotice(
            message: String(
              format: String(localized: "Could not turn off the System Proxy: %@. It stayed on, so your network still routes through ClashMax. Try again, or disable it in System Settings."),
              detail
            ),
            tone: .info
          )
          return
        }
        systemProxyEnabled = false
        applyProxyRoutingModeTransition(
          to: mode,
          shouldRestart: shouldRestart,
          preserveNetworkPolicyRestoreSnapshotOnRestart: preserveNetworkPolicyRestoreSnapshotOnRestart
        )
      }
      return
    }
    applyProxyRoutingModeTransition(
      to: mode,
      shouldRestart: shouldRestart,
      preserveNetworkPolicyRestoreSnapshotOnRestart: preserveNetworkPolicyRestoreSnapshotOnRestart
    )
  }

  /// Applies the published mode change and any TUN/helper/core (re)start the new
  /// routing mode requires. When leaving an enabled System Proxy this runs only
  /// after `restoreSystemProxyState` has resolved, so runtime startup is
  /// serialized behind System Proxy cleanup (issue #19).
  private func applyProxyRoutingModeTransition(
    to mode: ProxyRoutingMode,
    shouldRestart: Bool,
    preserveNetworkPolicyRestoreSnapshotOnRestart: Bool
  ) {
    proxyRoutingMode = mode
    if mode == .tun {
      resumeInitialTunHelperPromptDeferralForExplicitAction()
      if tunHelperPreparationState.allowsStartAttempt, !shouldRestart {
        lastError = nil
      } else {
        prepareTunHelperIfNeeded(
          force: true,
          restartWhenReady: shouldRestart,
          preserveNetworkPolicyRestoreSnapshotOnRestart: preserveNetworkPolicyRestoreSnapshotOnRestart
        )
      }
    } else {
      cancelTunHelperPreparation(resetState: true)
    }
    if mode != .tun, shouldRestart {
      restart(preserveNetworkPolicyRestoreSnapshot: preserveNetworkPolicyRestoreSnapshotOnRestart)
    }
  }

  func setDeveloperMode(_ enabled: Bool) {
    settings.developerMode = enabled
    if enabled {
      appNotice = nil
      installGlobalShortcuts(settings.globalShortcutSettings)
    } else {
      globalShortcutManager.stop()
      shortcutRegistrationStatus = nil
    }
  }

  func setMixedPort(_ port: Int) {
    updateRuntimeOverridesForAutoApply(reason: "Mixed Port updated") { overrides in
      overrides.mixedPort = port
    }
  }

  func setAllowLAN(_ enabled: Bool) {
    updateRuntimeOverridesForAutoApply(reason: "Allow LAN updated") { overrides in
      overrides.allowLan = enabled
    }
  }

  func setDNSOverrideEnabled(_ enabled: Bool) {
    updateRuntimeOverridesForAutoApply(reason: "DNS override updated") { overrides in
      overrides.dnsEnabled = enabled
    }
  }

  func setLogLevel(_ level: String) {
    updateRuntimeOverridesForAutoApply(reason: "Log Level updated") { overrides in
      overrides.logLevel = level
    }
  }

  @discardableResult
  func updateExternalControllerSettings(_ newSettings: ExternalControllerSettings) -> Bool {
    if let validationError = newSettings.validationError {
      lastError = validationError
      return false
    }
    seedAppliedRuntimeSettingsSnapshotIfNeeded()
    externalControllerSettings = newSettings
    scheduleRunningRuntimeSettingsApply(reason: "Controller settings updated")
    return true
  }

  private func updateRuntimeOverridesForAutoApply(
    reason: String,
    update: (inout RuntimeOverrides) -> Void
  ) {
    seedAppliedRuntimeSettingsSnapshotIfNeeded()
    var updated = overrides
    update(&updated)
    guard updated != overrides else { return }
    overrides = updated
    scheduleRunningRuntimeSettingsApply(reason: reason)
  }

  private func scheduleRunningRuntimeSettingsApply(reason: String) {
    guard canApplyRuntimeSettingsToCurrentRuntime else {
      runtimeSettingsApplyState = .idle
      return
    }
    runtimeSettingsApplyTask?.cancel()
    let token = UUID()
    runtimeSettingsApplyToken = token
    runtimeSettingsApplyState = .pending
    runtimeSettingsApplyTask = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await Task.sleep(nanoseconds: 50_000_000)
      } catch {
        return
      }
      guard self.runtimeSettingsApplyToken == token, !Task.isCancelled else { return }
      self.runtimeSettingsApplyState = .applying
      defer {
        if self.runtimeSettingsApplyToken == token {
          self.runtimeSettingsApplyTask = nil
          self.runtimeSettingsApplyToken = nil
        }
      }
      do {
        try await self.applyRunningRuntimeSettings(reason: reason)
        guard self.runtimeSettingsApplyToken == token, !Task.isCancelled else { return }
        self.runtimeSettingsApplyState = .idle
        self.lastError = nil
      } catch is CancellationError {
        return
      } catch RuntimeSettingsApplyFailure.followUpFailed(let message) {
        guard self.runtimeSettingsApplyToken == token else { return }
        self.runtimeSettingsApplyState = .appliedWithFollowUpFailure(message)
        self.lastError = String(
          format: String(localized: "Runtime settings applied, but proxy readiness or system proxy setup failed: %@"),
          message
        )
      } catch {
        guard self.runtimeSettingsApplyToken == token else { return }
        let message = UserFacingError.message(for: error)
        self.runtimeSettingsApplyState = .failed(message)
        self.lastError = String(
          format: String(localized: "Runtime settings saved but could not be applied: %@"),
          message
        )
      }
    }
  }

  private func applyRunningRuntimeSettings(reason: String) async throws {
    let target = makeRuntimeSettingsSnapshot()
    switch target.runtimeOwner {
    case .tunnel:
      try await applyRunningTunSettings(
        target.overrides.tunSettings,
        runtimeOverrides: target.overrides,
        reason: reason
      )
      recordAppliedRuntimeSettingsSnapshot(target)
    case .networkExtension:
      if networkExtensionRuntimeRestartRequired(for: target) {
        try await restartRuntimeForSettingsApply(reason: reason)
      } else {
        try await applyRunningNonTunRuntimeSettings(target, reason: reason)
      }
    case .user:
      try await applyRunningNonTunRuntimeSettings(target, reason: reason)
    case .preview, .stopped:
      return
    }
  }

  private func networkExtensionRuntimeRestartRequired(for target: AppliedRuntimeSettingsSnapshot) -> Bool {
    guard target.proxyRoutingMode == .neProxy || target.runtimeOwner == .networkExtension else {
      return false
    }
    guard let applied = settings.appliedRuntimeSettingsSnapshot else {
      return false
    }
    return applied.overrides.mixedPort != target.overrides.mixedPort
      || applied.overrides.endpoint != target.overrides.endpoint
  }

  private func applyRunningNonTunRuntimeSettings(
    _ target: AppliedRuntimeSettingsSnapshot,
    reason: String
  ) async throws {
    guard let currentClient = apiClient else {
      throw AppError.helperResponse(proxyRuntimeActionMessage)
    }
    let previouslyAppliedEndpoint = settings.appliedRuntimeSettingsSnapshot?.overrides.endpoint
    let materialization = try await materializeNonTunRuntimeConfig(target)
    let runtimeConfig = materialization.runtimeConfigURL
    try await currentClient.reloadConfig(path: runtimeConfig.path, force: true)
    activateRuntimeArtifacts(materialization)
    recordAppliedRuntimeSettingsSnapshot(target)
    appendAppLog(level: "info", message: "\(reason): Mihomo reloaded \(runtimeConfig.path).")

    let clientForRuntime: any MihomoAPIControlling
    if let appliedEndpoint = previouslyAppliedEndpoint,
       appliedEndpoint != target.overrides.endpoint {
      clientForRuntime = MihomoAPIClient(baseURL: try target.overrides.endpoint.baseURL, secret: target.overrides.secret)
    } else {
      clientForRuntime = currentClient
    }
    apiClient = clientForRuntime

    do {
      try await proxyPortReadinessProbe.waitUntilReady(host: "127.0.0.1", port: target.overrides.mixedPort)

      if target.proxyRoutingMode == .systemProxy || systemProxyEnabled {
        try await applySystemProxySettings(target)
        systemProxyEnabled = true
        try await activateSystemProxyGuardIfNeeded(target)
      }

      if target.runtimeOwner == .networkExtension,
         target.networkExtensionRoutingSettings.dnsCaptureEnabled {
        try await proxyPortReadinessProbe.waitUntilOpen(
          host: NetworkExtensionRoutingSettings.defaultDNSListenHost,
          port: target.networkExtensionRoutingSettings.normalizedDNSListenPort,
          serviceName: "Mihomo DNS"
        )
      }
    } catch {
      let message = UserFacingError.message(for: error)
      appendAppLog(level: "warn", message: "\(reason): post-reload setup failed: \(message)")
      throw RuntimeSettingsApplyFailure.followUpFailed(message)
    }

    startStreams(client: clientForRuntime, logLevel: target.overrides.logLevel)
    reloadRuntimeData()
  }

  private func restartRuntimeForSettingsApply(reason: String) async throws {
    appendAppLog(level: "info", message: "\(reason): restarting runtime to apply controller or proxy port changes.")
    let stopResult = await stopRuntimeCoordinated(.settingsApplyRestart)
    handleStopResult(stopResult)
    guard stopResult.succeeded else {
      throw AppError.coreStopFailed(stopResult.userFacingMessage ?? "Could not stop runtime before applying settings.")
    }
    startInFlight = true
    defer { startInFlight = false }
    do {
      try await withTimeout(seconds: Self.startWallClockSeconds) { @Sendable [weak self] in
        guard let self else { return }
        try await self.runStartSequence()
      }
    } catch {
      handleStopResult(await stopRuntimeCoordinated())
      throw error
    }
  }

  func setMode(_ mode: RunMode) {
    guard overrides.mode != mode else { return }
    seedAppliedRuntimeSettingsSnapshotIfNeeded()
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
        guard modeUpdateToken == token, !Task.isCancelled else { return }
        recordAppliedRuntimeSettingsSnapshot(makeRuntimeSettingsSnapshot())
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
    seedAppliedRuntimeSettingsSnapshotIfNeeded()
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
        guard ipv6UpdateToken == token, !Task.isCancelled else { return }
        recordAppliedRuntimeSettingsSnapshot(makeRuntimeSettingsSnapshot())
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
    let materialization = try await materializeNonTunRuntimeConfig()
    let runtimeConfig = materialization.runtimeConfigURL
    try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
    activateRuntimeArtifacts(materialization)
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

  private func materializeNonTunRuntimeConfig(
    _ snapshot: AppliedRuntimeSettingsSnapshot? = nil
  ) async throws -> RuntimeConfigMaterializationResult {
    let profile = try requireActiveProfile()
    var runtimeOverrides = snapshot?.overrides ?? overrides
    runtimeOverrides.tunEnabled = false
    let isNetworkExtensionRuntime = snapshot?.runtimeOwner == .networkExtension
      || snapshot?.proxyRoutingMode == .neProxy
      || proxyRoutingMode == .neProxy
      || runtimeOwner == .networkExtension
      || networkExtensionController.vpnStatus.isActive
    let options = RuntimeConfigOptions(
      networkExtensionRoutingSettings: isNetworkExtensionRuntime
        ? (snapshot?.networkExtensionRoutingSettings ?? networkExtensionRoutingSettings)
        : nil
    )
    return try await generateRuntimeConfig(
      for: profile,
      overrides: runtimeOverrides,
      selections: previewSelections,
      options: options
    )
  }

  private func makePreviewRuntimeOverrides(secret: String = UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> RuntimeOverrides {
    var previewOverrides = overrides
    previewOverrides.mixedPort = Self.previewRuntimeMixedPort
    previewOverrides.externalControllerHost = "127.0.0.1"
    previewOverrides.externalControllerPort = Self.previewRuntimeControllerPort
    previewOverrides.secret = secret
    previewOverrides.allowLan = false
    previewOverrides.mode = .direct
    previewOverrides.tunEnabled = false
    previewOverrides.externalControllerCORS = ExternalControllerCORSSettings(
      enabled: false,
      allowPrivateNetwork: false,
      allowedOrigins: []
    )
    return previewOverrides
  }

  private func materializePreviewRuntimeConfig(
    for profile: Profile,
    overrides previewOverrides: RuntimeOverrides
  ) async throws -> RuntimeConfigMaterializationResult {
    try await generateRuntimeConfig(
      for: profile,
      overrides: previewOverrides,
      selections: previewSelections
    )
  }

  private func reloadPreviewRuntimeConfig(
    apiClient: any MihomoAPIControlling,
    logMessage: String
  ) async throws {
    let profile = try requireActiveProfile()
    guard let previewOverrides = previewRuntimeOverrides else {
      appendAppLog(level: "debug", message: "\(logMessage) preview runtime reload skipped because preview settings are unavailable.")
      return
    }
    let materialization = try await materializePreviewRuntimeConfig(
      for: profile,
      overrides: previewOverrides
    )
    let runtimeConfig = materialization.runtimeConfigURL
    try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
    activateRuntimeArtifacts(materialization)
    appendAppLog(level: "debug", message: "\(logMessage) preview runtime reloaded \(runtimeConfig.path).")
    reloadRuntimeData()
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
    clearNetworkPolicyRestoreSnapshotForUserChange()
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

  func refreshCurrentNetworkPolicyState() {
    let ssid = currentNetworkProvider.currentSSID()
    currentNetworkSSID = ssid
    guard let ssid else {
      networkPolicyStatusMessage = String(localized: "No Wi-Fi SSID detected.")
      return
    }
    if let rule = networkPolicySettings.matchingRule(ssid: ssid) {
      networkPolicyStatusMessage = String(
        format: String(localized: "Current network %@ matches %@."),
        ssid,
        rule.name
      )
    } else {
      networkPolicyStatusMessage = String(
        format: String(localized: "No saved policy matches %@."),
        ssid
      )
    }
  }

  func applyMatchingNetworkPolicyForCurrentNetwork() {
    applyMatchingNetworkPolicyForCurrentNetwork(trigger: "manual")
  }

  func handleNetworkEnvironmentMayHaveChanged(reason: String) {
    guard networkPolicySettings.autoApplyEnabled else {
      networkPolicyStatusMessage = String(localized: "Automatic network policy application is off.")
      return
    }
    guard !networkPolicySettings.rules.isEmpty else { return }
    scheduleNetworkEnvironmentPolicyApply(reason: reason)
  }

  func startNetworkEnvironmentMonitoring() {
    guard networkEnvironmentTask == nil, let networkEnvironmentMonitor else { return }
    networkEnvironmentMonitor.start()
    networkEnvironmentTask = Task { @MainActor [weak self, networkEnvironmentMonitor] in
      for await event in networkEnvironmentMonitor.events {
        guard let self, !Task.isCancelled else { return }
        currentNetworkSSID = event.ssid ?? currentNetworkProvider.currentSSID()
        appendAppLog(
          level: "info",
          message: "Network environment changed via \(event.reason): path=\(event.pathStatus), ssid=\(event.ssid ?? "none")"
        )
        handleNetworkEnvironmentMayHaveChanged(reason: event.reason)
      }
    }
  }

  func stopNetworkEnvironmentMonitoring() {
    networkEnvironmentDebounceTask?.cancel()
    networkEnvironmentDebounceTask = nil
    networkEnvironmentTask?.cancel()
    networkEnvironmentTask = nil
    networkEnvironmentMonitor?.stop()
  }

  func applyNetworkPolicy(_ rule: NetworkPolicyRule) {
    clearNetworkPolicyRestoreSnapshotForUserChange()
    applyNetworkPolicy(rule, trigger: "manual", matchedSSID: nil)
  }

  private func applyMatchingNetworkPolicyForCurrentNetwork(trigger: String) {
    let ssid = currentNetworkProvider.currentSSID()
    currentNetworkSSID = ssid
    guard let ssid else {
      let message = String(localized: "No Wi-Fi SSID detected.")
      networkPolicyStatusMessage = message
      let didScheduleRestore = restoreNetworkPolicyStateIfNeeded(reason: message)
      if trigger == "manual", !didScheduleRestore {
        appNotice = AppNotice(message: message, tone: .info)
      }
      return
    }
    guard let rule = networkPolicySettings.matchingRule(ssid: ssid) else {
      let message = String(format: String(localized: "No saved policy matches %@."), ssid)
      networkPolicyStatusMessage = message
      let didScheduleRestore = restoreNetworkPolicyStateIfNeeded(reason: message)
      if trigger == "manual", !didScheduleRestore {
        appNotice = AppNotice(message: message, tone: .info)
      }
      return
    }
    applyNetworkPolicy(rule, trigger: trigger, matchedSSID: ssid)
  }

  private func scheduleNetworkEnvironmentPolicyApply(reason: String) {
    networkEnvironmentDebounceTask?.cancel()
    networkEnvironmentDebounceTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(nanoseconds: 650_000_000)
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      applyMatchingNetworkPolicyForCurrentNetwork(trigger: reason)
    }
  }

  private func applyNetworkPolicy(_ rule: NetworkPolicyRule, trigger: String, matchedSSID: String?) {
    networkPolicyApplyTask?.cancel()
    let token = UUID()
    networkPolicyApplyToken = token
    networkPolicyApplyTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.networkPolicyApplyToken == token {
          self.networkPolicyApplyTask = nil
          self.networkPolicyApplyToken = nil
        }
      }
      guard !Task.isCancelled else { return }
      await self.applyNetworkPolicyRule(rule, trigger: trigger, matchedSSID: matchedSSID)
    }
  }

  private func applyNetworkPolicyRule(_ rule: NetworkPolicyRule, trigger: String, matchedSSID: String?) async {
    if let validationError = rule.validationError {
      networkPolicyStatusMessage = validationError
      lastError = validationError
      return
    }

    let automatic = trigger != "manual"
    let policyStartedRuntime = rule.autoStartRuntime && !isRunning && !startInFlight
    if automatic, networkPolicySettings.unmatchedBehavior == .restorePreviousState, networkPolicyRestoreSnapshot == nil {
      networkPolicyRestoreSnapshot = NetworkPolicyRestoreSnapshot(
        policyID: rule.id,
        ssid: matchedSSID ?? rule.ssid,
        proxyRoutingMode: proxyRoutingMode,
        systemProxyEnabled: systemProxyEnabled,
        runtimeWasRunning: isRunning || startInFlight || canStopRuntime,
        policyStartedRuntime: policyStartedRuntime
      )
    }

    setProxyRoutingMode(
      rule.proxyRoutingMode,
      preserveNetworkPolicyRestoreSnapshotOnRestart: automatic
    )
    if rule.autoStartRuntime, !isRunning, !startInFlight {
      startFromNetworkPolicy()
      await waitForRuntimeStartAttempt()
    }
    if rule.proxyRoutingMode == .systemProxy, rule.enableSystemProxy {
      do {
        try await applySystemProxyEnabledState(true)
      } catch {
        let message = UserFacingError.message(for: error)
        networkPolicyStatusMessage = message
        lastError = message
        return
      }
    }
    guard !Task.isCancelled else { return }

    lastAppliedNetworkPolicyID = rule.id
    let message: String
    if let matchedSSID {
      message = String(
        format: String(localized: "Applied %@ for %@."),
        rule.name,
        matchedSSID
      )
    } else {
      message = String(format: String(localized: "Applied %@."), rule.name)
    }
    networkPolicyStatusMessage = message
    appNotice = AppNotice(message: message, tone: .success)
    appendAppLog(
      level: "info",
      message: "Applied network policy \(rule.name) via \(trigger): \(rule.proxyRoutingMode.rawValue), autoStart=\(rule.autoStartRuntime)"
    )
  }

  @discardableResult
  private func restoreNetworkPolicyStateIfNeeded(reason: String) -> Bool {
    guard networkPolicySettings.unmatchedBehavior == .restorePreviousState,
          let snapshot = networkPolicyRestoreSnapshot
    else { return false }
    networkPolicyApplyTask?.cancel()
    let token = UUID()
    networkPolicyApplyToken = token
    networkPolicyApplyTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if self.networkPolicyApplyToken == token {
          self.networkPolicyApplyTask = nil
          self.networkPolicyApplyToken = nil
        }
      }
      await self.restoreNetworkPolicyState(snapshot, reason: reason)
    }
    return true
  }

  private func restoreNetworkPolicyState(_ snapshot: NetworkPolicyRestoreSnapshot, reason: String) async {
    setProxyRoutingMode(
      snapshot.proxyRoutingMode,
      preserveNetworkPolicyRestoreSnapshotOnRestart: true
    )
    do {
      if systemProxyEnabled != snapshot.systemProxyEnabled {
        try await applySystemProxyEnabledState(snapshot.systemProxyEnabled)
      }
      if snapshot.policyStartedRuntime, !snapshot.runtimeWasRunning, canStopRuntime {
        let result = await stopRuntimeCoordinated()
        handleStopResult(result)
        guard result.succeeded else {
          networkPolicyStatusMessage = result.userFacingMessage
          lastError = result.userFacingMessage
          return
        }
      }
      networkPolicyRestoreSnapshot = nil
      lastAppliedNetworkPolicyID = nil
      let message = String(
        format: String(localized: "%@ Restored previous network state after leaving %@."),
        reason,
        snapshot.ssid
      )
      networkPolicyStatusMessage = message
      appNotice = AppNotice(message: message, tone: .info)
      appendAppLog(level: "info", message: "Restored network policy state after leaving \(snapshot.ssid).")
    } catch {
      let message = UserFacingError.message(for: error)
      networkPolicyStatusMessage = message
      lastError = message
    }
  }

  private func clearNetworkPolicyRestoreSnapshotForUserChange() {
    networkPolicyRestoreSnapshot = nil
  }

  private func waitForRuntimeStartAttempt() async {
    for _ in 0..<80 {
      guard startInFlight else { return }
      do {
        try await Task.sleep(nanoseconds: 50_000_000)
      } catch {
        return
      }
    }
  }

  func registerHelper() {
    prepareTunHelperIfNeeded(force: true)
  }

  func warmTunHelperRegistrationOnLaunch() {
    guard !didWarmTunHelperRegistrationOnLaunch else { return }
    let serviceStatus = helperClient.serviceStatus
    if shouldDeferInitialTunHelperPromptDuringSilentStart(serviceStatus) {
      didWarmTunHelperRegistrationOnLaunch = true
      deferInitialTunHelperPromptDuringSilentStart()
      return
    }
    if shouldPresentInitialTunHelperPromptBeforeWarmup(serviceStatus) {
      didWarmTunHelperRegistrationOnLaunch = true
      presentInitialTunHelperPrompt(for: serviceStatus)
      return
    }
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

  func evaluateInitialTunHelperPromptOnLaunch() {
    guard !settings.initialTunHelperPromptHandled else {
      initialTunHelperPrompt = nil
      return
    }
    let serviceStatus = helperClient.serviceStatus
    if shouldDeferInitialTunHelperPromptDuringSilentStart(serviceStatus) {
      deferInitialTunHelperPromptDuringSilentStart()
      return
    }
    presentInitialTunHelperPrompt(for: serviceStatus)
  }

  func resumeDeferredInitialTunHelperPromptAfterUserOpen() {
    guard initialTunHelperPromptDeferredDuringSilentStart else { return }
    didResumeInitialTunHelperPromptAfterUserOpen = true
    initialTunHelperPromptDeferredDuringSilentStart = false
    guard !settings.initialTunHelperPromptHandled else {
      initialTunHelperPrompt = nil
      return
    }
    presentInitialTunHelperPrompt(for: helperClient.serviceStatus)
  }

  func installInitialTunHelper() {
    guard !initialTunHelperPromptActionInFlight else { return }
    initialTunHelperPromptActionInFlight = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        initialTunHelperPromptActionInFlight = false
      }
      do {
        lastError = nil
        try await helperClient.register()
        await updateTunHelperStatusDetail()
        syncInitialTunHelperPromptAfterUserAction()
      } catch {
        let message = UserFacingError.message(for: error)
        helperClient.statusMessage = message
        lastError = message
        if settings.initialTunHelperPromptHandled {
          initialTunHelperPrompt = nil
        } else {
          initialTunHelperPrompt = InitialTunHelperPrompt(
            primaryAction: .install,
            statusMessage: message
          )
        }
        await updateTunHelperStatusDetail()
      }
    }
  }

  func dismissInitialTunHelperPrompt() {
    settings.markInitialTunHelperPromptHandled()
    initialTunHelperPrompt = nil
    initialTunHelperPromptActionInFlight = false
  }

  private func shouldPresentInitialTunHelperPromptBeforeWarmup(_ status: TunnelHelperServiceStatus) -> Bool {
    guard !settings.initialTunHelperPromptHandled else { return false }
    switch status {
    case .notRegistered, .requiresApproval:
      return true
    case .enabled:
      settings.markInitialTunHelperPromptHandled()
      return false
    case .notFound, .unknown:
      return false
    }
  }

  private func shouldDeferInitialTunHelperPromptDuringSilentStart(_ status: TunnelHelperServiceStatus) -> Bool {
    guard settings.launchSettings.silentStart,
          !didResumeInitialTunHelperPromptAfterUserOpen,
          !settings.initialTunHelperPromptHandled
    else { return false }
    switch status {
    case .notRegistered, .requiresApproval:
      return true
    case .enabled, .notFound, .unknown:
      return false
    }
  }

  private func deferInitialTunHelperPromptDuringSilentStart() {
    initialTunHelperPromptDeferredDuringSilentStart = true
    initialTunHelperPrompt = nil
    initialTunHelperPromptActionInFlight = false
  }

  private func resumeInitialTunHelperPromptDeferralForExplicitAction() {
    didResumeInitialTunHelperPromptAfterUserOpen = true
    initialTunHelperPromptDeferredDuringSilentStart = false
    initialTunHelperPrompt = nil
  }

  private func presentInitialTunHelperPrompt(for status: TunnelHelperServiceStatus) {
    guard !settings.initialTunHelperPromptHandled else {
      initialTunHelperPrompt = nil
      return
    }
    switch status {
    case .notRegistered:
      initialTunHelperPrompt = InitialTunHelperPrompt(
        primaryAction: .install,
        statusMessage: TunnelHelperClient.statusMessage(for: .notRegistered)
      )
    case .requiresApproval:
      initialTunHelperPrompt = InitialTunHelperPrompt(
        primaryAction: .openSettings,
        statusMessage: TunnelHelperClient.statusMessage(for: .requiresApproval)
      )
    case .enabled:
      settings.markInitialTunHelperPromptHandled()
      initialTunHelperPrompt = nil
    case .notFound, .unknown:
      initialTunHelperPrompt = nil
    }
  }

  private func syncInitialTunHelperPromptAfterUserAction() {
    guard !settings.initialTunHelperPromptHandled else {
      initialTunHelperPrompt = nil
      return
    }
    switch helperClient.serviceStatus {
    case .enabled:
      settings.markInitialTunHelperPromptHandled()
      initialTunHelperPrompt = nil
      if proxyRoutingMode == .tun {
        refreshHelperRegistrationStatus()
      }
    case .requiresApproval:
      initialTunHelperPrompt = InitialTunHelperPrompt(
        primaryAction: .openSettings,
        statusMessage: TunnelHelperClient.statusMessage(for: .requiresApproval)
      )
      if proxyRoutingMode == .tun {
        refreshHelperRegistrationStatus()
      }
    case .notRegistered:
      initialTunHelperPrompt = InitialTunHelperPrompt(
        primaryAction: .install,
        statusMessage: TunnelHelperClient.statusMessage(for: .notRegistered)
      )
    case .notFound, .unknown:
      initialTunHelperPrompt = nil
    }
  }

  func warmPreviewRuntimeOnLaunch() {
    guard !didWarmPreviewRuntimeOnLaunch else { return }
    didWarmPreviewRuntimeOnLaunch = true
    previewRuntimeRequested = true
    schedulePreviewRuntimeStartIfReady()
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
    restartWhenReady: Bool = false,
    preserveNetworkPolicyRestoreSnapshotOnRestart: Bool = false
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
        restart(preserveNetworkPolicyRestoreSnapshot: preserveNetworkPolicyRestoreSnapshotOnRestart)
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
        restart(preserveNetworkPolicyRestoreSnapshot: preserveNetworkPolicyRestoreSnapshotOnRestart)
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
    let analyticsProfileID = profileStore.activeProfileID
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
        let knownDelayStates = proxyDelayStateMap(from: proxyGroups)
        let cachedRuntimeGroups = proxyGroups
        let runtimeGroups = try await apiClient.proxyGroups()
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        let refreshedProviders: [ProxyProvider]
        let didRefreshProviders: Bool
        do {
          refreshedProviders = try await apiClient.structuredProxyProviders()
          didRefreshProviders = true
        } catch {
          refreshedProviders = []
          didRefreshProviders = false
        }
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        proxyProviders = providersPreservingKnownDelayStates(refreshedProviders)
        let refreshedRuleProviders: [RuleProvider]
        let didRefreshRuleProviders: Bool
        do {
          refreshedRuleProviders = try await apiClient.ruleProviders()
          didRefreshRuleProviders = true
        } catch {
          refreshedRuleProviders = []
          didRefreshRuleProviders = false
        }
        guard runtimeReloadToken == token, !Task.isCancelled else { return }
        ruleProviders = refreshedRuleProviders
        providerAnalytics.recordSnapshots(
          profileID: analyticsProfileID,
          proxyProviders: didRefreshProviders ? refreshedProviders : nil,
          ruleProviders: didRefreshRuleProviders ? refreshedRuleProviders : nil
        )
        proxyGroups = enrichProxyGroupsWithKnownEndpoints(
          runtimeGroups,
          providers: refreshedProviders,
          cachedRuntimeGroups: cachedRuntimeGroups
        ).preservingKnownDelayStates(knownDelayStates, profileID: profileStore.activeProfileID)
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

  func refreshTunDiagnostics(
    includeExternal: Bool = true,
    runtimeOverrides: RuntimeOverrides? = nil
  ) {
    tunDiagnosticsTask?.cancel()
    guard runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning else {
      tunDiagnostics = .empty
      tunDiagnosticsTask = nil
      return
    }

    let runtimeOverrides = runtimeOverrides ?? currentRuntimeOverrides
    let api = runtimeOverrides.endpoint
    let settings = runtimeOverrides.tunSettings
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

  func selectProxy(group: ProxyGroup, node: ProxyNode, closeOldConnections: Bool = false) {
    guard node.isSelectable else {
      lastError = "\(node.name) cannot be selected from the runtime."
      return
    }
    guard group.allowsManualProxySelection else {
      lastError = "\(group.name) is managed automatically by Mihomo."
      return
    }
    let previousSelection = group.selected
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
          closeOldConnectionsIfNeeded(
            enabled: closeOldConnections,
            previousSelection: previousSelection,
            newSelection: node.name
          )
          lastError = nil
          reloadRuntimeData()
        } catch is CancellationError {
          return
        } catch {
          guard proxySelectionTokens[groupID] == token else { return }
          if previewRuntimeActive {
            restoreSelectedProxy(groupName: group.name, nodeName: previousSelection)
          }
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
    if let group = visibleProxyGroups.first(where: { group in
      group.nodes.contains { $0.id == node.id || $0.name == node.name }
    }) {
      testDelay(in: group, for: node)
      return
    }

    let fallbackGroup = ProxyGroup(name: "", type: "select", selected: nil, nodes: [node])
    testDelay(in: fallbackGroup, for: node)
  }

  func testDelay(in group: ProxyGroup, testURL: URL? = nil) {
    let selectableNodes = group.nodes.filter(\.isSelectable)
    guard !selectableNodes.isEmpty else {
      lastError = "\(group.name) has no selectable nodes to test."
      return
    }
    for node in selectableNodes {
      testDelay(in: group, for: node, testURL: testURL, reloadAfterCompletion: false)
    }
  }

  func testDelayForAllProxyGroups(testURL: URL? = nil) {
    startProxyDelayBatch(overrideTestURL: testURL)
  }

  func cancelProxyDelayBatch() {
    guard proxyDelayBatchProgress?.isRunning == true else { return }
    proxyDelayBatchTask?.cancel()
  }

  func updateProxyPageSettings(_ update: (inout ProxyPageSettings) -> Void) {
    var nextSettings = proxyPageSettings
    update(&nextSettings)
    proxyPageSettings = nextSettings
  }

  func customDelayTestURL(forGroupName groupName: String) -> URL? {
    proxyPageSettings.customDelayTestURL(forGroupName: groupName)
  }

  func testDelay(in group: ProxyGroup, for node: ProxyNode, testURL: URL? = nil) {
    testDelay(in: group, for: node, testURL: testURL, reloadAfterCompletion: true)
  }

  private func testDelay(
    in group: ProxyGroup,
    for node: ProxyNode,
    testURL: URL?,
    reloadAfterCompletion: Bool
  ) {
    guard node.isSelectable else {
      lastError = "\(node.name) cannot be tested from the runtime."
      return
    }
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    let settings = delayTestSettings
    let effectiveTestURL = testURL ?? customDelayTestURL(forGroupName: group.name) ?? AppConstants.defaultDelayTestURL
    let nodeKey = proxyNodeKey(group: group, node: node, testURL: effectiveTestURL)
    let taskKey = proxyDelayTaskKey(group: group, node: node)
    delayTestTasks[taskKey]?.cancel()
    let token = UUID()
    delayTestTokens[taskKey] = token
    applyDelayState(.testing, to: nodeKey)
    delayTestTasks[taskKey] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if delayTestTokens[taskKey] == token {
          delayTestTasks[taskKey] = nil
          delayTestTokens[taskKey] = nil
        }
      }
      do {
        let delay = try await measureDelay(for: node, apiClient: apiClient, settings: settings, testURL: effectiveTestURL)
        guard delayTestTokens[taskKey] == token, !Task.isCancelled else { return }
        applyDelayState(.measured(delay), to: nodeKey)
        if reloadAfterCompletion {
          reloadRuntimeData()
        }
      } catch is CancellationError {
        return
      } catch {
        guard delayTestTokens[taskKey] == token else { return }
        applyDelayState(delayState(for: error), to: nodeKey)
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  private func startProxyDelayBatch(overrideTestURL: URL?) {
    guard let apiClient = runtimeAPIClientForProxyAction() else { return }
    guard proxyDelayBatchTask == nil else { return }
    let items = visibleProxyGroups.flatMap { group in
      group.nodes.filter(\.isSelectable).map { node in
        let effectiveTestURL = overrideTestURL
          ?? customDelayTestURL(forGroupName: group.name)
          ?? AppConstants.defaultDelayTestURL
        return ProxyDelayBatchItem(
          groupName: group.name,
          node: node,
          nodeKey: proxyNodeKey(group: group, node: node, testURL: effectiveTestURL),
          taskKey: proxyDelayTaskKey(group: group, node: node),
          testURL: effectiveTestURL,
          previousState: node.resolvedDelayState,
          nativePingHost: nativePingHost(for: node)
        )
      }
    }
    guard !items.isEmpty else {
      lastError = "No selectable proxy groups to test."
      return
    }

    let settings = delayTestSettings
    let pingTester = pingTester
    let token = UUID()
    proxyDelayBatchToken = token
    proxyDelayBatchProgress = .started(total: items.count)
    // Issue #11: mark every node testing in one coalesced write instead of one publish per node.
    var testingStates: [ProxyNodeKey: ProxyDelayState] = [:]
    testingStates.reserveCapacity(items.count)
    for item in items {
      cancelDelayTestTask(for: item.taskKey)
      testingStates[item.nodeKey] = .testing
    }
    applyDelayStates(testingStates)

    proxyDelayBatchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.runProxyDelayBatch(
        items: items,
        apiClient: apiClient,
        settings: settings,
        pingTester: pingTester,
        token: token
      )
    }
  }

  private func runProxyDelayBatch(
    items: [ProxyDelayBatchItem],
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    pingTester: any PingTesting,
    token: UUID
  ) async {
    var completedKeys = Set<ProxyNodeKey>()
    // Issue #11: accumulate per-result node states and progress mutations, then publish them in
    // coalesced flushes (by count or elapsed time) instead of once per result, so the list stays
    // scrollable while "Test All" runs over a large catalog.
    var pendingStates: [ProxyNodeKey: ProxyDelayState] = [:]
    var pendingProgress: [(inout ProxyDelayBatchProgress) -> Void] = []
    var processedSinceFlush = 0
    var lastFlushNanos: UInt64 = 0
    defer {
      if proxyDelayBatchToken == token {
        proxyDelayBatchTask = nil
        proxyDelayBatchToken = nil
      }
    }

    func flushPending() {
      if !pendingStates.isEmpty {
        applyDelayStates(pendingStates)
        pendingStates.removeAll(keepingCapacity: true)
      }
      if !pendingProgress.isEmpty {
        let mutations = pendingProgress
        pendingProgress.removeAll(keepingCapacity: true)
        updateProxyDelayBatchProgress(token: token) { progress in
          for mutate in mutations {
            mutate(&progress)
          }
        }
      }
      processedSinceFlush = 0
      lastFlushNanos = DispatchTime.now().uptimeNanoseconds
    }

    func flushIfThresholdReached() {
      guard processedSinceFlush > 0 else { return }
      // A zero sentinel forces the very first result to flush immediately (so results start
      // appearing right away); subsequent results coalesce up to the count or time threshold.
      let elapsedMs = lastFlushNanos == 0
        ? .greatestFiniteMagnitude
        : Double(DispatchTime.now().uptimeNanoseconds &- lastFlushNanos) / 1_000_000
      if processedSinceFlush >= Self.proxyDelayBatchFlushCount
        || elapsedMs >= Self.proxyDelayBatchFlushIntervalMs {
        flushPending()
      }
    }

    await withTaskGroup(of: ProxyDelayBatchItemResult.self) { taskGroup in
      var nextIndex = 0
      let initialCount = min(Self.proxyDelayBatchConcurrencyLimit, items.count)
      for _ in 0..<initialCount {
        let item = items[nextIndex]
        nextIndex += 1
        taskGroup.addTask {
          await Self.measureBatchDelay(
            item: item,
            apiClient: apiClient,
            settings: settings,
            pingTester: pingTester
          )
        }
      }

      while let result = await taskGroup.next() {
        guard proxyDelayBatchToken == token else {
          taskGroup.cancelAll()
          break
        }
        guard !Task.isCancelled else {
          taskGroup.cancelAll()
          break
        }

        switch result.outcome {
        case let .success(delay):
          completedKeys.insert(result.item.nodeKey)
          pendingStates[result.item.nodeKey] = .measured(delay)
          pendingProgress.append { progress in progress.recordSuccess() }
          processedSinceFlush += 1
        case let .failure(kind, message):
          guard kind != .cancelled else {
            // Restoration is handled in one batch by `restoreCancelledBatchItems` once the loop
            // unwinds, so cancelled in-flight results need no per-item publish here.
            continue
          }
          completedKeys.insert(result.item.nodeKey)
          pendingStates[result.item.nodeKey] = delayState(kind: kind, message: message)
          let failure = ProxyDelayBatchFailure(
            nodeKey: result.item.nodeKey,
            groupName: result.item.groupName,
            nodeName: result.item.node.name,
            providerName: result.item.node.providerName,
            kind: kind,
            message: message
          )
          pendingProgress.append { progress in progress.recordFailure(failure) }
          processedSinceFlush += 1
        }

        flushIfThresholdReached()

        if nextIndex < items.count {
          let item = items[nextIndex]
          nextIndex += 1
          taskGroup.addTask {
            await Self.measureBatchDelay(
              item: item,
              apiClient: apiClient,
              settings: settings,
              pingTester: pingTester
            )
          }
        }
      }
    }

    // Always force a final flush so completed results / progress land even below the threshold.
    flushPending()

    guard proxyDelayBatchToken == token else { return }

    // Only nodes that never produced a result are genuinely untested. If everything already
    // landed before the cancellation arrived, fall through and report the real completed/partial/
    // failed outcome instead of a misleading "cancelled" (issue #18).
    let cancelledItems: [ProxyDelayBatchItem]
    if Task.isCancelled {
      restoreCancelledBatchItems(items, completedKeys: completedKeys)
      cancelledItems = items.filter { !completedKeys.contains($0.nodeKey) }
    } else {
      cancelledItems = []
    }

    // Record each untested node as a cancelled failure so the strip and diagnostics can name them.
    // Built once and applied in a single coalesced progress update to preserve the issue #11
    // publish budget.
    let cancelledMessage = NSLocalizedString(
      "Cancelled before testing.",
      comment: "Batch delay failure reason shown for nodes skipped because the batch was cancelled."
    )
    let cancelledFailures = cancelledItems.map { item in
      ProxyDelayBatchFailure(
        nodeKey: item.nodeKey,
        groupName: item.groupName,
        nodeName: item.node.name,
        providerName: item.node.providerName,
        kind: .cancelled,
        message: cancelledMessage
      )
    }

    updateProxyDelayBatchProgress(token: token) { progress in
      for failure in cancelledFailures {
        progress.recordFailure(failure)
      }
      progress.finish()
    }

    if cancelledItems.isEmpty,
       let progress = proxyDelayBatchProgress,
       progress.failureCount > 0 {
      lastError = String.localizedStringWithFormat(
        NSLocalizedString("Batch delay test finished with %lld failures.", comment: ""),
        Int64(progress.failureCount)
      )
    }
    reloadRuntimeData()
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
    let analyticsProfileID = profileStore.activeProfileID
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
        self.providerAnalytics.recordUpdateAttempt(
          profileID: analyticsProfileID,
          kind: .proxy,
          providerName: provider.name,
          succeeded: true
        )
        self.reloadRuntimeData()
      } catch is CancellationError {
        return
      } catch {
        guard self.proxyProviderUpdateTokens[provider.id] == token, !Task.isCancelled else { return }
        let message = UserFacingError.message(for: error)
        self.providerAnalytics.recordUpdateAttempt(
          profileID: analyticsProfileID,
          kind: .proxy,
          providerName: provider.name,
          succeeded: false,
          errorMessage: message
        )
        self.lastError = message
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
    let analyticsProfileID = profileStore.activeProfileID
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
          self.providerAnalytics.recordUpdateAttempt(
            profileID: analyticsProfileID,
            kind: .proxy,
            providerName: provider.name,
            succeeded: true
          )
        } catch is CancellationError {
          return
        } catch {
          let message = UserFacingError.message(for: error)
          self.providerAnalytics.recordUpdateAttempt(
            profileID: analyticsProfileID,
            kind: .proxy,
            providerName: provider.name,
            succeeded: false,
            errorMessage: message
          )
          failures.append((provider.name, message))
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
    let analyticsProfileID = profileStore.activeProfileID
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
        self.providerAnalytics.recordUpdateAttempt(
          profileID: analyticsProfileID,
          kind: .rule,
          providerName: provider.name,
          succeeded: true
        )
        self.reloadRuntimeData()
      } catch is CancellationError {
        return
      } catch {
        guard self.ruleProviderUpdateTokens[provider.id] == token, !Task.isCancelled else { return }
        let message = UserFacingError.message(for: error)
        self.providerAnalytics.recordUpdateAttempt(
          profileID: analyticsProfileID,
          kind: .rule,
          providerName: provider.name,
          succeeded: false,
          errorMessage: message
        )
        self.lastError = message
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
    let analyticsProfileID = profileStore.activeProfileID
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
          self.providerAnalytics.recordUpdateAttempt(
            profileID: analyticsProfileID,
            kind: .rule,
            providerName: provider.name,
            succeeded: true
          )
        } catch is CancellationError {
          return
        } catch {
          let message = UserFacingError.message(for: error)
          self.providerAnalytics.recordUpdateAttempt(
            profileID: analyticsProfileID,
            kind: .rule,
            providerName: provider.name,
            succeeded: false,
            errorMessage: message
          )
          failures.append((provider.name, message))
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
    settings: DelayTestSettings,
    testURL: URL
  ) async throws -> Int {
    let attempts = settings.unifiedDelay ? 2 : 1
    var lastDelay: Int?
    var lastError: Error?

    for _ in 0..<attempts {
      do {
        lastDelay = try await measureDelayOnce(for: node, apiClient: apiClient, settings: settings, testURL: testURL)
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
    settings: DelayTestSettings,
    testURL: URL
  ) async throws -> Int {
    switch settings.mode {
    case .mihomoURL:
      return try await apiClient.testDelay(
        proxy: node.name,
        testURL: testURL,
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

  private static func measureBatchDelay(
    item: ProxyDelayBatchItem,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    pingTester: any PingTesting
  ) async -> ProxyDelayBatchItemResult {
    do {
      let delay = try await measureBatchDelayValue(
        item: item,
        apiClient: apiClient,
        settings: settings,
        pingTester: pingTester
      )
      guard !Task.isCancelled else {
        return ProxyDelayBatchItemResult(item: item, outcome: .failure(.cancelled, "Cancelled"))
      }
      return ProxyDelayBatchItemResult(item: item, outcome: .success(delay))
    } catch is CancellationError {
      return ProxyDelayBatchItemResult(item: item, outcome: .failure(.cancelled, "Cancelled"))
    } catch {
      let message = UserFacingError.message(for: error)
      return ProxyDelayBatchItemResult(
        item: item,
        outcome: .failure(delayFailureKind(for: error, message: message), message)
      )
    }
  }

  private static func measureBatchDelayValue(
    item: ProxyDelayBatchItem,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    pingTester: any PingTesting
  ) async throws -> Int {
    let attempts = settings.unifiedDelay ? 2 : 1
    var lastDelay: Int?
    var lastError: Error?

    for _ in 0..<attempts {
      do {
        switch settings.mode {
        case .mihomoURL:
          lastDelay = try await apiClient.testDelay(
            proxy: item.node.name,
            testURL: item.testURL,
            timeout: settings.normalizedTimeoutMilliseconds
          )
        case .nativePing:
          let trimmedHost = item.nativePingHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          guard !trimmedHost.isEmpty else {
            throw DelayTestError.missingServerHost(item.node.name)
          }
          lastDelay = try await pingTester.ping(
            host: trimmedHost,
            timeoutMilliseconds: settings.normalizedTimeoutMilliseconds
          )
        }
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
    throw lastError ?? DelayTestError.noResult(item.node.name)
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
    clearNetworkPolicyRestoreSnapshotForUserChange()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        try await applySystemProxyEnabledState(enabled)
      } catch {
        lastError = UserFacingError.message(for: error)
      }
    }
  }

  private func applySystemProxyEnabledState(_ enabled: Bool) async throws {
    if enabled {
      seedAppliedRuntimeSettingsSnapshotIfNeeded()
      proxyRoutingMode = .systemProxy
      try await applySystemProxySettings()
      systemProxyEnabled = true
      try await activateSystemProxyGuardIfNeeded()
      recordAppliedRuntimeSettingsSnapshot(makeRuntimeSettingsSnapshot(owner: effectiveRuntimeOwnerForSettingsSnapshot))
    } else {
      _ = try await restoreSystemProxyState(disableWhenNoSnapshot: true)
      systemProxyEnabled = false
    }
  }

  func updateSystemProxySettings(_ settings: SystemProxySettings) -> Bool {
    if let validationError = settings.validationError {
      lastError = validationError
      return false
    }
    seedAppliedRuntimeSettingsSnapshotIfNeeded()
    systemProxySettings = settings
    if systemProxyEnabled {
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await applySystemProxySettings()
          try await activateSystemProxyGuardIfNeeded()
          recordAppliedRuntimeSettingsSnapshot(makeRuntimeSettingsSnapshot())
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
    seedAppliedRuntimeSettingsSnapshotIfNeeded()
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
        recordAppliedRuntimeSettingsSnapshot(makeRuntimeSettingsSnapshot(owner: .tunnel))
        lastError = nil
      } catch is CancellationError {
        return
      } catch {
        guard self.tunSettingsApplyToken == token else { return }
        lastError = "Could not apply TUN settings without restart: \(UserFacingError.message(for: error))"
      }
    }
  }

  private func applyRunningTunSettings(
    _ settings: TunSettings,
    runtimeOverrides: RuntimeOverrides? = nil,
    reason: String
  ) async throws {
    guard runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning else { return }
    var effectiveOverrides = runtimeOverrides ?? runtimeOverridesForSettingsSnapshot(owner: .tunnel)
    effectiveOverrides.tunEnabled = true
    effectiveOverrides.tunSettings = settings
    let materialization = try await materializeTunRuntimeConfig(settings, runtimeOverrides: effectiveOverrides)
    let runtimeConfig = materialization.runtimeConfigURL
    var didRestartHelper = false
    if let apiClient {
      do {
        try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
        activateRuntimeArtifacts(materialization)
        appendAppLog(level: "info", message: "\(reason): Mihomo reloaded \(runtimeConfig.path).")
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        appendAppLog(
          level: "warn",
          message: "\(reason): Mihomo reload failed, restarting helper instead: \(UserFacingError.message(for: error))"
        )
        try await restartRunningTunHelper(
          runtimeConfig: runtimeConfig,
          settings: settings,
          runtimeOverrides: effectiveOverrides,
          reason: reason
        )
        activateRuntimeArtifacts(materialization)
        didRestartHelper = true
      }
    } else {
      appendAppLog(level: "warn", message: "\(reason): controller unavailable, restarting helper instead.")
      try await restartRunningTunHelper(
        runtimeConfig: runtimeConfig,
        settings: settings,
        runtimeOverrides: effectiveOverrides,
        reason: reason
      )
      activateRuntimeArtifacts(materialization)
      didRestartHelper = true
    }
    didRestartHelper = try await verifyRunningTunFacts(
      runtimeConfig: runtimeConfig,
      settings: settings,
      runtimeOverrides: effectiveOverrides,
      reason: reason,
      didRestartHelper: didRestartHelper
    )
    if !didRestartHelper {
      try await reconcileTunSystemDNS(for: settings)
    }
    refreshTunDiagnostics(includeExternal: false, runtimeOverrides: effectiveOverrides)
    reloadRuntimeData()
  }

  private func materializeTunRuntimeConfig(
    _ settings: TunSettings,
    runtimeOverrides: RuntimeOverrides? = nil
  ) async throws -> RuntimeConfigMaterializationResult {
    let profile = try requireActiveProfile()
    var runtimeOverrides = runtimeOverrides ?? overrides
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
    runtimeOverrides: RuntimeOverrides? = nil,
    reason: String
  ) async throws {
    let runtimeOverrides = runtimeOverrides ?? runtimeOverridesForSettingsSnapshot(owner: .tunnel)
    let response = try await helperClient.restartTunnel(
      coreURL: try bundledCoreURL(),
      configURL: runtimeConfig,
      workDirectory: paths.runtime,
      secret: runtimeOverrides.secret
    )
    if !response.ok {
      throw AppError.helperResponse(response.userFacingMessage)
    }
    guard response.running else {
      throw AppError.helperResponse("Helper reported restart success but TUN is not running.")
    }
    tunHelperPID = response.pid > 0 ? response.pid : nil
    let version = try await tunnelReadinessProbe.waitUntilReady(api: runtimeOverrides.endpoint)
    appendAppLog(level: "info", message: "\(reason): TUN helper restarted, controller ready with version \(version).")
    try await reconcileTunSystemDNS(for: settings)
    tunnelCoreRunning = true
    tunEnabled = true
    runtimeOwner = .tunnel
  }

  private func verifyRunningTunFacts(
    runtimeConfig: URL,
    settings: TunSettings,
    runtimeOverrides: RuntimeOverrides,
    reason: String,
    didRestartHelper: Bool
  ) async throws -> Bool {
    var didRestartHelper = didRestartHelper
    let postReloadSnapshot = await inspectTunRuntimeNow(
      includeExternal: false,
      runtimeOverrides: runtimeOverrides
    )
    guard postReloadSnapshot.hasRepairableRoutingIssue else {
      return didRestartHelper
    }

    if !didRestartHelper {
      appendAppLog(
        level: "warn",
        message: "\(reason): runtime diagnostics still report \(postReloadSnapshot.repairableRoutingIssueMessage), restarting helper instead."
      )
      try await restartRunningTunHelper(
        runtimeConfig: runtimeConfig,
        settings: settings,
        runtimeOverrides: runtimeOverrides,
        reason: reason
      )
      didRestartHelper = true
      let postRestartSnapshot = await inspectTunRuntimeNow(
        includeExternal: false,
        runtimeOverrides: runtimeOverrides
      )
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
          let runtimeOverrides = runtimeOverridesForSettingsSnapshot(owner: .tunnel)
          try await reconcileTunSystemDNS(for: runtimeOverrides.tunSettings)
          refreshTunDiagnostics(includeExternal: false, runtimeOverrides: runtimeOverrides)
        } else if systemProxyController.hasManagedSystemDNSState {
          _ = try await restoreTunSystemDNS()
          refreshTunDiagnostics(includeExternal: false)
        } else {
          setTunSystemDNSState(.inactive)
          refreshTunDiagnostics(includeExternal: false)
        }
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
          var runtimeOverrides = runtimeOverridesForSettingsSnapshot(owner: .tunnel)
          let settings = runtimeOverrides.tunSettings
          runtimeOverrides.tunEnabled = true
          runtimeOverrides.tunSettings = settings
          try await reconcileTunSystemDNS(for: settings)
          let materialization = try await materializeTunRuntimeConfig(
            settings,
            runtimeOverrides: runtimeOverrides
          )
          let runtimeConfig = materialization.runtimeConfigURL
          var didRestartHelper = false
          if let apiClient {
            do {
              try await apiClient.reloadConfig(path: runtimeConfig.path, force: true)
              activateRuntimeArtifacts(materialization)
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
                settings: settings,
                runtimeOverrides: runtimeOverrides,
                reason: "TUN routing repair"
              )
              activateRuntimeArtifacts(materialization)
              didRestartHelper = true
            }
          } else {
            try await restartRunningTunHelper(
              runtimeConfig: runtimeConfig,
              settings: settings,
              runtimeOverrides: runtimeOverrides,
              reason: "TUN routing repair"
            )
            activateRuntimeArtifacts(materialization)
            didRestartHelper = true
          }

          let postReloadSnapshot = await inspectTunRuntimeNow(
            includeExternal: false,
            runtimeOverrides: runtimeOverrides
          )
          if !didRestartHelper, postReloadSnapshot.hasRepairableRoutingIssue {
            try await restartRunningTunHelper(
              runtimeConfig: runtimeConfig,
              settings: settings,
              runtimeOverrides: runtimeOverrides,
              reason: "TUN routing repair"
            )
            activateRuntimeArtifacts(materialization)
            didRestartHelper = true
            let postRestartSnapshot = await inspectTunRuntimeNow(
              includeExternal: false,
              runtimeOverrides: runtimeOverrides
            )
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

  private func inspectTunRuntimeNow(
    includeExternal: Bool,
    runtimeOverrides: RuntimeOverrides? = nil
  ) async -> TunDiagnosticsSnapshot {
    guard runtimeOwner == .tunnel || tunEnabled || tunnelCoreRunning else {
      tunDiagnostics = .empty
      return .empty
    }
    stopTunDiagnostics(clear: false)
    let helperStatus = await liveTunHelperStatus(using: helperClient)
    tunHelperPID = helperStatus.pid
    let runtimeOverrides = runtimeOverrides ?? currentRuntimeOverrides
    let snapshot = await tunRuntimeInspector.inspect(
      TunRuntimeInspectionConfiguration(
        api: runtimeOverrides.endpoint,
        tunSettings: runtimeOverrides.tunSettings,
        helperPID: helperStatus.pid,
        helperStatusMessage: helperStatus.message,
        systemDNSState: tunSystemDNSState,
        includeExternal: includeExternal
      )
    )
    tunDiagnostics = snapshot
    return snapshot
  }

  private func applySystemProxySettings(_ snapshot: AppliedRuntimeSettingsSnapshot? = nil) async throws {
    try await systemProxy.apply(
      settings: snapshot?.systemProxySettings ?? systemProxySettings,
      mixedPort: snapshot?.overrides.mixedPort ?? overrides.mixedPort
    )
  }

  private func activateSystemProxyGuardIfNeeded(_ snapshot: AppliedRuntimeSettingsSnapshot? = nil) async throws {
    try await systemProxy.activateGuardIfNeeded(
      settings: snapshot?.systemProxySettings ?? systemProxySettings,
      mixedPort: snapshot?.overrides.mixedPort ?? overrides.mixedPort,
      onWarning: { [weak self] warning in
        self?.appendAppLog(level: "warn", message: warning)
        self?.appNotice = AppNotice(
          message: String(format: String(localized: "System Proxy was changed externally: %@"), warning),
          tone: .info
        )
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
    let appliedSnapshot = settings.appliedRuntimeSettingsSnapshot
    return try await systemProxy.restore(
      settings: appliedSnapshot?.systemProxySettings ?? systemProxySettings,
      mixedPort: appliedSnapshot?.overrides.mixedPort ?? overrides.mixedPort,
      additionalPorts: knownLocalProxyPorts(),
      disableWhenNoSnapshot: disableWhenNoSnapshot
    )
  }

  /// Local proxy ports ClashMax may have pointed System Proxy at across its own
  /// runtimes: the current mixed port, the last applied mixed port, and the
  /// preview runtime port. Residual cleanup must consider all of them so a stale
  /// proxy left on a non-current port — notably the preview port 17890 — is still
  /// detected and disabled instead of being silently "verified" away (issue #19).
  private func knownLocalProxyPorts() -> Set<Int> {
    var ports: Set<Int> = [overrides.mixedPort, Self.previewRuntimeMixedPort]
    if let appliedPort = settings.appliedRuntimeSettingsSnapshot?.overrides.mixedPort {
      ports.insert(appliedPort)
    }
    return ports
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
    stopNetworkEnvironmentMonitoring()
    profileCoordinator.cancelSubscriptionAutoUpdates()
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

  private func restartPreviewRuntimeIfNeeded(reason: String) {
    guard previewRuntimeRequested, !isRunning, !startInFlight else { return }
    cancelPendingPreviewRuntimeStart()
    previewTask = Task { @MainActor [weak self] in
      guard let self else { return }
      if self.previewRuntimeActive {
        let result = await self.leavePreviewRuntimeResult(cancelsPendingStart: false)
        guard result.succeeded else {
          self.previewTask = nil
          if let message = result.userFacingMessage {
            self.appendAppLog(level: "debug", message: "Preview runtime restart skipped after \(reason): \(message)")
          }
          return
        }
      }
      guard !Task.isCancelled else {
        self.previewTask = nil
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
      guard !Task.isCancelled else {
        self.previewTask = nil
        return
      }
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

  private func leavePreviewRuntimeResult(cancelsPendingStart: Bool = true) async -> RuntimeStopResult {
    var result = RuntimeStopResult()
    if cancelsPendingStart {
      cancelPendingPreviewRuntimeStart()
    }
    guard previewRuntimeActive else {
      previewRuntimeOverrides = nil
      return result
    }
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
    previewRuntimeOverrides = nil
    runtimeOwner = .stopped
    if result.succeeded {
      clearActiveRuntimeArtifacts()
    }
    return result
  }

  private func startPreviewRuntime() async {
    defer { previewTask = nil }
    do {
      let profile = try requireActiveProfile()
      let previewOverrides = makePreviewRuntimeOverrides()
      let materialization = try await materializePreviewRuntimeConfig(
        for: profile,
        overrides: previewOverrides
      )
      let runtimeConfig = materialization.runtimeConfigURL
      let client = MihomoAPIClient(baseURL: try previewOverrides.endpoint.baseURL, secret: previewOverrides.secret)
      previewRuntimeOverrides = previewOverrides
      previewRuntimeActive = true
      runtimeOwner = .preview
      try Task.checkCancellation()
      try await coreController.startUserMode(
        coreURL: try bundledCoreURL(),
        configURL: runtimeConfig,
        workDirectory: paths.runtime,
        api: previewOverrides.endpoint,
        proxyPort: previewOverrides.mixedPort
      )
      activateRuntimeArtifacts(materialization)
      try Task.checkCancellation()
      apiClient = client
      try Task.checkCancellation()
      do {
        let knownDelayStates = proxyDelayStateMap(from: proxyGroups)
        let cachedRuntimeGroups = proxyGroups
        let runtimeGroups = try await client.proxyGroups()
        let providers = (try? await client.structuredProxyProviders()) ?? []
        proxyProviders = providersPreservingKnownDelayStates(providers)
        proxyGroups = enrichProxyGroupsWithKnownEndpoints(
          runtimeGroups,
          providers: providers,
          cachedRuntimeGroups: cachedRuntimeGroups
        ).preservingKnownDelayStates(knownDelayStates, profileID: profileStore.activeProfileID)
      } catch {
        // Best-effort initial fetch; UI still shows YAML preview if this fails.
      }
    } catch is CancellationError {
      previewRuntimeActive = false
      previewRuntimeOverrides = nil
      let stopResult = await coreController.stop()
      if let error = stopResult.error {
        appendAppLog(level: "error", message: UserFacingError.message(for: error))
      }
      apiClient = nil
      runtimeOwner = .stopped
    } catch {
      previewRuntimeActive = false
      previewRuntimeOverrides = nil
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

  private func cancelRuntimeActionTasks(preservingRuntimeSettingsApply: Bool = false) {
    modeUpdateTask?.cancel()
    modeUpdateTask = nil
    modeUpdateToken = nil

    ipv6UpdateTask?.cancel()
    ipv6UpdateTask = nil
    ipv6UpdateToken = nil

    if !preservingRuntimeSettingsApply {
      runtimeSettingsApplyTask?.cancel()
      runtimeSettingsApplyTask = nil
      runtimeSettingsApplyToken = nil
    }

    proxySelectionTasks.values.forEach { $0.cancel() }
    proxySelectionTasks.removeAll()
    proxySelectionTokens.removeAll()

    delayTestTasks.values.forEach { $0.cancel() }
    delayTestTasks.removeAll()
    delayTestTokens.removeAll()
    proxyDelayBatchTask?.cancel()
    proxyDelayBatchTask = nil
    proxyDelayBatchToken = nil
    if proxyDelayBatchProgress?.isRunning == true {
      proxyDelayBatchProgress = nil
    }

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
    cancelRuntimeActionTasks(preservingRuntimeSettingsApply: purpose.preservesRuntimeSettingsApplyTask)
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
    previewRuntimeOverrides = nil
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
    if result.succeeded {
      clearActiveRuntimeArtifacts()
      settings.clearAppliedRuntimeSettingsSnapshot()
      runtimeSettingsApplyState = .idle
    }
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
    profileCoordinator.refreshPreview()
  }

  private func refreshProfilePreviewAndWait() async {
    await profileCoordinator.refreshPreviewAndWait()
  }

  func waitForProfilePreviewRefresh() async {
    await profileCoordinator.waitForPreviewRefresh()
  }

  private func runtimeAPIClientForProxyAction() -> (any MihomoAPIControlling)? {
    guard canControlRuntimeProxies, let apiClient else {
      lastError = proxyRuntimeActionMessage
      return nil
    }
    return apiClient
  }

  private func applySelectedProxy(groupName: String, nodeName: String?) {
    updateProxyGroupCollections { groups in
      guard let index = groups.firstIndex(where: { $0.name == groupName }) else { return }
      groups[index].selected = nodeName
    }
  }

  private func persistSelectedProxy(groupName: String, nodeName: String) {
    previewSelections[groupName] = nodeName
    saveCurrentPreviewSelections()
  }

  private func restoreSelectedProxy(groupName: String, nodeName: String?) {
    if let nodeName {
      previewSelections[groupName] = nodeName
    } else {
      previewSelections.removeValue(forKey: groupName)
    }
    saveCurrentPreviewSelections()
    applySelectedProxy(groupName: groupName, nodeName: nodeName)
  }

  private func closeOldConnectionsIfNeeded(enabled: Bool, previousSelection: String?, newSelection: String) {
    guard enabled,
          let previousSelection,
          previousSelection != newSelection
    else { return }
    let staleConnections = connections.filter { connection in
      connection.chain.contains(previousSelection)
    }
    for connection in staleConnections {
      closeConnection(connection)
    }
  }

  private func applyDelayState(_ state: ProxyDelayState, to nodeKey: ProxyNodeKey) {
    applyDelayStates([nodeKey: state])
  }

  /// Applies a batch of delay-state updates with at most one `@Published` write per affected
  /// collection.
  ///
  /// Issue #11: `startProxyDelayBatch` / `runProxyDelayBatch` previously called the single-node
  /// `applyDelayState` once per node — each call re-assigned `proxyGroups`,
  /// `profilePreviewGroups`, and `proxyProviders` and re-pruned the cache — so a "Test All" over
  /// 1000+ nodes published thousands of times and froze list scrolling. Coalescing the writes
  /// (cache recorded once, each collection rebuilt in a single pass and only re-assigned when a
  /// node actually changed) keeps the list smooth while the batch runs.
  private func applyDelayStates(_ updates: [ProxyNodeKey: ProxyDelayState], now: Date = Date()) {
    guard !updates.isEmpty else { return }

    // Record every cache entry first, then prune a single time.
    for (key, state) in updates {
      if state == .unknown {
        delayStateCache.removeValue(forKey: key)
      } else {
        delayStateCache[key] = ProxyDelayCacheEntry(state: state, recordedAt: now)
      }
    }
    pruneExpiredDelayStates(now: now)

    // Build lookup indexes that mirror `nodeMatches` / provider matching so each collection can
    // resolve every node's new state in a single O(nodes + updates) pass. A `nil` key provider is
    // a wildcard that matches any node with that name (matching the previous single-node logic).
    var exactByProvider: [String: ProxyDelayState] = [:]
    var wildcardByName: [String: ProxyDelayState] = [:]
    var providerByName: [String: ProxyDelayState] = [:]
    for (key, state) in updates {
      if let providerName = key.providerName {
        exactByProvider[Self.nodeMatchKey(group: key.groupName, node: key.nodeName, provider: providerName)] = state
        providerByName[Self.providerMatchKey(provider: providerName, node: key.nodeName)] = state
      } else {
        wildcardByName[Self.nodeMatchKey(group: key.groupName, node: key.nodeName)] = state
      }
    }

    // Update the runtime + preview group collections, each with at most one publish.
    if !proxyGroups.isEmpty {
      var groups = proxyGroups
      if applyDelayStates(exactByProvider: exactByProvider, wildcardByName: wildcardByName, to: &groups) {
        proxyGroups = groups
      }
    }
    if !profilePreviewGroups.isEmpty {
      var preview = profilePreviewGroups
      if applyDelayStates(exactByProvider: exactByProvider, wildcardByName: wildcardByName, to: &preview) {
        profilePreviewGroups = preview
      }
    }

    // Provider-backed nodes are surfaced in ProxiesView by expanding `proxyProviders`
    // (see ResolvedProxyCatalog), which the group collections never touch. Keep the provider copy
    // in sync so the visible node reflects the live delay state (issue #12).
    if !providerByName.isEmpty, !proxyProviders.isEmpty {
      var providers = proxyProviders
      var didChange = false
      for providerIndex in providers.indices {
        guard let providerName = providers[providerIndex].name
          .trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        else { continue }
        for nodeIndex in providers[providerIndex].proxies.indices {
          let nodeName = providers[providerIndex].proxies[nodeIndex].name
          guard let state = providerByName[Self.providerMatchKey(provider: providerName, node: nodeName)]
          else { continue }
          if applyDelayState(state, to: &providers[providerIndex].proxies[nodeIndex]) {
            didChange = true
          }
        }
      }
      if didChange {
        proxyProviders = providers
      }
    }
  }

  /// Applies the prepared indexes to one group collection in a single pass, returning whether any
  /// node actually changed (so the caller can skip a redundant `@Published` write).
  private func applyDelayStates(
    exactByProvider: [String: ProxyDelayState],
    wildcardByName: [String: ProxyDelayState],
    to groups: inout [ProxyGroup]
  ) -> Bool {
    var didChange = false
    for groupIndex in groups.indices {
      let groupName = groups[groupIndex].name
      for nodeIndex in groups[groupIndex].nodes.indices {
        let node = groups[groupIndex].nodes[nodeIndex]
        let resolved: ProxyDelayState?
        if let providerName = node.providerName,
           let match = exactByProvider[Self.nodeMatchKey(group: groupName, node: node.name, provider: providerName)] {
          resolved = match
        } else {
          resolved = wildcardByName[Self.nodeMatchKey(group: groupName, node: node.name)]
        }
        guard let state = resolved else { continue }
        if applyDelayState(state, to: &groups[groupIndex].nodes[nodeIndex]) {
          didChange = true
        }
      }
    }
    return didChange
  }

  private static func nodeMatchKey(group: String, node: String, provider: String) -> String {
    "\(group)\u{1}\(node)\u{1}\(provider)"
  }

  private static func nodeMatchKey(group: String, node: String) -> String {
    "\(group)\u{1}\(node)"
  }

  private static func providerMatchKey(provider: String, node: String) -> String {
    "\(provider)\u{1}\(node)"
  }

  /// Mutates a node's delay state, returning whether anything actually changed so batch callers
  /// can avoid republishing an unchanged collection.
  @discardableResult
  private func applyDelayState(_ state: ProxyDelayState, to node: inout ProxyNode) -> Bool {
    let previousState = node.delayState
    let previousDelay = node.delay
    node.delayState = state
    if case let .measured(delay) = state, delay >= 0 {
      node.delay = delay
    } else if state == .timeout || isErrorDelayState(state) {
      node.delay = nil
    }
    return node.delayState != previousState || node.delay != previousDelay
  }

  private func isErrorDelayState(_ state: ProxyDelayState) -> Bool {
    if case .error = state {
      return true
    }
    return false
  }

  private func cancelDelayTestTask(for taskKey: ProxyNodeKey) {
    delayTestTasks[taskKey]?.cancel()
    delayTestTasks[taskKey] = nil
    delayTestTokens[taskKey] = nil
  }

  private func updateProxyDelayBatchProgress(
    token: UUID,
    _ update: (inout ProxyDelayBatchProgress) -> Void
  ) {
    guard proxyDelayBatchToken == token,
          var progress = proxyDelayBatchProgress
    else { return }
    update(&progress)
    proxyDelayBatchProgress = progress
  }

  private func pruneExpiredDelayStates(now: Date = Date()) {
    guard delayStateCacheTTL > 0 else {
      delayStateCache.removeAll()
      return
    }
    delayStateCache = delayStateCache.filter { _, entry in
      now.timeIntervalSince(entry.recordedAt) <= delayStateCacheTTL
    }
  }

  private func delayState(for error: Error) -> ProxyDelayState {
    let message = UserFacingError.message(for: error)
    let normalized = message.lowercased()
    if normalized.contains("timeout") || normalized.contains("timed out") {
      return .timeout
    }
    return .error(message)
  }

  private func delayState(kind: ProxyDelayFailureKind, message: String) -> ProxyDelayState {
    switch kind {
    case .timeout:
      return .timeout
    case .cancelled:
      return .unknown
    case .missingEndpoint, .controllerUnavailable, .other:
      return .error(message)
    }
  }

  private static func delayFailureKind(for error: Error, message: String) -> ProxyDelayFailureKind {
    if error is CancellationError {
      return .cancelled
    }
    if let delayError = error as? DelayTestError {
      switch delayError {
      case .missingServerHost:
        return .missingEndpoint
      case .noResult:
        break
      }
    }

    let normalized = message.lowercased()
    if normalized.contains("timeout") || normalized.contains("timed out") {
      return .timeout
    }
    if normalized.contains("mihomo controller")
      || normalized.contains("controller")
      || normalized.contains("could not connect to the server")
      || normalized.contains("cannot connect to the server")
      || normalized.contains("unable to connect to the server")
      || normalized.contains("无法连接服务器")
      || normalized.contains("127.0.0.1:9097") {
      return .controllerUnavailable
    }
    return .other
  }

  private func restoreCancelledBatchItems(_ items: [ProxyDelayBatchItem], completedKeys: Set<ProxyNodeKey>) {
    var updates: [ProxyNodeKey: ProxyDelayState] = [:]
    for item in items where !completedKeys.contains(item.nodeKey) {
      updates[item.nodeKey] = item.previousState == .testing ? .unknown : item.previousState
    }
    applyDelayStates(updates)
  }

  private func proxyNodeKey(group: ProxyGroup, node: ProxyNode, testURL: URL = AppConstants.defaultDelayTestURL) -> ProxyNodeKey {
    ProxyNodeKey(
      profileID: profileStore.activeProfileID,
      groupName: group.name,
      nodeName: node.name,
      providerName: node.providerName,
      testURL: testURL
    )
  }

  private func proxyDelayTaskKey(group: ProxyGroup, node: ProxyNode) -> ProxyNodeKey {
    proxyNodeKey(group: group, node: node)
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

  private func proxyDelayStateMap(from groups: [ProxyGroup]) -> [ProxyNodeKey: ProxyDelayState] {
    pruneExpiredDelayStates()
    return groups.reduce(into: [ProxyNodeKey: ProxyDelayState]()) { result, group in
      for node in group.nodes {
        let key = proxyNodeKey(group: group, node: node)
        if let entry = latestDelayCacheEntry(matching: key) {
          result[key] = entry.state
        }
      }
    }
  }

  private func latestDelayCacheEntry(matching key: ProxyNodeKey) -> ProxyDelayCacheEntry? {
    delayStateCache
      .filter { cachedKey, _ in
        cachedKey.matchesNodeIdentity(of: key)
      }
      .max { lhs, rhs in
        lhs.value.recordedAt < rhs.value.recordedAt
      }?
      .value
  }

  /// Re-applies cached delay states onto freshly fetched providers so a runtime reload or
  /// provider-metadata refresh does not blank the delay of provider-backed visible nodes
  /// (issue #12). The cache is the source of truth; nodes with no live cache entry stay as-is.
  private func providersPreservingKnownDelayStates(_ providers: [ProxyProvider]) -> [ProxyProvider] {
    guard !providers.isEmpty else { return providers }
    pruneExpiredDelayStates()
    let activeProfileID = profileStore.activeProfileID?.uuidString
    return providers.map { provider in
      guard let providerName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
      else { return provider }
      var provider = provider
      provider.proxies = provider.proxies.map { node in
        guard let entry = latestProviderDelayCacheEntry(
          providerName: providerName,
          nodeName: node.name,
          profileID: activeProfileID
        ) else {
          return node
        }
        var node = node
        node.delayState = entry.state
        if let delay = entry.state.measuredDelay, node.delay == nil {
          node.delay = delay
        }
        return node
      }
      return provider
    }
  }

  private func latestProviderDelayCacheEntry(
    providerName: String,
    nodeName: String,
    profileID: String?
  ) -> ProxyDelayCacheEntry? {
    delayStateCache
      .filter { key, _ in
        key.profileID == profileID
          && key.providerName == providerName
          && key.nodeName == nodeName
      }
      .max { lhs, rhs in
        lhs.value.recordedAt < rhs.value.recordedAt
      }?
      .value
  }

  private func nativePingHost(for node: ProxyNode) -> String? {
    if let endpoint = proxyEndpoint(from: node) {
      return endpoint.host
    }
    if let providerName = node.providerName,
       let provider = proxyProviders.first(where: { $0.name == providerName }),
       let providerNode = provider.proxies.first(where: { $0.name == node.name }),
       let endpoint = proxyEndpoint(from: providerNode) {
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
    let providerNames = proxyProviderNameMap(from: providers)
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
        else {
          if node.providerName == nil, let providerName = providerNames[node.name] {
            var node = node
            node.providerName = providerName
            return node
          }
          return node
        }
        var node = node
        node.serverHost = endpoint.host
        node.serverPort = endpoint.port
        if node.providerName == nil {
          node.providerName = providerNames[node.name]
        }
        return node
      }
      return group
    }
  }

  private func proxyProviderNameMap(from providers: [ProxyProvider]) -> [String: String] {
    var providerNames: [String: String] = [:]
    var ambiguousNames = Set<String>()
    for provider in providers {
      for node in provider.proxies {
        if let existing = providerNames[node.name], existing != provider.name {
          ambiguousNames.insert(node.name)
        } else {
          providerNames[node.name] = provider.name
        }
      }
    }
    for name in ambiguousNames {
      providerNames[name] = nil
    }
    return providerNames
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

  private var protectedRuntimeArtifactURLs: [URL] {
    activeRuntimeConfigMaterialization?.artifactURLs ?? []
  }

  private func activateRuntimeArtifacts(_ materialization: RuntimeConfigMaterializationResult) {
    activeRuntimeConfigMaterialization = materialization
  }

  private func clearActiveRuntimeArtifacts() {
    activeRuntimeConfigMaterialization = nil
  }

  @discardableResult
  func preflightEffectiveRuntimeConfig(
    profile: Profile? = nil,
    overrides: RuntimeOverrides? = nil,
    runtimeSnippets: [RuntimeSnippet]? = nil,
    selectionOverrides: [String: String]? = nil
  ) async throws -> EffectiveRuntimeConfigSnapshot {
    let targetProfile = try profile ?? requireActiveProfile()
    let snippets: [RuntimeSnippet]
    if let runtimeSnippets {
      snippets = runtimeSnippets
    } else {
      await runtimeSnippetLibrary.waitForLoad()
      snippets = runtimeSnippetLibrary.snippets(applyingTo: targetProfile.id)
    }
    return try await makeEffectiveRuntimeConfigSnapshot(
      profile: targetProfile,
      overrides: overrides ?? self.overrides,
      selectionOverrides: selectionOverrides ?? previewSelections,
      runtimeSnippets: snippets,
      preflight: .requireCore
    )
  }

  private func makeEffectiveRuntimeConfigSnapshot(
    profile: Profile,
    overrides: RuntimeOverrides,
    selectionOverrides: [String: String]? = nil,
    runtimeSnippets: [RuntimeSnippet],
    preflight: EffectiveRuntimeConfigValidationIntent
  ) async throws -> EffectiveRuntimeConfigSnapshot {
    let preflightMode: EffectiveRuntimeConfigPreflightMode
    let optionalCoreErrorMessage: String?
    switch preflight {
    case .disabled:
      optionalCoreErrorMessage = nil
      preflightMode = .disabled
    case .validateOptionalCore:
      do {
        let coreURL = try bundledCoreURL()
        optionalCoreErrorMessage = nil
        preflightMode = .validate(coreURL: coreURL, validator: MihomoRuntimeConfigValidator())
      } catch {
        optionalCoreErrorMessage = UserFacingError.message(for: error)
        preflightMode = .disabled
      }
    case .requireCore:
      optionalCoreErrorMessage = nil
      preflightMode = .validate(coreURL: try bundledCoreURL(), validator: MihomoRuntimeConfigValidator())
    }
    var snapshot = try await EffectiveRuntimeConfigBuilder(
      materializer: runtimeConfigMaterializer
    ).snapshot(
      profile: profile,
      paths: paths,
      overrides: overrides,
      selectionOverrides: selectionOverrides ?? previewSelections,
      runtimeSnippets: runtimeSnippets,
      preflight: preflightMode
    )
    if let optionalCoreErrorMessage {
      snapshot.preflightStatus = .failed(optionalCoreErrorMessage)
    }
    if preflight == .requireCore, case let .failed(message) = snapshot.preflightStatus {
      throw AppError.configValidationFailed(message)
    }
    return snapshot
  }

  private func effectiveRuntimeSnippets(
    for profileID: Profile.ID,
    draftSnippet: RuntimeSnippet?
  ) async -> [RuntimeSnippet] {
    await runtimeSnippetLibrary.waitForLoad()
    var snippets = runtimeSnippetLibrary.snippets
    if let draftSnippet {
      if let index = snippets.firstIndex(where: { $0.id == draftSnippet.id }) {
        snippets[index] = draftSnippet
      } else {
        snippets.append(draftSnippet)
      }
    }
    return snippets.filter { $0.enabled && $0.applies(to: profileID) }
  }

  private func generateRuntimeConfig(
    for profile: Profile,
    overrides: RuntimeOverrides? = nil,
    selections: [String: String] = [:],
    options: RuntimeConfigOptions = .default
  ) async throws -> RuntimeConfigMaterializationResult {
    let effectiveOverrides = overrides ?? self.overrides
    var effectiveOptions = options
    effectiveOptions.subscriptionProviderOptions = profile.subscriptionProviderOptions
    await runtimeSnippetLibrary.waitForLoad()
    effectiveOptions.runtimeSnippets = runtimeSnippetLibrary.snippets(applyingTo: profile.id)
    return try await runtimeConfigMaterializer.materializeResult(
      RuntimeConfigMaterializationRequest(
        profileName: profile.name,
        sourcePath: profile.originalConfigPath,
        runtimeConfigURL: paths.runtimeConfigURL(for: profile),
        providerContentURL: paths.runtimeProviderContentURL(for: profile),
        overrides: effectiveOverrides,
        selectionOverrides: selections,
        options: effectiveOptions,
        protectedArtifactURLs: protectedRuntimeArtifactURLs
      )
    )
  }

  private func bundledCoreURL() throws -> URL {
    try bundledCoreURLProvider()
  }

  private static func resolveBundledCoreURL() throws -> URL {
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

  private func startStreams(client: any MihomoAPIControlling, logLevel: String? = nil) {
    streamTasks.forEach { $0.cancel() }
    let logLevel = logLevel ?? settings.appliedRuntimeSettingsSnapshot?.overrides.logLevel ?? overrides.logLevel
    streamTasks = [
      Task { [weak self] in
        do {
          for try await sample in client.trafficStream() {
            // This Task inherits the enclosing @MainActor method's isolation, so
            // the loop body already runs on the main actor — no MainActor.run hop.
            self?.appendTrafficSample(sample)
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await entry in client.logStream(level: logLevel) {
            self?.runtimeData.appendLog(entry)
          }
        } catch {}
      },
      Task { [weak self] in
        do {
          for try await snapshot in client.connectionStream(interval: 1000) {
            await self?.runtimeData.updateConnections(snapshot)
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

  private func notifySubscriptionUpdateFailure(profileName: String, message: String) {
    guard settings.subscriptionFetchSettings.notifyOnUpdateFailure else { return }
    let content = UNMutableNotificationContent()
    content.title = String(localized: "Subscription Update Failed")
    content.subtitle = profileName
    content.body = message
    let request = UNNotificationRequest(
      identifier: "subscription-update-\(profileName)-\(Date().timeIntervalSince1970)",
      content: content,
      trigger: nil
    )
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else { return }
      UNUserNotificationCenter.current().add(request)
    }
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
    profileCoordinator.loadSelectionsForActiveProfile()
  }

  private func saveCurrentPreviewSelections(forProfileID overrideID: Profile.ID? = nil) {
    profileCoordinator.saveCurrentSelections(forProfileID: overrideID)
  }

  private func recoverDanglingSystemProxyIfNeeded() {
    systemProxy.recoverDanglingIfNeeded(
      settingsProvider: { [weak self] in
        guard let self else {
          let fallbackPort = RuntimeOverrides.defaultForLaunch().mixedPort
          return (.default, fallbackPort, [fallbackPort, AppModel.previewRuntimeMixedPort])
        }
        if let snapshot = settings.appliedRuntimeSettingsSnapshot {
          return (snapshot.systemProxySettings, snapshot.overrides.mixedPort, knownLocalProxyPorts())
        }
        return (systemProxySettings, overrides.mixedPort, knownLocalProxyPorts())
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
  static var clashMaxBackup: UTType {
    UTType(filenameExtension: "clashmax-backup") ?? .json
  }

  static var yaml: UTType {
    UTType(filenameExtension: "yaml") ?? .text
  }

  static var yml: UTType {
    UTType(filenameExtension: "yml") ?? .text
  }
}

private extension Array where Element == ProxyGroup {
  func preservingKnownDelayStates(_ knownStates: [ProxyNodeKey: ProxyDelayState], profileID: Profile.ID?) -> [ProxyGroup] {
    map { group in
      var group = group
      group.nodes = group.nodes.map { node in
        let key = ProxyNodeKey(
          profileID: profileID,
          groupName: group.name,
          nodeName: node.name,
          providerName: node.providerName
        )
        guard let state = knownStates[key] else {
          return node
        }
        var node = node
        node.delayState = state
        if let delay = state.measuredDelay, node.delay == nil {
          node.delay = delay
        }
        return node
      }
      return group
    }
  }
}

private struct ProxyDelayCacheEntry {
  var state: ProxyDelayState
  var recordedAt: Date
}

private struct ProxyDelayBatchItem: Sendable {
  var groupName: String
  var node: ProxyNode
  var nodeKey: ProxyNodeKey
  var taskKey: ProxyNodeKey
  var testURL: URL
  var previousState: ProxyDelayState
  var nativePingHost: String?
}

private struct ProxyDelayBatchItemResult: Sendable {
  var item: ProxyDelayBatchItem
  var outcome: ProxyDelayBatchItemOutcome
}

private enum ProxyDelayBatchItemOutcome: Sendable {
  case success(Int)
  case failure(ProxyDelayFailureKind, String)
}

private extension ProxyNodeKey {
  func matchesNodeIdentity(of other: ProxyNodeKey) -> Bool {
    profileID == other.profileID
      && groupName == other.groupName
      && nodeName == other.nodeName
      && providerName == other.providerName
  }
}
