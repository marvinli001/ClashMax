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
    let response = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: false,
      running: true,
      pid: 42,
      code: HelperResponseCode.alreadyRunning,
      message: "already running"
    ))

    XCTAssertFalse(response.ok)
    XCTAssertTrue(response.running)
    XCTAssertEqual(response.pid, 42)
    XCTAssertEqual(response.code, HelperResponseCode.alreadyRunning)
    XCTAssertEqual(response.message, "already running")
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
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.notBootstrappedMessage)
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

    XCTAssertEqual(client.statusMessage, TunnelHelperClient.notBootstrappedMessage)
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
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
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
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
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
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.statusMessage(for: .requiresApproval))
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
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.statusMessage(for: .requiresApproval))
  }

  func testPreparingTunnelReturnsRequiresApprovalWithoutThrowing() async throws {
    let service = FakeHelperService(status: .requiresApproval)
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    let transport = FakeHelperTransport()
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let state = await client.prepareForTunnelStart()

    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(
      state,
      .requiresApproval(TunnelHelperClient.statusMessage(for: .requiresApproval))
    )
  }

  func testPreparingTunnelReportsReadyWhenHelperIsBootstrapped() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: HelperClientResponse(payload: HelperXPCPayload.response(ok: true)))
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "same"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "same")
    )

    let state = await client.prepareForTunnelStart()

    XCTAssertEqual(state, .ready)
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testRepairHelperReregistersWhenFingerprintMismatchOnEnabledHelper() async throws {
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
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testRepairHelperPingsXPCInsteadOfReregisteringWhenFingerprintMatchesAndXPCIsHealthy() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: HelperClientResponse(payload: HelperXPCPayload.response(ok: true)))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    try await client.repairRegistration()

    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testRepairHelperRecordsFingerprintWithoutReregisteringWhenEnabledHelperHasNoStoredFingerprintAndXPCIsHealthy() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: HelperClientResponse(payload: HelperXPCPayload.response(ok: true)))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    try await client.repairRegistration()

    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testRepairHelperFallsBackToReregistrationWhenFingerprintMatchesButXPCIsUnhealthy() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = ToggleableHelperTransport(
      initialStatus: .failure("xpc unavailable"),
      subsequentStatus: HelperClientResponse(payload: HelperXPCPayload.response(ok: true))
    )
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
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
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testRepairHelperOpensSettingsWithoutReregisteringWhenApprovalIsPending() async throws {
    let service = FakeHelperService(status: .requiresApproval)
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    let client = TunnelHelperClient(
      transport: FakeHelperTransport(),
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    try await client.repairRegistration()

    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.statusMessage(for: .requiresApproval))
  }

  func testHelperRegistrationStatusMessagesGuideRegistrationAndApproval() {
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .notRegistered),
      String(localized: "Helper not registered. Click Register or Start in TUN mode.")
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .enabled),
      String(localized: "Helper registered. Verifying helper connection.")
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .requiresApproval),
      String(localized: "Helper registered. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status.")
    )
    XCTAssertEqual(
      TunnelHelperClient.statusMessage(for: .notFound),
      String(localized: "Helper not found in the app bundle. Clean build and run ClashMax again.")
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

  func testContinuationBoxResumesConnectionFailureThatArrivesBeforeAttachWithoutCleanup() async {
    let cases = [
      "pre-attach invalidation",
      "pre-attach interruption"
    ]

    for expectedMessage in cases {
      let box = ContinuationBox<String>()
      let expectation = expectation(description: "\(expectedMessage) resumes")
      var cleanupCount = 0

      box.fail(AppError.helperResponse(expectedMessage), runCleanup: false)

      Task {
        do {
          _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let didAttach = box.attach(continuation) {
              cleanupCount += 1
            }
            XCTAssertFalse(didAttach)
          }
          XCTFail("Expected pre-attach failure")
        } catch {
          XCTAssertEqual(UserFacingError.message(for: error), expectedMessage)
        }
        expectation.fulfill()
      }

      await fulfillment(of: [expectation], timeout: 0.5)
      XCTAssertEqual(cleanupCount, 0)
    }
  }

  func testContinuationBoxRunsDeferredCleanupAfterPreAttachSuccess() async {
    let box = ContinuationBox<String>()
    let expectation = expectation(description: "pre-attach success resumes")
    var cleanupCount = 0

    box.succeed("ready")

    Task {
      do {
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
          let didAttach = box.attach(continuation) {
            cleanupCount += 1
          }
          XCTAssertFalse(didAttach)
        }
        XCTAssertEqual(value, "ready")
        XCTAssertEqual(cleanupCount, 1)
      } catch {
        XCTFail("Expected success, got \(error)")
      }
      expectation.fulfill()
    }

    await fulfillment(of: [expectation], timeout: 0.5)
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

private actor ToggleableHelperState {
  var nextStatus: HelperClientResponse
  let subsequentStatus: HelperClientResponse

  init(initialStatus: HelperClientResponse, subsequentStatus: HelperClientResponse) {
    self.nextStatus = initialStatus
    self.subsequentStatus = subsequentStatus
  }

  func consume() -> HelperClientResponse {
    let response = nextStatus
    nextStatus = subsequentStatus
    return response
  }
}

private final class ToggleableHelperTransport: HelperXPCTransport, Sendable {
  private let state: ToggleableHelperState

  init(initialStatus: HelperClientResponse, subsequentStatus: HelperClientResponse) {
    self.state = ToggleableHelperState(initialStatus: initialStatus, subsequentStatus: subsequentStatus)
  }

  func status() async throws -> HelperClientResponse {
    await state.consume()
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
    []
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
