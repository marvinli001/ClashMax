import Darwin
import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog

final class TransparentProxyProvider: NETransparentProxyProvider {
  private let logger = Logger(subsystem: "io.github.clashmax.ClashMax.NetworkExtension", category: "transparent-proxy")
  private let flowLock = NSLock()
  private var activeFlows: [ObjectIdentifier: TransparentTCPFlowBridge] = [:]
  private var mixedPort: UInt16 = 7890

  override func startProxy(
    options: [String: Any]? = nil,
    completionHandler: @escaping (Error?) -> Void
  ) {
    if let port = Self.mixedPort(from: options), (1...65_535).contains(port) {
      mixedPort = UInt16(port)
    }

    let completion = ProviderStartCompletion(handler: completionHandler)
    let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
    settings.includedNetworkRules = [
      NENetworkRule(
        remoteNetworkEndpoint: nil,
        remotePrefix: 0,
        localNetworkEndpoint: nil,
        localPrefix: 0,
        protocol: .TCP,
        direction: .outbound
      )
    ]

    setTunnelNetworkSettings(settings) { error in
      completion(error)
    }
  }

  override func stopProxy(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    let completion = ProviderStopCompletion(handler: completionHandler)
    flowLock.lock()
    let flows = Array(activeFlows.values)
    activeFlows.removeAll()
    flowLock.unlock()
    flows.forEach { $0.close() }
    completion()
  }

  override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
      logger.debug("Bypassing non-TCP flow.")
      return false
    }
    guard !shouldBypass(flow: tcpFlow) else {
      return false
    }
    guard let destination = Self.destination(for: tcpFlow) else {
      logger.debug("Bypassing TCP flow without a usable destination.")
      return false
    }

    let bridge = TransparentTCPFlowBridge(
      flow: tcpFlow,
      destination: destination,
      socksHost: "127.0.0.1",
      socksPort: mixedPort
    ) { [weak self, weak tcpFlow] in
      guard let self, let tcpFlow else { return }
      self.removeFlow(tcpFlow)
    }

    flowLock.lock()
    activeFlows[ObjectIdentifier(tcpFlow)] = bridge
    flowLock.unlock()
    bridge.start()
    return true
  }

  private func removeFlow(_ flow: NEAppProxyTCPFlow) {
    flowLock.lock()
    activeFlows.removeValue(forKey: ObjectIdentifier(flow))
    flowLock.unlock()
  }

  private func shouldBypass(flow: NEAppProxyTCPFlow) -> Bool {
    let signingIdentifier = flow.metaData.sourceAppSigningIdentifier.lowercased()
    if signingIdentifier.contains("clashmax") || signingIdentifier.contains("mihomo") {
      logger.debug("Bypassing source app \(signingIdentifier, privacy: .public).")
      return true
    }

    guard let destination = Self.destination(for: flow) else { return true }
    return Self.isLoopbackHost(destination.host)
  }

  private static func mixedPort(from options: [String: Any]?) -> Int? {
    if let port = options?["mixedPort"] as? Int {
      return port
    }
    if let port = options?["mixedPort"] as? NSNumber {
      return port.intValue
    }
    return nil
  }

  private static func destination(for flow: NEAppProxyTCPFlow) -> Socks5ConnectDestination? {
    guard case let .hostPort(endpointHost, endpointPort) = flow.remoteFlowEndpoint else {
      return nil
    }
    let hostname = flow.remoteHostname?.isEmpty == false
      ? flow.remoteHostname!
      : String(describing: endpointHost)
    return Socks5ConnectDestination(host: hostname, port: endpointPort.rawValue)
  }

  private static func isLoopbackHost(_ host: String) -> Bool {
    let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    if normalized == "localhost" || normalized == "::1" { return true }
    var ipv4 = in_addr()
    if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      return (UInt32(bigEndian: ipv4.s_addr) & 0xff00_0000) == 0x7f00_0000
    }
    return false
  }
}

private struct ProviderStartCompletion: @unchecked Sendable {
  let handler: (Error?) -> Void

  func callAsFunction(_ error: Error?) {
    handler(error)
  }
}

private struct ProviderStopCompletion: @unchecked Sendable {
  let handler: () -> Void

  func callAsFunction() {
    handler()
  }
}

