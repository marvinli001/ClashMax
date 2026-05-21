import Darwin
import Foundation

enum TunDiagnosticStatus: String, Codable, Equatable, Sendable {
  case pass
  case warn
  case fail
  case skipped

  var displayName: String {
    switch self {
    case .pass: "Pass"
    case .warn: "Warn"
    case .fail: "Fail"
    case .skipped: "Skipped"
    }
  }
}

struct TunDiagnosticCheck: Codable, Equatable, Identifiable, Sendable {
  var id: String
  var title: String
  var status: TunDiagnosticStatus
  var message: String
  var detail: String?

  init(
    id: String,
    title: String,
    status: TunDiagnosticStatus,
    message: String,
    detail: String? = nil
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.message = message
    self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }
}

struct TunDiagnosticsSnapshot: Codable, Equatable, Sendable {
  var checks: [TunDiagnosticCheck]
  var updatedAt: Date
  var externalProbeIncluded: Bool

  static let empty = TunDiagnosticsSnapshot(
    checks: [],
    updatedAt: Date.distantPast,
    externalProbeIncluded: false
  )

  var passCount: Int { checks.filter { $0.status == .pass }.count }
  var warnCount: Int { checks.filter { $0.status == .warn }.count }
  var failCount: Int { checks.filter { $0.status == .fail }.count }

  var overallStatus: TunDiagnosticStatus {
    if failCount > 0 {
      return .fail
    }
    if warnCount > 0 {
      return .warn
    }
    return checks.isEmpty ? .skipped : .pass
  }

  var summaryLabel: String {
    if checks.isEmpty {
      return "Waiting"
    }
    return "\(passCount) pass / \(warnCount) warn / \(failCount) fail"
  }

  var primaryIssue: TunDiagnosticCheck? {
    checks.first { $0.status == .fail } ?? checks.first { $0.status == .warn }
  }

  func check(id: String) -> TunDiagnosticCheck? {
    checks.first { $0.id == id }
  }
}

struct TunRuntimeInspectionConfiguration: Equatable, Sendable {
  var api: CoreAPIEndpoint
  var tunSettings: TunSettings
  var helperPID: Int?
  var helperStatusMessage: String?
  var systemDNSState: SystemDNSOverrideState
  var includeExternal: Bool

  init(
    api: CoreAPIEndpoint,
    tunSettings: TunSettings,
    helperPID: Int?,
    helperStatusMessage: String? = nil,
    systemDNSState: SystemDNSOverrideState,
    includeExternal: Bool = true
  ) {
    self.api = api
    self.tunSettings = tunSettings
    self.helperPID = helperPID
    self.helperStatusMessage = helperStatusMessage
    self.systemDNSState = systemDNSState
    self.includeExternal = includeExternal
  }
}

protocol TunRuntimeInspecting: Sendable {
  func inspect(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticsSnapshot
}

struct TunRuntimeInspector: TunRuntimeInspecting {
  private enum Command {
    static let ifconfig = "/sbin/ifconfig"
    static let route = "/sbin/route"
    static let netstat = "/usr/sbin/netstat"
    static let dig = "/usr/bin/dig"
    static let curl = "/usr/bin/curl"
  }

  private let commandRunner: any CommandRunning

  init(commandRunner: any CommandRunning = ProcessCommandRunner(timeout: 6)) {
    self.commandRunner = commandRunner
  }

