import Darwin
import Foundation

protocol CommandRunning: Sendable {
  func run(_ executable: String, _ arguments: [String]) async throws -> String
}

protocol PingTesting: Sendable {
  func ping(host: String, timeoutMilliseconds: Int) async throws -> Int
}

struct SystemPingTester: PingTesting {
  enum PingError: LocalizedError {
    case invalidHost(String)
    case missingLatency

    var errorDescription: String? {
      switch self {
      case let .invalidHost(host):
        return "Native ping cannot use invalid host: \(host)"
      case .missingLatency:
        return "Native ping finished without a latency result."
      }
    }
  }

  private let commandRunner: any CommandRunning

  init(commandRunner: any CommandRunning = ProcessCommandRunner(timeout: 6)) {
    self.commandRunner = commandRunner
  }

  func ping(host: String, timeoutMilliseconds: Int) async throws -> Int {
    let normalizedHost = try Self.normalizedHost(host)
    let timeout = min(max(timeoutMilliseconds, 1_000), 30_000)
    let output = try await commandRunner.run(
      "/sbin/ping",
      ["-c", "1", "-W", String(timeout), normalizedHost]
    )
    guard let latency = Self.latencyMilliseconds(from: output) else {
      throw PingError.missingLatency
    }
    return max(0, Int(latency.rounded()))
  }

  private static func normalizedHost(_ host: String) throws -> String {
    let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          !trimmed.hasPrefix("-"),
          trimmed.count <= 253,
          trimmed.range(of: #"^[A-Za-z0-9._:-]+$"#, options: .regularExpression) != nil
    else {
      throw PingError.invalidHost(host)
    }
    return trimmed
  }

  private static func latencyMilliseconds(from output: String) -> Double? {
    guard let range = output.range(
      of: #"time[=<]([0-9]+(?:\.[0-9]+)?)\s*ms"#,
      options: .regularExpression
    ) else {
      return nil
    }

    let match = String(output[range])
    guard let valueRange = match.range(
      of: #"[0-9]+(?:\.[0-9]+)?"#,
      options: .regularExpression
    ) else {
      return nil
    }
    return Double(match[valueRange])
  }
}

struct SystemProxyGuardVerification: Equatable, Sendable {
  var didRepair: Bool
  var warnings: [String]
}

struct SystemProxyRestoreResult: Equatable, Sendable {
  var restoredSnapshotCount: Int
  var didFallbackDisable: Bool
  var verified: Bool
}

struct SystemDNSApplyResult: Equatable, Sendable {
  var capturedSnapshotCount: Int
  var appliedServiceCount: Int
}

struct SystemDNSRestoreResult: Equatable, Sendable {
  var restoredSnapshotCount: Int
}

struct SystemProxyRestoreVerificationError: LocalizedError, Equatable, Sendable {
  var services: [String]

  var errorDescription: String? {
    "System Proxy still points to ClashMax after restore: \(services.joined(separator: ", "))"
  }
}

// Thread-safety: mutable state is serialized by `lock` (NSLock); async operations are serialized by `operationGate` (AsyncOperationGate).
final class SystemProxyController: @unchecked Sendable {
  static let defaultBypassDomains = SystemProxySettings.defaultBypassDomains

  static let applyBudgetSeconds: TimeInterval = 15
  static let restoreVerificationBudgetSeconds: TimeInterval = 20
  static let commandTimeoutSeconds: TimeInterval = 12
  private static let persistedSnapshotsDefaultsKey = "io.github.clashmax.systemProxySnapshots"
  private static let persistedDNSSnapshotsDefaultsKey = "io.github.clashmax.systemDNSSnapshots"

