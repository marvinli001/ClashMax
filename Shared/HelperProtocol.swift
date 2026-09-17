import Darwin
import Foundation
import Security

let clashMaxHelperMachServiceName = "io.github.clashmax.ClashMax.Helper"
let clashMaxAppBundleIdentifier = "io.github.clashmax.ClashMax"
let clashMaxHelperBundleIdentifier = "io.github.clashmax.ClashMax.Helper"
let clashMaxAppSupportDirectoryName = "ClashMax"
let clashMaxRuntimeDirectoryName = "Runtime"

@objc(ClashMaxHelperXPCProtocol)
protocol ClashMaxHelperXPCProtocol {
  func status(withReply reply: @escaping (NSString) -> Void)
  func startTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  )
  func stopTunnel(withReply reply: @escaping (NSString) -> Void)
  func restartTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  )
  func recentLogs(withReply reply: @escaping (NSString) -> Void)
}

enum ClashMaxHelperXPCInterface {
  static func make() -> NSXPCInterface {
    let interface = NSXPCInterface(with: ClashMaxHelperXPCProtocol.self)
    let stringClasses = allowedClassSet([NSString.self])
    let replySelectors = [
      #selector(ClashMaxHelperXPCProtocol.status(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.startTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.stopTunnel(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.restartTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.recentLogs(withReply:)),
    ]

    for selector in replySelectors {
      interface.setClasses(stringClasses, for: selector, argumentIndex: 0, ofReply: true)
    }

    let tunnelRequestSelectors = [
      #selector(ClashMaxHelperXPCProtocol.startTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.restartTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
    ]
    for selector in tunnelRequestSelectors {
      for argumentIndex in 0..<4 {
        interface.setClasses(stringClasses, for: selector, argumentIndex: argumentIndex, ofReply: false)
      }
    }
    return interface
  }

  private static func allowedClassSet(_ classes: [AnyClass]) -> Set<AnyHashable> {
    NSSet(array: classes) as! Set<AnyHashable>
  }
}

enum HelperResponseKey {
  static let ok = "ok"
  static let running = "running"
  static let pid = "pid"
  static let code = "code"
  static let message = "message"
  static let protocolVersion = "protocolVersion"
  static let helperBuildVersion = "helperBuildVersion"
}

enum HelperResponseCode {
  static let alreadyRunning = "alreadyRunning"
  static let invalidPath = "invalidPath"
  static let untrustedSignature = "untrustedSignature"
  static let launchFailed = "launchFailed"
  static let incompatibleProtocol = "incompatibleProtocol"
  /// `stopTunnel` gave up waiting: the helper's Mihomo is still alive after SIGTERM and SIGKILL.
  static let stopTimedOut = "stopTimedOut"
}

enum ClashMaxHelperProtocolVersion {
  static let current = 1
  static let minimumCompatible = 1
}

enum ClashMaxHelperBuild {
  static var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    let shortVersion = info["CFBundleShortVersionString"] as? String
    let buildVersion = info["CFBundleVersion"] as? String

    switch (shortVersion?.isEmpty == false ? shortVersion : nil, buildVersion?.isEmpty == false ? buildVersion : nil) {
    case let (short?, build?):
      return "\(short) (\(build))"
    case let (short?, nil):
      return short
    case let (nil, build?):
      return build
    case (nil, nil):
      return "unknown"
    }
  }
}

enum HelperXPCPayload {
  static func response(
    ok: Bool,
    running: Bool = false,
    pid: Int = 0,
    code: String = "",
    message: String = "",
    protocolVersion: Int? = ClashMaxHelperProtocolVersion.current,
    helperBuildVersion: String? = ClashMaxHelperBuild.version
  ) -> NSString {
    var payload: [String: Any] = [
      HelperResponseKey.ok: ok,
      HelperResponseKey.running: running,
      HelperResponseKey.pid: pid,
      HelperResponseKey.code: code,
      HelperResponseKey.message: message,
    ]
    if let protocolVersion {
      payload[HelperResponseKey.protocolVersion] = protocolVersion
    }
    if let helperBuildVersion, !helperBuildVersion.isEmpty {
      payload[HelperResponseKey.helperBuildVersion] = helperBuildVersion
    }
    return jsonString(payload) as NSString
  }

  static func responseDictionary(from payload: NSString) -> [String: Any] {
    guard let data = (payload as String).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return object
  }

  static func logs(_ lines: [String]) -> NSString {
    jsonString(lines) as NSString
  }

  static func logLines(from payload: NSString) -> [String] {
    guard let data = (payload as String).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String]
    else {
      return []
    }
    return object
  }

  private static func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}

