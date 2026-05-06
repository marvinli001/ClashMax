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

  func testEnabledRegistrationIsReportedAsNotBootstrappedWhenXPCStatusFails() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusError: AppError.helperResponse("lookup failed"))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "v1")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "v1"),
      registrationRecordStore: recordStore
    )

    await client.refreshRegistrationStatus()

    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(
      client.statusMessage,
      "Helper registered but not bootstrapped. Open System Settings > General > Login Items & Extensions, approve ClashMax, then click Repair or restart macOS."
    )
  }

  func testEnabledRegistrationIsReportedAsNotBootstrappedWhenXPCStatusPayloadFails() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: .failure("status failed"))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "v1")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "v1"),
      registrationRecordStore: recordStore
    )

    await client.refreshRegistrationStatus()

    XCTAssertEqual(
      client.statusMessage,
      "Helper registered but not bootstrapped. Open System Settings > General > Login Items & Extensions, approve ClashMax, then click Repair or restart macOS."
    )
  }

  func testRegisterRepairsChangedHelperFingerprintBeforeVerifyingXPCStatus() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: HelperClientResponse(payload: HelperXPCPayload.response(ok: true)))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "old")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "new"),
      registrationRecordStore: recordStore
    )

    try await client.register()

    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "new")
    XCTAssertEqual(client.statusMessage, "Helper registered and bootstrapped.")
  }

  func testRegisterDoesNotReregisterUnchangedEnabledHelper() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: HelperClientResponse(payload: HelperXPCPayload.response(ok: true)))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "same")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "same"),
      registrationRecordStore: recordStore
    )

    try await client.register()

    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(client.statusMessage, "Helper registered and bootstrapped.")
  }

  func testRegisterOpensSystemSettingsWhenHelperRequiresApproval() async throws {
    let service = FakeHelperService(status: .requiresApproval)
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    let client = TunnelHelperClient(
      transport: FakeHelperTransport(),
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    try await client.register()

    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(
      client.statusMessage,
      "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status."
    )
  }

  func testRegisterOpensSystemSettingsAfterRegistrationRequiresApproval() async throws {
    let service = FakeHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    let client = TunnelHelperClient(
      transport: FakeHelperTransport(),
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    try await client.register()

    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(
      client.statusMessage,
      "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status."
    )
  }

  func testRepairHelperAlwaysUnregistersThenRegistersAndVerifies() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: HelperClientResponse(payload: HelperXPCPayload.response(ok: true)))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "stale")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    try await client.repairRegistration()

    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(client.statusMessage, "Helper registered and bootstrapped.")
  }

  func testHelperRegistrationStatusMessagesGuideRegistrationAndApproval() {
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .notRegistered),
      "Helper not registered. Click Register or Start in TUN mode."
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .enabled),
      "Helper registered. Verifying helper connection."
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .requiresApproval),
      "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status."
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
  let statusResponse: HelperClientResponse
  let statusError: Error?

  init(
    response: [String] = [],
    statusResponse: HelperClientResponse = .failure("unused"),
    statusError: Error? = nil
  ) {
    self.response = response
    self.statusResponse = statusResponse
    self.statusError = statusError
  }

  func status() async throws -> HelperClientResponse {
    if let statusError {
      throw statusError
    }
    return statusResponse
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

@MainActor
private final class FakeHelperService: HelperServiceManaging {
  var status: SMAppService.Status
  var statusAfterRegister: SMAppService.Status
  private(set) var registerCount = 0
  private(set) var unregisterCount = 0
  private(set) var openSettingsCount = 0

  init(status: SMAppService.Status, statusAfterRegister: SMAppService.Status = .enabled) {
    self.status = status
    self.statusAfterRegister = statusAfterRegister
  }

  func register() throws {
    registerCount += 1
    status = statusAfterRegister
  }

  func unregister() async throws {
    unregisterCount += 1
    status = .notRegistered
  }

  func openSystemSettingsLoginItems() {
    openSettingsCount += 1
  }
}

private struct StaticHelperFingerprintProvider: HelperFingerprintProviding {
  let fingerprint: String

  func currentFingerprint() throws -> String {
    fingerprint
  }
}

private final class InMemoryHelperRegistrationRecordStore: HelperRegistrationRecordStoring, @unchecked Sendable {
  var storedFingerprint: String?

  init(storedFingerprint: String?) {
    self.storedFingerprint = storedFingerprint
  }

  func helperFingerprint() -> String? {
    storedFingerprint
  }

  func setHelperFingerprint(_ fingerprint: String?) {
    storedFingerprint = fingerprint
  }
}