  private let commandRunner: CommandRunning
  private let snapshotDefaults: UserDefaults?
  private let snapshotDefaultsKey: String
  private let operationGate = AsyncOperationGate()
  private var snapshots: [String: ServiceProxySnapshot] = [:]
  private var dnsSnapshots: [String: ServiceDNSSnapshot] = [:]
  private var expectedConfiguration: ExpectedSystemProxyConfiguration?
  private var storedGuardState: SystemProxyGuardState = .idle
  private let lock = NSLock()

  var guardState: SystemProxyGuardState {
    lock.lock()
    defer { lock.unlock() }
    return storedGuardState
  }

  init(
    commandRunner: CommandRunning = ProcessCommandRunner(timeout: SystemProxyController.commandTimeoutSeconds),
    snapshotDefaults: UserDefaults? = nil,
    snapshotDefaultsKey: String = SystemProxyController.persistedSnapshotsDefaultsKey
  ) {
    self.commandRunner = commandRunner
    self.snapshotDefaults = snapshotDefaults
    self.snapshotDefaultsKey = snapshotDefaultsKey
    self.snapshots = Self.loadPersistedSnapshots(defaults: snapshotDefaults, key: snapshotDefaultsKey)
    self.dnsSnapshots = Self.loadPersistedDNSSnapshots(defaults: snapshotDefaults, key: Self.persistedDNSSnapshotsDefaultsKey)
  }

  func apply(host: String, port: Int, bypassDomains: [String] = SystemProxyController.defaultBypassDomains) async throws {
    try await operationGate.run { [self] in
      do {
        try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
          try await applyInner(host: host, port: port, bypassDomains: bypassDomains, captureSnapshots: true)
        }
      } catch {
        try? await restoreCapturedSnapshots()
        throw error
      }
    }
  }

  func enableGuard(host: String, port: Int, bypassDomains: [String] = SystemProxyController.defaultBypassDomains) async throws {
    writeGuardConfiguration(
      ExpectedSystemProxyConfiguration(host: host, port: port, bypassDomains: bypassDomains),
      state: .active
    )
  }

  func disableGuard() {
    writeGuardConfiguration(nil, state: .idle)
  }

  func verifyGuardOnce() async throws -> Bool {
    try await verifyGuardOnceDetailed().didRepair
  }

  func verifyGuardOnceDetailed() async throws -> SystemProxyGuardVerification {
    try await operationGate.run { [self] in
      try await verifyGuardOnceInner()
    }
  }

  private func verifyGuardOnceInner() async throws -> SystemProxyGuardVerification {
    guard let expected = readActiveGuardConfiguration() else {
      return SystemProxyGuardVerification(didRepair: false, warnings: [])
    }
    var didRepair = false
    var warnings: [String] = []
    let services: [String]
    do {
      services = try await networkServices()
    } catch {
      return SystemProxyGuardVerification(
        didRepair: false,
        warnings: ["System Proxy Guard could not list network services: \(UserFacingError.message(for: error))"]
      )
    }

    for service in services {
      try Task.checkCancellation()
      let currentSnapshot: ServiceProxySnapshot
      do {
        currentSnapshot = try await snapshot(for: service)
      } catch {
        warnings.append("System Proxy Guard could not read \(service) proxy settings: \(UserFacingError.message(for: error))")
        continue
      }
      guard !currentSnapshot.matches(expected) else { continue }
      try await applyProxyCommands(host: expected.host, port: expected.port, service: service)
      try await setBypassDomains(expected.bypassDomains, service: service)
      didRepair = true
    }
    return SystemProxyGuardVerification(didRepair: didRepair, warnings: warnings)
  }

