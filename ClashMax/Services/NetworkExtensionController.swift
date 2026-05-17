import AppKit
import Combine
import Foundation
import NetworkExtension
import SystemExtensions

struct NetworkExtensionRuntimeConfiguration: Equatable, Sendable {
  var providerBundleIdentifier: String
  var localizedDescription: String
  var serverAddress: String
  var socksHost: String
  var socksPort: Int

  static func clashMax(overrides: RuntimeOverrides) -> NetworkExtensionRuntimeConfiguration {
    NetworkExtensionRuntimeConfiguration(
      providerBundleIdentifier: NetworkExtensionRuntimeConstants.providerBundleIdentifier,
      localizedDescription: "ClashMax NE Transparent Proxy Experimental",
      serverAddress: "ClashMax Local Mihomo",
      socksHost: "127.0.0.1",
      socksPort: overrides.mixedPort
    )
  }

  var providerConfiguration: [String: Any] {
    [
      "socksHost": socksHost,
      "socksPort": socksPort
    ]
  }
}

enum NetworkExtensionInstallState: Equatable, Sendable {
  case notInstalled
  case activating
  case activated
  case requiresApproval
  case needsReboot
  case unsupportedBundleLocation
  case missingEntitlementOrProfile
  case codeSignatureInvalid
  case failed(String)

  var isActivated: Bool {
    if case .activated = self { return true }
    return false
  }

  var message: String {
    switch self {
    case .notInstalled:
      return "System Extension is not installed."
    case .activating:
      return "System Extension activation is in progress."
    case .activated:
      return "System Extension is activated and enabled."
    case .requiresApproval:
      return "System Extension requires approval in System Settings."
    case .needsReboot:
      return "System Extension activation will complete after restart."
    case .unsupportedBundleLocation:
      return "Move ClashMax.app to /Applications before activating the System Extension."
    case .missingEntitlementOrProfile:
      return "Missing Network Extension/System Extension entitlement or provisioning profile."
    case .codeSignatureInvalid:
      return "System Extension code signature is invalid for Developer ID activation."
    case let .failed(message):
      return message
    }
  }
}

enum NetworkExtensionTunnelStatus: String, Equatable, Sendable {
  case notConfigured
  case invalid
  case disconnected
  case connecting
  case connected
  case reasserting
  case disconnecting

  var isActive: Bool {
    switch self {
    case .connecting, .connected, .reasserting, .disconnecting:
      return true
    case .notConfigured, .invalid, .disconnected:
      return false
    }
  }

  var displayName: String {
    switch self {
    case .notConfigured: "Ready to Start"
    case .invalid: "Invalid"
    case .disconnected: "Disconnected"
    case .connecting: "Connecting"
    case .connected: "Connected"
    case .reasserting: "Reasserting"
    case .disconnecting: "Disconnecting"
    }
  }
}

private extension NetworkExtensionTunnelStatus {
  var indicatesStartProgress: Bool {
    switch self {
    case .connecting, .connected, .reasserting:
      return true
    case .notConfigured, .invalid, .disconnected, .disconnecting:
      return false
    }
  }
}

struct SystemExtensionSnapshot: Equatable, Sendable {
  var isEnabled: Bool
  var isAwaitingUserApproval: Bool
  var isUninstalling: Bool
}

struct NetworkExtensionStartTiming: Equatable, Sendable {
  var timeoutNanoseconds: UInt64
  var disconnectedGraceNanoseconds: UInt64
  var pollIntervalNanoseconds: UInt64

  static let production = NetworkExtensionStartTiming(
    timeoutNanoseconds: 8_000_000_000,
    disconnectedGraceNanoseconds: 1_500_000_000,
    pollIntervalNanoseconds: 100_000_000
  )
}

@MainActor
struct NetworkExtensionStatusObservation {
  var cancel: () -> Void

  static let none = NetworkExtensionStatusObservation(cancel: {})
}

@MainActor
final class NetworkExtensionStartStatusTracker {
  private(set) var latestStatus: NetworkExtensionTunnelStatus
  private(set) var sawStartProgress: Bool

  init(initialStatus: NetworkExtensionTunnelStatus) {
    latestStatus = initialStatus
    sawStartProgress = initialStatus.indicatesStartProgress
  }

  func record(_ status: NetworkExtensionTunnelStatus) {
    latestStatus = status
    if status.indicatesStartProgress {
      sawStartProgress = true
    }
  }
}

