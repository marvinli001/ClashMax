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
  private let diagnostics = NetworkExtensionDiagnosticsRecorder()
  private var bridges: [UUID: FlowBridge] = [:]
  private var socksHost = defaultSocksHost
  private var socksPort = defaultSocksPort
  private var dnsCapturePolicy = NetworkExtensionDNSCapturePolicy.disabled

  override func startProxy(
    options: [String: Any]? = nil,
    completionHandler: @escaping ((any Error)?) -> Void
  ) {
    let completion = ProxyStartCompletion(completionHandler)
    let configuration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration ?? [:]
    socksHost = Self.stringValue(options?["socksHost"]) ?? Self.stringValue(configuration["socksHost"]) ?? Self.defaultSocksHost
    socksPort = Self.intValue(options?["socksPort"]) ?? Self.intValue(configuration["socksPort"]) ?? Self.defaultSocksPort
    let dnsCaptureEnabled = Self.boolValue(options?["dnsCaptureEnabled"])
      ?? Self.boolValue(configuration["dnsCaptureEnabled"])
      ?? false
    let dnsListenHost = Self.stringValue(options?["dnsListenHost"])
      ?? Self.stringValue(configuration["dnsListenHost"])
      ?? NetworkExtensionRoutingSettings.defaultDNSListenHost
    let dnsListenPort = Self.intValue(options?["dnsListenPort"])
      ?? Self.intValue(configuration["dnsListenPort"])
      ?? NetworkExtensionRoutingSettings.defaultDNSListenPort
    dnsCapturePolicy = NetworkExtensionDNSCapturePolicy(
      enabled: dnsCaptureEnabled,
      listenHost: dnsListenHost,
      listenPort: NetworkExtensionRoutingSettings.isValidPort(dnsListenPort)
        ? dnsListenPort
        : NetworkExtensionRoutingSettings.defaultDNSListenPort
    )
    let dnsFakeIPEnabled = Self.boolValue(options?["dnsFakeIPEnabled"])
      ?? Self.boolValue(configuration["dnsFakeIPEnabled"])
      ?? false
    let systemDNSOverrideEnabled = Self.boolValue(options?["systemDNSOverrideEnabled"])
      ?? Self.boolValue(configuration["systemDNSOverrideEnabled"])
      ?? false
    let systemDNSOverrideApplied = Self.boolValue(options?["systemDNSOverrideApplied"])
      ?? Self.boolValue(configuration["systemDNSOverrideApplied"])
      ?? false

    let routeExcludeCIDRs = Self.stringArrayValue(options?["routeExcludeCIDRs"])
      ?? Self.stringArrayValue(configuration["routeExcludeCIDRs"])
      ?? []
    diagnostics.reset(
      dnsCaptureEnabled: dnsCaptureEnabled,
      dnsFakeIPEnabled: dnsFakeIPEnabled,
      systemDNSOverrideApplied: systemDNSOverrideApplied,
      systemDNSOverrideStatus: systemDNSOverrideEnabled ? "enabled" : "disabled",
      routeExcludeCIDRCount: routeExcludeCIDRs.count
    )
    let excludedNetworkRules: [NENetworkRule]
    do {
      excludedNetworkRules = try Self.excludedNetworkRules(for: routeExcludeCIDRs)
    } catch {
      let message = "Invalid NE route exclude configuration: \(error.localizedDescription)"
      diagnostics.recordError(message)
      Self.log.error("\(message, privacy: .public)")
      completion(error)
      return
    }

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
      ),
      NENetworkRule(
        remoteNetworkEndpoint: nil,
        remotePrefix: 0,
        localNetworkEndpoint: nil,
        localPrefix: 0,
        protocol: .UDP,
        direction: .outbound
      )
    ]
    settings.excludedNetworkRules = excludedNetworkRules

    let excludedNetworkRuleCount = excludedNetworkRules.count
    setTunnelNetworkSettings(settings) { error in
      if let error {
        self.diagnostics.recordError("Failed to apply transparent proxy settings: \(error.localizedDescription)")
        Self.log.error("Failed to apply transparent proxy settings: \(error.localizedDescription, privacy: .public)")
        completion(error)
      } else {
        Self.log.info("Applied \(excludedNetworkRuleCount, privacy: .public) transparent proxy exclude rules.")
        completion(nil)
      }
    }
  }

  override func stopProxy(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    Self.log.info("Stopping transparent proxy, reason=\(reason.rawValue, privacy: .public)")
    let activeBridges = removeAllBridges()
    activeBridges.forEach { $0.cancel() }
    diagnostics.setActiveBridgeCounts(tcp: 0, udp: 0)
    completionHandler()
  }

  override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
    guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
      diagnostics.recordBypass(
        "Bypassed non-TCP transparent proxy flow.",
        flowProtocol: .unknown,
        sourceAppSigningIdentifier: flow.metaData.sourceAppSigningIdentifier
      )
      Self.log.debug("Bypassing non-TCP transparent proxy flow.")
      return false
    }
    guard shouldProxy(
      flow: tcpFlow,
      flowProtocol: .tcp,
      remoteEndpoint: Self.endpointDescription(from: tcpFlow.remoteFlowEndpoint)
    ) else {
      return false
    }
    guard let endpoint = Self.socksEndpoint(from: tcpFlow) else {
      diagnostics.recordBypass(
        "Bypassed TCP flow with unsupported remote endpoint.",
        flowProtocol: .tcp,
        remoteEndpoint: Self.endpointDescription(from: tcpFlow.remoteFlowEndpoint),
        sourceAppSigningIdentifier: tcpFlow.metaData.sourceAppSigningIdentifier
      )
      Self.log.debug("Bypassing TCP flow with unsupported remote endpoint.")
      return false
    }

    let id = UUID()
    let targetEndpoint = dnsCapturePolicy.targetEndpoint(for: endpoint)
    let endpointDescription = endpoint.diagnosticDescription
    let sourceAppSigningIdentifier = tcpFlow.metaData.sourceAppSigningIdentifier
    if targetEndpoint != endpoint {
      diagnostics.recordDNSCapture(
        flowProtocol: .tcp,
        originalEndpoint: endpoint,
        targetEndpoint: targetEndpoint,
        sourceAppSigningIdentifier: sourceAppSigningIdentifier
      )
    }
    let bridge = TCPFlowBridge(
      id: id,
      flow: tcpFlow,
      endpoint: targetEndpoint,
      socksHost: socksHost,
      socksPort: socksPort,
      onError: { [weak self] message, socksHandshakeFailure in
        self?.diagnostics.recordError(
          message,
          flowProtocol: .tcp,
          remoteEndpoint: endpointDescription,
          sourceAppSigningIdentifier: sourceAppSigningIdentifier,
          socksHandshakeFailure: socksHandshakeFailure
        )
      },
      onClose: { [weak self] id in
        self?.removeBridge(id: id)
      }
    )
    insertBridge(bridge, id: id)
    bridge.start()
    return true
  }

  func handleNewUDPFlow(_ flow: NEAppProxyUDPFlow, initialRemoteFlowEndpoint remoteEndpoint: NWEndpoint) -> Bool {
    guard shouldProxy(flow: flow, flowProtocol: .udp, remoteEndpoint: Self.endpointDescription(from: remoteEndpoint)) else {
      return false
    }
    guard let endpoint = Self.socksEndpoint(from: remoteEndpoint) else {
      diagnostics.recordBypass(
        "Bypassed UDP flow with unsupported remote endpoint.",
        flowProtocol: .udp,
        remoteEndpoint: Self.endpointDescription(from: remoteEndpoint),
        sourceAppSigningIdentifier: flow.metaData.sourceAppSigningIdentifier
      )
      Self.log.debug("Bypassing UDP flow with unsupported remote endpoint.")
      return false
    }

    let id = UUID()
    let endpointDescription = endpoint.diagnosticDescription
    let sourceAppSigningIdentifier = flow.metaData.sourceAppSigningIdentifier
    let bridge = UDPFlowBridge(
      id: id,
      flow: flow,
      initialEndpoint: endpoint,
      dnsCapturePolicy: dnsCapturePolicy,
      socksHost: socksHost,
      socksPort: socksPort,
      onDatagram: { [weak self] originalEndpoint, targetEndpoint in
        self?.diagnostics.recordUDPDatagram(
          remoteEndpoint: originalEndpoint.diagnosticDescription,
          sourceAppSigningIdentifier: sourceAppSigningIdentifier
        )
        if originalEndpoint != targetEndpoint {
          self?.diagnostics.recordDNSCapture(
            flowProtocol: .udp,
            originalEndpoint: originalEndpoint,
            targetEndpoint: targetEndpoint,
            sourceAppSigningIdentifier: sourceAppSigningIdentifier
          )
        }
      },
      onDNSRetargetFailure: { [weak self] message in
        self?.diagnostics.recordDNSRetargetFailure(
          message,
          flowProtocol: .udp,
          remoteEndpoint: endpointDescription,
          sourceAppSigningIdentifier: sourceAppSigningIdentifier
        )
      },
      onError: { [weak self] message, socksHandshakeFailure, udpRelayFailure in
        self?.diagnostics.recordError(
          message,
          flowProtocol: .udp,
          remoteEndpoint: endpointDescription,
          sourceAppSigningIdentifier: sourceAppSigningIdentifier,
          socksHandshakeFailure: socksHandshakeFailure,
          udpRelayFailure: udpRelayFailure
        )
      },
      onClose: { [weak self] id in
        self?.removeBridge(id: id)
      }
    )
    insertBridge(bridge, id: id)
    bridge.start()
    return true
  }

  private func shouldProxy(
    flow: NEAppProxyFlow,
    flowProtocol: NetworkExtensionFlowProtocol,
    remoteEndpoint: String?
  ) -> Bool {
    let source = flow.metaData.sourceAppSigningIdentifier
    if Self.bypassSourceSigningIdentifiers.contains(source) {
      diagnostics.recordBypass(
        "Bypassed self/core flow from \(source).",
        flowProtocol: flowProtocol,
        remoteEndpoint: remoteEndpoint,
        sourceAppSigningIdentifier: source
      )
      Self.log.debug("Bypassing self/core flow from \(source, privacy: .public).")
      return false
    }
    return true
  }

  private func insertBridge(_ bridge: FlowBridge, id: UUID) {
    lock.lock()
    bridges[id] = bridge
    let counts = bridgeCounts()
    lock.unlock()
    diagnostics.setActiveBridgeCounts(tcp: counts.tcp, udp: counts.udp)
  }

  private func removeBridge(id: UUID) {
    lock.lock()
    bridges.removeValue(forKey: id)
    let counts = bridgeCounts()
    lock.unlock()
    diagnostics.setActiveBridgeCounts(tcp: counts.tcp, udp: counts.udp)
  }

  private func removeAllBridges() -> [FlowBridge] {
    lock.lock()
    defer { lock.unlock() }
    let values = Array(bridges.values)
    bridges.removeAll()
    return values
  }

  private func bridgeCounts() -> (tcp: Int, udp: Int) {
    var tcp = 0
    var udp = 0
    for bridge in bridges.values {
      switch bridge.flowProtocol {
      case .tcp:
        tcp += 1
      case .udp:
        udp += 1
      case .unknown:
        break
      }
    }
    return (tcp, udp)
  }

  private static func excludedNetworkRules(for values: [String]) throws -> [NENetworkRule] {
    var rules: [NENetworkRule] = []
    for value in values {
      let cidr = try NetworkExtensionRouteCIDR(value)
      let endpoint = NWEndpoint.hostPort(
        host: NWEndpoint.Host(cidr.address),
        port: NWEndpoint.Port(rawValue: 0) ?? NWEndpoint.Port(integerLiteral: 0)
      )
      rules.append(
        NENetworkRule(
          remoteNetworkEndpoint: endpoint,
          remotePrefix: cidr.prefix,
          localNetworkEndpoint: nil,
          localPrefix: 0,
          protocol: .TCP,
          direction: .outbound
        )
      )
      rules.append(
        NENetworkRule(
          remoteNetworkEndpoint: endpoint,
          remotePrefix: cidr.prefix,
          localNetworkEndpoint: nil,
          localPrefix: 0,
          protocol: .UDP,
          direction: .outbound
        )
      )
    }
    return rules
  }

  private static func socksEndpoint(from flow: NEAppProxyTCPFlow) -> Socks5Endpoint? {
    socksEndpoint(from: flow.remoteFlowEndpoint)
  }

  private static func socksEndpoint(from endpoint: NWEndpoint) -> Socks5Endpoint? {
    switch endpoint {
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

  private static func boolValue(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      return value
    case let value as NSNumber:
      return value.boolValue
    case let value as String:
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      if ["true", "yes", "1"].contains(normalized) { return true }
      if ["false", "no", "0"].contains(normalized) { return false }
      return nil
    case let value as NSString:
      return boolValue(value as String)
    default:
      return nil
    }
  }

  private static func stringArrayValue(_ value: Any?) -> [String]? {
    switch value {
    case let values as [String]:
      return values
    case let values as [NSString]:
      return values.map(String.init)
    case let values as NSArray:
      let strings = values.compactMap { stringValue($0) }
      return strings.isEmpty && values.count > 0 ? nil : strings
    default:
      return nil
    }
  }
}

