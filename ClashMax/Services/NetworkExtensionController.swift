import Foundation
@preconcurrency import NetworkExtension
import SystemExtensions

@MainActor
protocol NetworkExtensionControlling: AnyObject {
  var status: NetworkExtensionRuntimeStatus { get }
  var statusMessage: String { get }
  var recentError: String? { get }

  func refreshStatus() async
  func startTransparentProxy(mixedPort: Int) async throws -> NetworkExtensionRuntimeStatus
  func stopTransparentProxy() async throws -> NetworkExtensionRuntimeStatus
}

@MainActor
final class NetworkExtensionController: ObservableObject, NetworkExtensionControlling {
  @Published private(set) var status: NetworkExtensionRuntimeStatus = .disconnected
  @Published private(set) var statusMessage = String(localized: "Transparent Proxy is disconnected.")
  @Published private(set) var recentError: String?

  private static let localizedDescription = "ClashMax NE Transparent Proxy"
  private let bundleIdentifier: String
  private var activationDelegate: SystemExtensionActivationDelegate?

  init(bundleIdentifier: String = AppConstants.networkExtensionBundleIdentifier) {
    self.bundleIdentifier = bundleIdentifier
  }

  func refreshStatus() async {
    do {
      guard let manager = try await currentTransparentProxyManager() else {
        applyStatus(.disconnected)
        return
      }
      applyStatus(Self.runtimeStatus(from: manager.connection.status))
    } catch {
      let message = UserFacingError.message(for: error)
      recentError = message
      applyStatus(.unavailable(message))
    }
  }

  @discardableResult
  func startTransparentProxy(mixedPort: Int) async throws -> NetworkExtensionRuntimeStatus {
    recentError = nil
    applyStatus(.connecting)
    do {
      try await activateSystemExtension()
      try await removeLegacyPacketTunnelManagers()
      let manager = try await configuredTransparentProxyManager(mixedPort: mixedPort)
      try manager.connection.startVPNTunnel(options: ["mixedPort": NSNumber(value: mixedPort)])
      let connectedStatus = try await waitForStart(manager: manager)
      applyStatus(connectedStatus)
      return connectedStatus
    } catch {
      let message = UserFacingError.message(for: error)
      recentError = message
      await refreshStatus()
      throw AppError.networkExtensionResponse(message)
    }
  }

  @discardableResult
  func stopTransparentProxy() async throws -> NetworkExtensionRuntimeStatus {
    recentError = nil
    guard let manager = try await currentTransparentProxyManager() else {
      applyStatus(.disconnected)
      return .disconnected
    }

    applyStatus(.disconnecting)
    manager.connection.stopVPNTunnel()
    do {
      let stoppedStatus = try await waitForStop(manager: manager)
      applyStatus(stoppedStatus)
      return stoppedStatus
    } catch {
      let message = UserFacingError.message(for: error)
      recentError = message
      applyStatus(Self.runtimeStatus(from: manager.connection.status))
      throw AppError.networkExtensionResponse(message)
    }
  }

  private func activateSystemExtension() async throws {
    try await withCheckedThrowingContinuation { continuation in
      let delegate = SystemExtensionActivationDelegate(continuation: continuation)
      activationDelegate = delegate
      let request = OSSystemExtensionRequest.activationRequest(
        forExtensionWithIdentifier: bundleIdentifier,
        queue: .main
      )
      request.delegate = delegate
      OSSystemExtensionManager.shared.submitRequest(request)
    }
    activationDelegate = nil
  }

  private func configuredTransparentProxyManager(mixedPort: Int) async throws -> NETransparentProxyManager {
    let manager = try await currentTransparentProxyManager() ?? NETransparentProxyManager()
    let proto = NETunnelProviderProtocol()
    proto.providerBundleIdentifier = bundleIdentifier
    proto.serverAddress = "127.0.0.1:\(mixedPort)"
    proto.providerConfiguration = ["mixedPort": mixedPort]

    manager.localizedDescription = Self.localizedDescription
    manager.protocolConfiguration = proto
    manager.isEnabled = true
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
    return manager
  }

