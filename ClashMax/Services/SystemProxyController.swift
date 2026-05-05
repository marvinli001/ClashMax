import Darwin
import Foundation

protocol CommandRunning: Sendable {
  func run(_ executable: String, _ arguments: [String]) async throws -> String
}

final class SystemProxyController: @unchecked Sendable {
  static let defaultBypassDomains = [
    "localhost",
    "127.0.0.1",
    "::1",
    "*.local",
    "169.254/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16"
  ]

  static let applyBudgetSeconds: TimeInterval = 8

  private let commandRunner: CommandRunning
  private var snapshots: [String: ServiceProxySnapshot] = [:]
  private let lock = NSLock()

  init(commandRunner: CommandRunning = ProcessCommandRunner()) {
    self.commandRunner = commandRunner
  }

  func apply(host: String, port: Int) async throws {
    try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
      try await applyInner(host: host, port: port)
    }
  }

  func restore() async throws {
    try await withTimeout(seconds: Self.applyBudgetSeconds) { [self] in
      try await restoreInner()
    }
  }

  private func applyInner(host: String, port: Int) async throws {
    for service in try await networkServices() {
      try Task.checkCancellation()
      if readSnapshot(service) == nil {
        let snapshot = try await snapshot(for: service)
        writeSnapshot(snapshot, for: service)
      }
      _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setwebproxy", service, host, String(port)])
      _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, host, String(port)])
      _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, host, String(port)])
      try await setBypassDomains(Self.defaultBypassDomains, service: service)
    }
  }

  private func restoreInner() async throws {
    let captured = readAllSnapshots()
    if captured.isEmpty {
      for service in try await networkServices() {
        try Task.checkCancellation()
        try await disableAllProxyTypes(for: service)
        try await setBypassDomains([], service: service)
      }
      return
    }

    for (service, snapshot) in captured {
      try Task.checkCancellation()
      try await restore(snapshot.web, service: service, kind: .web)
      try await restore(snapshot.secureWeb, service: service, kind: .secureWeb)
      try await restore(snapshot.socks, service: service, kind: .socks)
      try await setBypassDomains(snapshot.bypassDomains, service: service)
    }
    clearSnapshots()
  }

  private func disableAllProxyTypes(for service: String) async throws {
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
    _ = try await commandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
  }

  private func snapshot(for service: String) async throws -> ServiceProxySnapshot {
    ServiceProxySnapshot(
      web: ProxyState(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service])),
      secureWeb: ProxyState(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])),
      socks: ProxyState(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])),
      bypassDomains: ProxyBypassDomains(output: try await commandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])).domains
    )
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

  private func readSnapshot(_ service: String) -> ServiceProxySnapshot? {
    lock.lock()
    defer { lock.unlock() }
    return snapshots[service]
  }

  private func writeSnapshot(_ snapshot: ServiceProxySnapshot, for service: String) {
    lock.lock()
    defer { lock.unlock() }
    snapshots[service] = snapshot
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
  }
}

private struct ServiceProxySnapshot {
  var web: ProxyState
  var secureWeb: ProxyState
  var socks: ProxyState
  var bypassDomains: [String]
}

private struct ProxyState {
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

struct ProcessCommandRunner: CommandRunning {
  let timeout: TimeInterval

  init(timeout: TimeInterval = 2) {
    self.timeout = timeout
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let timeout = self.timeout
    return try await Task.detached(priority: .userInitiated) {
      try Self.runSync(executable: executable, arguments: arguments, timeout: timeout)
    }.value
  }

  private static func runSync(executable: String, arguments: [String], timeout: TimeInterval) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()

    let waitGroup = DispatchGroup()
    waitGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      process.waitUntilExit()
      waitGroup.leave()
    }

    if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if waitGroup.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        waitGroup.wait()
      }

      let output = Self.output(from: pipe)
      throw NSError(
        domain: "ClashMax.CommandRunner",
        code: Int(ETIMEDOUT),
        userInfo: [
          NSLocalizedDescriptionKey: "Command timed out after \(timeout)s: \(([executable] + arguments).joined(separator: " "))\(output.isEmpty ? "" : "\n\(output)")"
        ]
      )
    }

    let output = Self.output(from: pipe)
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "ClashMax.CommandRunner",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output]
      )
    }
    return output
  }

  private static func output(from pipe: Pipe) -> String {
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
  }
}
