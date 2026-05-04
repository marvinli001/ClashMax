import Foundation

let service = HelperService()
let delegate = HelperListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: clashMaxHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
  let service: HelperService

  init(service: HelperService) {
    self.service = service
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    newConnection.exportedInterface = NSXPCInterface(with: ClashMaxHelperXPCProtocol.self)
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

final class HelperService: NSObject, ClashMaxHelperXPCProtocol, @unchecked Sendable {
  private var process: Process?
  private var logs = BoundedBuffer<String>(limit: 200)
  private let lock = NSLock()

  func status(withReply reply: @escaping (NSDictionary) -> Void) {
    reply([
      HelperResponseKey.ok: true,
      HelperResponseKey.running: process?.isRunning ?? false,
      HelperResponseKey.pid: process?.processIdentifier ?? 0
    ])
  }

  func startTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSDictionary) -> Void
  ) {
    do {
      try start(corePath: corePath as String, configPath: configPath as String, workDirectoryPath: workDirectoryPath as String, secret: secret as String)
      reply([
        HelperResponseKey.ok: true,
        HelperResponseKey.running: true,
        HelperResponseKey.pid: process?.processIdentifier ?? 0
      ])
    } catch {
      reply([
        HelperResponseKey.ok: false,
        HelperResponseKey.message: String(describing: error)
      ])
    }
  }

  func stopTunnel(withReply reply: @escaping (NSDictionary) -> Void) {
    process?.terminate()
    process = nil
    reply([HelperResponseKey.ok: true, HelperResponseKey.running: false])
  }

  func restartTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSDictionary) -> Void
  ) {
    process?.terminate()
    process = nil
    startTunnel(corePath: corePath, configPath: configPath, workDirectoryPath: workDirectoryPath, secret: secret, withReply: reply)
  }

  func recentLogs(withReply reply: @escaping (NSArray) -> Void) {
    lock.lock()
    let snapshot = logs.elements
    lock.unlock()
    reply(snapshot as NSArray)
  }

  private func start(corePath: String, configPath: String, workDirectoryPath: String, secret: String) throws {
    let appSupportRoot = URL(fileURLWithPath: workDirectoryPath)
      .deletingLastPathComponent()
      .standardizedFileURL
    let validator = HelperPathValidator(
      appSupportRoot: appSupportRoot,
      bundledCoreRoot: bundledCoreRoot()
    )
    try validator.validate(
      coreURL: URL(fileURLWithPath: corePath),
      configURL: URL(fileURLWithPath: configPath),
      workDirectory: URL(fileURLWithPath: workDirectoryPath)
    )

    if process?.isRunning == true { return }

    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: corePath)
    process.arguments = ["-f", configPath, "-d", workDirectoryPath]
    process.currentDirectoryURL = URL(fileURLWithPath: workDirectoryPath)
    process.environment = ProcessInfo.processInfo.environment.merging([
      "SAFE_PATHS": workDirectoryPath,
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

  private func bundledCoreRoot() -> URL {
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    return executable
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("Resources/Core", isDirectory: true)
  }
}
