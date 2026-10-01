import Foundation
import Yams

// Roadmap A5: one file a user can attach to a bug report, with every secret removed before a byte
// of it is written. Redaction is a type boundary rather than a convention: `RedactedDiagnosticText`
// can only be constructed by `DiagnosticBundleRedactor` in this file, and `DiagnosticBundleWriter`
// only accepts a `DiagnosticBundle`, which only holds that type. Code elsewhere cannot hand the
// writer unredacted text, because it has no way to make the type the writer takes.

/// Text that has been through `DiagnosticBundleRedactor`.
struct RedactedDiagnosticText: Equatable, Sendable {
  let text: String

  fileprivate init(redactedText: String) {
    text = redactedText
  }
}

/// The finished, redacted bundle — the exact bytes the sheet previews, copies and saves.
struct DiagnosticBundle: Equatable, Sendable {
  let contents: RedactedDiagnosticText
  let generatedAt: Date

  fileprivate init(contents: RedactedDiagnosticText, generatedAt: Date) {
    self.contents = contents
    self.generatedAt = generatedAt
  }

  var data: Data {
    Data(contents.text.utf8)
  }

  var suggestedFileName: String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "clashmax-diagnostics-\(formatter.string(from: generatedAt)).txt"
  }
}

enum DiagnosticBundleWriter {
  /// Writes the bundle, readable only by the current user. The bundle is already redacted; the
  /// permission is there because the user may save it somewhere shared before reviewing it.
  static func write(_ bundle: DiagnosticBundle, to url: URL) throws {
    try bundle.data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

// MARK: - Input

struct DiagnosticBundleVersions: Equatable, Sendable {
  var appVersion: String
  var appBuild: String
  /// The core version the app bundle ships, from `mihomo-manifest.json`.
  var bundledCore: String?
  /// The version the running core reported, when one is running.
  var runningCore: String?
  var operatingSystem: String
  var hardwareArchitecture: String
  var processArchitecture: String
  /// True when an x86_64 build of the app runs under Rosetta on Apple silicon.
  var isTranslated: Bool

  static func current(bundle: Bundle = .main, bundledCore: String?, runningCore: String?) -> DiagnosticBundleVersions {
    let info = bundle.infoDictionary ?? [:]
    return DiagnosticBundleVersions(
      appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
      appBuild: info["CFBundleVersion"] as? String ?? "unknown",
      bundledCore: bundledCore,
      runningCore: runningCore,
      operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
      hardwareArchitecture: Self.sysctlString("hw.machine") ?? "unknown",
      processArchitecture: Self.processArchitecture,
      isTranslated: Self.sysctlInt("sysctl.proc_translated") == 1
    )
  }

  private static var processArchitecture: String {
    #if arch(arm64)
      return "arm64"
    #elseif arch(x86_64)
      return "x86_64"
    #else
      return "unknown"
    #endif
  }

  private static func sysctlString(_ name: String) -> String? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
  }

  private static func sysctlInt(_ name: String) -> Int32? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return value
  }
}

/// Where the runtime YAML in the bundle came from. The difference matters to whoever reads it: a
/// config the core loaded is a fact, a generated one is only what the next start would use.
enum DiagnosticBundleConfigSource: Equatable, Sendable {
  case loadedByCore(yaml: String, path: String)
  case generated(yaml: String, profileName: String)
  case unavailable(String)
}

struct DiagnosticBundleNetwork: Equatable, Sendable {
  var wiFi: WiFiNetworkSnapshot
  var savedPolicyCount: Int
  var autoApplyEnabled: Bool
  var lastAppliedPolicyName: String?
  var policyStatus: String?
  var lastNetworkChange: Date?
}

/// Every value known to be secret, collected from the app's own state. The redactor removes each
/// one literally wherever it appears — logs, error text, YAML — on top of the shape-based rules.
struct DiagnosticBundleSecrets: Equatable, Sendable {
  var controllerSecrets: [String] = []
  var subscriptionURLs: [String] = []
  var ssids: [String] = []
  var publicIPAddresses: [String] = []
  var providerContentPaths: [String] = []
  /// Anything else held as a secret by value, such as subscription request header values.
  var otherSecrets: [String] = []
  var homeDirectory: String?
}