enum HelperBundleLocator {
  static func bundledCoreRoot(
    executableURL: URL? = Bundle.main.executableURL,
    commandPath: String = CommandLine.arguments.first ?? "",
    currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  ) -> URL {
    let candidates = executableCandidates(
      executableURL: executableURL,
      commandPath: commandPath,
      currentDirectoryURL: currentDirectoryURL
    )

    for candidate in candidates {
      if let contents = contentsDirectory(containing: candidate) {
        return contents.appendingPathComponent("Resources/Core", isDirectory: true).standardizedFileURL
      }
    }

    return currentDirectoryURL
      .appendingPathComponent(commandPath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Core", isDirectory: true)
      .standardizedFileURL
  }

  private static func executableCandidates(
    executableURL: URL?,
    commandPath: String,
    currentDirectoryURL: URL
  ) -> [URL] {
    var candidates: [URL] = []
    if let executableURL {
      candidates.append(executableURL.standardizedFileURL)
    }
    if !commandPath.isEmpty {
      let commandURL = commandPath.hasPrefix("/")
        ? URL(fileURLWithPath: commandPath)
        : currentDirectoryURL.appendingPathComponent(commandPath)
      candidates.append(commandURL.standardizedFileURL)
    }
    return candidates
  }

  private static func contentsDirectory(containing executableURL: URL) -> URL? {
    var cursor = executableURL.standardizedFileURL.deletingLastPathComponent()
    while cursor.path != "/" {
      if cursor.lastPathComponent == "Contents" {
        return cursor
      }
      let parent = cursor.deletingLastPathComponent()
      if parent.path == cursor.path {
        break
      }
      cursor = parent
    }
    return nil
  }
}

struct HelperTrustedPaths {
  let runtimeRoot: URL
  let bundledCoreRoot: URL

  init(runtimeRoot: URL, bundledCoreRoot: URL) {
    self.runtimeRoot = runtimeRoot.standardizedFileURL
    self.bundledCoreRoot = bundledCoreRoot.standardizedFileURL
  }

  static func live(clientUserID: uid_t, bundledCoreRoot: URL = HelperBundleLocator.bundledCoreRoot()) throws -> HelperTrustedPaths {
    let homeDirectory = try HelperUserHomeDirectoryResolver.homeDirectory(for: clientUserID)
    let runtimeRoot = homeDirectory
      .appendingPathComponent("Library", isDirectory: true)
      .appendingPathComponent("Application Support", isDirectory: true)
      .appendingPathComponent(clashMaxAppSupportDirectoryName, isDirectory: true)
      .appendingPathComponent(clashMaxRuntimeDirectoryName, isDirectory: true)
    return HelperTrustedPaths(runtimeRoot: runtimeRoot, bundledCoreRoot: bundledCoreRoot)
  }
}

enum HelperUserHomeDirectoryResolver {
  enum ResolutionError: Error, CustomStringConvertible {
    case cannotResolveHomeDirectory(uid_t)

    var description: String {
      switch self {
      case let .cannotResolveHomeDirectory(userID):
        return "Unable to resolve home directory for uid \(userID)"
      }
    }
  }

  static func homeDirectory(for userID: uid_t) throws -> URL {
    var password = passwd()
    var result: UnsafeMutablePointer<passwd>?
    let configuredBufferSize = sysconf(_SC_GETPW_R_SIZE_MAX)
    let bufferSize = configuredBufferSize > 0 ? Int(configuredBufferSize) : 16_384
    var buffer = [CChar](repeating: 0, count: bufferSize)

    let status = getpwuid_r(userID, &password, &buffer, buffer.count, &result)
    guard status == 0,
          let record = result,
          let home = record.pointee.pw_dir,
          !String(cString: home).isEmpty
    else {
      throw ResolutionError.cannotResolveHomeDirectory(userID)
    }

    return URL(fileURLWithPath: String(cString: home), isDirectory: true)
  }
}

struct HelperValidatedTunnelPaths {
  let coreURL: URL
  let configURL: URL
  let workDirectory: URL
}

struct HelperPathValidator {
  enum ValidationError: Error, CustomStringConvertible {
    case pathEscapesAllowedRoots(String)
    case unexpectedWorkDirectory(String)
    case untrustedCoreExecutableName(String)
    case missingFile(String)
    case missingDirectory(String)
    case notExecutable(String)

    var description: String {
      switch self {
      case let .pathEscapesAllowedRoots(path):
        return "Path is outside ClashMax-managed locations: \(path)"
      case let .unexpectedWorkDirectory(path):
        return "Work directory must be ClashMax's fixed runtime directory: \(path)"
      case let .untrustedCoreExecutableName(name):
        return "Core executable is not an approved bundled Mihomo binary: \(name)"
      case let .missingFile(path):
        return "Required file is missing: \(path)"
      case let .missingDirectory(path):
        return "Required directory is missing: \(path)"
      case let .notExecutable(path):
        return "Core executable is not executable: \(path)"
      }
    }
  }