@MainActor
struct NetworkExtensionStartStatusWaiter {
  var timing: NetworkExtensionStartTiming = .production

  func wait(
    currentStatus: () -> NetworkExtensionTunnelStatus,
    observeStatusChanges: (@MainActor @escaping (NetworkExtensionTunnelStatus) -> Void) -> NetworkExtensionStatusObservation
  ) async throws -> NetworkExtensionTunnelStatus {
    let tracker = NetworkExtensionStartStatusTracker(initialStatus: currentStatus())
    let startedAt = Date()
    let observation = observeStatusChanges { status in
      tracker.record(status)
    }
    defer {
      observation.cancel()
    }

    while elapsedNanoseconds(since: startedAt) < timing.timeoutNanoseconds {
      tracker.record(currentStatus())
      let elapsed = elapsedNanoseconds(since: startedAt)
      if let result = terminalStartResult(
        for: tracker.latestStatus,
        elapsedNanoseconds: elapsed,
        sawStartProgress: tracker.sawStartProgress
      ) {
        return result
      }

      let remaining = timing.timeoutNanoseconds > elapsed ? timing.timeoutNanoseconds - elapsed : 0
      try await Task.sleep(nanoseconds: min(timing.pollIntervalNanoseconds, remaining))
    }

    tracker.record(currentStatus())
    if tracker.latestStatus == .connected {
      return .connected
    }
    if tracker.latestStatus == .disconnected || tracker.latestStatus == .invalid {
      return tracker.latestStatus
    }
    throw NetworkExtensionControllerError.transparentProxyStartTimedOut(tracker.latestStatus)
  }

  private func terminalStartResult(
    for status: NetworkExtensionTunnelStatus,
    elapsedNanoseconds: UInt64,
    sawStartProgress: Bool
  ) -> NetworkExtensionTunnelStatus? {
    switch status {
    case .connected:
      return .connected
    case .disconnected, .invalid:
      return sawStartProgress || elapsedNanoseconds >= timing.disconnectedGraceNanoseconds ? status : nil
    case .notConfigured, .connecting, .reasserting, .disconnecting:
      return nil
    }
  }

  private func elapsedNanoseconds(since date: Date) -> UInt64 {
    let elapsedSeconds = max(0, Date().timeIntervalSince(date))
    return UInt64(elapsedSeconds * 1_000_000_000)
  }
}

@MainActor
protocol SystemExtensionRequesting: AnyObject {
  func activate(identifier: String) async -> NetworkExtensionInstallState
  func properties(identifier: String) async -> [SystemExtensionSnapshot]
}

@MainActor
protocol TransparentProxyManaging: AnyObject {
  func status(forProviderBundleIdentifier identifier: String) async throws -> NetworkExtensionTunnelStatus
  func removeLegacyPacketTunnelConfiguration(providerBundleIdentifier identifier: String) async throws
  func startProxy(configuration: NetworkExtensionRuntimeConfiguration) async throws -> NetworkExtensionTunnelStatus
  func stopProxy(providerBundleIdentifier identifier: String) async throws -> NetworkExtensionTunnelStatus
  func lastDisconnectError(forProviderBundleIdentifier identifier: String) async -> String?
}

@MainActor
protocol LaunchServicesRegistering: AnyObject {
  func registerCurrentApplicationIfNeeded() async throws
}

enum NetworkExtensionControllerError: LocalizedError, Equatable {
  case systemExtensionNotActivated(String)
  case applicationRegistrationFailed(String)
  case transparentProxyDisconnected(String)
  case transparentProxyStartTimedOut(NetworkExtensionTunnelStatus)
  case transparentProxyStopIncomplete(NetworkExtensionTunnelStatus)

  var errorDescription: String? {
    switch self {
    case let .systemExtensionNotActivated(message):
      return message
    case let .applicationRegistrationFailed(message):
      return message
    case let .transparentProxyDisconnected(message):
      return message
    case let .transparentProxyStartTimedOut(status):
      return "NE transparent proxy did not become connected before timeout. Last status: \(status.displayName)."
    case let .transparentProxyStopIncomplete(status):
      return "NE transparent proxy did not stop cleanly. Last status: \(status.displayName)."
    }
  }
}

@MainActor
final class NetworkExtensionController: ObservableObject {
  nonisolated static let providerBundleIdentifier = NetworkExtensionRuntimeConstants.providerBundleIdentifier
  nonisolated static let appGroupIdentifier = NetworkExtensionRuntimeConstants.appGroupIdentifier