struct DiagnosticBundleInput: Sendable {
  var generatedAt: Date
  var versions: DiagnosticBundleVersions
  var report: RuntimeDiagnosticsReport
  var config: DiagnosticBundleConfigSource
  /// From the generated config: whether the DNS override is in effect, and the sniffer plan.
  var dnsOverride: DNSOverridePlan?
  var sniffer: SnifferPlan?
  /// Whether the config the running core loaded enables sniffing; nil when no core is running or
  /// the file has not been read yet.
  var runningCoreSniffing: Bool?
  var dnsResolution: DNSResolutionSnapshot?
  var network: DiagnosticBundleNetwork
  var logs: [LogEntry]
  var coreProcessOutput: String
  var secrets: DiagnosticBundleSecrets
  /// Raw YAML the bundle never prints — the active profile's stored source, a provider's node
  /// list — read only so that every credential value in it is removed wherever else it appears.
  var credentialSourceYAMLs: [String] = []
}

// MARK: - Builder

enum DiagnosticBundleBuilder {
  /// Enough to cover a failure that took minutes to develop, still small enough to attach.
  static let logLimit = 500
  static let helperLogLimit = 80
  static let coreOutputLineLimit = 120

  static func build(_ input: DiagnosticBundleInput) -> DiagnosticBundle {
    let configYAML = redactedConfigYAML(input)
    let redactor = DiagnosticBundleRedactor(
      secrets: input.secrets,
      credentialValues: credentialValues(in: input.config)
        + input.credentialSourceYAMLs.flatMap(credentialValues(inYAML:))
    )
    var lines: [String] = []
    lines.append("ClashMax Diagnostic Bundle")
    lines.append("Generated: \(timestamp(input.generatedAt))")
    lines.append(
      "Redacted before writing: the controller secret, subscription URLs and their hosts and tokens, "
        + "node passwords, UUIDs and keys, inbound authentication, Wi-Fi network names, the public IP "
        + "address, and file names under your home folder."
    )
    lines.append(
      "Still included: proxy node names and server addresses, and the domains in recent logs. "
        + "Review the file before you share it."
    )

    section("Versions", into: &lines, body: versionLines(input.versions))
    section("Runtime State", into: &lines, body: runtimeStateLines(input.report))
    section("Diagnoses", into: &lines, body: diagnosisLines(input))
    section("Network Environment", into: &lines, body: networkLines(input.network))
    section("Effective Runtime YAML", into: &lines, body: configLines(input.config, redactedYAML: configYAML))
    section("Logs", into: &lines, body: logLines(input))

    let raw = lines.joined(separator: "\n") + "\n"
    return DiagnosticBundle(contents: redactor.redact(raw), generatedAt: input.generatedAt)
  }

  private static func section(_ title: String, into lines: inout [String], body: [String]) {
    lines.append("")
    lines.append("== \(title) ==")
    lines.append(contentsOf: body)
  }

  private static func subsection(_ title: String, _ body: [String]) -> [String] {
    ["", "-- \(title) --"] + body
  }