  private static let approvedBundledCoreNames: Set<String> = [
    "mihomo",
    "mihomo-darwin-amd64",
    "mihomo-darwin-arm64",
  ]
  // Downloaded cores need a manifest hash or signing requirement before adding any non-bundle root.

  let trustedPaths: HelperTrustedPaths
  private let fileManager: FileManager

  init(trustedPaths: HelperTrustedPaths, fileManager: FileManager = .default) {
    self.trustedPaths = trustedPaths
    self.fileManager = fileManager
  }

  init(runtimeRoot: URL, bundledCoreRoot: URL, fileManager: FileManager = .default) {
    self.init(
      trustedPaths: HelperTrustedPaths(runtimeRoot: runtimeRoot, bundledCoreRoot: bundledCoreRoot),
      fileManager: fileManager
    )
  }

  func validate(coreURL: URL, configURL: URL, workDirectory: URL) throws {
    _ = try validatedPaths(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
  }

  func validatedPaths(coreURL: URL, configURL: URL, workDirectory: URL) throws -> HelperValidatedTunnelPaths {
    let core = try canonicalExistingFile(coreURL, requireExecutable: true)
    let config = try canonicalExistingFile(configURL, requireExecutable: false)
    let workDirectory = try canonicalExistingDirectory(workDirectory)
    let bundledCoreRoot = try canonicalExistingDirectory(trustedPaths.bundledCoreRoot)
    let runtimeRoot = try canonicalExistingDirectory(trustedPaths.runtimeRoot)

    guard isInside(core, root: bundledCoreRoot) else {
      throw ValidationError.pathEscapesAllowedRoots(coreURL.path)
    }
    guard Self.approvedBundledCoreNames.contains(core.lastPathComponent) else {
      throw ValidationError.untrustedCoreExecutableName(core.lastPathComponent)
    }
    guard isInside(config, root: runtimeRoot) else {
      throw ValidationError.pathEscapesAllowedRoots(configURL.path)
    }
    guard workDirectory.path == runtimeRoot.path else {
      throw ValidationError.unexpectedWorkDirectory(workDirectory.path)
    }

    return HelperValidatedTunnelPaths(coreURL: core, configURL: config, workDirectory: workDirectory)
  }

  private func isInside(_ candidate: URL, root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }

  private func canonicalExistingFile(_ url: URL, requireExecutable: Bool) throws -> URL {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
      throw ValidationError.missingFile(url.path)
    }
    if requireExecutable, !fileManager.isExecutableFile(atPath: resolved.path) {
      throw ValidationError.notExecutable(url.path)
    }
    return resolved
  }

  private func canonicalExistingDirectory(_ url: URL) throws -> URL {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ValidationError.missingDirectory(url.path)
    }
    return resolved
  }
}

struct HelperCodeSignatureInfo: Equatable {
  let bundleIdentifier: String?
  let teamIdentifier: String?
}

enum HelperBuildConfiguration {
  #if DEBUG
    static let allowsLocalDevelopmentSignatureFallback = true
  #else
    static let allowsLocalDevelopmentSignatureFallback = false
  #endif
}

struct HelperCodeSignaturePolicy {
  let expectedClientBundleIdentifier: String
  let helperBundleIdentifier: String
  let trustedTeamIdentifier: String?
  let allowsLocalDevelopmentFallback: Bool
  let localDevelopmentClientIdentifiers: Set<String>

  init(
    expectedClientBundleIdentifier: String = clashMaxAppBundleIdentifier,
    helperBundleIdentifier: String = clashMaxHelperBundleIdentifier,
    trustedTeamIdentifier: String?,
    allowsLocalDevelopmentFallback: Bool = HelperBuildConfiguration.allowsLocalDevelopmentSignatureFallback,
    localDevelopmentClientIdentifiers: Set<String> = ["ClashMax"]
  ) {
    self.expectedClientBundleIdentifier = expectedClientBundleIdentifier
    self.helperBundleIdentifier = helperBundleIdentifier
    self.trustedTeamIdentifier = trustedTeamIdentifier
    self.allowsLocalDevelopmentFallback = allowsLocalDevelopmentFallback
    self.localDevelopmentClientIdentifiers = localDevelopmentClientIdentifiers
  }

  static func live() -> HelperCodeSignaturePolicy {
    HelperCodeSignaturePolicy(
      trustedTeamIdentifier: try? HelperCodeSignatureReader.currentTeamIdentifier()
    )
  }