private protocol FlowBridge: AnyObject {
  var flowProtocol: NetworkExtensionFlowProtocol { get }
  func cancel()
}

private extension Socks5Endpoint {
  var diagnosticDescription: String {
    let hostDescription: String
    switch host {
    case let .ipv4(address):
      hostDescription = address
    case let .ipv6(address):
      hostDescription = "[\(address)]"
    case let .domain(domain):
      hostDescription = domain
    }
    return "\(hostDescription):\(port)"
  }
}

private extension TransparentProxyProvider {
  static func endpointDescription(from endpoint: NWEndpoint) -> String? {
    switch endpoint {
    case let .hostPort(host, port):
      let hostDescription: String
      switch host {
      case let .ipv4(address):
        hostDescription = address.debugDescription
      case let .ipv6(address):
        hostDescription = "[\(address.debugDescription)]"
      case let .name(name, _):
        hostDescription = name
      @unknown default:
        return nil
      }
      return "\(hostDescription):\(port.rawValue)"
    case .service, .unix, .url, .opaque:
      return nil
    @unknown default:
      return nil
    }
  }
}

private final class NetworkExtensionDiagnosticsRecorder: @unchecked Sendable {
  private enum PersistencePolicy {
    case immediate
    case deferred
  }

  private static let log = Logger(subsystem: "io.github.clashmax.ClashMax.NetworkExtension", category: "diagnostics")
  private static let retainedEventLimit = 20
  private static let deferredPersistDelay: DispatchTimeInterval = .seconds(1)