  @Published private(set) var systemExtensionState: NetworkExtensionInstallState = .notInstalled
  @Published private(set) var vpnStatus: NetworkExtensionTunnelStatus = .disconnected
  @Published private(set) var recentError: String?

  private let systemExtensionRequester: any SystemExtensionRequesting
  private let transparentProxyManager: any TransparentProxyManaging
  private let launchServicesRegistrar: any LaunchServicesRegistering

  init(
    systemExtensionRequester: any SystemExtensionRequesting = OSSystemExtensionRequestBridge(),
    transparentProxyManager: any TransparentProxyManaging = NETransparentProxyManagerAdapter(),
    launchServicesRegistrar: any LaunchServicesRegistering = LaunchServicesAppRegistrar()
  ) {
    self.systemExtensionRequester = systemExtensionRequester
    self.transparentProxyManager = transparentProxyManager
    self.launchServicesRegistrar = launchServicesRegistrar
  }

  var statusMessage: String {
    systemExtensionState.message
  }

  var tunnelStatusMessage: String {
    switch vpnStatus {
    case .notConfigured:
      if systemExtensionState.isActivated {
        return "System Extension is approved. The transparent proxy is not created until Network Extension mode starts."
      }
      return "Transparent Proxy configuration will be created after the System Extension is approved and Network Extension mode starts."
    case .invalid:
      return "Transparent Proxy preferences are invalid or could not be loaded."
    case .disconnected:
      return "Transparent Proxy is configured but currently stopped."
    case .connecting:
      return "Transparent Proxy is connecting."
    case .connected:
      return "Transparent Proxy is connected."
    case .reasserting:
      return "Transparent Proxy is reconnecting."
    case .disconnecting:
      return "Transparent Proxy is disconnecting."
    }
  }

  func activateSystemExtension() async {
    systemExtensionState = .activating
    recentError = nil
    do {
      try await launchServicesRegistrar.registerCurrentApplicationIfNeeded()
    } catch {
      let message = UserFacingError.message(for: error)
      systemExtensionState = .failed(message)
      recentError = message
      return
    }
    let state = await systemExtensionRequester.activate(identifier: Self.providerBundleIdentifier)
    systemExtensionState = state
    if !state.isActivated {
      recentError = state.message
    }
  }

  func refreshStatus() async {
    recentError = nil
    do {
      try await launchServicesRegistrar.registerCurrentApplicationIfNeeded()
    } catch {
      recentError = UserFacingError.message(for: error)
    }
    let snapshots = await systemExtensionRequester.properties(identifier: Self.providerBundleIdentifier)
    systemExtensionState = Self.installState(from: snapshots)

    do {
      vpnStatus = try await transparentProxyManager.status(forProviderBundleIdentifier: Self.providerBundleIdentifier)
    } catch {
      vpnStatus = .invalid
      recentError = UserFacingError.message(for: error)
    }
  }

  func startTransparentProxy(configuration: NetworkExtensionRuntimeConfiguration) async throws {
    recentError = nil
    if !systemExtensionState.isActivated {
      await activateSystemExtension()
    }
    guard systemExtensionState.isActivated else {
      let message = systemExtensionState.message
      recentError = message
      throw NetworkExtensionControllerError.systemExtensionNotActivated(message)
    }
    do {
      try await launchServicesRegistrar.registerCurrentApplicationIfNeeded()
    } catch {
      let message = UserFacingError.message(for: error)
      recentError = message
      throw NetworkExtensionControllerError.applicationRegistrationFailed(message)
    }

    do {
      vpnStatus = .connecting
      try await transparentProxyManager.removeLegacyPacketTunnelConfiguration(
        providerBundleIdentifier: configuration.providerBundleIdentifier
      )
      let status = try await transparentProxyManager.startProxy(configuration: configuration)
      vpnStatus = status
      if status == .connected {
        return
      } else if status == .disconnected || status == .invalid {
        let message = await transparentProxyManager.lastDisconnectError(
          forProviderBundleIdentifier: configuration.providerBundleIdentifier
        ) ?? "NE transparent proxy disconnected before it became usable."
        recentError = message
        throw NetworkExtensionControllerError.transparentProxyDisconnected(message)
      } else {
        let error = NetworkExtensionControllerError.transparentProxyStartTimedOut(status)
        recentError = error.localizedDescription
        throw error
      }
    } catch {
      vpnStatus = (try? await transparentProxyManager.status(
        forProviderBundleIdentifier: configuration.providerBundleIdentifier
      )) ?? .disconnected
      let message = UserFacingError.message(for: error)
      recentError = message
      throw error
    }
  }