  private static func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = .current
    return formatter.string(from: date)
  }

  // MARK: Sections

  private static func versionLines(_ versions: DiagnosticBundleVersions) -> [String] {
    var cpu = "\(versions.hardwareArchitecture) hardware, \(versions.processArchitecture) process"
    if versions.isTranslated {
      cpu += " (running under Rosetta)"
    }
    return [
      "ClashMax: \(versions.appVersion) (\(versions.appBuild))",
      "Mihomo (bundled): \(versions.bundledCore ?? "unknown — the bundled core manifest could not be read")",
      "Mihomo (running): \(versions.runningCore ?? "no core is running")",
      "macOS: \(versions.operatingSystem)",
      "CPU: \(cpu)",
    ]
  }

  private static func runtimeStateLines(_ report: RuntimeDiagnosticsReport) -> [String] {
    var lines = report.stateLines
    if let coreMemory = report.coreMemory, coreMemory.hasReading {
      lines.append("Core Memory: \(coreMemory.formattedInUse)")
    } else {
      lines.append("Core Memory: no reading — the core reports memory only while it is running")
    }
    lines.append("Readiness: \(report.readinessIssue ?? "ready to start")")
    lines.append("Last Error: \(report.lastError ?? "none")")
    return lines
  }

  private static func diagnosisLines(_ input: DiagnosticBundleInput) -> [String] {
    let report = input.report
    var lines: [String] = []

    var proxyEffect = report.proxyEffectReportLines(includingPublicIP: false)
    proxyEffect.insert(
      "Public IP: \(report.publicIPInfo == nil ? "not checked yet" : "<redacted>")",
      at: 0
    )
    if report.proxyEffect == nil {
      proxyEffect.append("Proxy Effect: not evaluated — no public IP result or current node to judge")
    }
    lines += subsection("Proxy Effect", proxyEffect)

    var tun = ["TUN: \(report.tunEnabled ? "enabled" : "disabled")", "TUN Diagnostics: \(report.tunDiagnostics.summaryLabel)"]
    if report.tunDiagnostics.checks.isEmpty {
      tun.append(
        report.routingMode == .tun
          ? "TUN Checks: none have run yet — refresh TUN diagnostics on the Status page"
          : "TUN Checks: not applicable — routing mode is \(report.routingMode.displayName)"
      )
    } else {
      tun.append("TUN Checks:")
      tun += report.tunDiagnostics.checks.map { "- \($0.title): \($0.status.displayName) - \($0.message)" }
    }
    lines += subsection("TUN", tun)

    let ne = report.networkExtensionDiagnostics
    lines += subsection("Network Extension", [
      "NE Proxy: \(report.networkExtensionEnabled ? "enabled" : "disabled")",
      "NE System DNS: \(report.networkExtensionSystemDNS)",
      "Bridges: TCP \(ne.activeTCPBridgeCount), UDP \(ne.activeUDPBridgeCount), DNS \(ne.dnsCaptureCount)",
    ])

    var sniffer = input.sniffer?.plainTextLines
      ?? ["Sniffer: unknown — the effective config could not be generated, see Effective Runtime YAML"]
    switch input.runningCoreSniffing {
    case .some(true): sniffer.append("Running Core: sniffing is on")
    case .some(false): sniffer.append("Running Core: sniffing is off")
    case .none: sniffer.append("Running Core: not known — no core is running, or its config has not been read yet")
    }
    lines += subsection("Sniffer", sniffer)

    lines += subsection(
      "Fake IP",
      report.fakeIP?.plainTextLines ?? ["Fake IP: not evaluated"]
    )
    lines += subsection(
      "Geo Databases",
      report.geoDatabases?.plainTextLines ?? ["Geo Databases: not evaluated"]
    )
    lines += subsection(
      "Listener Exposure",
      report.listenerExposure?.plainTextLines ?? ["Listener Exposure: not evaluated"]
    )

    var dns = ["TUN DNS: \(report.tunSystemDNS) / \(report.tunDNSMode)"]
    dns += input.dnsOverride?.plainTextLines
      ?? ["DNS Override: unknown — the effective config could not be generated"]
    dns += input.dnsResolution?.plainTextLines
      ?? ["DNS Resolution: no query has been made from the DNS panel"]
    lines += subsection("DNS", dns)
    return lines
  }

  private static func networkLines(_ network: DiagnosticBundleNetwork) -> [String] {
    var lines: [String] = []
    if network.wiFi.ssid != nil {
      // The name itself is redacted; that a Wi-Fi network was joined is the useful fact.
      lines.append("Wi-Fi: connected (network name redacted)")
    } else if let reason = network.wiFi.unavailableReason {
      lines.append("Wi-Fi: no network name — \(NetworkPolicyStatusPresenter.unavailableMessage(reason))")
    } else {
      lines.append("Wi-Fi: not checked yet")
    }
    lines.append("Network Policies: \(network.savedPolicyCount) saved, automatic apply \(network.autoApplyEnabled ? "on" : "off")")
    lines.append("Last Applied Policy: \(network.lastAppliedPolicyName ?? "none")")
    lines.append("Policy Status: \(network.policyStatus ?? "none")")
    lines.append(
      "Last Network Change: \(network.lastNetworkChange.map(timestamp) ?? "none seen since ClashMax started")"
    )
    return lines
  }

  private static func configLines(_ source: DiagnosticBundleConfigSource, redactedYAML: String?) -> [String] {
    switch source {
    case let .loadedByCore(_, path):
      return ["Source: the config the running core loaded (\(path))", redactedYAML ?? ""]
    case let .generated(_, profileName):
      return [
        "Source: generated from the active profile \(profileName); no running core has loaded it",
        redactedYAML ?? "",
      ]
    case let .unavailable(reason):
      return ["Unavailable: \(reason)"]
    }
  }

  private static func logLines(_ input: DiagnosticBundleInput) -> [String] {
    var lines: [String] = []
    let logs = input.logs.suffix(logLimit)
    var app = ["Showing \(logs.count) of \(input.logs.count) retained entries, all levels."]
    if logs.isEmpty {
      app = ["No log entries have been recorded since ClashMax started."]
    } else {
      app += logs.map { "\(timestamp($0.date)) [\($0.level)] \($0.message)" }
    }
    lines += subsection("App and Core Log", app)

    let helper = input.report.helperLogs.suffix(helperLogLimit)
    lines += subsection(
      "Helper Log",
      helper.isEmpty
        ? ["The helper reported no output. It only holds the core's output while ClashMax runs in TUN mode."]
        : helper.map { "- \($0)" }
    )

    let output = input.coreProcessOutput
      .split(separator: "\n", omittingEmptySubsequences: true)
      .suffix(coreOutputLineLimit)
    lines += subsection(
      "Core Process Output",
      output.isEmpty
        ? ["The core process has written nothing since it was last started."]
        : output.map(String.init)
    )
    return lines
  }

  // MARK: Config redaction

  private static func rawYAML(_ source: DiagnosticBundleConfigSource) -> String? {
    switch source {
    case let .loadedByCore(yaml, _), let .generated(yaml, _):
      return yaml
    case .unavailable:
      return nil
    }
  }

  /// Key-aware redaction first, because only the structure can say that the value under `uuid` or
  /// in the `authentication` list is a secret. The whole document then goes through the text pass.
  private static func redactedConfigYAML(_ input: DiagnosticBundleInput) -> String? {
    guard let yaml = rawYAML(input.config) else { return nil }
    return RuntimeConfigDisplayRedactor.redacted(
      yaml,
      controllerSecret: input.secrets.controllerSecrets.first ?? "",
      providerContentPaths: input.secrets.providerContentPaths
    )
  }

  /// Every credential value in the raw config, so the same value is also removed where it shows up
  /// outside the YAML — an error message that quotes a password, a log line that echoes a UUID.
  static func credentialValues(in source: DiagnosticBundleConfigSource) -> [String] {
    rawYAML(source).map(credentialValues(inYAML:)) ?? []
  }

  static func credentialValues(inYAML yaml: String) -> [String] {
    guard let root = try? Yams.load(yaml: yaml) else { return [] }
    var values: [String] = []
    collectCredentials(root, path: [], into: &values)
    return values
  }

  /// Account names are not secrets to the Effective Config view, but in a file meant for a public
  /// issue they identify whoever an inbound or an upstream proxy was set up for.
  private static let accountNameKeys: Set<String> = ["username", "user"]

  private static func collectCredentials(_ value: Any, path: [String], into values: inout [String]) {
    if let map = value as? [String: Any] {
      for (key, child) in map {
        if ConfigCredentialKeyPolicy.isCredential(key: key, path: path)
          || accountNameKeys.contains(key.lowercased())
        {
          collectScalars(child, splittingUserPass: key.lowercased() == "authentication", into: &values)
        } else {
          collectCredentials(child, path: path + [key], into: &values)
        }
      }
    } else if let list = value as? [Any] {
      for child in list {
        collectCredentials(child, path: path, into: &values)
      }
    }
  }

  private static func collectScalars(_ value: Any, splittingUserPass: Bool, into values: inout [String]) {
    if let list = value as? [Any] {
      list.forEach { collectScalars($0, splittingUserPass: splittingUserPass, into: &values) }
    } else if let map = value as? [String: Any] {
      map.values.forEach { collectScalars($0, splittingUserPass: splittingUserPass, into: &values) }
    } else if let string = value as? String {
      values.append(string)
      // `authentication` entries are `user:pass`, and each half is its own secret. Only there:
      // splitting a provider URL the same way would make its `https` a "secret".
      if splittingUserPass {
        values.append(contentsOf: string.split(separator: ":", maxSplits: 1).map(String.init))
      }
    } else if let number = value as? Int {
      values.append(String(number))
    }
  }
}

