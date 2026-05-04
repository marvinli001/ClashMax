import Foundation
import ServiceManagement

@MainActor
protocol HelperXPCTransport {
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
  private let transport: HelperXPCTransport

  init(transport: HelperXPCTransport = PrivilegedHelperXPCTransport()) {
    self.transport = transport
  }

  func register() throws {
    let service = SMAppService.daemon(plistName: "io.github.clashmax.ClashMax.Helper.plist")
    try service.register()
    statusMessage = "Registered. Approve ClashMax Helper in System Settings if macOS asks."
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
    connection.resume()
    defer { connection.invalidate() }

    return try await withCheckedThrowingContinuation { continuation in
      let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        continuation.resume(throwing: error)
      } as? ClashMaxHelperXPCProtocol

      guard let proxy else {
        continuation.resume(throwing: AppError.helperResponse("Unable to connect to ClashMax Helper."))
        return
      }
      body(proxy) { payload in
        continuation.resume(returning: HelperClientResponse(payload: payload))
      }
    }
  }

  private func callLogs(
    _ body: @escaping (ClashMaxHelperXPCProtocol, @escaping (NSString) -> Void) -> Void
  ) async throws -> [String] {
    let connection = NSXPCConnection(machServiceName: clashMaxHelperMachServiceName, options: .privileged)
    connection.remoteObjectInterface = ClashMaxHelperXPCInterface.make()
    connection.resume()
    defer { connection.invalidate() }

    return try await withCheckedThrowingContinuation { continuation in
      let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        continuation.resume(throwing: error)
      } as? ClashMaxHelperXPCProtocol

      guard let proxy else {
        continuation.resume(throwing: AppError.helperResponse("Unable to connect to ClashMax Helper."))
        return
      }
      body(proxy) { payload in
        continuation.resume(returning: HelperXPCPayload.logLines(from: payload))
      }
    }
  }
}