  func restore() async throws {
    try await operationGate.run { [self] in
      try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
        try await restoreInner()
      }
    }
  }

  func restoreManagedState() async throws {
    try await operationGate.run { [self] in
      try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
        disableGuard()
        try await restoreCapturedSnapshots()
      }
    }
  }

  func restoreAndVerify(
    hosts: [String],
    ports: [Int],
    disableWhenNoSnapshot: Bool
  ) async throws -> SystemProxyRestoreResult {
    try await restoreAndVerify(
      hosts: normalizedProxyMatchHosts(hosts),
      ports: Set(ports),
      disableWhenNoSnapshot: disableWhenNoSnapshot
    )
  }

  func restoreAndVerify(
    hosts: Set<String>,
    ports: Set<Int>,
    disableWhenNoSnapshot: Bool
  ) async throws -> SystemProxyRestoreResult {
    let normalizedHosts = normalizedProxyMatchHosts(hosts)
    return try await withTimeout(seconds: Self.restoreVerificationBudgetSeconds) { [self] in
      try await operationGate.run { [self] in
        try await restoreAndVerifyInner(
          hosts: normalizedHosts,
          ports: ports,
          disableWhenNoSnapshot: disableWhenNoSnapshot
        )
      }
    }
  }

  var hasManagedSystemProxyState: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !snapshots.isEmpty || expectedConfiguration != nil
  }

  var hasManagedSystemDNSState: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !dnsSnapshots.isEmpty
  }

  @discardableResult
  func applyDNS(servers: [String], restoreOnFailure: Bool = true) async throws -> SystemDNSApplyResult {
    let normalizedServers = NetworkExtensionRoutingSettings.normalizedDNSServers(servers)
    guard !normalizedServers.isEmpty else {
      throw AppError.invalidProfileConfig("System DNS override requires at least one valid DNS server.")
    }
    return try await operationGate.run { [self] in
      do {
        return try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
          try await applyDNSInner(servers: normalizedServers)
        }
      } catch {
        if restoreOnFailure {
          _ = try? await restoreCapturedDNSSnapshots()
        }
        throw error
      }
    }
  }

  func restoreDNS() async throws -> SystemDNSRestoreResult {
    try await operationGate.run { [self] in
      try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
        try await restoreCapturedDNSSnapshots()
      }
    }
  }

  @discardableResult
  func disableMatchingProxy(hosts: Set<String>, ports: Set<Int>) async throws -> Bool {
    let normalizedHosts = normalizedProxyMatchHosts(hosts)
    return try await operationGate.run { [self] in
      try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
        try await disableMatchingProxyInner(hosts: normalizedHosts, ports: ports)
      }
    }
  }

  private func applyInner(
    host: String,
    port: Int,
    bypassDomains: [String],
    captureSnapshots: Bool
  ) async throws {
    for service in try await networkServices() {
      try Task.checkCancellation()
      if captureSnapshots, readSnapshot(service) == nil {
        let snapshot = try await snapshot(for: service)
        writeSnapshot(snapshot, for: service)
      }
      try await applyProxyCommands(host: host, port: port, service: service)
      try await setBypassDomains(bypassDomains, service: service)
    }
  }

  private func applyDNSInner(servers: [String]) async throws -> SystemDNSApplyResult {
    var appliedServiceCount = 0
    for service in try await networkServices() {
      try Task.checkCancellation()
      if readDNSSnapshot(service) == nil {
        let snapshot = try await dnsSnapshot(for: service)
        writeDNSSnapshot(snapshot, for: service)
      }
      try await setDNSServers(servers, service: service)
      appliedServiceCount += 1
    }
    return SystemDNSApplyResult(
      capturedSnapshotCount: readAllDNSSnapshots().count,
      appliedServiceCount: appliedServiceCount
    )
  }

  private func restoreInner() async throws {
    disableGuard()
    let captured = readAllSnapshots()
    if captured.isEmpty {
      for service in try await networkServices() {
        try Task.checkCancellation()
        try await disableAllProxyTypes(for: service)
        try await setBypassDomains([], service: service)
      }
      return
    }

    try await restoreCapturedSnapshots()
  }

  private func restoreAndVerifyInner(
    hosts: Set<String>,
    ports: Set<Int>,
    disableWhenNoSnapshot: Bool
  ) async throws -> SystemProxyRestoreResult {
    disableGuard()
    let capturedCount = readAllSnapshots().count
    var restoreError: Error?

    do {
      if capturedCount > 0 {
        try await restoreCapturedSnapshots(removeAfterRestore: false)
      } else if disableWhenNoSnapshot {
        for service in try await networkServices() {
          try Task.checkCancellation()
          try await disableAllProxyTypes(for: service)
          try await setBypassDomains([], service: service)
        }
      }
    } catch {
      restoreError = error
    }

    var didFallbackDisable = false
    do {
      let residualServices = try await servicesMatchingProxyInner(hosts: hosts, ports: ports)
      if restoreError != nil || !residualServices.isEmpty {
        didFallbackDisable = try await disableMatchingProxyInner(hosts: hosts, ports: ports)
      }
    } catch {
      if restoreError == nil {
        restoreError = error
      }
    }

    let residualServices = try await servicesMatchingProxyInner(hosts: hosts, ports: ports)
    guard residualServices.isEmpty else {
      throw SystemProxyRestoreVerificationError(services: residualServices)
    }
    if let restoreError {
      throw restoreError
    }

    clearSnapshots()
    writeGuardConfiguration(nil, state: .idle)
    return SystemProxyRestoreResult(
      restoredSnapshotCount: capturedCount,
      didFallbackDisable: didFallbackDisable,
      verified: true
    )
  }

  private func restoreCapturedSnapshots(removeAfterRestore: Bool = true) async throws {
    let captured = readAllSnapshots()
    var firstError: Error?

    for (service, snapshot) in captured {
      try Task.checkCancellation()
      do {
        try await restore(snapshot.web, service: service, kind: .web)
        try await restore(snapshot.secureWeb, service: service, kind: .secureWeb)
        try await restore(snapshot.socks, service: service, kind: .socks)
        try await setBypassDomains(snapshot.bypassDomains, service: service)
        if removeAfterRestore {
          removeSnapshot(for: service)
        }
      } catch {
        if firstError == nil {
          firstError = error
        }
      }
    }

    if removeAfterRestore, readAllSnapshots().isEmpty {
      writeGuardConfiguration(nil, state: .idle)
    }
    if let firstError {
      throw firstError
    }
  }

  private func restoreCapturedDNSSnapshots(removeAfterRestore: Bool = true) async throws -> SystemDNSRestoreResult {
    let captured = readAllDNSSnapshots()
    var firstError: Error?

    for (service, snapshot) in captured {
      try Task.checkCancellation()
      do {
        try await setDNSServers(snapshot.servers, service: service)
        if removeAfterRestore {
          removeDNSSnapshot(for: service)
        }
      } catch {
        if firstError == nil {
          firstError = error
        }
      }
    }

    if let firstError {
      throw firstError
    }
    return SystemDNSRestoreResult(restoredSnapshotCount: captured.count)
  }

  private func disableMatchingProxyInner(hosts: Set<String>, ports: Set<Int>) async throws -> Bool {
    var didChange = false
    for service in try await networkServices() {
      try Task.checkCancellation()
      let snapshot = try await snapshot(for: service)
      var changedService = false
      if snapshot.web.matches(hosts: hosts, ports: ports) {
        _ = try await commandRunner.run("/usr/sbin/networksetup", [ProxyKind.web.stateCommand, service, "off"])
        changedService = true
        didChange = true
      }
      if snapshot.secureWeb.matches(hosts: hosts, ports: ports) {
        _ = try await commandRunner.run("/usr/sbin/networksetup", [ProxyKind.secureWeb.stateCommand, service, "off"])
        changedService = true
        didChange = true
      }
      if snapshot.socks.matches(hosts: hosts, ports: ports) {
        _ = try await commandRunner.run("/usr/sbin/networksetup", [ProxyKind.socks.stateCommand, service, "off"])
        changedService = true
        didChange = true
      }
      if changedService, snapshot.bypassDomains == Self.defaultBypassDomains {
        try await setBypassDomains([], service: service)
      }
    }
    return didChange
  }

  private func servicesMatchingProxyInner(hosts: Set<String>, ports: Set<Int>) async throws -> [String] {
    var servicesWithResidualProxy: [String] = []
    for service in try await networkServices() {
      try Task.checkCancellation()
      let snapshot = try await snapshot(for: service)
      if snapshot.containsProxyMatching(hosts: hosts, ports: ports) {
        servicesWithResidualProxy.append(service)
      }
    }
    return servicesWithResidualProxy
  }

  private func disableAllProxyTypes(for service: String) async throws {
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
  }

  private func applyProxyCommands(host: String, port: Int, service: String) async throws {
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setwebproxy", service, host, String(port)])
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, host, String(port)])
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, host, String(port)])
  }

  private func snapshot(for service: String) async throws -> ServiceProxySnapshot {
    ServiceProxySnapshot(
      web: ProxyState(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service])),
      secureWeb: ProxyState(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])),
      socks: ProxyState(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])),
      bypassDomains: ProxyBypassDomains(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])).domains
    )
  }

  private func dnsSnapshot(for service: String) async throws -> ServiceDNSSnapshot {
    ServiceDNSSnapshot(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getdnsservers", service]))
  }

  private func restore(_ state: ProxyState, service: String, kind: ProxyKind) async throws {
    if state.enabled {
      if !state.server.isEmpty, state.port > 0 {
        _ = try await commandRunner.run("/usr/sbin/networksetup", [kind.setCommand, service, state.server, String(state.port)])
      }
      _ = try await commandRunner.run("/usr/sbin/networksetup", [kind.stateCommand, service, "on"])
    } else {
      _ = try await commandRunner.run("/usr/sbin/networksetup", [kind.stateCommand, service, "off"])
    }
  }

  private func networkServices() async throws -> [String] {
    let orderedOutput = try? await commandRunner.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
    let activeOutput = try? await commandRunner.run("/usr/sbin/scutil", ["--nwi"])
    let orderedServices = orderedOutput.map(OrderedNetworkService.parse) ?? []
    var activeInterfaces = activeOutput.map(ActiveNetworkInterfaces.parse) ?? []
    if activeInterfaces.isEmpty {
      let routeOutput = try? await commandRunner.run("/sbin/route", ["-n", "get", "default"])
      activeInterfaces = routeOutput.map(DefaultRouteInterfaces.parse) ?? []
    }
    if !orderedServices.isEmpty, !activeInterfaces.isEmpty {
      let activeServices = orderedServices
        .filter { service in
          guard let device = service.device else { return false }
          return activeInterfaces.contains(device)
        }
        .map(\.name)
      if !activeServices.isEmpty {
        return activeServices
      }
    }

    let output = try await commandRunner.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
    return output
      .split(separator: "\n")
      .map(String.init)
      .filter { !$0.hasPrefix("An asterisk") }
      .filter { !$0.hasPrefix("*") }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private func setBypassDomains(_ domains: [String], service: String) async throws {
    let arguments = ["-setproxybypassdomains", service] + (domains.isEmpty ? ["Empty"] : domains)
    _ = try await commandRunner.run("/usr/sbin/networksetup", arguments)
  }

  private func setDNSServers(_ servers: [String], service: String) async throws {
    let arguments = ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)
    _ = try await commandRunner.run("/usr/sbin/networksetup", arguments)
  }

  private func readSnapshot(_ service: String) -> ServiceProxySnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return snapshots[service]
  }

  private func writeSnapshot(_ snapshot: ServiceProxySnapshot, for service: String) {
    lock.lock()
    defer { lock.unlock() }
    snapshots[service] = snapshot
    persistSnapshotsLocked()
  }

  private func readAllSnapshots() -> [String: ServiceProxySnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return snapshots
  }

  private func clearSnapshots() {
    lock.lock()
    defer { lock.unlock() }
    snapshots.removeAll()
    persistSnapshotsLocked()
  }

  private func readDNSSnapshot(_ service: String) -> ServiceDNSSnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return dnsSnapshots[service]
  }

  private func writeDNSSnapshot(_ snapshot: ServiceDNSSnapshot, for service: String) {
    lock.lock()
    defer { lock.unlock() }
    dnsSnapshots[service] = snapshot
    persistDNSSnapshotsLocked()
  }

  private func readAllDNSSnapshots() -> [String: ServiceDNSSnapshot] {
    lock.lock()
    defer { lock.unlock() }
    return dnsSnapshots
  }

  private func removeDNSSnapshot(for service: String) {
    lock.lock()
    defer { lock.unlock() }
    dnsSnapshots.removeValue(forKey: service)
    persistDNSSnapshotsLocked()
  }

  private func removeSnapshot(for service: String) {
    lock.lock()
    defer { lock.unlock() }
    snapshots.removeValue(forKey: service)
    persistSnapshotsLocked()
  }

  private func readActiveGuardConfiguration() -> ExpectedSystemProxyConfiguration? {
    lock.lock()
    defer { lock.unlock() }
    guard storedGuardState == .active else { return nil }
    return expectedConfiguration
  }

  private func writeGuardConfiguration(
    _ configuration: ExpectedSystemProxyConfiguration?,
    state: SystemProxyGuardState
  ) {
    lock.lock()
    defer { lock.unlock() }
    expectedConfiguration = configuration
    storedGuardState = state
  }

  private static func loadPersistedSnapshots(defaults: UserDefaults?, key: String) -> [String: ServiceProxySnapshot] {
    guard let data = defaults?.data(forKey: key),
          let snapshots = try? JSONDecoder().decode([String: ServiceProxySnapshot].self, from: data)
    else {
      return [:]
    }
    return snapshots
  }

  private static func loadPersistedDNSSnapshots(defaults: UserDefaults?, key: String) -> [String: ServiceDNSSnapshot] {
    guard let data = defaults?.data(forKey: key),
          let snapshots = try? JSONDecoder().decode([String: ServiceDNSSnapshot].self, from: data)
    else {
      return [:]
    }
    return snapshots
  }

  private func persistSnapshotsLocked() {
    guard let snapshotDefaults else { return }
    if snapshots.isEmpty {
      snapshotDefaults.removeObject(forKey: snapshotDefaultsKey)
      return
    }
    guard let data = try? JSONEncoder().encode(snapshots) else { return }
    snapshotDefaults.set(data, forKey: snapshotDefaultsKey)
  }

  private func persistDNSSnapshotsLocked() {
    guard let snapshotDefaults else { return }
    if dnsSnapshots.isEmpty {
      snapshotDefaults.removeObject(forKey: Self.persistedDNSSnapshotsDefaultsKey)
      return
    }
    guard let data = try? JSONEncoder().encode(dnsSnapshots) else { return }
    snapshotDefaults.set(data, forKey: Self.persistedDNSSnapshotsDefaultsKey)
  }
}