  private let lock = NSLock()
  private let persistenceQueue = DispatchQueue(label: "io.github.clashmax.network-extension.diagnostics-persist")
  private let fileURL: URL?
  private var snapshot = NetworkExtensionDiagnosticsSnapshot.empty
  private var hasScheduledDeferredPersist = false

  init(fileURL: URL? = nil) {
    self.fileURL = fileURL ?? FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: NetworkExtensionRuntimeConstants.appGroupIdentifier)?
      .appendingPathComponent(NetworkExtensionRuntimeConstants.diagnosticsFilename)
  }

  func reset(
    dnsCaptureEnabled: Bool = false,
    dnsFakeIPEnabled: Bool = false,
    systemDNSOverrideApplied: Bool = false,
    systemDNSOverrideStatus: String = "inactive",
    routeExcludeCIDRCount: Int = 0
  ) {
    update(preservesExternalSystemDNSState: false) { snapshot in
      snapshot = .empty
      snapshot.dnsCaptureEnabled = dnsCaptureEnabled
      snapshot.dnsFakeIPEnabled = dnsFakeIPEnabled
      snapshot.systemDNSOverrideApplied = systemDNSOverrideApplied
      snapshot.systemDNSOverrideStatus = systemDNSOverrideStatus
      snapshot.routeExcludeCIDRCount = max(0, routeExcludeCIDRCount)
      snapshot.updatedAt = Date()
    }
  }

  func setActiveBridgeCounts(tcp: Int, udp: Int) {
    update { snapshot in
      snapshot.activeTCPBridgeCount = max(0, tcp)
      snapshot.activeUDPBridgeCount = max(0, udp)
      snapshot.activeBridgeCount = snapshot.activeTCPBridgeCount + snapshot.activeUDPBridgeCount
    }
  }

  func recordUDPDatagram(remoteEndpoint: String?, sourceAppSigningIdentifier: String?) {
    update(persistence: .deferred) { snapshot in
      snapshot.udpDatagramCount += 1
      if Self.isDNSEndpoint(remoteEndpoint) {
        snapshot.dnsDatagramCount += 1
        snapshot.lastDNSEndpoint = remoteEndpoint
        snapshot.lastDNSSourceAppSigningIdentifier = sourceAppSigningIdentifier
      }
    }
  }

  func recordDNSCapture(
    flowProtocol: NetworkExtensionFlowProtocol,
    originalEndpoint: Socks5Endpoint,
    targetEndpoint: Socks5Endpoint,
    sourceAppSigningIdentifier: String?
  ) {
    update(persistence: .deferred) { snapshot in
      snapshot.dnsCaptureCount += 1
      snapshot.lastDNSEndpoint = "\(originalEndpoint.diagnosticDescription) -> \(targetEndpoint.diagnosticDescription)"
      snapshot.lastDNSSourceAppSigningIdentifier = sourceAppSigningIdentifier
      append(
        NetworkExtensionDiagnosticEvent(
          message: "Captured DNS flow.",
          sourceAppSigningIdentifier: sourceAppSigningIdentifier,
          flowProtocol: flowProtocol,
          remoteEndpoint: originalEndpoint.diagnosticDescription
        ),
        to: &snapshot.recentBypasses
      )
    }
  }

  func recordDNSRetargetFailure(
    _ message: String,
    flowProtocol: NetworkExtensionFlowProtocol,
    remoteEndpoint: String?,
    sourceAppSigningIdentifier: String?
  ) {
    update { snapshot in
      snapshot.errorCount += 1
      snapshot.dnsRetargetFailureCount += 1
      append(
        NetworkExtensionDiagnosticEvent(
          message: message,
          sourceAppSigningIdentifier: sourceAppSigningIdentifier,
          flowProtocol: flowProtocol,
          remoteEndpoint: remoteEndpoint
        ),
        to: &snapshot.recentErrors
      )
    }
  }

  func recordBypass(
    _ message: String,
    flowProtocol: NetworkExtensionFlowProtocol,
    remoteEndpoint: String? = nil,
    sourceAppSigningIdentifier: String?
  ) {
    update { snapshot in
      snapshot.bypassCount += 1
      if flowProtocol == .udp {
        snapshot.udpBypassCount += 1
      }
      append(
        NetworkExtensionDiagnosticEvent(
          message: message,
          sourceAppSigningIdentifier: sourceAppSigningIdentifier,
          flowProtocol: flowProtocol,
          remoteEndpoint: remoteEndpoint
        ),
        to: &snapshot.recentBypasses
      )
    }
  }

  func recordError(
    _ message: String,
    flowProtocol: NetworkExtensionFlowProtocol = .unknown,
    remoteEndpoint: String? = nil,
    sourceAppSigningIdentifier: String? = nil,
    socksHandshakeFailure: Bool = false,
    udpRelayFailure: Bool = false
  ) {
    update { snapshot in
      snapshot.errorCount += 1
      if socksHandshakeFailure {
        snapshot.socksHandshakeFailureCount += 1
      }
      if udpRelayFailure {
        snapshot.udpBridgeFailureCount += 1
      }
      append(
        NetworkExtensionDiagnosticEvent(
          message: message,
          sourceAppSigningIdentifier: sourceAppSigningIdentifier,
          flowProtocol: flowProtocol,
          remoteEndpoint: remoteEndpoint
        ),
        to: &snapshot.recentErrors
      )
    }
  }

  private func update(
    persistence: PersistencePolicy = .immediate,
    preservesExternalSystemDNSState: Bool = true,
    _ body: (inout NetworkExtensionDiagnosticsSnapshot) -> Void
  ) {
    lock.lock()
    body(&snapshot)
    snapshot.updatedAt = Date()
    let nextSnapshot = snapshot
    if persistence == .deferred {
      scheduleDeferredPersistLocked()
    }
    lock.unlock()
    if persistence == .immediate {
      persist(nextSnapshot, preservesExternalSystemDNSState: preservesExternalSystemDNSState)
    }
  }

  private func scheduleDeferredPersistLocked() {
    guard !hasScheduledDeferredPersist else { return }
    hasScheduledDeferredPersist = true
    persistenceQueue.asyncAfter(deadline: .now() + Self.deferredPersistDelay) { [weak self] in
      self?.flushDeferredPersist()
    }
  }

  private func flushDeferredPersist() {
    lock.lock()
    hasScheduledDeferredPersist = false
    let nextSnapshot = snapshot
    lock.unlock()
    persist(nextSnapshot, preservesExternalSystemDNSState: true)
  }

  private func append(
    _ event: NetworkExtensionDiagnosticEvent,
    to events: inout [NetworkExtensionDiagnosticEvent]
  ) {
    events.append(event)
    if events.count > Self.retainedEventLimit {
      events.removeFirst(events.count - Self.retainedEventLimit)
    }
  }

  private func persist(_ snapshot: NetworkExtensionDiagnosticsSnapshot, preservesExternalSystemDNSState: Bool) {
    guard let fileURL else { return }
    do {
      let directory = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var snapshotToPersist = snapshot
      if preservesExternalSystemDNSState,
         let persistedSnapshot = Self.persistedSnapshot(at: fileURL) {
        snapshotToPersist.systemDNSOverrideApplied = persistedSnapshot.systemDNSOverrideApplied
        snapshotToPersist.systemDNSOverrideStatus = persistedSnapshot.systemDNSOverrideStatus
      }
      let data = try JSONEncoder().encode(snapshotToPersist)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      Self.log.error("Could not persist NE diagnostics: \(error.localizedDescription, privacy: .public)")
    }
  }

  private static func persistedSnapshot(at fileURL: URL) -> NetworkExtensionDiagnosticsSnapshot? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    return try? JSONDecoder().decode(NetworkExtensionDiagnosticsSnapshot.self, from: data)
  }

  private static func isDNSEndpoint(_ endpoint: String?) -> Bool {
    guard let endpoint else { return false }
    return endpoint.hasSuffix(":53") || endpoint.hasSuffix(":853")
  }
}

