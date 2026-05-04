import Foundation
import XCTest
@testable import ClashMax

@MainActor
final class TunnelHelperClientTests: XCTestCase {
  func testRecentLogsAreMappedFromHelperResponse() async throws {
    let transport = FakeHelperTransport(response: ["one", "two"] as NSArray)
    let client = TunnelHelperClient(transport: transport)

    let logs = try await client.recentLogs()

    XCTAssertEqual(logs, ["one", "two"])
  }

  func testHelperInterfaceRestrictsCollectionReplyClasses() {
    let interface = ClashMaxHelperXPCInterface.make()
    let dictionaryReplySelectors = [
      #selector(ClashMaxHelperXPCProtocol.status(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.startTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.stopTunnel(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.restartTunnel(corePath:configPath:workDirectoryPath:secret:withReply:))
    ]

    for selector in dictionaryReplySelectors {
      let classes = interface.classes(for: selector, argumentIndex: 0, ofReply: true) as NSSet
      XCTAssertTrue(classes.contains(NSDictionary.self))
      XCTAssertTrue(classes.contains(NSString.self))
      XCTAssertTrue(classes.contains(NSNumber.self))
      XCTAssertFalse(classes.contains(NSObject.self))
    }

    let logClasses = interface.classes(
      for: #selector(ClashMaxHelperXPCProtocol.recentLogs(withReply:)),
      argumentIndex: 0,
      ofReply: true
    ) as NSSet
    XCTAssertTrue(logClasses.contains(NSArray.self))
    XCTAssertTrue(logClasses.contains(NSString.self))
    XCTAssertFalse(logClasses.contains(NSObject.self))
  }
}

private final class FakeHelperTransport: HelperXPCTransport {
  let response: NSArray

  init(response: NSArray) {
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
    response.compactMap { $0 as? String }
  }
}