  func inspect(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticsSnapshot {
    var checks: [TunDiagnosticCheck] = [
      await controllerCheck(configuration),
      helperPIDCheck(configuration)
    ]

    checks.append(await interfaceCheck(configuration))
    checks.append(await defaultRouteCheck(configuration))
    checks.append(await routeExcludeCheck(configuration))
    checks.append(systemDNSCheck(configuration))
    checks.append(await dnsHijackCheck(configuration))

    if configuration.includeExternal {
      checks.append(await externalTCPCheck())
      checks.append(await externalUDPCheck())
    } else {
      checks.append(TunDiagnosticCheck(
        id: "external-tcp",
        title: "External TCP",
        status: .skipped,
        message: "External TCP probe skipped."
      ))
      checks.append(TunDiagnosticCheck(
        id: "external-udp",
        title: "External UDP",
        status: .skipped,
        message: "External UDP DNS probe skipped."
      ))
    }

    return TunDiagnosticsSnapshot(
      checks: checks,
      updatedAt: Date(),
      externalProbeIncluded: configuration.includeExternal
    )
  }

  private func controllerCheck(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticCheck {
    let title = "Controller"
    let versionURL: URL
    do {
      versionURL = try configuration.api.baseURL.appendingPathComponent("version")
    } catch {
      return TunDiagnosticCheck(
        id: "controller",
        title: title,
        status: .fail,
        message: "Mihomo controller endpoint is invalid.",
        detail: UserFacingError.message(for: error)
      )
    }

    do {
      let output = try await commandRunner.run(
        Command.curl,
        [
          "-fsS",
          "--max-time",
          "2",
          "-H",
          "Authorization: Bearer \(configuration.api.secret)",
          versionURL.absoluteString
        ]
      )
      guard let version = controllerVersion(from: output) else {
        return TunDiagnosticCheck(
          id: "controller",
          title: title,
          status: .fail,
          message: "Mihomo controller did not return a valid /version response.",
          detail: outputSnippet(output)
        )
      }
      return TunDiagnosticCheck(
        id: "controller",
        title: title,
        status: .pass,
        message: "Mihomo controller is responding at \(configuration.api.host):\(configuration.api.port).",
        detail: "version: \(version)"
      )
    } catch {
      return TunDiagnosticCheck(
        id: "controller",
        title: title,
        status: .fail,
        message: "Mihomo controller did not answer /version at \(configuration.api.host):\(configuration.api.port).",
        detail: UserFacingError.message(for: error)
      )
    }
  }

  private func helperPIDCheck(_ configuration: TunRuntimeInspectionConfiguration) -> TunDiagnosticCheck {
    guard let helperPID = configuration.helperPID, helperPID > 0 else {
      return TunDiagnosticCheck(
        id: "helper-pid",
        title: "Helper PID",
        status: .fail,
        message: configuration.helperStatusMessage ?? "Helper status probe did not report a running Mihomo PID."
      )
    }

    return TunDiagnosticCheck(
      id: "helper-pid",
      title: "Helper PID",
      status: .pass,
      message: "Helper is running Mihomo as PID \(helperPID)."
    )
  }

  private func interfaceCheck(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticCheck {
    do {
      let output = try await commandRunner.run(Command.ifconfig, [])
      let device = configuration.tunSettings.normalizedDevice
      if output.contains("\(device):") {
        return TunDiagnosticCheck(
          id: "interface",
          title: "TUN Interface",
          status: .pass,
          message: "\(device) is present.",
          detail: firstLine(containing: "\(device):", in: output)
        )
      }
      if let utunLine = firstMatchingLine(in: output, prefix: "utun", suffix: ":") {
        return TunDiagnosticCheck(
          id: "interface",
          title: "TUN Interface",
          status: .warn,
          message: "A utun interface is present, but not the configured \(device).",
          detail: utunLine
        )
      }
      return TunDiagnosticCheck(
        id: "interface",
        title: "TUN Interface",
        status: .fail,
        message: "No utun interface was found after TUN startup."
      )
    } catch {
      return commandFailureCheck(id: "interface", title: "TUN Interface", error: error)
    }
  }

  private func defaultRouteCheck(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticCheck {
    guard configuration.tunSettings.autoRoute else {
      return TunDiagnosticCheck(
        id: "default-route",
        title: "Default Route",
        status: .skipped,
        message: "auto-route is disabled."
      )
    }

    do {
      let output = try await commandRunner.run(Command.route, ["-n", "get", "default"])
      let routeInterface = routeInterface(from: output)
      let detail = routeInterface.map { "interface: \($0)" } ?? outputSnippet(output)
      let device = configuration.tunSettings.normalizedDevice
      if routeInterface == device || routeInterface?.hasPrefix("utun") == true {
        return TunDiagnosticCheck(
          id: "default-route",
          title: "Default Route",
          status: .pass,
          message: "Default route points at \(routeInterface ?? device).",
          detail: detail
        )
      }
      return TunDiagnosticCheck(
        id: "default-route",
        title: "Default Route",
        status: .warn,
        message: "Default route is not using the configured TUN device.",
        detail: detail
      )
    } catch {
      return commandFailureCheck(id: "default-route", title: "Default Route", error: error)
    }
  }

  private func routeExcludeCheck(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticCheck {
    let excludes = configuration.tunSettings.normalizedRouteExcludeAddresses
    guard !excludes.isEmpty else {
      return TunDiagnosticCheck(
        id: "route-exclude",
        title: "Route Exclude",
        status: .skipped,
        message: "No route excludes are configured."
      )
    }

    do {
      let output = try await commandRunner.run(Command.netstat, ["-rn"])
      let missing = excludes.filter { !routeTable(output, containsCIDR: $0) }
      if missing.isEmpty {
        return TunDiagnosticCheck(
          id: "route-exclude",
          title: "Route Exclude",
          status: .pass,
          message: "\(excludes.count) route exclude rule(s) were found in the route table."
        )
      }
      return TunDiagnosticCheck(
        id: "route-exclude",
        title: "Route Exclude",
        status: .warn,
        message: "Route table does not show \(missing.count) configured exclude rule(s).",
        detail: missing.joined(separator: ", ")
      )
    } catch {
      return commandFailureCheck(id: "route-exclude", title: "Route Exclude", error: error)
    }
  }

  private func systemDNSCheck(_ configuration: TunRuntimeInspectionConfiguration) -> TunDiagnosticCheck {
    if configuration.tunSettings.systemDNSOverrideEnabled {
      switch configuration.systemDNSState {
      case let .applied(serviceCount):
        return TunDiagnosticCheck(
          id: "system-dns",
          title: "System DNS",
          status: .pass,
          message: "System DNS override is applied to \(serviceCount) service(s)."
        )
      case let .applyFailed(message), let .restoreFailed(message):
        return TunDiagnosticCheck(
          id: "system-dns",
          title: "System DNS",
          status: .fail,
          message: "System DNS override failed.",
          detail: message
        )
      case .applying:
        return TunDiagnosticCheck(
          id: "system-dns",
          title: "System DNS",
          status: .warn,
          message: "System DNS override is still applying."
        )
      case .restoring, .restored, .inactive:
        return TunDiagnosticCheck(
          id: "system-dns",
          title: "System DNS",
          status: .warn,
          message: "System DNS override is enabled but not currently applied."
        )
      }
    }

    switch configuration.systemDNSState {
    case .applied:
      return TunDiagnosticCheck(
        id: "system-dns",
        title: "System DNS",
        status: .warn,
        message: "System DNS override is off but ClashMax still owns DNS state."
      )
    case let .restoreFailed(message):
      return TunDiagnosticCheck(
        id: "system-dns",
        title: "System DNS",
        status: .fail,
        message: "System DNS restore failed.",
        detail: message
      )
    case .inactive, .restored, .restoring, .applying, .applyFailed:
      return TunDiagnosticCheck(
        id: "system-dns",
        title: "System DNS",
        status: .skipped,
        message: "System DNS override is off."
      )
    }
  }

  private func dnsHijackCheck(_ configuration: TunRuntimeInspectionConfiguration) async -> TunDiagnosticCheck {
    guard !configuration.tunSettings.normalizedDNSHijack.isEmpty else {
      return TunDiagnosticCheck(
        id: "dns-hijack",
        title: "DNS Hijack",
        status: .skipped,
        message: "No DNS hijack endpoint is configured."
      )
    }

    do {
      let output = try await commandRunner.run(
        Command.dig,
        ["+time=2", "+tries=1", "+short", "www.gstatic.com", "A"]
      )
      let ips = ipv4Addresses(in: output)
      if configuration.tunSettings.dnsFakeIPEnabled {
        let range = configuration.tunSettings.normalizedFakeIPRange
        if ips.contains(where: { ipv4($0, isInCIDR: range) }) {
          return TunDiagnosticCheck(
            id: "dns-hijack",
            title: "DNS Hijack",
            status: .pass,
            message: "DNS hijack returned a fake IP in \(range).",
            detail: ips.joined(separator: ", ")
          )
        }
        return TunDiagnosticCheck(
          id: "dns-hijack",
          title: "DNS Hijack",
          status: ips.isEmpty ? .fail : .warn,
          message: ips.isEmpty
            ? "DNS hijack did not return an A record."
            : "DNS hijack did not return the configured fake IP range.",
          detail: outputSnippet(output)
        )
      }

      return TunDiagnosticCheck(
        id: "dns-hijack",
        title: "DNS Hijack",
        status: ips.isEmpty ? .warn : .pass,
        message: ips.isEmpty ? "DNS query returned no A records." : "DNS query returned \(ips.count) A record(s).",
        detail: ips.joined(separator: ", ")
      )
    } catch {
      return commandFailureCheck(id: "dns-hijack", title: "DNS Hijack", error: error)
    }
  }

  private func externalTCPCheck() async -> TunDiagnosticCheck {
    do {
      let output = try await commandRunner.run(
        Command.curl,
        [
          "-fsS",
          "-o",
          "/dev/null",
          "-w",
          "%{http_code}",
          "--max-time",
          "5",
          AppConstants.defaultDelayTestURL.absoluteString
        ]
      )
      let statusCode = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
      if (200..<400).contains(statusCode) {
        return TunDiagnosticCheck(
          id: "external-tcp",
          title: "External TCP",
          status: .pass,
          message: "External TCP probe returned HTTP \(statusCode)."
        )
      }
      return TunDiagnosticCheck(
        id: "external-tcp",
        title: "External TCP",
        status: .fail,
        message: "External TCP probe returned HTTP \(statusCode).",
        detail: outputSnippet(output)
      )
    } catch {
      return commandFailureCheck(id: "external-tcp", title: "External TCP", error: error)
    }
  }

  private func externalUDPCheck() async -> TunDiagnosticCheck {
    do {
      let output = try await commandRunner.run(
        Command.dig,
        ["@1.1.1.1", "+time=2", "+tries=1", "+short", "example.com", "A"]
      )
      let ips = ipv4Addresses(in: output)
      return TunDiagnosticCheck(
        id: "external-udp",
        title: "External UDP",
        status: ips.isEmpty ? .fail : .pass,
        message: ips.isEmpty ? "External UDP DNS probe returned no A records." : "External UDP DNS probe returned \(ips.count) A record(s).",
        detail: ips.joined(separator: ", ")
      )
    } catch {
      return commandFailureCheck(id: "external-udp", title: "External UDP", error: error)
    }
  }

  private func commandFailureCheck(id: String, title: String, error: Error) -> TunDiagnosticCheck {
    TunDiagnosticCheck(
      id: id,
      title: title,
      status: .fail,
      message: "\(title) check failed.",
      detail: UserFacingError.message(for: error)
    )
  }

  private func routeInterface(from output: String) -> String? {
    for line in output.components(separatedBy: .newlines) {
      let pieces = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard pieces.count == 2,
            pieces[0].trimmingCharacters(in: .whitespaces) == "interface"
      else { continue }
      return pieces[1].trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    return nil
  }

  private struct RouteDestination: Equatable {
    var family: NetworkExtensionRouteCIDR.AddressFamily
    var prefix: Int
    var ipv4: UInt32?
    var ipv6: [UInt8]?
  }

  private func routeTable(_ output: String, containsCIDR cidr: String) -> Bool {
    guard let parsed = try? NetworkExtensionRouteCIDR(cidr) else {
      return false
    }
    guard let expected = routeDestination(for: parsed) else { return false }
    return routeDestinations(in: output).contains { routeDestination($0, matches: expected) }
  }

  private func routeDestinations(in output: String) -> [RouteDestination] {
    output.components(separatedBy: .newlines).compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return nil }
      guard let destination = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
        return nil
      }
      return routeDestination(fromNetstatDestination: destination)
    }
  }

  private func routeDestination(for cidr: NetworkExtensionRouteCIDR) -> RouteDestination? {
    switch cidr.family {
    case .ipv4:
      guard let value = ipv4Value(cidr.address) else { return nil }
      return RouteDestination(family: .ipv4, prefix: cidr.prefix, ipv4: value, ipv6: nil)
    case .ipv6:
      guard let bytes = ipv6Bytes(cidr.address) else { return nil }
      return RouteDestination(family: .ipv6, prefix: cidr.prefix, ipv4: nil, ipv6: bytes)
    }
  }

  private func routeDestination(fromNetstatDestination destination: String) -> RouteDestination? {
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed != "Destination",
          !trimmed.hasSuffix(":")
    else { return nil }

    if trimmed == "default" {
      return RouteDestination(family: .ipv4, prefix: 0, ipv4: 0, ipv6: nil)
    }

    if let ipv4 = ipv4RouteDestination(trimmed) {
      return ipv4
    }
    return ipv6RouteDestination(trimmed)
  }

  private func ipv4RouteDestination(_ destination: String) -> RouteDestination? {
    let pieces = destination.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard (1...2).contains(pieces.count) else { return nil }
    let addressPart = pieces[0]
    let octets = addressPart.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...4).contains(octets.count) else { return nil }
    let values = octets.compactMap { octet -> UInt8? in
      guard let value = UInt8(octet) else { return nil }
      return value
    }
    guard values.count == octets.count else { return nil }

    let prefix: Int
    if pieces.count == 2 {
      guard let parsedPrefix = Int(pieces[1]), (0...32).contains(parsedPrefix) else { return nil }
      prefix = parsedPrefix
    } else {
      prefix = values.count < 4 ? values.count * 8 : 32
    }

    let padded = values + Array(repeating: UInt8(0), count: 4 - values.count)
    let value = padded.reduce(UInt32(0)) { result, octet in
      (result << 8) | UInt32(octet)
    }
    return RouteDestination(family: .ipv4, prefix: prefix, ipv4: value, ipv6: nil)
  }

  private func ipv6RouteDestination(_ destination: String) -> RouteDestination? {
    let pieces = destination.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
    guard (1...2).contains(pieces.count) else { return nil }
    let address = pieces[0].split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? pieces[0]
    let prefix: Int
    if pieces.count == 2 {
      guard let parsedPrefix = Int(pieces[1]), (0...128).contains(parsedPrefix) else { return nil }
      prefix = parsedPrefix
    } else {
      prefix = 128
    }
    guard let bytes = ipv6Bytes(address) else { return nil }
    return RouteDestination(family: .ipv6, prefix: prefix, ipv4: nil, ipv6: bytes)
  }

  private func routeDestination(_ candidate: RouteDestination, matches expected: RouteDestination) -> Bool {
    guard candidate.family == expected.family, candidate.prefix == expected.prefix else {
      return false
    }
    switch expected.family {
    case .ipv4:
      guard let lhs = candidate.ipv4, let rhs = expected.ipv4 else { return false }
      return ipv4(lhs, matches: rhs, prefix: expected.prefix)
    case .ipv6:
      guard let lhs = candidate.ipv6, let rhs = expected.ipv6 else { return false }
      return ipv6(lhs, matches: rhs, prefix: expected.prefix)
    }
  }

  private func controllerVersion(from output: String) -> String? {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    return (object?["version"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
  }

  private func firstLine(containing needle: String, in output: String) -> String? {
    output.components(separatedBy: .newlines).first { $0.contains(needle) }?.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func firstMatchingLine(in output: String, prefix: String, suffix: String) -> String? {
    output.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { $0.hasPrefix(prefix) && $0.contains(suffix) }
  }

  private func outputSnippet(_ output: String, limit: Int = 240) -> String {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > limit else { return trimmed }
    return "\(trimmed.prefix(limit - 3))..."
  }

  private func ipv4Addresses(in output: String) -> [String] {
    output
      .split { $0.isWhitespace || $0 == "," || $0 == ";" }
      .map(String.init)
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]()")) }
      .filter { ipv4Value($0) != nil }
  }

  private func ipv4(_ ip: String, isInCIDR cidr: String) -> Bool {
    guard let route = try? NetworkExtensionRouteCIDR(cidr),
          route.family == .ipv4,
          let addressValue = ipv4Value(ip),
          let baseValue = ipv4Value(route.address)
    else {
      return false
    }
    let mask: UInt32
    if route.prefix == 0 {
      mask = 0
    } else {
      mask = UInt32.max << UInt32(32 - route.prefix)
    }
    return addressValue & mask == baseValue & mask
  }

  private func ipv4(_ lhs: UInt32, matches rhs: UInt32, prefix: Int) -> Bool {
    let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
    return lhs & mask == rhs & mask
  }

  private func ipv6(_ lhs: [UInt8], matches rhs: [UInt8], prefix: Int) -> Bool {
    guard lhs.count == 16, rhs.count == 16 else { return false }
    var remainingBits = prefix
    for index in 0..<16 {
      if remainingBits >= 8 {
        guard lhs[index] == rhs[index] else { return false }
        remainingBits -= 8
      } else if remainingBits > 0 {
        let mask = UInt8.max << UInt8(8 - remainingBits)
        return lhs[index] & mask == rhs[index] & mask
      } else {
        return true
      }
    }
    return true
  }

  private func ipv4Value(_ value: String) -> UInt32? {
    var address = in_addr()
    let result = value.withCString { inet_pton(AF_INET, $0, &address) }
    guard result == 1 else { return nil }
    return UInt32(bigEndian: address.s_addr)
  }

  private func ipv6Bytes(_ value: String) -> [UInt8]? {
    var address = in6_addr()
    let result = value.withCString { inet_pton(AF_INET6, $0, &address) }
    guard result == 1 else { return nil }
    return withUnsafeBytes(of: address) { Array($0) }
  }
}

private extension String {
  var nilIfEmpty: String? {
    isEmpty ? nil : self
  }
}