private final class TCPFlowBridge: FlowBridge, @unchecked Sendable {
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
  let flowProtocol: NetworkExtensionFlowProtocol = .tcp

  private let id: UUID
  private let flow: NEAppProxyTCPFlow
  private let endpoint: Socks5Endpoint
  private let connection: NWConnection
  private let queue: DispatchQueue
  private let onError: @Sendable (String, Bool) -> Void
  private let onClose: @Sendable (UUID) -> Void
  private let lock = NSLock()
  private var isClosed = false
  private var socksHandshakeFailed = false

  init(
    id: UUID,
    flow: NEAppProxyTCPFlow,
    endpoint: Socks5Endpoint,
    socksHost: String,
    socksPort: Int,
    onError: @escaping @Sendable (String, Bool) -> Void,
    onClose: @escaping @Sendable (UUID) -> Void
  ) {
    self.id = id
    self.flow = flow
    self.endpoint = endpoint
    self.queue = DispatchQueue(label: "io.github.clashmax.network-extension.tcp-flow.\(id.uuidString)")
    self.onError = onError
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
            self.socksHandshakeFailed = true
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
          self.readSocksReply { result in
            completion(result.map { _ in () })
          }
        }
      })
    } catch {
      completion(.failure(error))
    }
  }

  private func readSocksReply(completion: @escaping @Sendable (Result<Socks5Reply, Error>) -> Void) {
    receiveExact(length: 4) { [weak self] result in
      guard let self else { return }
      switch result {
      case let .failure(error):
        completion(.failure(error))
      case let .success(header):
        guard header.count == 4, header[0] == 0x05, header[2] == 0x00 else {
          completion(.failure(Socks5ReplyError.invalidHeader))
          return
        }
        guard header[1] == 0x00 else {
          completion(.failure(Socks5ReplyError.failureReply(header[1])))
          return
        }
        self.readSocksReplyAddress(addressType: header[3]) { addressResult in
          switch addressResult {
          case let .failure(error):
            completion(.failure(error))
          case let .success(addressData):
            var response = header
            response.append(addressData)
            do {
              completion(.success(try Socks5ReplyParser.parse(response)))
            } catch {
              completion(.failure(error))
            }
          }
        }
      }
    }
  }

  private func readSocksReplyAddress(
    addressType: UInt8,
    completion: @escaping @Sendable (Result<Data, Error>) -> Void
  ) {
    switch addressType {
    case 0x01:
      receiveExact(length: 6, completion: completion)
    case 0x03:
      receiveExact(length: 1) { [weak self] result in
        guard let self else { return }
        switch result {
        case let .failure(error):
          completion(.failure(error))
        case let .success(lengthBytes):
          let length = Int(lengthBytes[0])
          self.receiveExact(length: length + 2) { result in
            completion(result.map { remainder in
              var data = lengthBytes
              data.append(remainder)
              return data
            })
          }
        }
      }
    case 0x04:
      receiveExact(length: 18, completion: completion)
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
    if let error {
      onError("TCP bridge failed: \(error.localizedDescription)", socksHandshakeFailed)
    }
    onClose(id)
  }
}

