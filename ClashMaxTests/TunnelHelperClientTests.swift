import Foundation
import ServiceManagement
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

  func testHelperRegistrationStatusMessagesGuideRegistrationAndApproval() {
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .notRegistered),
      "Helper not registered. Click Register or Start in TUN mode."
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .enabled),
      "Helper registered and enabled."
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .requiresApproval),
      "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions."
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .notFound),
      "Helper not found in the app bundle. Clean build and run ClashMax again."
    )
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

  func testUnavailablePrivilegedHelperStatusReturnsWithoutMainQueueAssertion() async {
    let startedAt = Date()
    do {
      _ = try await withTimeout(seconds: 2) {
        try await PrivilegedHelperXPCTransport().status()
      }
    } catch {
      // Missing or unapproved helpers should surface as ordinary errors, not libdispatch assertions.
    }

    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
  }
}

private final class FakeHelperTransport: HelperXPCTransport, @unchecked Sendable {
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