  @discardableResult
  func stopTransparentProxy() async throws -> NetworkExtensionTunnelStatus {
    recentError = nil
    do {
      vpnStatus = try await transparentProxyManager.stopProxy(providerBundleIdentifier: Self.providerBundleIdentifier)
      if vpnStatus.isActive {
        let error = NetworkExtensionControllerError.transparentProxyStopIncomplete(vpnStatus)
        recentError = error.localizedDescription
        throw error
      }
      return vpnStatus
    } catch {
      recentError = UserFacingError.message(for: error)
      throw error
    }
  }

  func openSystemExtensionSettings() {
    let candidates = [
      Self.networkExtensionsSettingsURL,
      URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"),
      URL(fileURLWithPath: "/System/Applications/System Settings.app")
    ].compactMap(\.self)

    for url in candidates where NSWorkspace.shared.open(url) {
      return
    }
  }

  nonisolated static var networkExtensionsSettingsURL: URL? {
    URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extension-points=com.apple.system_extension.network_extension.extension-point")
  }

  private static func installState(from snapshots: [SystemExtensionSnapshot]) -> NetworkExtensionInstallState {
    if snapshots.contains(where: { $0.isEnabled && !$0.isAwaitingUserApproval && !$0.isUninstalling }) {
      return .activated
    }
    if snapshots.contains(where: { $0.isAwaitingUserApproval && !$0.isUninstalling }) {
      return .requiresApproval
    }
    if snapshots.contains(where: \.isUninstalling) {
      return .failed("System Extension is uninstalling. Restart macOS before retrying.")
    }
    if snapshots.contains(where: \.isEnabled) {
      return .activated
    }
    return .notInstalled
  }
}

@MainActor
final class OSSystemExtensionRequestBridge: NSObject, SystemExtensionRequesting {
  private let delegateStore = SystemExtensionDelegateStore()

  func activate(identifier: String) async -> NetworkExtensionInstallState {
    await withCheckedContinuation { continuation in
      let requestID = UUID()
      let request = OSSystemExtensionRequest.activationRequest(
        forExtensionWithIdentifier: identifier,
        queue: .main
      )
      let delegate = SystemExtensionDelegate { [weak self] state in
        self?.delegateStore.release(requestID)
        continuation.resume(returning: state)
      }
      delegateStore.retain(delegate, id: requestID)
      request.delegate = delegate
      OSSystemExtensionManager.shared.submitRequest(request)
    }
  }

  func properties(identifier: String) async -> [SystemExtensionSnapshot] {
    await withCheckedContinuation { continuation in
      let requestID = UUID()
      let request = OSSystemExtensionRequest.propertiesRequest(
        forExtensionWithIdentifier: identifier,
        queue: .main
      )
      let delegate = SystemExtensionDelegate { [weak self] _ in
        self?.delegateStore.release(requestID)
        continuation.resume(returning: [])
      } propertiesHandler: { [weak self] snapshots in
        self?.delegateStore.release(requestID)
        continuation.resume(returning: snapshots)
      }
      delegateStore.retain(delegate, id: requestID)
      request.delegate = delegate
      OSSystemExtensionManager.shared.submitRequest(request)
    }
  }
}

@MainActor
final class SystemExtensionDelegateStore {
  private var delegates: [UUID: AnyObject] = [:]

  @discardableResult
  func retain(_ delegate: AnyObject, id: UUID = UUID()) -> UUID {
    delegates[id] = delegate
    return id
  }

  func release(_ id: UUID) {
    delegates.removeValue(forKey: id)
  }

  var retainedDelegateCount: Int {
    delegates.count
  }
}

private final class SystemExtensionDelegate: NSObject, OSSystemExtensionRequestDelegate {
  private let completion: (NetworkExtensionInstallState) -> Void
  private let propertiesHandler: ([SystemExtensionSnapshot]) -> Void
  private var didComplete = false

  init(
    completion: @escaping (NetworkExtensionInstallState) -> Void,
    propertiesHandler: @escaping ([SystemExtensionSnapshot]) -> Void = { _ in }
  ) {
    self.completion = completion
    self.propertiesHandler = propertiesHandler
  }