private final class UDPFlowBridge: FlowBridge, @unchecked Sendable {
  private enum BridgeError {
    static func make(_ message: String, code: Int = 1) -> NSError {
      NSError(
        domain: "io.github.clashmax.ClashMax.NetworkExtension.TransparentProxy.UDP",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: message]
      )
    }
  }

  private static let log = Logger(subsystem: "io.github.clashmax.ClashMax.NetworkExtension", category: "udp-flow")
  let flowProtocol: NetworkExtensionFlowProtocol = .udp

  private let id: UUID
  private let flow: NEAppProxyUDPFlow
  private let initialEndpoint: Socks5Endpoint?
  private let dnsCapturePolicy: NetworkExtensionDNSCapturePolicy
  private let socksHost: String
  private let controlConnection: NWConnection
  private let queue: DispatchQueue
  private let onDatagram: @Sendable (Socks5Endpoint, Socks5Endpoint) -> Void
  private let onDNSRetargetFailure: @Sendable (String) -> Void
  private let onError: @Sendable (String, Bool, Bool) -> Void
  private let onClose: @Sendable (UUID) -> Void
  private let lock = NSLock()
  private var udpConnection: NWConnection?
  private var dnsResponseEndpointMapper = DNSResponseEndpointMapper()
  private var isClosed = false
  private var socksHandshakeFailed = false
  private var udpRelayFailed = false

  init(
    id: UUID,
    flow: NEAppProxyUDPFlow,
    initialEndpoint: Socks5Endpoint?,
    dnsCapturePolicy: NetworkExtensionDNSCapturePolicy,
    socksHost: String,
    socksPort: Int,
    onDatagram: @escaping @Sendable (Socks5Endpoint, Socks5Endpoint) -> Void,
    onDNSRetargetFailure: @escaping @Sendable (String) -> Void,
    onError: @escaping @Sendable (String, Bool, Bool) -> Void,
    onClose: @escaping @Sendable (UUID) -> Void
  ) {
    self.id = id
    self.flow = flow
    self.initialEndpoint = initialEndpoint
    self.dnsCapturePolicy = dnsCapturePolicy
    self.socksHost = socksHost
    self.queue = DispatchQueue(label: "io.github.clashmax.network-extension.udp-flow.\(id.uuidString)")
    self.onDatagram = onDatagram
    self.onDNSRetargetFailure = onDNSRetargetFailure
    self.onError = onError
    self.onClose = onClose
    let port = NWEndpoint.Port(rawValue: UInt16(clamping: socksPort)) ?? NWEndpoint.Port(integerLiteral: 7890)
    self.controlConnection = NWConnection(host: NWEndpoint.Host(socksHost), port: port, using: .tcp)
  }

  func start() {
    guard initialEndpoint != nil else {
      close(BridgeError.make("UDP flow has an unsupported initial remote endpoint."))
      return
    }

    controlConnection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      guard self.isOpen() else { return }
      switch state {
      case .ready:
        self.performSocksHandshake { result in
          switch result {
          case let .success(reply):
            self.startUDPRelay(reply: reply)
          case let .failure(error):
            Self.log.error("SOCKS5 UDP ASSOCIATE failed: \(error.localizedDescription, privacy: .public)")
            self.socksHandshakeFailed = true
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
    guard startControlConnectionIfOpen() else { return }
  }

  func cancel() {
    close(nil)
  }

  private func performSocksHandshake(completion: @escaping @Sendable (Result<Socks5Reply, Error>) -> Void) {
    controlConnection.send(content: Socks5ConnectRequest.noAuthenticationGreeting, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      guard self.isOpen() else { return }
      if let error {
        completion(.failure(error))
        return
      }
      self.receiveExact(length: 2) { greetingResult in
        guard self.isOpen() else { return }
        switch greetingResult {
        case let .failure(error):
          completion(.failure(error))
        case let .success(response):
          guard response == Data([0x05, 0x00]) else {
            completion(.failure(BridgeError.make("SOCKS5 server rejected no-authentication method.")))
            return
          }
          self.sendUDPAssociateRequest(completion: completion)
        }
      }
    })
  }

  private func sendUDPAssociateRequest(completion: @escaping @Sendable (Result<Socks5Reply, Error>) -> Void) {
    do {
      let request = try Socks5ConnectRequest.udpAssociateBytes()
      controlConnection.send(content: request, completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        guard self.isOpen() else { return }
        if let error {
          completion(.failure(error))
        } else {
          self.readSocksReply(completion: completion)
        }
      })
    } catch {
      completion(.failure(error))
    }
  }

  private func startUDPRelay(reply: Socks5Reply) {
    guard isOpen() else { return }
    guard let portValue = UInt16(exactly: reply.bindEndpoint.port),
          let relayPort = NWEndpoint.Port(rawValue: portValue),
          reply.bindEndpoint.port > 0 else {
      close(BridgeError.make("SOCKS5 UDP relay returned an invalid port: \(reply.bindEndpoint.port)."))
      return
    }
    let relayHost = Self.relayHost(from: reply.bindEndpoint, fallbackHost: socksHost)
    let udpConnection = NWConnection(host: relayHost, port: relayPort, using: .udp)
    udpConnection.stateUpdateHandler = { [weak self] state in
      guard let self else { return }
      guard self.isOpen() else { return }
      switch state {
      case .ready:
        self.openFlowAndCopy()
      case let .failed(error):
        self.close(error)
      case .cancelled:
        self.close(nil)
      default:
        break
      }
    }
    guard startUDPConnectionIfOpen(udpConnection) else {
      udpConnection.cancel()
      return
    }
  }

  private static func relayHost(from endpoint: Socks5Endpoint, fallbackHost: String) -> NWEndpoint.Host {
    switch endpoint.host {
    case let .ipv4(address) where address == "0.0.0.0":
      return NWEndpoint.Host(fallbackHost)
    case let .ipv4(address):
      return NWEndpoint.Host(address)
    case let .ipv6(address) where address == "::":
      return NWEndpoint.Host(fallbackHost)
    case let .ipv6(address):
      return NWEndpoint.Host(address)
    case let .domain(domain):
      return NWEndpoint.Host(domain)
    }
  }

  private func openFlowAndCopy() {
    guard isOpen() else { return }
    flow.open(withLocalFlowEndpoint: nil) { [weak self] error in
      guard let self else { return }
      guard self.isOpen() else { return }
      if let error {
        self.close(error)
        return
      }
      Self.log.info("UDP flow bridge ready; targetPortCategory=\(Self.targetPortCategory(from: self.initialEndpoint), privacy: .public)")
      self.copyFlowToRelay()
      self.copyRelayToFlow()
    }
  }

  private func copyFlowToRelay() {
    guard isOpen() else { return }
    flow.readDatagrams { [weak self] datagrams, error in
      guard let self else { return }
      guard self.isOpen() else { return }
      if let error {
        self.close(error)
        return
      }
      guard let datagrams else {
        self.close(nil)
        return
      }
      guard !datagrams.isEmpty else {
        self.copyFlowToRelay()
        return
      }
      self.sendDatagramsToRelay(datagrams, index: 0)
    }
  }

  private func sendDatagramsToRelay(_ datagrams: [(Data, NWEndpoint)], index: Int) {
    guard isOpen() else { return }
    guard index < datagrams.count else {
      copyFlowToRelay()
      return
    }
    guard let udpConnection = udpConnectionIfOpen() else {
      udpRelayFailed = true
      close(BridgeError.make("SOCKS5 UDP relay connection is not ready."))
      return
    }

    let datagram = datagrams[index]
    guard let endpoint = Self.socksEndpoint(from: datagram.1) ?? initialEndpoint else {
      udpRelayFailed = true
      close(BridgeError.make("UDP datagram has an unsupported remote endpoint."))
      return
    }
    let targetEndpoint = dnsCapturePolicy.targetEndpoint(for: endpoint)
    if targetEndpoint != endpoint {
      recordCapturedDNSQuery(payload: datagram.0, originalEndpoint: endpoint)
    }
    onDatagram(endpoint, targetEndpoint)

    let encoded: Data
    do {
      encoded = try Socks5UDPDatagramCodec.encode(
        Socks5UDPDatagram(endpoint: targetEndpoint, payload: datagram.0)
      )
    } catch {
      close(error)
      return
    }

    udpConnection.send(content: encoded, completion: .contentProcessed { [weak self] error in
      guard let self else { return }
      guard self.isOpen() else { return }
      if let error {
        self.close(error)
      } else {
        self.sendDatagramsToRelay(datagrams, index: index + 1)
      }
    })
  }

  private func copyRelayToFlow() {
    guard isOpen() else { return }
    guard let udpConnection = udpConnectionIfOpen() else {
      udpRelayFailed = true
      close(BridgeError.make("SOCKS5 UDP relay connection is not ready."))
      return
    }
    udpConnection.receiveMessage { [weak self] data, _, _, error in
      guard let self else { return }
      guard self.isOpen() else { return }
      if let error {
        self.close(error)
        return
      }
      guard let data, !data.isEmpty else {
        self.copyRelayToFlow()
        return
      }

      let decoded: Socks5UDPDatagram
      do {
        decoded = try Socks5UDPDatagramCodec.decode(data)
      } catch let codecError as Socks5UDPDatagramError {
        if case let .unsupportedFragment(fragment) = codecError {
          Self.log.debug("Dropping fragmented SOCKS5 UDP datagram, fragment=\(fragment, privacy: .public)")
          self.copyRelayToFlow()
        } else {
          self.close(codecError)
        }
        return
      } catch {
        self.close(error)
        return
      }

      let responseEndpoint = self.responseEndpoint(for: decoded.endpoint, payload: decoded.payload)
      guard let endpoint = Self.nwEndpoint(from: responseEndpoint) else {
        self.udpRelayFailed = true
        self.close(BridgeError.make("SOCKS5 UDP reply has an unsupported source endpoint."))
        return
      }
      self.flow.writeDatagrams([(decoded.payload, endpoint)]) { [weak self] error in
        guard let self else { return }
        guard self.isOpen() else { return }
        if let error {
          self.close(error)
        } else {
          self.copyRelayToFlow()
        }
      }
    }
  }

  private func readSocksReply(completion: @escaping @Sendable (Result<Socks5Reply, Error>) -> Void) {
    guard isOpen() else { return }
    receiveExact(length: 4) { [weak self] result in
      guard let self else { return }
      guard self.isOpen() else { return }
      switch result {
      case let .failure(error):
        completion(.failure(error))
      case let .success(header):
        guard header.count == 4, header[0] == 0x05, header[2] == 0x00 else {
          completion(.failure(Socks5ReplyError.invalidHeader))
          return
        }
        guard header[1] == 0x00 else {
          completion(.failure(Socks5ReplyError.failureReply(header[1])))
          return
        }
        self.readSocksReplyAddress(addressType: header[3]) { addressResult in
          switch addressResult {
          case let .failure(error):
            completion(.failure(error))
          case let .success(addressData):
            var response = header
            response.append(addressData)
            do {
              completion(.success(try Socks5ReplyParser.parse(response)))
            } catch {
              completion(.failure(error))
            }
          }
        }
      }
    }
  }

  private func readSocksReplyAddress(
    addressType: UInt8,
    completion: @escaping @Sendable (Result<Data, Error>) -> Void
  ) {
    switch addressType {
    case 0x01:
      receiveExact(length: 6, completion: completion)
    case 0x03:
      receiveExact(length: 1) { [weak self] result in
        guard let self else { return }
        guard self.isOpen() else { return }
        switch result {
        case let .failure(error):
          completion(.failure(error))
        case let .success(lengthBytes):
          let length = Int(lengthBytes[0])
          self.receiveExact(length: length + 2) { result in
            completion(result.map { remainder in
              var data = lengthBytes
              data.append(remainder)
              return data
            })
          }
        }
      }
    case 0x04:
      receiveExact(length: 18, completion: completion)
    default:
      completion(.failure(BridgeError.make("SOCKS5 server returned unsupported address type \(addressType).")))
    }
  }

  private func receiveExact(
    length: Int,
    accumulated: Data = Data(),
    completion: @escaping @Sendable (Result<Data, Error>) -> Void
  ) {
    guard isOpen() else { return }
    guard length > accumulated.count else {
      completion(.success(accumulated))
      return
    }
    let remaining = length - accumulated.count
    controlConnection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] data, _, isComplete, error in
      guard let self else { return }
      guard self.isOpen() else { return }
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

  private static func targetPortCategory(from endpoint: Socks5Endpoint?) -> String {
    guard let endpoint else {
      return "unknown"
    }
    switch endpoint.port {
    case 53:
      return "DNS/53"
    case 853:
      return "DNS-over-TLS/853"
    case 80:
      return "HTTP/80"
    case 443:
      return "HTTPS/443"
    default:
      return "port-\(endpoint.port)"
    }
  }

  private static func socksEndpoint(from endpoint: NWEndpoint) -> Socks5Endpoint? {
    switch endpoint {
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

  private static func nwEndpoint(from endpoint: Socks5Endpoint) -> NWEndpoint? {
    guard let portValue = UInt16(exactly: endpoint.port),
          let port = NWEndpoint.Port(rawValue: portValue),
          endpoint.port > 0 else {
      return nil
    }
    let host: NWEndpoint.Host
    switch endpoint.host {
    case let .ipv4(address):
      host = NWEndpoint.Host(address)
    case let .ipv6(address):
      host = NWEndpoint.Host(address)
    case let .domain(domain):
      host = NWEndpoint.Host(domain)
    }
    return .hostPort(host: host, port: port)
  }

  private func responseEndpoint(for endpoint: Socks5Endpoint, payload: Data) -> Socks5Endpoint {
    guard dnsCapturePolicy.isCaptureEndpoint(endpoint) else {
      return endpoint
    }
    if let mappedEndpoint = capturedDNSResponseEndpoint(payload: payload) {
      return mappedEndpoint
    }
    onDNSRetargetFailure(
      "Could not map captured DNS response from \(endpoint.diagnosticDescription) back to its original resolver."
    )
    return initialEndpoint ?? endpoint
  }

  private func isOpen() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return !isClosed
  }

  private func startControlConnectionIfOpen() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else {
      return false
    }
    controlConnection.start(queue: queue)
    return true
  }

  private func startUDPConnectionIfOpen(_ connection: NWConnection) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else {
      return false
    }
    udpConnection = connection
    connection.start(queue: queue)
    return true
  }

  private func udpConnectionIfOpen() -> NWConnection? {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else {
      return nil
    }
    return udpConnection
  }

  private func recordCapturedDNSQuery(payload: Data, originalEndpoint: Socks5Endpoint) {
    lock.lock()
    _ = dnsResponseEndpointMapper.recordQueryPayload(payload, originalEndpoint: originalEndpoint)
    lock.unlock()
  }

  private func capturedDNSResponseEndpoint(payload: Data) -> Socks5Endpoint? {
    lock.lock()
    defer { lock.unlock() }
    guard !isClosed else {
      return nil
    }
    return dnsResponseEndpointMapper.responseEndpoint(for: payload)
  }

  private func close(_ error: Error?) {
    lock.lock()
    guard !isClosed else {
      lock.unlock()
      return
    }
    isClosed = true
    let activeUDPConnection = udpConnection
    udpConnection = nil
    lock.unlock()

    let nsError = error as NSError?
    flow.closeReadWithError(nsError)
    flow.closeWriteWithError(nsError)
    controlConnection.cancel()
    activeUDPConnection?.cancel()
    if let error {
      onError("UDP bridge failed: \(error.localizedDescription)", socksHandshakeFailed, udpRelayFailed)
    }
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
