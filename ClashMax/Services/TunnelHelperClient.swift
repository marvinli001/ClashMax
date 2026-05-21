import CryptoKit
import Foundation
import ServiceManagement

protocol HelperXPCTransport: Sendable {
  func status() async throws -> HelperClientResponse
  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse
  func stopTunnel() async throws -> HelperClientResponse
  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse
  func recentLogs() async throws -> [String]
}

@MainActor
protocol HelperServiceManaging: AnyObject {
  var status: SMAppService.Status { get }
  func register() throws
  func unregister() async throws
  func openSystemSettingsLoginItems()
}

@MainActor
final class SMAppServiceHelperService: HelperServiceManaging {
  private let service: SMAppService

  init(service: SMAppService = SMAppService.daemon(plistName: "io.github.clashmax.ClashMax.Helper.plist")) {
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

protocol HelperFingerprintProviding: Sendable {
  func currentFingerprint() throws -> String
}

struct AppBundleHelperFingerprintProvider: HelperFingerprintProviding {
  let helperURL: URL
  let launchDaemonPlistURL: URL

  init(bundleURL: URL = Bundle.main.bundleURL) {
    helperURL = bundleURL.appendingPathComponent("Contents/Library/LaunchServices/ClashMaxHelper")
    launchDaemonPlistURL = bundleURL
      .appendingPathComponent("Contents/Library/LaunchDaemons/io.github.clashmax.ClashMax.Helper.plist")
  }

  func currentFingerprint() throws -> String {
    var data = Data()
    for url in [helperURL, launchDaemonPlistURL] {
      let fileData = try Data(contentsOf: url)
      data.append(url.path.data(using: .utf8) ?? Data())
      data.append(0)
      data.append(fileData)
      data.append(0)
    }
    let digest = SHA256.hash(data: data)
    return digest.map { String(format: "%02x", $0) }.joined()
  }
}

protocol HelperRegistrationRecordStoring: Sendable {
  func helperFingerprint() -> String?
  func setHelperFingerprint(_ fingerprint: String?)
}

final class UserDefaultsHelperRegistrationRecordStore: HelperRegistrationRecordStoring, @unchecked Sendable {
  private let defaults: UserDefaults
  private let key = "io.github.clashmax.helper.registrationFingerprint"

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func helperFingerprint() -> String? {
    defaults.string(forKey: key)
  }

  func setHelperFingerprint(_ fingerprint: String?) {
    if let fingerprint {
      defaults.set(fingerprint, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

struct HelperClientResponse: Sendable {
  var ok: Bool
  var running: Bool
  var pid: Int
  var code: String
  var message: String

  init(payload: NSString) {
    let dictionary = HelperXPCPayload.responseDictionary(from: payload)
    ok = dictionary[HelperResponseKey.ok] as? Bool ?? false
    running = dictionary[HelperResponseKey.running] as? Bool ?? false
    pid = (dictionary[HelperResponseKey.pid] as? NSNumber)?.intValue
      ?? dictionary[HelperResponseKey.pid] as? Int
      ?? 0
    code = dictionary[HelperResponseKey.code] as? String ?? ""
    message = dictionary[HelperResponseKey.message] as? String ?? ""
  }

  static func failure(_ message: String, code: String = "") -> HelperClientResponse {
    HelperClientResponse(ok: false, running: false, pid: 0, code: code, message: message)
  }

  private init(ok: Bool, running: Bool, pid: Int, code: String, message: String) {
    self.ok = ok
    self.running = running
    self.pid = pid
    self.code = code
    self.message = message
  }

  var userFacingMessage: String {
    let fallback = message.isEmpty ? "Helper returned an empty error response." : message
    switch code {
    case HelperResponseCode.alreadyRunning:
      return pid > 0
        ? "TUN helper reports Mihomo is already running as PID \(pid). Stop TUN and retry."
        : "TUN helper reports Mihomo is already running. Stop TUN and retry."
    case HelperResponseCode.invalidPath:
      return "TUN helper rejected an unsafe core, config, or workdir path. Move ClashMax to a trusted app location and retry."
    case HelperResponseCode.untrustedSignature:
      return "TUN helper rejected the app or core signature. Reinstall a signed ClashMax build, then click Repair Helper."
    case HelperResponseCode.launchFailed:
      return "TUN helper could not launch Mihomo: \(fallback)"
    default:
      return fallback
    }
  }
}

enum TunnelHelperServiceStatus: String, Equatable, Sendable {
  case notRegistered
  case enabled
  case requiresApproval
  case notFound
  case unknown

  init(_ status: SMAppService.Status) {
    switch status {
    case .notRegistered:
      self = .notRegistered
    case .enabled:
      self = .enabled
    case .requiresApproval:
      self = .requiresApproval
    case .notFound:
      self = .notFound
    @unknown default:
      self = .unknown
    }
  }

  var displayName: String {
    switch self {
    case .notRegistered: "Not Registered"
    case .enabled: "Enabled"
    case .requiresApproval: "Requires Approval"
    case .notFound: "Not Found"
    case .unknown: "Unknown"
    }
  }
}

struct TunnelHelperStatusDetail: Equatable, Sendable {
  var serviceStatus: TunnelHelperServiceStatus
  var registered: Bool
  var enabled: Bool
  var requiresApproval: Bool
  var bootstrapped: Bool
  var fingerprintRecorded: Bool
  var fingerprintMatches: Bool?
  var xpcReachable: Bool
  var running: Bool
  var pid: Int?
  var message: String

  static let unknown = TunnelHelperStatusDetail(
    serviceStatus: .unknown,
    registered: false,
    enabled: false,
    requiresApproval: false,
    bootstrapped: false,
    fingerprintRecorded: false,
    fingerprintMatches: nil,
    xpcReachable: false,
    running: false,
    pid: nil,
    message: String(localized: "Helper status has not been checked.")
  )
}

@MainActor
final class TunnelHelperClient: ObservableObject {
  @Published var statusMessage: String = "Not registered"
  private let transport: any HelperXPCTransport
  private let service: any HelperServiceManaging
  private let fingerprintProvider: any HelperFingerprintProviding
  private let registrationRecordStore: any HelperRegistrationRecordStoring
  private let bootstrapStatusTimeoutSeconds: TimeInterval
  private var automaticBootstrapRepairFingerprint: String?

  init(
    transport: any HelperXPCTransport = PrivilegedHelperXPCTransport(),
    service: any HelperServiceManaging = SMAppServiceHelperService(),
    fingerprintProvider: any HelperFingerprintProviding = AppBundleHelperFingerprintProvider(),
    registrationRecordStore: any HelperRegistrationRecordStoring = UserDefaultsHelperRegistrationRecordStore(),
    bootstrapStatusTimeoutSeconds: TimeInterval = 2.5
  ) {
    self.transport = transport
    self.service = service
    self.fingerprintProvider = fingerprintProvider
    self.registrationRecordStore = registrationRecordStore
    self.bootstrapStatusTimeoutSeconds = bootstrapStatusTimeoutSeconds
  }

  func register() async throws {
    let fingerprint = try fingerprintProvider.currentFingerprint()
    switch service.status {
    case .enabled:
      if registrationRecordStore.helperFingerprint().map({ $0 != fingerprint }) == true {
        try await repairRegistration(fingerprint: fingerprint)
        return
      }
      registrationRecordStore.setHelperFingerprint(fingerprint)
      try await verifyBootstrapped()
    case .requiresApproval:
      statusMessage = Self.statusMessage(for: service.status)
      registrationRecordStore.setHelperFingerprint(fingerprint)
      openApprovalSettings()
    case .notRegistered, .notFound:
      try service.register()
      registrationRecordStore.setHelperFingerprint(fingerprint)
      try await updateStatusAfterRegistration()
    @unknown default:
      try service.register()
      registrationRecordStore.setHelperFingerprint(fingerprint)
      try await updateStatusAfterRegistration()
    }
  }

  func prepareForTunnelStart(openSystemSettingsWhenApprovalRequired: Bool = true) async -> TunHelperPreparationState {
    do {
      let fingerprint = try fingerprintProvider.currentFingerprint()
      return try await prepareForTunnelStart(
        fingerprint: fingerprint,
        openSystemSettingsWhenApprovalRequired: openSystemSettingsWhenApprovalRequired
      )
    } catch {
      let message = UserFacingError.message(for: error)
      statusMessage = message
      return .failed(message)
    }
  }

  func warmRegistration() async -> TunHelperPreparationState {
    do {
      let fingerprint = try fingerprintProvider.currentFingerprint()
      switch service.status {
      case .enabled:
        if registrationRecordStore.helperFingerprint() == nil {
          registrationRecordStore.setHelperFingerprint(fingerprint)
        }
        statusMessage = Self.registeredMessage
        return .registered(Self.registeredMessage)
      case .requiresApproval:
        registrationRecordStore.setHelperFingerprint(fingerprint)
        let message = Self.statusMessage(for: .requiresApproval)
        statusMessage = message
        return .requiresApproval(message)
      case .notRegistered:
        try service.register()
        registrationRecordStore.setHelperFingerprint(fingerprint)
        return warmPreparationStateAfterRegistration()
      case .notFound:
        let message = Self.statusMessage(for: service.status)
        statusMessage = message
        return .failed(message)
      @unknown default:
        let message = Self.statusMessage(for: service.status)
        statusMessage = message
        return .failed(message)
      }
    } catch {
      let message = UserFacingError.message(for: error)
      statusMessage = message
      return .failed(message)
    }
  }

  func openApprovalSettings() {
    service.openSystemSettingsLoginItems()
  }

  func repairRegistration() async throws {
    try await repairRegistration(fingerprint: fingerprintProvider.currentFingerprint())
  }

  func unregister() async throws {
    try await service.unregister()
    registrationRecordStore.setHelperFingerprint(nil)
    automaticBootstrapRepairFingerprint = nil
    statusMessage = Self.statusMessage(for: service.status)
  }

  func resetRegistrationState() {
    registrationRecordStore.setHelperFingerprint(nil)
    automaticBootstrapRepairFingerprint = nil
    statusMessage = Self.statusMessage(for: service.status)
  }

  func statusDetail() async -> TunnelHelperStatusDetail {
    let serviceStatus = TunnelHelperServiceStatus(service.status)
    let storedFingerprint = registrationRecordStore.helperFingerprint()
    let currentFingerprint = try? fingerprintProvider.currentFingerprint()
    let fingerprintMatches = currentFingerprint.map { storedFingerprint == $0 }
    let baseMessage = Self.statusMessage(for: service.status)

    guard service.status == .enabled else {
      return TunnelHelperStatusDetail(
        serviceStatus: serviceStatus,
        registered: serviceStatus == .requiresApproval,
        enabled: false,
        requiresApproval: serviceStatus == .requiresApproval,
        bootstrapped: false,
        fingerprintRecorded: storedFingerprint != nil,
        fingerprintMatches: fingerprintMatches,
        xpcReachable: false,
        running: false,
        pid: nil,
        message: baseMessage
      )
    }

    do {
      let response = try await statusWithTimeout()
      let isRunning = response.running || response.pid > 0
      let message = response.ok
        ? Self.bootstrappedMessage
        : response.userFacingMessage
      return TunnelHelperStatusDetail(
        serviceStatus: serviceStatus,
        registered: true,
        enabled: true,
        requiresApproval: false,
        bootstrapped: response.ok,
        fingerprintRecorded: storedFingerprint != nil,
        fingerprintMatches: fingerprintMatches,
        xpcReachable: true,
        running: isRunning,
        pid: response.pid > 0 ? response.pid : nil,
        message: message
      )
    } catch {
      return TunnelHelperStatusDetail(
        serviceStatus: serviceStatus,
        registered: true,
        enabled: true,
        requiresApproval: false,
        bootstrapped: false,
        fingerprintRecorded: storedFingerprint != nil,
        fingerprintMatches: fingerprintMatches,
        xpcReachable: false,
        running: false,
        pid: nil,
        message: "TUN helper XPC is unreachable: \(UserFacingError.message(for: error))"
      )
    }
  }

  func refreshRegistrationStatus() async {
    switch service.status {
    case .enabled:
      do {
        try await verifyBootstrapped()
      } catch {
        statusMessage = Self.notBootstrappedMessage
      }
    default:
      statusMessage = Self.statusMessage(for: service.status)
    }
  }

  func currentPreparationState() async -> TunHelperPreparationState {
    switch service.status {
    case .enabled:
      return await bootstrappedPreparationState()
    case .requiresApproval:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .requiresApproval(message)
    case .notRegistered:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .idle
    case .notFound:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .failed(message)
    @unknown default:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .failed(message)
    }
  }

  static func statusMessage(for status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered:
      return String(localized: "Helper not registered. Click Register or Start in TUN mode.")
    case .enabled:
      return String(localized: "Helper registered. Verifying helper connection.")
    case .requiresApproval:
      return String(localized: "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status.")
    case .notFound:
      return String(localized: "Helper not found in the app bundle. Clean build and run ClashMax again.")
    @unknown default:
      return String(localized: "Helper status is unknown. Clean build and run ClashMax again.")
    }
  }

  static let bootstrappedMessage = String(localized: "Helper registered and bootstrapped.")
  static let registeredMessage = String(localized: "TUN helper is registered.")
  static let notBootstrappedMessage = String(localized: "TUN helper is registered, but launchd cannot start it. Click Repair after installing the latest build.")

  private func repairRegistration(fingerprint: String) async throws {
    switch service.status {
    case .requiresApproval:
      registrationRecordStore.setHelperFingerprint(fingerprint)
      statusMessage = Self.statusMessage(for: .requiresApproval)
      openApprovalSettings()
      return
    case .enabled:
      let storedFingerprint = registrationRecordStore.helperFingerprint()
      if storedFingerprint == nil || storedFingerprint == fingerprint {
        do {
          try await verifyBootstrapped()
          registrationRecordStore.setHelperFingerprint(fingerprint)
          return
        } catch {
          // XPC unhealthy — fall through to re-register.
        }
      }
      try await service.unregister()
    case .notRegistered, .notFound:
      break
    @unknown default:
      try await service.unregister()
    }
    try service.register()
    registrationRecordStore.setHelperFingerprint(fingerprint)
    try await updateStatusAfterRegistration()
  }

  private func updateStatusAfterRegistration() async throws {
    switch service.status {
    case .enabled:
      try await verifyBootstrapped()
    case .requiresApproval, .notRegistered, .notFound:
      statusMessage = Self.statusMessage(for: service.status)
      if service.status == .requiresApproval {
        openApprovalSettings()
      }
    @unknown default:
      statusMessage = Self.statusMessage(for: service.status)
    }
  }

  private func prepareForTunnelStart(
    fingerprint: String,
    openSystemSettingsWhenApprovalRequired: Bool
  ) async throws -> TunHelperPreparationState {
    switch service.status {
    case .enabled:
      if registrationRecordStore.helperFingerprint().map({ $0 != fingerprint }) == true {
        return try await reregisterEnabledHelper(
          fingerprint: fingerprint,
          openSystemSettingsWhenApprovalRequired: openSystemSettingsWhenApprovalRequired
        )
      }
      registrationRecordStore.setHelperFingerprint(fingerprint)
      return try await enabledPreparationState(
        fingerprint: fingerprint,
        openSystemSettingsWhenApprovalRequired: openSystemSettingsWhenApprovalRequired
      )
    case .requiresApproval:
      registrationRecordStore.setHelperFingerprint(fingerprint)
      return approvalRequiredState(openSystemSettings: openSystemSettingsWhenApprovalRequired)
    case .notRegistered:
      try service.register()
      registrationRecordStore.setHelperFingerprint(fingerprint)
      return await preparationStateAfterRegistration(
        openSystemSettingsWhenApprovalRequired: openSystemSettingsWhenApprovalRequired
      )
    case .notFound:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .failed(message)
    @unknown default:
      try service.register()
      registrationRecordStore.setHelperFingerprint(fingerprint)
      return await preparationStateAfterRegistration(
        openSystemSettingsWhenApprovalRequired: openSystemSettingsWhenApprovalRequired
      )
    }
  }

  private func preparationStateAfterRegistration(openSystemSettingsWhenApprovalRequired: Bool) async -> TunHelperPreparationState {
    switch service.status {
    case .enabled:
      return await bootstrappedPreparationState()
    case .requiresApproval:
      return approvalRequiredState(openSystemSettings: openSystemSettingsWhenApprovalRequired)
    case .notRegistered:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .notBootstrapped(message)
    case .notFound:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .failed(message)
    @unknown default:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .failed(message)
    }
  }

  private func warmPreparationStateAfterRegistration() -> TunHelperPreparationState {
    switch service.status {
    case .enabled:
      statusMessage = Self.registeredMessage
      return .registered(Self.registeredMessage)
    case .requiresApproval:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .requiresApproval(message)
    case .notRegistered:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .idle
    case .notFound:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .failed(message)
    @unknown default:
      let message = Self.statusMessage(for: service.status)
      statusMessage = message
      return .failed(message)
    }
  }

  private func approvalRequiredState(openSystemSettings: Bool) -> TunHelperPreparationState {
    let message = Self.statusMessage(for: service.status)
    statusMessage = message
    if openSystemSettings {
      openApprovalSettings()
    }
    return .requiresApproval(message)
  }

  private func enabledPreparationState(
    fingerprint: String,
    openSystemSettingsWhenApprovalRequired: Bool
  ) async throws -> TunHelperPreparationState {
    let state = await bootstrappedPreparationState()
    if state.isReady {
      return state
    }

    guard case .notBootstrapped = state,
          automaticBootstrapRepairFingerprint != fingerprint
    else {
      return state
    }

    automaticBootstrapRepairFingerprint = fingerprint
    let repairedState = try await reregisterEnabledHelper(
      fingerprint: fingerprint,
      openSystemSettingsWhenApprovalRequired: openSystemSettingsWhenApprovalRequired
    )
    return repairedState
  }

  private func reregisterEnabledHelper(
    fingerprint: String,
    openSystemSettingsWhenApprovalRequired: Bool
  ) async throws -> TunHelperPreparationState {
    try await service.unregister()
    try service.register()
    registrationRecordStore.setHelperFingerprint(fingerprint)
    return await preparationStateAfterRegistration(
      openSystemSettingsWhenApprovalRequired: openSystemSettingsWhenApprovalRequired
    )
  }

  private func bootstrappedPreparationState() async -> TunHelperPreparationState {
    do {
      let response = try await statusWithTimeout()
      guard response.ok else {
        let message = response.message.isEmpty ? Self.notBootstrappedMessage : response.message
        statusMessage = message
        return .notBootstrapped(message)
      }
      markHelperBootstrapped()
      return .ready
    } catch {
      statusMessage = Self.notBootstrappedMessage
      return .notBootstrapped(Self.notBootstrappedMessage)
    }
  }

  private func verifyBootstrapped() async throws {
    do {
      let response = try await statusWithTimeout()
      guard response.ok else {
        throw AppError.helperResponse(response.message.isEmpty ? Self.notBootstrappedMessage : response.message)
      }
      markHelperBootstrapped()
    } catch {
      statusMessage = Self.notBootstrappedMessage
      throw AppError.helperResponse(Self.notBootstrappedMessage)
    }
  }

  private func markHelperBootstrapped() {
    statusMessage = Self.bootstrappedMessage
    automaticBootstrapRepairFingerprint = nil
  }

  private func statusWithTimeout() async throws -> HelperClientResponse {
    try await withTimeout(seconds: bootstrapStatusTimeoutSeconds) { @Sendable [transport] in
      try await transport.status()
    }
  }

  func status() async throws -> HelperClientResponse {
    try await transport.status()
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await transport.startTunnel(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, secret: secret)
  }

  func stopTunnel() async throws -> HelperClientResponse {
    try await transport.stopTunnel()
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await transport.restartTunnel(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, secret: secret)
  }

  func recentLogs() async throws -> [String] {
    try await transport.recentLogs()
  }
}

struct PrivilegedHelperXPCTransport: HelperXPCTransport {
  func status() async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.status(withReply: reply)
    }
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.startTunnel(
        corePath: coreURL.path as NSString,
        configPath: configURL.path as NSString,
        workDirectoryPath: workDirectory.path as NSString,
        secret: secret as NSString,
        withReply: reply
      )
    }
  }

  func stopTunnel() async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.stopTunnel(withReply: reply)
    }
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.restartTunnel(
        corePath: coreURL.path as NSString,
        configPath: configURL.path as NSString,
        workDirectoryPath: workDirectory.path as NSString,
        secret: secret as NSString,
        withReply: reply
      )
    }
  }

  func recentLogs() async throws -> [String] {
    try await callLogs { proxy, reply in
      proxy.recentLogs(withReply: reply)
    }
  }

  private func callResponse(
    _ body: @escaping (ClashMaxHelperXPCProtocol, @escaping (NSString) -> Void) -> Void
  ) async throws -> HelperClientResponse {
    let connection = NSXPCConnection(machServiceName: clashMaxHelperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = ClashMaxHelperXPCInterface.make()
    let box = ContinuationBox<HelperClientResponse>()

    connection.invalidationHandler = {
      box.fail(AppError.helperResponse(HelperXPCConnectionMessage.invalidated), runCleanup: false)
    }
    connection.interruptionHandler = {
      box.fail(AppError.helperResponse("Helper connection interrupted."), runCleanup: false)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperClientResponse, Error>) in
        guard box.attach(continuation, cleanup: {
          connection.invalidate()
        }) else { return }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
          box.fail(error)
        } as? ClashMaxHelperXPCProtocol

        guard let proxy else {
          box.fail(AppError.helperResponse("Unable to connect to ClashMax Helper."))
          return
        }
        connection.resume()
        body(proxy) { payload in
          box.succeed(HelperClientResponse(payload: payload))
        }
      }
    } onCancel: {
      box.fail(CancellationError())
    }
  }

  private func callLogs(
    _ body: @escaping (ClashMaxHelperXPCProtocol, @escaping (NSString) -> Void) -> Void
  ) async throws -> [String] {
    let connection = NSXPCConnection(machServiceName: clashMaxHelperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = ClashMaxHelperXPCInterface.make()
    let box = ContinuationBox<[String]>()

    connection.invalidationHandler = {
      box.fail(AppError.helperResponse(HelperXPCConnectionMessage.invalidated), runCleanup: false)
    }
    connection.interruptionHandler = {
      box.fail(AppError.helperResponse("Helper connection interrupted."), runCleanup: false)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
        guard box.attach(continuation, cleanup: {
          connection.invalidate()
        }) else { return }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
          box.fail(error)
        } as? ClashMaxHelperXPCProtocol

        guard let proxy else {
          box.fail(AppError.helperResponse("Unable to connect to ClashMax Helper."))
          return
        }
        connection.resume()
        body(proxy) { payload in
          box.succeed(HelperXPCPayload.logLines(from: payload))
        }
      }
    } onCancel: {
      box.fail(CancellationError())
    }
  }
}