  var clientCodeSigningRequirement: String? {
    if let trustedTeamIdentifier {
      return #"identifier "\#(Self.requirementLiteral(expectedClientBundleIdentifier))" and anchor apple generic and certificate leaf[subject.OU] = "\#(Self.requirementLiteral(trustedTeamIdentifier))""#
    }

    guard allowsLocalDevelopmentFallback else {
      return nil
    }

    return localDevelopmentAllowedClientIdentifiers
      .sorted()
      .map { #"identifier "\#(Self.requirementLiteral($0))""# }
      .joined(separator: " or ")
  }

  var coreCodeSigningRequirement: String? {
    guard let trustedTeamIdentifier else {
      return nil
    }
    return #"anchor apple generic and certificate leaf[subject.OU] = "\#(Self.requirementLiteral(trustedTeamIdentifier))""#
  }

  func allowsClient(_ info: HelperCodeSignatureInfo) -> Bool {
    guard let bundleIdentifier = info.bundleIdentifier else {
      return false
    }
    guard let trustedTeamIdentifier else {
      return allowsLocalDevelopmentFallback && localDevelopmentAllowedClientIdentifiers.contains(bundleIdentifier)
    }
    return bundleIdentifier == expectedClientBundleIdentifier && info.teamIdentifier == trustedTeamIdentifier
  }

  func allowsCore(_ info: HelperCodeSignatureInfo) -> Bool {
    guard let trustedTeamIdentifier else {
      return allowsLocalDevelopmentFallback
    }
    return info.teamIdentifier == trustedTeamIdentifier
  }

  private static func requirementLiteral(_ value: String) -> String {
    value
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }

  private var localDevelopmentAllowedClientIdentifiers: Set<String> {
    var identifiers = localDevelopmentClientIdentifiers
    identifiers.insert(expectedClientBundleIdentifier)
    return identifiers
  }
}

enum HelperCodeSignatureError: Error, CustomStringConvertible {
  case securityFrameworkFailure(operation: String, status: OSStatus)
  case untrustedClientSignature(String)
  case untrustedCoreSignature(String)

  var description: String {
    switch self {
    case let .securityFrameworkFailure(operation, status):
      let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
      return "Code signature \(operation) failed: \(message)"
    case let .untrustedClientSignature(identifier):
      return "Rejected untrusted ClashMax client signature: \(identifier)"
    case let .untrustedCoreSignature(path):
      return "Rejected untrusted Mihomo core signature: \(path)"
    }
  }
}

enum HelperCodeSignatureReader {
  static func currentTeamIdentifier() throws -> String? {
    var code: SecCode?
    let copyStatus = SecCodeCopySelf(SecCSFlags(), &code)
    guard copyStatus == errSecSuccess, let code else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "copy self", status: copyStatus)
    }

    let info = try info(from: code, requirementString: nil)
    return info.teamIdentifier
  }

  static func info(forProcessIdentifier processIdentifier: pid_t, requirementString: String?) throws -> HelperCodeSignatureInfo {
    var code: SecCode?
    let attributes = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)] as CFDictionary
    let copyStatus = SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code)
    guard copyStatus == errSecSuccess, let code else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "copy guest", status: copyStatus)
    }

    return try info(from: code, requirementString: requirementString)
  }

  static func info(forStaticCodeAt url: URL, requirementString: String?) throws -> HelperCodeSignatureInfo {
    var staticCode: SecStaticCode?
    let createStatus = SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode)
    guard createStatus == errSecSuccess, let staticCode else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "create static code", status: createStatus)
    }

    if let requirementString {
      try checkStaticCode(staticCode, requirementString: requirementString)
    }

    return try signingInfo(from: staticCode)
  }

  private static func info(from code: SecCode, requirementString: String?) throws -> HelperCodeSignatureInfo {
    if let requirementString {
      try checkDynamicCode(code, requirementString: requirementString)
    }

    var staticCode: SecStaticCode?
    let copyStatus = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
    guard copyStatus == errSecSuccess, let staticCode else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "copy static code", status: copyStatus)
    }
    return try signingInfo(from: staticCode)
  }

  private static func signingInfo(from staticCode: SecStaticCode) throws -> HelperCodeSignatureInfo {
    var information: CFDictionary?
    let infoStatus = SecCodeCopySigningInformation(
      staticCode,
      SecCSFlags(rawValue: kSecCSSigningInformation),
      &information
    )
    guard infoStatus == errSecSuccess, let dictionary = information as? [String: Any] else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "copy signing info", status: infoStatus)
    }

    return HelperCodeSignatureInfo(
      bundleIdentifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
      teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    )
  }

  private static func checkDynamicCode(_ code: SecCode, requirementString: String) throws {
    let requirement = try requirement(from: requirementString)
    let status = SecCodeCheckValidity(code, SecCSFlags(), requirement)
    guard status == errSecSuccess else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "check dynamic validity", status: status)
    }
  }

  private static func checkStaticCode(_ staticCode: SecStaticCode, requirementString: String) throws {
    let requirement = try requirement(from: requirementString)
    let status = SecStaticCodeCheckValidity(staticCode, SecCSFlags(), requirement)
    guard status == errSecSuccess else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "check static validity", status: status)
    }
  }

  private static func requirement(from requirementString: String) throws -> SecRequirement {
    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString(requirementString as CFString, SecCSFlags(), &requirement)
    guard status == errSecSuccess, let requirement else {
      throw HelperCodeSignatureError.securityFrameworkFailure(operation: "create requirement", status: status)
    }
    return requirement
  }
}

