import Foundation
import XCTest
@testable import ClashMax

@MainActor
final class TunnelHelperClientTests: XCTestCase {
  func testRecentLogsAreMappedFromHelperResponse() async throws {
    let transport = FakeHelperTransport(response: ["one", "two"])
    let client = TunnelHelperClient(transport: transport)

    let logs = try await client.recentLogs()

    XCTAssertEqual(logs, ["one", "two"])
  }

  func testHelperStringPayloadsDecodeResponsesAndLogs() {
    let response = HelperClientResponse(payload: HelperXPCPayload.response(ok: true, running: true, pid: 42, message: "ready"))

    XCTAssertTrue(response.ok)
    XCTAssertTrue(response.running)
    XCTAssertEqual(response.pid, 42)
    XCTAssertEqual(response.message, "ready")
    XCTAssertEqual(HelperXPCPayload.logLines(from: HelperXPCPayload.logs(["one", "two"])), ["one", "two"])
  }

  func testHelperInterfaceUsesStringPayloadReplies() throws {
    let interface = ClashMaxHelperXPCInterface.make()
    let replySelectors = [
      #selector(ClashMaxHelperXPCProtocol.status(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.startTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.stopTunnel(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.restartTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.recentLogs(withReply:))
    ]

    for selector in replySelectors {
      let classes = try XCTUnwrap(interface.classes(for: selector, argumentIndex: 0, ofReply: true) as NSSet?)
      XCTAssertTrue(classes.contains(NSString.self))
      XCTAssertFalse(classes.contains(NSDictionary.self))
      XCTAssertFalse(classes.contains(NSArray.self))
      XCTAssertFalse(classes.contains(NSObject.self))
    }
  }

  func testHelperInterfaceRestrictsTunnelRequestStringArguments() throws {
    let interface = ClashMaxHelperXPCInterface.make()
    let selectors = [
      #selector(ClashMaxHelperXPCProtocol.startTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.restartTunnel(corePath:configPath:workDirectoryPath:secret:withReply:))
    ]

    for selector in selectors {
      for argumentIndex in 0..<4 {
        let classes = try XCTUnwrap(
          interface.classes(for: selector, argumentIndex: argumentIndex, ofReply: false) as NSSet?
        )
        XCTAssertEqual(classes, NSSet(object: NSString.self))
        XCTAssertFalse(classes.contains(NSObject.self))
      }
    }
  }
}

private final class FakeHelperTransport: HelperXPCTransport {
  let response: [String]

  init(response: [String]) {
    self.response = response
  }

  func status() async throws -> HelperClientResponse {
    .failure("unused")
  }

  func startTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    .failure("unused")
  }

  func stopTunnel() async throws -> HelperClientResponse {
    .failure("unused")
  }

  func restartTunnel(coreURL: URL, configURL: URL, workDirectory: URL, secret: String) async throws -> HelperClientResponse {
    .failure("unused")
  }

  func recentLogs() async throws -> [String] {
    response
  }
}