private final class TransparentTCPFlowBridge: @unchecked Sendable {
  private let flow: NEAppProxyTCPFlow
  private let destination: Socks5ConnectDestination
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let onClose: () -> Void
  private let closeLock = NSLock()
  private var closed = false

  init(
    flow: NEAppProxyTCPFlow,
    destination: Socks5ConnectDestination,
    socksHost: String,
    socksPort: UInt16,
    onClose: @escaping () -> Void
  ) {
    self.flow = flow
    self.destination = destination
    self.connection = NWConnection(
      host: NWEndpoint.Host(socksHost),
      port: NWEndpoint.Port(rawValue: socksPort)!,
      using: .tcp
    )
    self.queue = DispatchQueue(label: "io.github.clashmax.ne.flow.\(UUID().uuidString)")
    self.onClose = onClose
  }

  func start() {
    flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
      guard let self else { return }
      if error != nil {
        self.close()
        return
      }
      self.startConnection()
    }
  }

  func close() {
    closeLock.lock()
    guard !closed else {
      closeLock.unlock()
      return
    }
    closed = true
    closeLock.unlock()
    connection.cancel()
    flow.closeReadWithError(nil)
    flow.closeWriteWithError(nil)
    onClose()
  }

  private func startConnection() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.startSocksHandshake()
      case .failed, .cancelled:
        self.close()
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  private func startSocksHandshake() {
    send(Socks5ConnectRequest.noAuthenticationGreeting) { [weak self] error in
      guard let self else { return }
      guard error == nil else {
        self.close()
        return
      }
      self.receive(minimum: 2, maximum: 2) { data in
        guard data == Data([0x05, 0x00]) else {
          self.close()
          return
        }
        self.sendConnectRequest()
      }
    }
  }

  private func sendConnectRequest() {
    do {
      let request = try Socks5ConnectRequest.make(destination: destination)
      send(request) { [weak self] error in
        guard let self else { return }
        guard error == nil else {
          self.close()
          return
        }
        self.receiveConnectReply {
          self.pumpFlowToConnection()
          self.pumpConnectionToFlow()
        }
      }
    } catch {
      close()
    }
  }

  private func receiveConnectReply(completion: @escaping @Sendable () -> Void) {
    receive(
      minimum: Socks5ConnectReply.minimumPrefixLength,
      maximum: Socks5ConnectReply.minimumPrefixLength
    ) { [weak self] prefix in
      guard let self else { return }
      do {
        let expectedLength = try Socks5ConnectReply.expectedLength(forPrefix: prefix)
        let remainingLength = expectedLength - prefix.count
        guard remainingLength > 0 else {
          completion()
          return
        }
        self.receive(minimum: remainingLength, maximum: remainingLength) { [weak self] tail in
          guard let self else { return }
          guard tail.count == remainingLength else {
            self.close()
            return
          }
          completion()
        }
      } catch {
        self.close()
      }
    }
  }

  private func pumpFlowToConnection() {
    flow.readData { [weak self] data, error in
      guard let self else { return }
      guard error == nil, let data, !data.isEmpty else {
        self.connection.send(content: nil, completion: .contentProcessed { _ in })
        return
      }
      self.send(data) { error in
        guard error == nil else {
          self.close()
          return
        }
        self.pumpFlowToConnection()
      }
    }
  }

  private func pumpConnectionToFlow() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      guard error == nil else {
        self.close()
        return
      }
      if let data, !data.isEmpty {
        self.flow.write(data) { error in
          guard error == nil else {
            self.close()
            return
          }
          if isComplete {
            self.flow.closeWriteWithError(nil)
          } else {
            self.pumpConnectionToFlow()
          }
        }
      } else {
        self.flow.closeWriteWithError(nil)
      }
    }
  }

  private func send(_ data: Data, completion: @escaping @Sendable (NWError?) -> Void) {
    connection.send(content: data, completion: .contentProcessed(completion))
  }

  private func receive(
    minimum: Int,
    maximum: Int,
    completion: @escaping @Sendable (Data) -> Void
  ) {
    connection.receive(minimumIncompleteLength: minimum, maximumLength: maximum) { [weak self] data, _, _, error in
      guard let self else { return }
      guard error == nil, let data else {
        self.close()
        return
      }
      completion(data)
    }
  }
}