// MARK: - Redactor

/// The one place `RedactedDiagnosticText` is made. Three passes, each a superset safety net for
/// the one before:
///
/// 1. Every value the app *knows* is secret is removed literally — controller secrets, full
///    subscription URLs plus their hosts, tokens and long path segments, credential values read out
///    of the config, provider file paths, and the public IP address.
/// 2. Wi-Fi names are removed case-insensitively at word boundaries, plus any `ssid=` value in logs.
/// 3. `StructuredLogRedactor` — the log pipeline's shape-based rules: share links, URL paths and
///    queries, `key: value` credentials, bearer tokens, and file names under the home folder.
struct DiagnosticBundleRedactor {
  static let placeholder = StructuredLogRedactor.placeholder
  static let ssidPlaceholder = "<ssid>"
  static let subscriptionHostPlaceholder = "<subscription-host>"

  /// Values shorter than this are not replaced literally: a two-character password replaced
  /// everywhere would shred the text. Their structural occurrences are still removed by key.
  static let minimumLiteralLength = 4

  private let literals: [(value: String, replacement: String)]
  private let ssidExpressions: [NSRegularExpression]
  private let homeDirectory: String?

  init(secrets: DiagnosticBundleSecrets, credentialValues: [String] = []) {
    var literals: [(String, String)] = []
    func add(_ value: String, _ replacement: String = Self.placeholder) {
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count >= Self.minimumLiteralLength, trimmed != Self.placeholder else { return }
      literals.append((trimmed, replacement))
    }
    secrets.controllerSecrets.forEach { add($0) }
    for url in secrets.subscriptionURLs {
      add(url)
      for part in Self.subscriptionURLParts(url) {
        add(part.value, part.isHost ? Self.subscriptionHostPlaceholder : Self.placeholder)
      }
    }
    credentialValues.forEach { add($0) }
    secrets.otherSecrets.forEach { add($0) }
    secrets.providerContentPaths.forEach { add($0) }
    secrets.publicIPAddresses.forEach { add($0) }
    // Longest first, so a URL is replaced whole before its host is.
    self.literals = literals.sorted { $0.0.count > $1.0.count }

    ssidExpressions = Set(secrets.ssids.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      .filter { !$0.isEmpty }
      .sorted { $0.count > $1.count }
      .compactMap { ssid in
        try? NSRegularExpression(
          pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: ssid) + "(?![\\p{L}\\p{N}])",
          options: [.caseInsensitive]
        )
      }
    homeDirectory = secrets.homeDirectory
  }

