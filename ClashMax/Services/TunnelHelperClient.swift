import Foundation
import ServiceManagement

protocol HelperXPCTransport: Sendable {
  func status() async throws -> HelperClientResponse
  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse
  func stopTunnel() async throws -> HelperClientResponse
  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse
  func recentLogs() async throws -> [String]
}

struct HelperClientResponse: Sendable {
  var ok: Bool
  var running: Bool
  var pid: Int
  var message: String

  init(payload: NSString) {
    let dictionary = HelperXPCPayload.responseDictionary(from: payload)
    ok = dictionary[HelperResponseKey.ok] as? Bool ?? false
    running = dictionary[HelperResponseKey.running] as? Bool ?? false
    pid = (dictionary[HelperResponseKey.pid] as? NSNumber)?.intValue
      ?? dictionary[HelperResponseKey.pid] as? Int
      ?? 0
    message = dictionary[HelperResponseKey.message] as? String ?? ""
  }

  static func failure(_ message: String) -> HelperClientResponse {
    HelperClientResponse(ok: false, running: false, pid: 0, message: message)
  }

  private init(ok: Bool, running: Bool, pid: Int, message: String) {
    self.ok = ok
    self.running = running
    self.pid = pid
    self.message = message
  }
}

@MainActor
final class TunnelHelperClient: ObservableObject {
  @Published var statusMessage: String = "Not registered"
  private let transport: any HelperXPCTransport
  private static var service: SMAppService {
    SMAppService.daemon(plistName: "io.github.clashmax.ClashMax.Helper.plist")
  }

  init(transport: any HelperXPCTransport = PrivilegedHelperXPCTransport()) {
    self.transport = transport
  }

  func register() throws {
    let service = Self.service
    switch service.status {
    case .enabled, .requiresApproval:
      statusMessage = Self.statusMessage(for: service.status)
      return
    case .notRegistered, .notFound:
      break
    @unknown default:
      break
    }
    try service.register()
    statusMessage = Self.statusMessage(for: service.status)
  }

  func refreshRegistrationStatus() {
    statusMessage = Self.statusMessage(for: Self.service.status)
  }

  static func statusMessage(for status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered:
      return "Helper not registered. Click Register or Start in TUN mode."
    case .enabled:
      return "Helper registered and enabled."
    case .requiresApproval:
      return "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions."
    case .notFound:
      return "Helper not found in the app bundle. Clean build and run ClashMax again."
    @unknown default:
      return "Helper status is unknown. Clean build and run ClashMax again."
    }
  }

  func status() async throws -> HelperClientResponse {
    try await transport.status()
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await transport.startTunnel(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, secret: secret)
  }

  func stopTunnel() async throws -> HelperClientResponse {
    try await transport.stopTunnel()
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await transport.restartTunnel(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, secret: secret)
  }

  func recentLogs() async throws -> [String] {
    try await transport.recentLogs()
  }
}

struct PrivilegedHelperXPCTransport: HelperXPCTransport {
  func status() async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.status(withReply: reply)
    }
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.startTunnel(
        corePath: coreURL.path as NSString,
        configPath: configURL.path as NSString,
        workDirectoryPath: workDirectory.path as NSString,
        secret: secret as NSString,
        withReply: reply
      )
    }
  }

  func stopTunnel() async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.stopTunnel(withReply: reply)
    }
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    try await callResponse { proxy, reply in
      proxy.restartTunnel(
        corePath: coreURL.path as NSString,
        configPath: configURL.path as NSString,
        workDirectoryPath: workDirectory.path as NSString,
        secret: secret as NSString,
        withReply: reply
      )
    }
  }

  func recentLogs() async throws -> [String] {
    try await callLogs { proxy, reply in
      proxy.recentLogs(withReply: reply)
    }
  }

  private func callResponse(
    _ body: @escaping (ClashMaxHelperXPCProtocol, @escaping (NSString) -> Void) -> Void
  ) async throws -> HelperClientResponse {
    let connection = NSXPCConnection(machServiceName: clashMaxHelperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = ClashMaxHelperXPCInterface.make()
    let box = ContinuationBox<HelperClientResponse>()

    connection.invalidationHandler = {
      box.fail(
        AppError.helperResponse("Helper connection invalidated. The privileged helper may not be installed or approved."),
        runCleanup: false
      )
    }
    connection.interruptionHandler = {
      box.fail(AppError.helperResponse("Helper connection interrupted."), runCleanup: false)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HelperClientResponse, Error>) in
        box.attach(continuation) {
          connection.invalidate()
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
          box.fail(error)
        } as? ClashMaxHelperXPCProtocol

        guard let proxy else {
          box.fail(AppError.helperResponse("Unable to connect to ClashMax Helper."))
          return
        }
        connection.resume()
        body(proxy) { payload in
          box.succeed(HelperClientResponse(payload: payload))
        }
      }
    } onCancel: {
      box.fail(CancellationError())
    }
  }

  private func callLogs(
    _ body: @escaping (ClashMaxHelperXPCProtocol, @escaping (NSString) -> Void) -> Void
  ) async throws -> [String] {
    let connection = NSXPCConnection(machServiceName: clashMaxHelperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = ClashMaxHelperXPCInterface.make()
    let box = ContinuationBox<[String]>()

    connection.invalidationHandler = {
      box.fail(
        AppError.helperResponse("Helper connection invalidated. The privileged helper may not be installed or approved."),
        runCleanup: false
      )
    }
    connection.interruptionHandler = {
      box.fail(AppError.helperResponse("Helper connection interrupted."), runCleanup: false)
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
        box.attach(continuation) {
          connection.invalidate()
        }

        let proxy = connection.remoteObjectProxyWithErrorHandler { error in
          box.fail(error)
        } as? ClashMaxHelperXPCProtocol

        guard let proxy else {
          box.fail(AppError.helperResponse("Unable to connect to ClashMax Helper."))
          return
        }
        connection.resume()
        body(proxy) { payload in
          box.succeed(HelperXPCPayload.logLines(from: payload))
        }
      }
    } onCancel: {
      box.fail(CancellationError())
    }
  }
}

private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var cleanup: (() -> Void)?
  private var settled = false

  func attach(_ continuation: CheckedContinuation<Value, Error>, cleanup: @escaping () -> Void) {
    lock.lock()
    if settled {
      lock.unlock()
      cleanup()
      return
    }
    self.continuation = continuation
    self.cleanup = cleanup
    lock.unlock()
  }

  func succeed(_ value: Value) {
    settle(.success(value), runCleanup: true)
  }

  func fail(_ error: Error, runCleanup: Bool = true) {
    settle(.failure(error), runCleanup: runCleanup)
  }

  private func settle(_ result: Result<Value, Error>, runCleanup: Bool) {
    lock.lock()
    guard !settled else { lock.unlock(); return }
    settled = true
    let continuation = self.continuation
    let cleanup = self.cleanup
    self.continuation = nil
    self.cleanup = nil
    lock.unlock()
    switch result {
    case let .success(value):
      continuation?.resume(returning: value)
    case let .failure(error):
      continuation?.resume(throwing: error)
    }
    if runCleanup {
      cleanup?()
    }
  }
}