protocol HelperCoreExecutableValidating {
  func validateCoreExecutable(at url: URL) throws
}

struct CodeSignatureCoreExecutableValidator: HelperCoreExecutableValidating {
  private let policy: HelperCodeSignaturePolicy

  init(policy: HelperCodeSignaturePolicy = .live()) {
    self.policy = policy
  }

  func validateCoreExecutable(at url: URL) throws {
    let info = try HelperCodeSignatureReader.info(
      forStaticCodeAt: url,
      requirementString: policy.coreCodeSigningRequirement
    )
    guard policy.allowsCore(info) else {
      throw HelperCodeSignatureError.untrustedCoreSignature(url.path)
    }
  }
}

enum HelperRuntimeError: Error, CustomStringConvertible {
  case alreadyRunning(pid: pid_t)
  case stopTimedOut(pid: pid_t, waited: TimeInterval)

  var description: String {
    switch self {
    case let .alreadyRunning(pid):
      return "Mihomo is already running with pid \(pid). Stop the tunnel or call restartTunnel before starting with new parameters."
    case let .stopTimedOut(pid, waited):
      return "Mihomo pid \(pid) is still running \(String(format: "%.1f", waited))s after SIGTERM and SIGKILL; it is probably still tearing down TUN. Wait a moment and stop again."
    }
  }
}

/// The loopback ports the helper's Mihomo listens on, read from the runtime config it was
/// launched with. The helper has no YAML parser and needs none: ClashMax generates that file
/// itself with these keys at the root, one per line, and only these two matter for the stop
/// hand-off (issue #33). Anything it cannot read yields no port, never a wrong one.
enum HelperRuntimeListenerPorts {
  static func parse(configText: String) -> [Int] {
    var ports: [Int] = []
    for rawLine in configText.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
      guard let first = rawLine.first, !first.isWhitespace, first != "#" else { continue }
      guard let colon = rawLine.firstIndex(of: ":") else { continue }
      let key = rawLine[..<colon].trimmingCharacters(in: .whitespaces)
      let value = rawLine[rawLine.index(after: colon)...]
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      switch key {
      case "mixed-port":
        if let port = Int(value) {
          ports.append(port)
        }
      case "external-controller":
        if let lastColon = value.lastIndex(of: ":"),
           let port = Int(value[value.index(after: lastColon)...])
        {
          ports.append(port)
        }
      default:
        continue
      }
    }
    return Array(Set(ports.filter { (1...65_535).contains($0) })).sorted()
  }

  static func parse(configURL: URL) -> [Int] {
    guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return [] }
    return parse(configText: text)
  }
}

/// A single loopback connect, for the helper to confirm its Mihomo's ports really closed before
/// it tells the app "stopped". Any user can make this call; it needs no privilege. Non-blocking
/// with a real deadline: SO_RCVTIMEO does not bound `connect(2)` on Darwin, and this runs inside
/// the root helper, where nothing may hang on a socket.
enum HelperLoopbackPortProbe {
  static func isAccepting(port: Int, timeout: TimeInterval) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }

    var noSigPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(clamping: port)).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if result == 0 {
      return true
    }
    guard errno == EINPROGRESS else { return false }

    var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&descriptors, 1, Int32(max(1, timeout * 1000)))
    guard ready > 0 else { return false }
    var socketError: Int32 = 0
    var length = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return false }
    return socketError == 0
  }
}