private struct DefaultRouteInterfaces {
  static func parse(_ output: String) -> Set<String> {
    var interfaces = Set<String>()
    for rawLine in output.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix("interface:"),
            let separator = line.firstIndex(of: ":")
      else {
        continue
      }
      let interface = line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !interface.isEmpty {
        interfaces.insert(interface)
      }
    }
    return interfaces
  }
}

private struct ExpectedSystemProxyConfiguration: Equatable, Sendable {
  var host: String
  var port: Int
  var bypassDomains: [String]
}

private struct OrderedNetworkService {
  var name: String
  var device: String?

  static func parse(_ output: String) -> [OrderedNetworkService] {
    var services: [OrderedNetworkService] = []
    var pendingName: String?

    for rawLine in output.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("(Hardware Port:"), let name = pendingName {
        services.append(OrderedNetworkService(name: name, device: parseDevice(from: line)))
        pendingName = nil
      } else if line.hasPrefix("("), let closingIndex = line.firstIndex(of: ")") {
        let nameStart = line.index(after: closingIndex)
        let name = line[nameStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        pendingName = name.hasPrefix("*") ? nil : name
      }
    }

    return services
  }

  private static func parseDevice(from line: String) -> String? {
    guard let deviceRange = line.range(of: "Device:") else { return nil }
    let rawDevice = line[deviceRange.upperBound...]
      .trimmingCharacters(in: CharacterSet(charactersIn: " )"))
    return rawDevice.isEmpty ? nil : rawDevice
  }
}

