import Foundation
import XCTest
@testable import ClashMax

@MainActor
func XCTAssertThrowsErrorAsync<T>(
  _ expression: () async throws -> T,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail(message(), file: file, line: line)
  } catch {}
}

@MainActor
func XCTAssertThrowsCancellationErrorAsync<T>(
  _ expression: () async throws -> T,
  _ message: @autoclosure () -> String = "",
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail(message(), file: file, line: line)
  } catch is CancellationError {
  } catch {
    XCTFail("Expected CancellationError, got \(error)", file: file, line: line)
  }
}

final class URLProtocolRecorder: @unchecked Sendable {
  nonisolated(unsafe) private static var active: URLProtocolRecorder?
  private let lock = NSLock()
  private var recordedRequest: URLRequest?
  private var recordedBody: Data?
  private let responseBody: String
  private let responseDelay: TimeInterval

  init(responseBody: String = #"{"delay":42}"#, responseDelay: TimeInterval = 0) {
    self.responseBody = responseBody
    self.responseDelay = responseDelay
  }

  var configuration: URLSessionConfiguration {
    Self.active = self
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RecordingURLProtocol.self]
    return configuration
  }

  static func configurationReturning(_ body: String) -> URLSessionConfiguration {
    let recorder = URLProtocolRecorder(responseBody: body)
    return recorder.configuration
  }

  var lastRequest: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequest
  }

  var lastBody: Data? {
    lock.lock()
    defer { lock.unlock() }
    return recordedBody
  }

  fileprivate func record(_ request: URLRequest, body: Data?) {
    lock.lock()
    recordedRequest = request
    recordedBody = body
    lock.unlock()
  }

  fileprivate static func current() -> URLProtocolRecorder? {
    active
  }

  fileprivate func responseData() -> Data {
    responseBody.data(using: .utf8)!
  }

  fileprivate func delayResponseIfNeeded() {
    if responseDelay > 0 {
      Thread.sleep(forTimeInterval: responseDelay)
    }
  }
}

final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let request = request
    let body = request.httpBody ?? Self.readBodyStream(request.httpBodyStream)

    URLProtocolRecorder.current()?.record(request, body: body)
    URLProtocolRecorder.current()?.delayResponseIfNeeded()
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: URLProtocolRecorder.current()?.responseData() ?? Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func readBodyStream(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
      let count = stream.read(buffer, maxLength: 4096)
      if count <= 0 { break }
      data.append(buffer, count: count)
    }

    return data
  }
}

@MainActor
final class FakeProcessLauncher: CoreProcessLaunching {
  let process = FakeRunningProcess()
  private(set) var lastArguments: [String] = []

  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    lastArguments = arguments
    return process
  }
}

@MainActor
final class FakeRunningProcess: RunningCoreProcess {
  let processIdentifier: Int32
  var onTermination: ((Int32) -> Void)?
  private(set) var didTerminate = false
  var stubbedOutputTail = ""

  init(processIdentifier: Int32 = 42) {
    self.processIdentifier = processIdentifier
  }

  func terminate() {
    didTerminate = true
  }

  func finish(exitCode: Int32) {
    onTermination?(exitCode)
  }

  func recentOutputTail(maxBytes: Int) -> String {
    stubbedOutputTail
  }
}

final class RecordingCommandRunner: CommandRunning, @unchecked Sendable {
  let outputs: [String: String]
  private let queue = DispatchQueue(label: "io.github.clashmax.tests.RecordingCommandRunner")
  private var _commands: [String] = []

  init(outputs: [String: String]) {
    self.outputs = outputs
  }

  var commands: [String] {
    queue.sync { _commands }
  }

  func run(_ executable: String, _ arguments: [String]) async throws -> String {
    let command = ([executable] + arguments).joined(separator: " ")
    queue.sync {
      _commands.append(command)
    }
    return outputs[command] ?? ""
  }
}
