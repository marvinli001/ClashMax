import Foundation
import Network
import NetworkExtension
import os

final class TransparentProxyProvider: NETransparentProxyProvider, @unchecked Sendable, NEAppProxyUDPFlowHandling {
  private static let log = Logger(subsystem: "io.github.clashmax.ClashMax.NetworkExtension", category: "transparent-proxy")
  private static let defaultSocksHost = "127.0.0.1"
  private static let defaultSocksPort = 7890
  private static let bypassSourceSigningIdentifiers: Set<String> = [
    "io.github.clashmax.ClashMax",
    "io.github.clashmax.ClashMax.Helper",
    NetworkExtensionRuntimeConstants.providerBundleIdentifier,
    NetworkExtensionRuntimeConstants.mihomoArm64SigningIdentifier,
    NetworkExtensionRuntimeConstants.mihomoAmd64SigningIdentifier
  ]

  private let lock = NSLock()
  private var bridges: [UUID: TCPFlowBridge] = [:]
  private var socksHost = defaultSocksHost
  private var socksPort = defaultSocksPort

  override func startProxy(
    options: [String: Any]? = nil,
    completionHandler: @escaping ((any Error)?) -> Void
  ) {
    let completion = ProxyStartCompletion(completionHandler)
    let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
    socksHost = Self.stringValue(options?["socksHost"]) ?? Self.stringValue(configuration["socksHost"]) ?? Self.defaultSocksHost
    socksPort = Self.intValue(options?["socksPort"]) ?? Self.intValue(configuration["socksPort"]) ?? Self.defaultSocksPort

    Self.log.info("Starting transparent proxy; socks=\(self.socksHost, privacy: .public):\(self.socksPort, privacy: .public)")
    let settings = NETransparentProxyNetworkSettings(tunnelRemoteAddress: socksHost)
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
      if let error {
        Self.log.error("Failed to apply transparent proxy settings: \(error.localizedDescription, privacy: .public)")
        completion(error)
      } else {
        completion(nil)
      }
    }
  }

  override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    Self.log.info("Stopping transparent proxy, reason=\(reason.rawValue, privacy: .public)")
    let activeBridges = removeAllBridges()
    activeBridges.forEach { $0.cancel() }
    completionHandler()
  }

  override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
      Self.log.debug("Bypassing non-TCP transparent proxy flow.")
      return false
    }
    guard shouldProxy(flow: tcpFlow) else {
      return false
    }
    guard let endpoint = Self.socksEndpoint(from: tcpFlow) else {
      Self.log.debug("Bypassing TCP flow with unsupported remote endpoint.")
      return false
    }

    let id = UUID()
    let bridge = TCPFlowBridge(
      id: id,
      flow: tcpFlow,
      endpoint: endpoint,
      socksHost: socksHost,
      socksPort: socksPort
    ) { [weak self] id in
      self?.removeBridge(id: id)
    }
    insertBridge(bridge, id: id)
    bridge.start()
    return true
  }

  func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: NWEndpoint) -> Bool {
    Self.log.debug("Bypassing UDP flow; UDP transparent proxying is not enabled in this build.")
    return false
  }

  private func shouldProxy(flow: NEAppProxyFlow) -> Bool {
    let source = flow.metaData.sourceAppSigningIdentifier
    if Self.bypassSourceSigningIdentifiers.contains(source) {
      Self.log.debug("Bypassing self/core flow from \(source, privacy: .public).")
      return false
    }
    return true
  }

  private func insertBridge(_ bridge: TCPFlowBridge, id: UUID) {
    lock.lock()
    bridges[id] = bridge
    lock.unlock()
  }

  private func removeBridge(id: UUID) {
    lock.lock()
    bridges.removeValue(forKey: id)
    lock.unlock()
  }

  private func removeAllBridges() -> [TCPFlowBridge] {
    lock.lock()
    defer { lock.unlock() }
    let values = Array(bridges.values)
    bridges.removeAll()
    return values
  }

  private static func socksEndpoint(from flow: NEAppProxyTCPFlow) -> Socks5Endpoint? {
    switch flow.remoteFlowEndpoint {
    case let .hostPort(host, port):
      let endpointPort = Int(port.rawValue)
      switch host {
      case let .ipv4(address):
        return Socks5Endpoint(host: .ipv4(address.debugDescription), port: endpointPort)
      case let .ipv6(address):
        return Socks5Endpoint(host: .ipv6(address.debugDescription), port: endpointPort)
      case let .name(name, _):
        return Socks5Endpoint(host: .domain(name), port: endpointPort)
      @unknown default:
        return nil
      }
    case .service, .unix, .url, .opaque:
      return nil
    @unknown default:
      return nil
    }
  }

  private static func stringValue(_ value: Any?) -> String? {
    switch value {
    case let value as String:
      return value
    case let value as NSString:
      return value as String
    default:
      return nil
    }
  }

  private static func intValue(_ value: Any?) -> Int? {
    switch value {
    case let value as Int:
      return value
    case let value as NSNumber:
      return value.intValue
    case let value as String:
      return Int(value)
    case let value as NSString:
      return Int(value as String)
    default:
      return nil
    }
  }
}