private struct ActiveNetworkInterfaces {
  static func parse(_ output: String) -> Set<String> {
    var interfaces = Set<String>()
    for rawLine in output.split(separator: "\n") {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.hasPrefix("Network interfaces:"), let separator = line.firstIndex(of: ":") {
        let valuesStart = line.index(after: separator)
        for value in line[valuesStart...].split(whereSeparator: \.isWhitespace) {
          interfaces.insert(String(value))
        }
      } else if let flagsRange = line.range(of: " : flags") {
        let interface = String(line[..<flagsRange.lowerBound])
        if interface != "REACH" {
          interfaces.insert(interface)
        }
      }
    }
    return interfaces
  }
}

private struct ServiceProxySnapshot: Codable {
  var web: ProxyState
  var secureWeb: ProxyState
  var socks: ProxyState
  var bypassDomains: [String]

  func matches(_ expected: ExpectedSystemProxyConfiguration) -> Bool {
    guard let expectedHost = normalizedProxyMatchHost(expected.host) else {
      return false
    }
    return [web, secureWeb, socks].allSatisfy {
      $0.matches(hosts: [expectedHost], ports: [expected.port])
    } && bypassDomains == expected.bypassDomains
  }

  func containsProxyMatching(hosts: Set<String>, ports: Set<Int>) -> Bool {
    [web, secureWeb, socks].contains { $0.matches(hosts: hosts, ports: ports) }
  }
}