  func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension ext: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    finish(.requiresApproval)
  }

  func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    switch result {
    case .completed:
      finish(.activated)
    case .willCompleteAfterReboot:
      finish(.needsReboot)
    @unknown default:
      finish(.activated)
    }
  }

  func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    finish(Self.state(for: error))
  }

  func request(_ request: OSSystemExtensionRequest, foundProperties properties: [OSSystemExtensionProperties]) {
    let snapshots = properties.map {
      SystemExtensionSnapshot(
        isEnabled: $0.isEnabled,
        isAwaitingUserApproval: $0.isAwaitingUserApproval,
        isUninstalling: $0.isUninstalling
      )
    }
    didComplete = true
    propertiesHandler(snapshots)
  }

  private func finish(_ state: NetworkExtensionInstallState) {
    guard !didComplete else { return }
    didComplete = true
    completion(state)
  }

  private static func state(for error: Error) -> NetworkExtensionInstallState {
    let nsError = error as NSError
    guard nsError.domain == OSSystemExtensionErrorDomain else {
      return .failed(UserFacingError.message(for: error))
    }
    switch nsError.code {
    case 2:
      return .missingEntitlementOrProfile
    case 3:
      return .unsupportedBundleLocation
    case 8:
      return .codeSignatureInvalid
    case 13:
      return .requiresApproval
    default:
      return .failed(UserFacingError.message(for: error))
    }
  }
}

private struct SendableVPNConnectionStatusReader: @unchecked Sendable {
  let connection: NEVPNConnection

  @MainActor
  func status() -> NetworkExtensionTunnelStatus {
    NetworkExtensionTunnelStatus(connection.status)
  }
}

@MainActor
final class LaunchServicesAppRegistrar: LaunchServicesRegistering {
  private static let lsregisterURL = URL(
    fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  )

  private let bundleURL: URL
  private let fileManager: FileManager

  init(
    bundleURL: URL = Bundle.main.bundleURL,
    fileManager: FileManager = .default
  ) {
    self.bundleURL = bundleURL
    self.fileManager = fileManager
  }

  func registerCurrentApplicationIfNeeded() async throws {
    let applicationURL = bundleURL.standardizedFileURL
    guard applicationURL.pathExtension == "app" else {
      return
    }
    guard applicationURL.path == "/Applications/ClashMax.app" else {
      return
    }

    let systemExtensionURL = applicationURL
      .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
      .appendingPathComponent("\(NetworkExtensionController.providerBundleIdentifier).systemextension", isDirectory: true)
    guard fileManager.fileExists(atPath: systemExtensionURL.path) else {
      return
    }

    let result = try await ProcessOutputCapture.run(
      executable: Self.lsregisterURL,
      arguments: ["-f", "-R", applicationURL.path],
      timeout: 10
    )
    guard result.terminationStatus == 0 else {
      let output = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
      throw NSError(
        domain: "ClashMax.LaunchServicesRegistration",
        code: Int(result.terminationStatus),
        userInfo: [
          NSLocalizedDescriptionKey: [
            "Could not refresh LaunchServices registration for /Applications/ClashMax.app.",
            output
          ].filter { !$0.isEmpty }.joined(separator: " ")
        ]
      )
    }
  }
}

@MainActor
final class NETransparentProxyManagerAdapter: TransparentProxyManaging {
  private let startWaiter = NetworkExtensionStartStatusWaiter()

  func status(forProviderBundleIdentifier identifier: String) async throws -> NetworkExtensionTunnelStatus {
    guard let manager = try await manager(forProviderBundleIdentifier: identifier) else {
      return .notConfigured
    }
    return NetworkExtensionTunnelStatus(manager.connection.status)
  }