private enum HelperXPCConnectionMessage {
  static let invalidated = "Helper connection invalidated. Open System Settings > General > Login Items & Extensions, approve ClashMax, then click Repair Helper or restart macOS."
}

final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var cleanup: (() -> Void)?
  private var pendingResult: Result<Value, Error>?
  private var shouldRunPendingCleanup = false
  private var cleanupHasRun = false

  @discardableResult
  func attach(_ continuation: CheckedContinuation<Value, Error>, cleanup: @escaping () -> Void) -> Bool {
    let resultToResume: Result<Value, Error>?
    let cleanupToRun: (() -> Void)?
    let didAttach: Bool

    lock.lock()
    if let pendingResult {
      resultToResume = pendingResult
      didAttach = false
      if shouldRunPendingCleanup && !cleanupHasRun {
        cleanupToRun = cleanup
        cleanupHasRun = true
      } else {
        cleanupToRun = nil
      }
    } else {
      resultToResume = nil
      cleanupToRun = nil
      didAttach = true
      self.continuation = continuation
      self.cleanup = cleanup
    }
    lock.unlock()

    if let resultToResume {
      resume(continuation, with: resultToResume)
    }
    cleanupToRun?()
    return didAttach
  }

  func succeed(_ value: Value) {
    settle(.success(value), runCleanup: true)
  }

  func fail(_ error: Error, runCleanup: Bool = true) {
    settle(.failure(error), runCleanup: runCleanup)
  }

  private func settle(_ result: Result<Value, Error>, runCleanup: Bool) {
    let continuationToResume: CheckedContinuation<Value, Error>?
    let cleanupToRun: (() -> Void)?

    lock.lock()
    guard pendingResult == nil else {
      lock.unlock()
      return
    }
    pendingResult = result
    shouldRunPendingCleanup = runCleanup
    continuationToResume = self.continuation
    if continuationToResume != nil, runCleanup, !cleanupHasRun {
      cleanupToRun = self.cleanup
      cleanupHasRun = true
    } else {
      cleanupToRun = nil
    }
    self.continuation = nil
    self.cleanup = nil
    lock.unlock()

    if let continuationToResume {
      resume(continuationToResume, with: result)
    }
    cleanupToRun?()
  }

  private func resume(_ continuation: CheckedContinuation<Value, Error>, with result: Result<Value, Error>) {
    switch result {
    case let .success(value):
      continuation.resume(returning: value)
    case let .failure(error):
      continuation.resume(throwing: error)
    }
  }
}