private struct ServiceDNSSnapshot: Codable {
  var servers: [String]

  init(servers: [String]) {
    self.servers = servers
  }

  init(output: String) {
    let values = output
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .filter { !$0.localizedCaseInsensitiveContains("there aren't any dns servers") }
      .filter { !$0.localizedCaseInsensitiveContains("there are no dns servers") }
    servers = NetworkExtensionRoutingSettings.normalizedDNSServers(values)
  }
}

private struct ProxyState: Codable {
  var enabled: Bool
  var server: String
  var port: Int

  init(output: String) {
    let values = output
      .split(separator: "\n")
      .reduce(into: [String: String]()) { result, line in
        let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        result[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = parts[1]
          .trimmingCharacters(in: .whitespacesAndNewlines)
      }

    let enabledValue = values["Enabled"]?.lowercased() ?? "no"
    enabled = enabledValue == "yes" || enabledValue == "1"
    server = values["Server"] ?? ""
    port = Int(values["Port"] ?? "") ?? 0
  }

  func matches(hosts: Set<String>, ports: Set<Int>) -> Bool {
    guard let normalizedServer = normalizedProxyMatchHost(server) else { return false }
    return enabled && hosts.contains(normalizedServer) && ports.contains(port)
  }
}

private func normalizedProxyMatchHosts<S: Sequence>(_ hosts: S) -> Set<String> where S.Element == String {
  Set(hosts.compactMap(normalizedProxyMatchHost))
}

private func normalizedProxyMatchHost(_ host: String) -> String? {
  let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  return trimmed.lowercased()
}

private struct ProxyBypassDomains {
  var domains: [String]

