import CoreWLAN
import Foundation
import Network

struct NetworkEnvironmentEvent: Equatable, Sendable {
  var reason: String
  var network: WiFiNetworkSnapshot
  var pathStatus: String
  var isExpensive: Bool
  var isConstrained: Bool

  var ssid: String? {
    network.ssid
  }

  init(
    reason: String,
    network: WiFiNetworkSnapshot,
    pathStatus: String,
    isExpensive: Bool,
    isConstrained: Bool
  ) {
    self.reason = reason
    self.network = network
    self.pathStatus = pathStatus
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
  }

  init(
    reason: String,
    ssid: String?,
    pathStatus: String,
    isExpensive: Bool,
    isConstrained: Bool
  ) {
    self.init(
      reason: reason,
      network: ssid.map(WiFiNetworkSnapshot.joined) ?? .notChecked,
      pathStatus: pathStatus,
      isExpensive: isExpensive,
      isConstrained: isConstrained
    )
  }
}

protocol NetworkEnvironmentMonitoring: AnyObject, Sendable {
  var events: AsyncStream<NetworkEnvironmentEvent> { get }
  func start()
  func stop()
}

final class NetworkEnvironmentMonitor: NetworkEnvironmentMonitoring, @unchecked Sendable {
  private let monitor: NWPathMonitor
  private let queue = DispatchQueue(label: "io.github.clashmax.network-environment-monitor")
  private let currentNetworkProvider: any CurrentNetworkProviding
  private let wiFiClient: CWWiFiClient?
  private let stream: AsyncStream<NetworkEnvironmentEvent>
  private let continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation
  private let wiFiEventDelegate = WiFiEventDelegate()
  private var isStarted = false
  private var lastPathStatus = "unknown"
  private var lastIsExpensive = false
  private var lastIsConstrained = false

  init(
    monitor: NWPathMonitor = NWPathMonitor(),
    currentNetworkProvider: any CurrentNetworkProviding = CoreWLANCurrentNetworkProvider(),
    wiFiClient: CWWiFiClient? = CWWiFiClient.shared()
  ) {
    self.monitor = monitor
    self.currentNetworkProvider = currentNetworkProvider
    self.wiFiClient = wiFiClient
    var continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation!
    stream = AsyncStream { continuation = $0 }
    self.continuation = continuation
  }

  var events: AsyncStream<NetworkEnvironmentEvent> {
    stream
  }

  func start() {
    guard !isStarted else { return }
    isStarted = true
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      lastPathStatus = Self.label(for: path.status)
      lastIsExpensive = path.isExpensive
      lastIsConstrained = path.isConstrained
      emit(reason: "path")
    }
    monitor.start(queue: queue)
    startWiFiEventMonitoring()
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    stopWiFiEventMonitoring()
    monitor.cancel()
    continuation.finish()
  }

  deinit {
    stop()
  }

  /// Roaming between two Wi-Fi networks often keeps `NWPath` satisfied the whole time, so CoreWLAN
  /// events are what actually tell ClashMax the SSID changed. Power events cover Wi-Fi being toggled.
  private func startWiFiEventMonitoring() {
    guard let wiFiClient else { return }
    wiFiEventDelegate.onEvent = { [weak self] reason in
      self?.emit(reason: reason)
    }
    wiFiClient.delegate = wiFiEventDelegate
    try? wiFiClient.startMonitoringEvent(with: .ssidDidChange)
    try? wiFiClient.startMonitoringEvent(with: .powerDidChange)
    try? wiFiClient.startMonitoringEvent(with: .linkDidChange)
  }

  private func stopWiFiEventMonitoring() {
    wiFiEventDelegate.onEvent = nil
    guard let wiFiClient else { return }
    try? wiFiClient.stopMonitoringAllEvents()
    wiFiClient.delegate = nil
  }

  private func emit(reason: String) {
    continuation.yield(
      NetworkEnvironmentEvent(
        reason: reason,
        network: currentNetworkProvider.currentNetwork(),
        pathStatus: lastPathStatus,
        isExpensive: lastIsExpensive,
        isConstrained: lastIsConstrained
      )
    )
  }

  private static func label(for status: NWPath.Status) -> String {
    switch status {
    case .satisfied:
      return "satisfied"
    case .unsatisfied:
      return "unsatisfied"
    case .requiresConnection:
      return "requiresConnection"
    @unknown default:
      return "unknown"
    }
  }
}

/// CoreWLAN delivers these callbacks on its own queue, so the handler must be safe to call from
/// anywhere; it only forwards into the monitor's `AsyncStream`, which is itself thread-safe.
private final class WiFiEventDelegate: NSObject, CWEventDelegate, @unchecked Sendable {
  var onEvent: ((String) -> Void)?

  func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
    onEvent?("wifi-ssid")
  }

  func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
    onEvent?("wifi-power")
  }

  func linkDidChangeForWiFiInterface(withName interfaceName: String) {
    onEvent?("wifi-link")
  }
}