  func redact(_ raw: String) -> RedactedDiagnosticText {
    var text = raw
    for literal in literals {
      text = text.replacingOccurrences(of: literal.value, with: literal.replacement)
    }
    for expression in ssidExpressions {
      text = expression.stringByReplacingMatches(
        in: text,
        range: NSRange(text.startIndex..., in: text),
        withTemplate: NSRegularExpression.escapedTemplate(for: Self.ssidPlaceholder)
      )
    }
    text = Self.redactSSIDAssignments(in: text)
    text = StructuredLogRedactor.redactCredentials(in: text, homeDirectory: homeDirectory)
    return RedactedDiagnosticText(redactedText: text)
  }

  /// `ssid=<name>` as the network monitor logs it. The reasons logged when there is no name are
  /// kept, because they are the diagnosis.
  private static let ssidAssignment = try? NSRegularExpression(
    pattern: "\\b(ssid)\\s*[=:]\\s*([^\\s,;)]+)",
    options: [.caseInsensitive]
  )

  private static let keptSSIDValues: Set<String> = Set(
    WiFiSSIDUnavailableReason.allCases.map(\.rawValue) + ["none", ssidPlaceholder]
  )

  private static func redactSSIDAssignments(in text: String) -> String {
    guard let ssidAssignment else { return text }
    let matches = ssidAssignment.matches(in: text, range: NSRange(text.startIndex..., in: text))
    var result = text
    for match in matches.reversed() {
      guard let valueRange = Range(match.range(at: 2), in: result) else { continue }
      if keptSSIDValues.contains(String(result[valueRange])) { continue }
      result.replaceSubrange(valueRange, with: ssidPlaceholder)
    }
    return result
  }

  /// The parts of a subscription URL that identify the account or the provider on their own.
  private static func subscriptionURLParts(_ string: String) -> [(value: String, isHost: Bool)] {
    guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) else {
      return []
    }
    var parts: [(String, Bool)] = []
    if let host = components.host, !host.isEmpty {
      parts.append((host, true))
    }
    if let user = components.user { parts.append((user, false)) }
    if let password = components.password { parts.append((password, false)) }
    for item in components.queryItems ?? [] {
      if let value = item.value, value.count >= 6 {
        parts.append((value, false))
      }
    }
    // Panels put the token in the path as often as in the query (`/api/v1/client/<token>`).
    for segment in components.path.split(separator: "/") where segment.count >= 16 {
      parts.append((String(segment), false))
    }
    return parts
  }
}