// Thread-safety: XPC methods may be invoked from arbitrary threads; process state is guarded by
// stateLock and the log buffer by logLock. start/stop/restart additionally serialize on
// lifecycleLock for their whole duration (a stop can legitimately wait several seconds for a
// Mihomo tearing down TUN), while stateLock is only ever held for a moment, so a status() call
// arriving mid-stop answers immediately instead of queueing behind the wait.
final class HelperService: NSObject, ClashMaxHelperXPCProtocol, @unchecked Sendable {
  // Guard every read/write of process with stateLock via withStateLock or *Locked helpers.
  private var process: Process?
  /// Loopback ports the tracked process was launched to listen on; see `HelperRuntimeListenerPorts`.
  private var trackedListenerPorts: [Int] = []
  private var logs = BoundedBuffer<String>(limit: 200)
  private let stateLock = NSLock()
  /// Lock order: lifecycleLock before stateLock, never the reverse.
  private let lifecycleLock = NSLock()
  private let logLock = NSLock()
  private let trustedPathsProvider: (uid_t) throws -> HelperTrustedPaths
  private let coreExecutableValidator: any HelperCoreExecutableValidating
  private let clientUserIDProvider: () throws -> uid_t
  /// How long SIGTERM gets before SIGKILL.
  private let processTerminationTimeout: TimeInterval
  /// How long SIGKILL gets before the stop is reported as failed. A root Mihomo tearing down TUN
  /// (utun close, route and DNS restore) can outlive the old 1s, and reporting "stopped" while it
  /// still held 9097 is what broke the TUN -> NE Proxy switch (issue #33).
  private let processKillTimeout: TimeInterval
  /// How long, after the process is gone, to wait for its ports to stop accepting connections.
  private let portReleaseTimeout: TimeInterval
  private let processDidLaunch: ((Process) -> Void)?
  private let portProbe: (Int) -> Bool
  /// `kill(2)` for the SIGKILL escalation; tests substitute a sender that delays or withholds it.
  private let killSignalSender: (pid_t, Int32) -> Int32

  init(
    trustedPathsProvider: @escaping (uid_t) throws -> HelperTrustedPaths = { userID in
      try HelperTrustedPaths.live(clientUserID: userID, bundledCoreRoot: HelperBundleLocator.bundledCoreRoot())
    },
    coreExecutableValidator: any HelperCoreExecutableValidating = CodeSignatureCoreExecutableValidator(),
    clientUserIDProvider: @escaping () throws -> uid_t = {
      guard let connection = NSXPCConnection.current() else {
        throw HelperCodeSignatureError.untrustedClientSignature("<missing XPC connection>")
      }
      return connection.effectiveUserIdentifier
    },
    processTerminationTimeout: TimeInterval = 2,
    processKillTimeout: TimeInterval = 3,
    portReleaseTimeout: TimeInterval = 2,
    processDidLaunch: ((Process) -> Void)? = nil,
    portProbe: @escaping (Int) -> Bool = { HelperLoopbackPortProbe.isAccepting(port: $0, timeout: 0.2) },
    killSignalSender: @escaping (pid_t, Int32) -> Int32 = { kill($0, $1) }
  ) {
    self.trustedPathsProvider = trustedPathsProvider
    self.coreExecutableValidator = coreExecutableValidator
    self.clientUserIDProvider = clientUserIDProvider
    self.processTerminationTimeout = processTerminationTimeout
    self.processKillTimeout = processKillTimeout
    self.portReleaseTimeout = portReleaseTimeout
    self.processDidLaunch = processDidLaunch
    self.portProbe = portProbe
    self.killSignalSender = killSignalSender
  }

  func status(withReply reply: @escaping (NSString) -> Void) {
    let status = withStateLock { () -> (running: Bool, pid: Int) in
      let existingProcess = process
      let running = existingProcess?.isRunning ?? false
      let pid = running ? Int(existingProcess?.processIdentifier ?? 0) : 0
      if !running {
        if let existingProcess {
          HelperProcessOutputHandlers.clear(for: existingProcess)
        }
        process = nil
        trackedListenerPorts = []
      }
      return (running, pid)
    }

    reply(HelperXPCPayload.response(ok: true, running: status.running, pid: status.pid))
  }

