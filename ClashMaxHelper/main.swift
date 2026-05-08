import Foundation

let service = HelperService()
let delegate = HelperListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: clashMaxHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
  let service: HelperService
  private let connectionAuthorizer: any HelperConnectionAuthorizing

  init(
    service: HelperService,
    connectionAuthorizer: any HelperConnectionAuthorizing = CodeSignatureConnectionAuthorizer()
  ) {
    self.service = service
    self.connectionAuthorizer = connectionAuthorizer
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    guard connectionAuthorizer.isAuthorized(newConnection) else {
      return false
    }

    newConnection.exportedInterface = ClashMaxHelperXPCInterface.make()
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

protocol HelperConnectionAuthorizing {
  func isAuthorized(_ connection: NSXPCConnection) -> Bool
}

final class CodeSignatureConnectionAuthorizer: HelperConnectionAuthorizing {
  private let policy: HelperCodeSignaturePolicy

  init(policy: HelperCodeSignaturePolicy = .live()) {
    self.policy = policy
  }

  func isAuthorized(_ connection: NSXPCConnection) -> Bool {
    do {
      let requirement = policy.clientCodeSigningRequirement
      if let requirement {
        connection.setCodeSigningRequirement(requirement)
      }

      let info = try HelperCodeSignatureReader.info(
        forProcessIdentifier: connection.processIdentifier,
        requirementString: requirement
      )
      guard policy.allowsClient(info) else {
        throw HelperCodeSignatureError.untrustedClientSignature(info.bundleIdentifier ?? "<unsigned>")
      }
      return true
    } catch {
      return false
    }
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

final class HelperService: NSObject, ClashMaxHelperXPCProtocol, @unchecked Sendable {
  private var process: Process?
  private var logs = BoundedBuffer<String>(limit: 200)
  private let lock = NSLock()
  private let trustedPathsProvider: (uid_t) throws -> HelperTrustedPaths
  private let coreExecutableValidator: any HelperCoreExecutableValidating

  init(
    trustedPathsProvider: @escaping (uid_t) throws -> HelperTrustedPaths = { userID in
      try HelperTrustedPaths.live(clientUserID: userID, bundledCoreRoot: HelperBundleLocator.bundledCoreRoot())
    },
    coreExecutableValidator: any HelperCoreExecutableValidating = CodeSignatureCoreExecutableValidator()
  ) {
    self.trustedPathsProvider = trustedPathsProvider
    self.coreExecutableValidator = coreExecutableValidator
  }

  func status(withReply reply: @escaping (NSString) -> Void) {
    reply(HelperXPCPayload.response(
      ok: true,
      running: process?.isRunning ?? false,
      pid: Int(process?.processIdentifier ?? 0)
    ))
  }

  func startTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  ) {
    do {
      try start(corePath: corePath as String, configPath: configPath as String, workDirectoryPath: workDirectoryPath as String, secret: secret as String)
      reply(HelperXPCPayload.response(
        ok: true,
        running: true,
        pid: Int(process?.processIdentifier ?? 0)
      ))
    } catch {
      reply(HelperXPCPayload.response(ok: false, message: String(describing: error)))
    }
  }

  func stopTunnel(withReply reply: @escaping (NSString) -> Void) {
    process?.terminate()
    process = nil
    reply(HelperXPCPayload.response(ok: true, running: false))
  }

  func restartTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  ) {
    process?.terminate()
    process = nil
    startTunnel(corePath: corePath, configPath: configPath, workDirectoryPath: workDirectoryPath, secret: secret, withReply: reply)
  }

  func recentLogs(withReply reply: @escaping (NSString) -> Void) {
    lock.lock()
    let snapshot = logs.elements
    lock.unlock()
    reply(HelperXPCPayload.logs(snapshot))
  }

  private func start(corePath: String, configPath: String, workDirectoryPath: String, secret: String) throws {
    guard let connection = NSXPCConnection.current() else {
      throw HelperCodeSignatureError.untrustedClientSignature("<missing XPC connection>")
    }

    let trustedPaths = try trustedPathsProvider(connection.effectiveUserIdentifier)
    let validator = HelperPathValidator(trustedPaths: trustedPaths)
    let paths = try validator.validatedPaths(
      coreURL: URL(fileURLWithPath: corePath),
      configURL: URL(fileURLWithPath: configPath),
      workDirectory: URL(fileURLWithPath: workDirectoryPath)
    )
    try coreExecutableValidator.validateCoreExecutable(at: paths.coreURL)

    if process?.isRunning == true { return }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = paths.coreURL
    process.arguments = ["-f", paths.configURL.path, "-d", paths.workDirectory.path]
    process.currentDirectoryURL = paths.workDirectory
    process.environment = ProcessInfo.processInfo.environment.merging([
      "SAFE_PATHS": paths.workDirectory.path,
      "CLASHMAX_HELPER": "1",
      "CLASHMAX_SECRET": secret
    ]) { _, new in new }
    process.standardOutput = pipe
    process.standardError = pipe
    process.terminationHandler = { [weak self] process in
      self?.appendLog("mihomo exited with code \(process.terminationStatus)")
    }

    pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
      self?.appendLog(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    try process.run()
    self.process = process
  }

  private func appendLog(_ line: String) {
    lock.lock()
    logs.append(line)
    lock.unlock()
  }
}