private final class TCPFlowBridge: @unchecked Sendable {
  private enum BridgeError {
    static func make(_ message: String, code: Int = 1) -> NSError {
      NSError(
        domain: "io.github.clashmax.ClashMax.NetworkExtension.TransparentProxy",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  private static let log = Logger(subsystem: "io.github.clashmax.ClashMax.NetworkExtension", category: "tcp-flow")

  private let id: UUID
  private let flow: NEAppProxyTCPFlow
  private let endpoint: Socks5Endpoint
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let onClose: @Sendable (UUID) -> Void
  private let lock = NSLock()
  private var isClosed = false

  init(
    id: UUID,
    flow: NEAppProxyTCPFlow,
    endpoint: Socks5Endpoint,
    socksHost: String,
    socksPort: Int,
    onClose: @escaping @Sendable (UUID) -> Void
  ) {
    self.id = id
    self.flow = flow
    self.endpoint = endpoint
    self.queue = DispatchQueue(label: "io.github.clashmax.network-extension.tcp-flow.\(id.uuidString)")
    self.onClose = onClose
    let port = NWEndpoint.Port(rawValue: UInt16(clamping: socksPort)) ?? NWEndpoint.Port(integerLiteral: 7890)
    self.connection = NWConnection(host: NWEndpoint.Host(socksHost), port: port, using: .tcp)
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      switch state {
      case .ready:
        self.performSocksHandshake { result in
          switch result {
          case .success:
            self.openFlowAndCopy()
          case let .failure(error):
            Self.log.error("SOCKS5 handshake failed: \(error.localizedDescription, privacy: .public)")
            self.close(error)
          }
        }
      case let .failed(error):
        self.close(error)
      case .cancelled:
        self.close(nil)
      default:
        break
      }
    }
    connection.start(queue: queue)
  }

  func cancel() {
    close(nil)
  }

  private func performSocksHandshake(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    connection.send(content: Socks5ConnectRequest.noAuthenticationGreeting, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      if let error {
        completion(.failure(error))
        return
      }
      self.receiveExact(length: 2) { greetingResult in
        switch greetingResult {
        case let .failure(error):
          completion(.failure(error))
        case let .success(response):
          guard response == Data([0x05, 0x00]) else {
            completion(.failure(BridgeError.make("SOCKS5 server rejected no-authentication method.")))
            return
          }
          self.sendConnectRequest(completion: completion)
        }
      }
    })
  }

  private func sendConnectRequest(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    do {
      let request = try Socks5ConnectRequest.bytes(for: endpoint)
      connection.send(content: request, completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if let error {
          completion(.failure(error))
        } else {
          self.readConnectResponse(completion: completion)
        }
      })
    } catch {
      completion(.failure(error))
    }
  }