  func startTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  ) {
    do {
      let launchedProcess = try start(
        corePath: corePath as String,
        configPath: configPath as String,
        workDirectoryPath: workDirectoryPath as String,
        secret: secret as String
      )
      reply(HelperXPCPayload.response(
        ok: true,
        running: true,
        pid: Int(launchedProcess.processIdentifier)
      ))
    } catch {
      reply(response(for: error))
    }
  }

  func stopTunnel(withReply reply: @escaping (NSString) -> Void) {
    let outcome = withLifecycleLock {
      stopTrackedProcess()
    }

    switch outcome {
    case .stopped:
      reply(HelperXPCPayload.response(ok: true, running: false))
    case let .stillRunning(pid, waited):
      // Keep tracking it: the next stop, status or restart must see this process, not a
      // fresh slate that lets a new Mihomo collide with the one still shutting down.
      reply(HelperXPCPayload.response(
        ok: false,
        running: true,
        pid: Int(pid),
        code: HelperResponseCode.stopTimedOut,
        message: String(describing: HelperRuntimeError.stopTimedOut(pid: pid, waited: waited))
      ))
    }
  }

  func restartTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  ) {
    do {
      let launchedProcess = try restart(
        corePath: corePath as String,
        configPath: configPath as String,
        workDirectoryPath: workDirectoryPath as String,
        secret: secret as String
      )
      reply(HelperXPCPayload.response(
        ok: true,
        running: true,
        pid: Int(launchedProcess.processIdentifier)
      ))
    } catch {
      reply(response(for: error))
    }
  }

  func recentLogs(withReply reply: @escaping (NSString) -> Void) {
    logLock.lock()
    let snapshot = logs.elements
    logLock.unlock()
    reply(HelperXPCPayload.logs(snapshot))
  }

  private func start(corePath: String, configPath: String, workDirectoryPath: String, secret: String) throws -> Process {
    let launchedProcess = try withLifecycleLock {
      try rejectAlreadyRunningProcess()
      let paths = try validatedPaths(corePath: corePath, configPath: configPath, workDirectoryPath: workDirectoryPath)

      return try withStateLock {
        try rejectAlreadyRunningProcessLocked()
        return try launchProcessLocked(paths: paths, secret: secret)
      }
    }
    processDidLaunch?(launchedProcess)
    return launchedProcess
  }

  private func restart(corePath: String, configPath: String, workDirectoryPath: String, secret: String) throws -> Process {
    let launchedProcess = try withLifecycleLock {
      if case let .stillRunning(pid, waited) = stopTrackedProcess() {
        throw HelperRuntimeError.stopTimedOut(pid: pid, waited: waited)
      }
      let paths = try validatedPaths(corePath: corePath, configPath: configPath, workDirectoryPath: workDirectoryPath)
      return try withStateLock {
        try launchProcessLocked(paths: paths, secret: secret)
      }
    }
    processDidLaunch?(launchedProcess)
    return launchedProcess
  }

  private func rejectAlreadyRunningProcess() throws {
    try withStateLock {
      try rejectAlreadyRunningProcessLocked()
    }
  }

  private func rejectAlreadyRunningProcessLocked() throws {
    guard let existingProcess = process else { return }
    if existingProcess.isRunning {
      throw HelperRuntimeError.alreadyRunning(pid: existingProcess.processIdentifier)
    }
    HelperProcessOutputHandlers.clear(for: existingProcess)
    process = nil
    trackedListenerPorts = []
  }

  private func validatedPaths(corePath: String, configPath: String, workDirectoryPath: String) throws -> HelperValidatedTunnelPaths {
    let clientUserID = try clientUserIDProvider()
    let trustedPaths = try trustedPathsProvider(clientUserID)
    let validator = HelperPathValidator(trustedPaths: trustedPaths)
    let paths = try validator.validatedPaths(
      coreURL: URL(fileURLWithPath: corePath),
      configURL: URL(fileURLWithPath: configPath),
      workDirectory: URL(fileURLWithPath: workDirectoryPath)
    )
    try coreExecutableValidator.validateCoreExecutable(at: paths.coreURL)
    return paths
  }

  private func launchProcessLocked(paths: HelperValidatedTunnelPaths, secret _: String) throws -> Process {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = paths.coreURL
    process.arguments = ["-f", paths.configURL.path, "-d", paths.workDirectory.path]
    process.currentDirectoryURL = paths.workDirectory
    process.environment = ProcessInfo.processInfo.environment.merging([
      "SAFE_PATHS": paths.workDirectory.path,
      "CLASHMAX_HELPER": "1",
    ]) { _, new in new }
    process.standardOutput = pipe
    process.standardError = pipe
    process.terminationHandler = { [weak self] process in
      self?.appendLog("mihomo exited with code \(process.terminationStatus)")
    }
    HelperProcessOutputHandlers.install(on: pipe) { [weak self] text in
      self?.appendLog(text)
    }

    do {
      try process.run()
    } catch {
      HelperProcessOutputHandlers.clear(for: process)
      throw error
    }
    self.process = process
    trackedListenerPorts = HelperRuntimeListenerPorts.parse(configURL: paths.configURL)
    return process
  }

  private enum StopOutcome {
    case stopped
    case stillRunning(pid: pid_t, waited: TimeInterval)
  }

  /// Caller holds lifecycleLock. stateLock is taken only to read and to clear the tracked process,
  /// never across the waits, so `status()` stays answerable while a stop is in progress.
  @discardableResult
  private func stopTrackedProcess() -> StopOutcome {
    let tracked = withStateLock { (process: process, ports: trackedListenerPorts) }
    guard let existingProcess = tracked.process else { return .stopped }
    if existingProcess.isRunning {
      let started = Date()
      guard terminateAndWait(existingProcess) else {
        let waited = Date().timeIntervalSince(started)
        appendLog("mihomo pid \(existingProcess.processIdentifier) still running \(String(format: "%.1f", waited))s after SIGTERM and SIGKILL; stop not confirmed")
        return .stillRunning(pid: existingProcess.processIdentifier, waited: waited)
      }
      waitForListenerPortsToRelease(tracked.ports)
    }
    withStateLock {
      HelperProcessOutputHandlers.clear(for: existingProcess)
      // A concurrent status() may already have cleared it; only clear what is still ours.
      if process === existingProcess {
        process = nil
        trackedListenerPorts = []
      }
    }
    return .stopped
  }

  /// SIGTERM, then SIGKILL, then keep waiting until the process is really gone or the kill budget
  /// runs out. Returns false when it is still alive: the caller must keep tracking it.
  private func terminateAndWait(_ process: Process) -> Bool {
    process.terminate()
    waitForProcessExit(process, timeout: processTerminationTimeout)

    guard process.isRunning else { return true }
    _ = killSignalSender(process.processIdentifier, SIGKILL)
    waitForProcessExit(process, timeout: processKillTimeout)
    return !process.isRunning
  }

  private func waitForProcessExit(_ process: Process, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
      Thread.sleep(forTimeInterval: 0.02)
    }
  }

  /// The process has exited; its listening sockets close with it, but "stopped" must mean the
  /// app can bind the same ports now, so confirm that rather than assume it. Bounded: a port
  /// that stays busy is logged, not fatal — it may belong to something else entirely.
  private func waitForListenerPortsToRelease(_ ports: [Int]) {
    guard !ports.isEmpty else { return }
    let deadline = Date().addingTimeInterval(portReleaseTimeout)
    while true {
      let busy = ports.filter(portProbe)
      if busy.isEmpty { return }
      guard Date() < deadline else {
        appendLog("port \(busy.map(String.init).joined(separator: ",")) still accepts connections \(String(format: "%.1f", portReleaseTimeout))s after mihomo exited")
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  private func response(for error: Error) -> NSString {
    if case let HelperRuntimeError.alreadyRunning(pid) = error {
      return HelperXPCPayload.response(
        ok: false,
        running: true,
        pid: Int(pid),
        code: HelperResponseCode.alreadyRunning,
        message: String(describing: error)
      )
    }
    if case let HelperRuntimeError.stopTimedOut(pid, _) = error {
      return HelperXPCPayload.response(
        ok: false,
        running: true,
        pid: Int(pid),
        code: HelperResponseCode.stopTimedOut,
        message: String(describing: error)
      )
    }

    return HelperXPCPayload.response(
      ok: false,
      code: responseCode(for: error),
      message: String(describing: error)
    )
  }

  private func responseCode(for error: Error) -> String {
    switch error {
    case is HelperPathValidator.ValidationError:
      return HelperResponseCode.invalidPath
    case is HelperCodeSignatureError:
      return HelperResponseCode.untrustedSignature
    default:
      return HelperResponseCode.launchFailed
    }
  }

  private func appendLog(_ line: String) {
    logLock.lock()
    logs.append(line)
    logLock.unlock()
  }

  private func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
    stateLock.lock()
    defer { stateLock.unlock() }
    return try body()
  }

  private func withLifecycleLock<T>(_ body: () throws -> T) rethrows -> T {
    lifecycleLock.lock()
    defer { lifecycleLock.unlock() }
    return try body()
  }
}

enum HelperProcessOutputHandlers {
  static func install(on pipe: Pipe, appendLog: @escaping @Sendable (String) -> Void) {
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      guard let text = String(data: data, encoding: .utf8) else {
        return
      }
      appendLog(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  static func clear(for process: Process) {
    var clearedHandles = Set<ObjectIdentifier>()
    clearHandler(for: process.standardOutput, clearedHandles: &clearedHandles)
    clearHandler(for: process.standardError, clearedHandles: &clearedHandles)
    process.terminationHandler = nil
  }

  private static func clearHandler(for stream: Any?, clearedHandles: inout Set<ObjectIdentifier>) {
    if let pipe = stream as? Pipe {
      clearHandler(for: pipe.fileHandleForReading, clearedHandles: &clearedHandles)
    } else if let handle = stream as? FileHandle {
      clearHandler(for: handle, clearedHandles: &clearedHandles)
    }
  }

  private static func clearHandler(for handle: FileHandle, clearedHandles: inout Set<ObjectIdentifier>) {
    let identifier = ObjectIdentifier(handle)
    guard clearedHandles.insert(identifier).inserted else {
      return
    }
    handle.readabilityHandler = nil
  }
}