  init(output: String) {
    domains = output
      .split(separator: "\n")
      .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .filter { $0 != "Exceptions List" }
      .filter { $0 != "(null)" }
      .filter { !$0.localizedCaseInsensitiveContains("There aren't any") }
  }
}

private enum ProxyKind {
  case web
  case secureWeb
  case socks

  var setCommand: String {
    switch self {
    case .web: "-setwebproxy"
    case .secureWeb: "-setsecurewebproxy"
    case .socks: "-setsocksfirewallproxy"
    }
  }

  var stateCommand: String {
    switch self {
    case .web: "-setwebproxystate"
    case .secureWeb: "-setsecurewebproxystate"
    case .socks: "-setsocksfirewallproxystate"
    }
  }
}

// Thread-safety: Sendable escape is backed by AsyncOperationGateState actor isolation; this type only holds an immutable reference to that actor.
final class AsyncOperationGate: @unchecked Sendable {
  private let state = AsyncOperationGateState()

  func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
    try await state.acquire()
    do {
      try Task.checkCancellation()
      let result = try await operation()
      await state.release()
      return result
    } catch {
      await state.release()
      throw error
    }
  }
}

private actor AsyncOperationGateState {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Void, Error>
  }

  private var isLocked = false
  private var waiters: [Waiter] = []

  func acquire() async throws {
    if !isLocked {
      isLocked = true
      return
    }

    let waiterID = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append(Waiter(id: waiterID, continuation: continuation))
        }
      }
    } onCancel: {
      Task {
        await self.cancelWaiter(id: waiterID)
      }
    }
  }

  func release() {
    if waiters.isEmpty {
      isLocked = false
    } else {
      waiters.removeFirst().continuation.resume()
    }
  }

  private func cancelWaiter(id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.id == id }) else {
      return
    }
    waiters.remove(at: index).continuation.resume(throwing: CancellationError())
  }
}

