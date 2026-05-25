import Foundation
import Network

struct NetworkEnvironmentEvent: Equatable, Sendable {
  var reason: String
  var ssid: String?
  var pathStatus: String
  var isExpensive: Bool
  var isConstrained: Bool
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
  private let stream: AsyncStream<NetworkEnvironmentEvent>
  private let continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation
  private var isStarted = false

  init(
    monitor: NWPathMonitor = NWPathMonitor(),
    currentNetworkProvider: any CurrentNetworkProviding = CoreWLANCurrentNetworkProvider()
  ) {
    self.monitor = monitor
    self.currentNetworkProvider = currentNetworkProvider
    var continuation: AsyncStream<NetworkEnvironmentEvent>.Continuation!
    self.stream = AsyncStream { continuation = $0 }
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
      continuation.yield(
        NetworkEnvironmentEvent(
          reason: "path",
          ssid: currentNetworkProvider.currentSSID(),
          pathStatus: Self.label(for: path.status),
          isExpensive: path.isExpensive,
          isConstrained: path.isConstrained
        )
      )
    }
    monitor.start(queue: queue)
  }

  func stop() {
    guard isStarted else { return }
    isStarted = false
    monitor.cancel()
    continuation.finish()
  }

  deinit {
    stop()
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
