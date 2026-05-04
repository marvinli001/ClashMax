import Foundation

protocol CommandRunning {
  func run(_ executable: String, _ arguments: [String]) throws -> String
}

final class SystemProxyController {
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

  private let commandRunner: CommandRunning
  private var snapshots: [String: ServiceProxySnapshot] = [:]

  init(commandRunner: CommandRunning = ProcessCommandRunner()) {
    self.commandRunner = commandRunner
  }

  func apply(host: String, port: Int) throws {
    for service in try networkServices() {
      if snapshots[service] == nil {
        snapshots[service] = try snapshot(for: service)
      }
      _ = try commandRunner.run("/usr/sbin/networksetup", ["-setwebproxy", service, host, String(port)])
      _ = try commandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, host, String(port)])
      _ = try commandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxy", service, host, String(port)])
      try setBypassDomains(Self.defaultBypassDomains, service: service)
    }
  }

  func restore() throws {
    guard !snapshots.isEmpty else {
      for service in try networkServices() {
        try disableAllProxyTypes(for: service)
        try setBypassDomains([], service: service)
      }
      return
    }

    for (service, snapshot) in snapshots {
      try restore(snapshot.web, service: service, kind: .web)
      try restore(snapshot.secureWeb, service: service, kind: .secureWeb)
      try restore(snapshot.socks, service: service, kind: .socks)
      try setBypassDomains(snapshot.bypassDomains, service: service)
    }
    snapshots.removeAll()
  }

  private func disableAllProxyTypes(for service: String) throws {
    _ = try commandRunner.run("/usr/sbin/networksetup", ["-setwebproxystate", service, "off"])
    _ = try commandRunner.run("/usr/sbin/networksetup", ["-setsecurewebproxystate", service, "off"])
    _ = try commandRunner.run("/usr/sbin/networksetup", ["-setsocksfirewallproxystate", service, "off"])
  }

  private func snapshot(for service: String) throws -> ServiceProxySnapshot {
    ServiceProxySnapshot(
      web: ProxyState(output: try commandRunner.run("/usr/sbin/networksetup", ["-getwebproxy", service])),
      secureWeb: ProxyState(output: try commandRunner.run("/usr/sbin/networksetup", ["-getsecurewebproxy", service])),
      socks: ProxyState(output: try commandRunner.run("/usr/sbin/networksetup", ["-getsocksfirewallproxy", service])),
      bypassDomains: ProxyBypassDomains(output: try commandRunner.run("/usr/sbin/networksetup", ["-getproxybypassdomains", service])).domains
    )
  }

  private func restore(_ state: ProxyState, service: String, kind: ProxyKind) throws {
    if state.enabled {
      if !state.server.isEmpty, state.port > 0 {
        _ = try commandRunner.run("/usr/sbin/networksetup", [kind.setCommand, service, state.server, String(state.port)])
      }
      _ = try commandRunner.run("/usr/sbin/networksetup", [kind.stateCommand, service, "on"])
    } else {
      _ = try commandRunner.run("/usr/sbin/networksetup", [kind.stateCommand, service, "off"])
    }
  }

  private func networkServices() throws -> [String] {
    let output = try commandRunner.run("/usr/sbin/networksetup", ["-listallnetworkservices"])
    return output
      .split(separator: "\n")
      .map(String.init)
      .filter { !$0.hasPrefix("An asterisk") }
      .filter { !$0.hasPrefix("*") }
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private func setBypassDomains(_ domains: [String], service: String) throws {
    let arguments = ["-setproxybypassdomains", service] + (domains.isEmpty ? ["Empty"] : domains)
    _ = try commandRunner.run("/usr/sbin/networksetup", arguments)
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
  func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "ClashMax.CommandRunner",
        code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: output]
      )
    }
    return output
  }
}