  private func readConnectResponse(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    receiveExact(length: 4) { [weak self] result in
      guard let self else { return }
      switch result {
      case let .failure(error):
        completion(.failure(error))
      case let .success(header):
        guard header.count == 4, header[0] == 0x05 else {
          completion(.failure(BridgeError.make("SOCKS5 server returned an invalid CONNECT response.")))
          return
        }
        guard header[1] == 0x00 else {
          completion(.failure(BridgeError.make("SOCKS5 CONNECT failed with reply code \(header[1]).")))
          return
        }
        self.readConnectResponseAddress(addressType: header[3], completion: completion)
      }
    }
  }

  private func readConnectResponseAddress(addressType: UInt8, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
    switch addressType {
    case 0x01:
      receiveExact(length: 6) { result in completion(result.map { _ in () }) }
    case 0x03:
      receiveExact(length: 1) { [weak self] result in
        guard let self else { return }
        switch result {
        case let .failure(error):
          completion(.failure(error))
        case let .success(lengthBytes):
          let length = Int(lengthBytes[0])
          self.receiveExact(length: length + 2) { result in completion(result.map { _ in () }) }
        }
      }
    case 0x04:
      receiveExact(length: 18) { result in completion(result.map { _ in () }) }
    default:
      completion(.failure(BridgeError.make("SOCKS5 server returned unsupported address type \(addressType).")))
    }
  }

  private func receiveExact(
    length: Int,
    accumulated: Data = Data(),
    completion: @escaping @Sendable (Result<Data, Error>) -> Void
  ) {
    guard length > accumulated.count else {
      completion(.success(accumulated))
      return
    }
    let remaining = length - accumulated.count
    connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        completion(.failure(error))
        return
      }
      var next = accumulated
      if let data {
        next.append(data)
      }
      if next.count >= length {
        completion(.success(next))
      } else if isComplete {
        completion(.failure(BridgeError.make("SOCKS5 server closed before sending enough data.")))
      } else {
        self.receiveExact(length: length, accumulated: next, completion: completion)
      }
    }
  }

  private func openFlowAndCopy() {
    flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
      guard let self else { return }
      if let error {
        self.close(error)
        return
      }
      self.copyFlowToConnection()
      self.copyConnectionToFlow()
    }
  }

  private func copyFlowToConnection() {
    flow.readData { [weak self] data, error in
      guard let self else { return }
      if let error {
        self.close(error)
        return
      }
      guard let data, !data.isEmpty else {
        self.connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
        return
      }
      self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if let error {
          self.close(error)
        } else {
          self.copyFlowToConnection()
        }
      })
    }
  }

  private func copyConnectionToFlow() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      if let error {
        self.close(error)
        return
      }
      if let data, !data.isEmpty {
        self.flow.write(data) { [weak self] error in
          guard let self else { return }
          if let error {
            self.close(error)
          } else if isComplete {
            self.close(nil)
          } else {
            self.copyConnectionToFlow()
          }
        }
      } else if isComplete {
        self.close(nil)
      } else {
        self.copyConnectionToFlow()
      }
    }
  }

  private func close(_ error: Error?) {
    lock.lock()
    guard !isClosed else {
      lock.unlock()
      return
    }
    isClosed = true
    lock.unlock()

    let nsError = error as NSError?
    flow.closeReadWithError(nsError)
    flow.closeWriteWithError(nsError)
    connection.cancel()
    onClose(id)
  }
}

private struct ProxyStartCompletion: @unchecked Sendable {
  private let handler: ((any Error)?) -> Void

  init(_ handler: @escaping ((any Error)?) -> Void) {
    self.handler = handler
  }

  func callAsFunction(_ error: ((any Error)?)) {
    handler(error)
  }
}