  private func currentTransparentProxyManager() async throws -> NETransparentProxyManager? {
    let managers = try await NETransparentProxyManager.loadAllFromPreferences()
    return managers.first { manager in
      guard manager.localizedDescription == Self.localizedDescription else {
        return (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleIdentifier
      }
      return true
    }
  }

  private func removeLegacyPacketTunnelManagers() async throws {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    for manager in managers {
      let providerID = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
      guard providerID == bundleIdentifier else { continue }
      try await manager.removeFromPreferences()
    }
  }

  private func waitForStart(manager: NETransparentProxyManager) async throws -> NetworkExtensionRuntimeStatus {
    let waiter = NetworkExtensionStartStatusWaiter()
    return try await waiter.wait {
      Self.runtimeStatus(from: manager.connection.status)
    }
  }

  private func waitForStop(manager: NETransparentProxyManager) async throws -> NetworkExtensionRuntimeStatus {
    try await waitForStatus(manager: manager, timeout: 8) { status in
      switch status {
      case .invalid, .disconnected:
        return true
      default:
        return false
      }
    }
  }

  private func waitForStatus(
    manager: NETransparentProxyManager,
    timeout: TimeInterval,
    predicate: (NetworkExtensionRuntimeStatus) throws -> Bool
  ) async throws -> NetworkExtensionRuntimeStatus {
    let deadline = Date().addingTimeInterval(timeout)
    var latest = Self.runtimeStatus(from: manager.connection.status)

    while Date() < deadline {
      latest = Self.runtimeStatus(from: manager.connection.status)
      if try predicate(latest) {
        return latest
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }

    throw AppError.networkExtensionResponse("NE transparent proxy timed out while \(latest.displayName.lowercased()).")
  }

  private func applyStatus(_ newStatus: NetworkExtensionRuntimeStatus) {
    status = newStatus
    statusMessage = "Transparent Proxy: \(newStatus.displayName)"
  }

  private static func runtimeStatus(from status: NEVPNStatus) -> NetworkExtensionRuntimeStatus {
    switch status {
    case .invalid:
      return .invalid
    case .disconnected:
      return .disconnected
    case .connecting:
      return .connecting
    case .connected:
      return .connected
    case .reasserting:
      return .reasserting
    case .disconnecting:
      return .disconnecting
    @unknown default:
      return .unavailable(String(localized: "macOS reported an unknown Network Extension status."))
    }
  }
}

struct NetworkExtensionStartStatusWaiter {
  var timeout: TimeInterval = 15
  var initialDisconnectedGrace: TimeInterval = 2
  var pollIntervalNanoseconds: UInt64 = 250_000_000
  var now: () -> Date = Date.init
  var sleep: (UInt64) async throws -> Void = { nanoseconds in
    try await Task.sleep(nanoseconds: nanoseconds)
  }

  @MainActor
  func wait(statusProvider: () -> NetworkExtensionRuntimeStatus) async throws -> NetworkExtensionRuntimeStatus {
    let startedAt = now()
    let deadline = startedAt.addingTimeInterval(timeout)
    var latest: NetworkExtensionRuntimeStatus = .disconnected
    var observedStartupProgress = false

    while now() < deadline {
      latest = statusProvider()
      switch latest {
      case .connected:
        return latest
      case .invalid:
        throw AppError.networkExtensionResponse("NE transparent proxy became invalid before it became usable.")
      case .connecting, .reasserting, .disconnecting:
        observedStartupProgress = true
      case .disconnected:
        if observedStartupProgress || now().timeIntervalSince(startedAt) >= initialDisconnectedGrace {
          throw AppError.networkExtensionResponse("NE transparent proxy disconnected before it became usable.")
        }
      case let .unavailable(message):
        throw AppError.networkExtensionResponse(message)
      }

      try await sleep(pollIntervalNanoseconds)
    }

    throw AppError.networkExtensionResponse("NE transparent proxy timed out while \(latest.displayName.lowercased()).")
  }
}

private final class SystemExtensionActivationDelegate: NSObject, OSSystemExtensionRequestDelegate {
  private var continuation: CheckedContinuation<Void, Error>?

  init(continuation: CheckedContinuation<Void, Error>) {
    self.continuation = continuation
  }

  func request(
    _ request: OSSystemExtensionRequest,
    actionForReplacingExtension existing: OSSystemExtensionProperties,
    withExtension extension: OSSystemExtensionProperties
  ) -> OSSystemExtensionRequest.ReplacementAction {
    .replace
  }

  func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
    resumeOnce(throwing: AppError.networkExtensionResponse(
      "Approve ClashMax Network Extension in System Settings, then start NE mode again."
    ))
  }

  func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
    resumeOnce()
  }

  func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
    resumeOnce(throwing: error)
  }

  private func resumeOnce(throwing error: Error? = nil) {
    guard let continuation else { return }
    self.continuation = nil
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
  }
}

private struct NonSendableBox<Value>: @unchecked Sendable {
  let value: Value
}

private extension NEVPNManager {
  func saveToPreferences() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      saveToPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func loadFromPreferences() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      loadFromPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }

  func removeFromPreferences() async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      removeFromPreferences { error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume()
        }
      }
    }
  }
}

private extension NETransparentProxyManager {
  static func loadAllFromPreferences() async throws -> [NETransparentProxyManager] {
    let box: NonSendableBox<[NETransparentProxyManager]> = try await withCheckedThrowingContinuation { continuation in
      loadAllFromPreferences { managers, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: NonSendableBox(value: managers ?? []))
        }
      }
    }
    return box.value
  }
}

private extension NETunnelProviderManager {
  static func loadAllFromPreferences() async throws -> [NETunnelProviderManager] {
    let box: NonSendableBox<[NETunnelProviderManager]> = try await withCheckedThrowingContinuation { continuation in
      loadAllFromPreferences { managers, error in
        if let error {
          continuation.resume(throwing: error)
        } else {
          continuation.resume(returning: NonSendableBox(value: managers ?? []))
        }
      }
    }
    return box.value
  }
}