struct ProcessCommandRunner: CommandRunning {
  let timeout: TimeInterval

  init(timeout: TimeInterval = 6) {
    self.timeout = timeout
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    try Self.assertCommandIsSafeForCurrentProcess(executable: executable, arguments: arguments)

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe

    let drain = LiveOutputDrain(maxRetainedBytes: nil)
    drain.attach(pipe.fileHandleForReading)
    let command = ([executable] + arguments).joined(separator: " ")
    let result = try await CancellableProcessExecution(
      process: process,
      timeout: timeout,
      timeoutError: { output in
        NSError(
          domain: "ClashMax.CommandRunner",
          code: Int(ETIMEDOUT),
          userInfo: [
            NSLocalizedDescriptionKey: "Command timed out after \(timeout)s: \(command)\(output.isEmpty ? "" : "\n\(output)")"
          ]
        )
      },
      output: {
        drain.flush(trimmed: false)
      },
      cleanup: {
        drain.detachAll()
      }
    ).run()

    guard result.terminationStatus == 0 else {
      throw NSError(
        domain: "ClashMax.CommandRunner",
        code: Int(result.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: result.output]
      )
    }
    return result.output
  }

  private static func assertCommandIsSafeForCurrentProcess(executable: String, arguments: [String]) throws {
    guard isRunningUnderXCTest else { return }
    guard URL(fileURLWithPath: executable).lastPathComponent == "networksetup" else { return }
    guard arguments.contains(where: { $0.hasPrefix("-set") }) else { return }

    let command = ([executable] + arguments).joined(separator: " ")
    throw NSError(
      domain: "ClashMax.CommandRunner",
      code: Int(EPERM),
      userInfo: [
        NSLocalizedDescriptionKey: "Refusing to run mutating networksetup command inside XCTest: \(command). Inject a test CommandRunning double instead."
      ]
    )
  }

  private static var isRunningUnderXCTest: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestBundlePath"] != nil
      || NSClassFromString("XCTest.XCTestCase") != nil
      || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
  }
}