  func removeLegacyPacketTunnelConfiguration(providerBundleIdentifier identifier: String) async throws {
    let managers = try await loadLegacyPacketTunnelManagers()
    for manager in managers where (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier {
      if manager.connection.status.isActive {
        manager.connection.stopVPNTunnel()
      }
      try await removeFromPreferences(manager)
    }
  }

  func startProxy(configuration: NetworkExtensionRuntimeConfiguration) async throws -> NetworkExtensionTunnelStatus {
    let manager = try await configuredManager(configuration)
    try manager.connection.startVPNTunnel(options: [
      "socksHost": configuration.socksHost as NSString,
      "socksPort": String(configuration.socksPort) as NSString
    ])
    return try await waitForStartResult(manager)
  }

  func stopProxy(providerBundleIdentifier identifier: String) async throws -> NetworkExtensionTunnelStatus {
    guard let manager = try await manager(forProviderBundleIdentifier: identifier) else {
      return .disconnected
    }
    manager.connection.stopVPNTunnel()
    return await waitForStopResult(manager)
  }

  func lastDisconnectError(forProviderBundleIdentifier identifier: String) async -> String? {
    guard let manager = try? await manager(forProviderBundleIdentifier: identifier) else {
      return nil
    }
    return await withCheckedContinuation { continuation in
      manager.connection.fetchLastDisconnectError { error in
        continuation.resume(returning: error.map(UserFacingError.message))
      }
    }
  }

  private func configuredManager(_ configuration: NetworkExtensionRuntimeConfiguration) async throws -> NETransparentProxyManager {
    let manager = try await manager(forProviderBundleIdentifier: configuration.providerBundleIdentifier) ?? NETransparentProxyManager()
    let tunnelProtocol = NETunnelProviderProtocol()
    tunnelProtocol.providerBundleIdentifier = configuration.providerBundleIdentifier
    tunnelProtocol.serverAddress = configuration.serverAddress
    tunnelProtocol.providerConfiguration = configuration.providerConfiguration
    manager.localizedDescription = configuration.localizedDescription
    manager.protocolConfiguration = tunnelProtocol
    manager.isEnabled = true
    try await saveToPreferences(manager)
    try await loadFromPreferences(manager)
    return manager
  }

  private func manager(forProviderBundleIdentifier identifier: String) async throws -> NETransparentProxyManager? {
    let managers = try await loadAllFromPreferences()
    return managers.first { manager in
      (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
    }
  }

  private func waitForStartResult(_ manager: NETransparentProxyManager) async throws -> NetworkExtensionTunnelStatus {
    let statusReader = SendableVPNConnectionStatusReader(connection: manager.connection)
    return try await startWaiter.wait(
      currentStatus: {
        statusReader.status()
      },
      observeStatusChanges: { handler in
        let observer = NotificationCenter.default.addObserver(
          forName: .NEVPNStatusDidChange,
          object: statusReader.connection,
          queue: .main
        ) { _ in
          Task { @MainActor in
            handler(statusReader.status())
          }
        }
        return NetworkExtensionStatusObservation {
          NotificationCenter.default.removeObserver(observer)
        }
      }
    )
  }

  private func waitForStopResult(_ manager: NETransparentProxyManager) async -> NetworkExtensionTunnelStatus {
    for _ in 0..<80 {
      let status = NetworkExtensionTunnelStatus(manager.connection.status)
      if status == .disconnected || status == .invalid {
        return status
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return NetworkExtensionTunnelStatus(manager.connection.status)
  }

  private func loadAllFromPreferences() async throws -> [NETransparentProxyManager] {
    let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NonSendableBox<[NETransparentProxyManager]>, Error>) in
      NETransparentProxyManager.loadAllFromPreferences { managers, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: NonSendableBox(managers ?? []))
        }
      }
    }
    return box.value
  }

  private func loadLegacyPacketTunnelManagers() async throws -> [NETunnelProviderManager] {
    let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NonSendableBox<[NETunnelProviderManager]>, Error>) in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: NonSendableBox(managers ?? []))
        }
      }
    }
    return box.value
  }

  private func saveToPreferences(_ manager: NEVPNManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.saveToPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func loadFromPreferences(_ manager: NEVPNManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.loadFromPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  private func removeFromPreferences(_ manager: NEVPNManager) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      manager.removeFromPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

private final class NonSendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

extension NetworkExtensionTunnelStatus {
  init(_ status: NEVPNStatus) {
    switch status {
    case .invalid:
      self = .invalid
    case .disconnected:
      self = .disconnected
    case .connecting:
      self = .connecting
    case .connected:
      self = .connected
    case .reasserting:
      self = .reasserting
    case .disconnecting:
      self = .disconnecting
    @unknown default:
      self = .invalid
    }
  }
}

private extension NEVPNStatus {
  var isActive: Bool {
    switch self {
    case .connecting, .connected, .reasserting, .disconnecting:
      return true
    case .invalid, .disconnected:
      return false
    @unknown default:
      return false
    }
  }
}
