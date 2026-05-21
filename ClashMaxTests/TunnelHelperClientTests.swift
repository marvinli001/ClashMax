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
    XCTAssertEqual(response.protocolVersion, ClashMaxHelperProtocolVersion.current)
    XCTAssertEqual(response.helperBuildVersion, ClashMaxHelperBuild.version)
    XCTAssertEqual(HelperXPCPayload.logLines(from: HelperXPCPayload.logs(["one", "two"])), ["one", "two"])
  }

  func testHelperProtocolCompatibilityClassifiesMissingOldAndCompatibleVersions() throws {
    let missing = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: true,
      protocolVersion: nil,
      helperBuildVersion: nil
    ))
    let old = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: true,
      protocolVersion: ClashMaxHelperProtocolVersion.minimumCompatible - 1,
      helperBuildVersion: "old"
    ))
    let compatible = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: true,
      protocolVersion: ClashMaxHelperProtocolVersion.minimumCompatible,
      helperBuildVersion: "current"
    ))

    XCTAssertNil(missing.protocolVersion)
    XCTAssertFalse(missing.protocolCompatible)
    XCTAssertTrue(missing.protocolMigrationRequired)
    XCTAssertFalse(old.protocolCompatible)
    XCTAssertTrue(old.protocolMigrationRequired)
    XCTAssertTrue(compatible.protocolCompatible)
    XCTAssertFalse(compatible.protocolMigrationRequired)
    XCTAssertNil(TunnelHelperClient.helperProtocolMigrationMessage(for: compatible))
    XCTAssertFalse(try XCTUnwrap(TunnelHelperClient.helperProtocolMigrationMessage(for: missing)).isEmpty)
    let oldMessage = try XCTUnwrap(TunnelHelperClient.helperProtocolMigrationMessage(for: old))
    XCTAssertTrue(oldMessage.contains("v\(ClashMaxHelperProtocolVersion.minimumCompatible - 1)"))
    XCTAssertTrue(oldMessage.contains("v\(ClashMaxHelperProtocolVersion.minimumCompatible)"))
  }

  func testHelperResponseClassifiesUserFacingFailureCodes() {
    let invalidPath = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: false,
      code: HelperResponseCode.invalidPath,
      message: "bad path"
    ))
    let untrustedSignature = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: false,
      code: HelperResponseCode.untrustedSignature,
      message: "bad signature"
    ))
    let launchFailed = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: false,
      code: HelperResponseCode.launchFailed,
      message: "spawn failed"
    ))

    XCTAssertTrue(invalidPath.userFacingMessage.contains("unsafe core, config, or workdir path"))
    XCTAssertTrue(untrustedSignature.userFacingMessage.contains("rejected the app or core signature"))
    XCTAssertTrue(launchFailed.userFacingMessage.contains("spawn failed"))
  }

  func testStructuredStatusReportsBootstrappedEnabledHelper() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: HelperClientResponse(payload: HelperXPCPayload.response(
      ok: true,
      running: true,
      pid: 456
    )))
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    )

    let detail = await client.statusDetail()

    XCTAssertEqual(detail.serviceStatus, .enabled)
    XCTAssertTrue(detail.registered)
    XCTAssertTrue(detail.enabled)
    XCTAssertFalse(detail.requiresApproval)
    XCTAssertTrue(detail.bootstrapped)
    XCTAssertTrue(detail.fingerprintRecorded)
    XCTAssertEqual(detail.fingerprintMatches, true)
    XCTAssertTrue(detail.xpcReachable)
    XCTAssertTrue(detail.running)
    XCTAssertEqual(detail.pid, 456)
    XCTAssertEqual(detail.protocolVersion, ClashMaxHelperProtocolVersion.current)
    XCTAssertTrue(detail.protocolCompatible)
    XCTAssertFalse(detail.migrationRequired)
    XCTAssertEqual(detail.helperBuildVersion, ClashMaxHelperBuild.version)
  }

  func testStructuredStatusReportsFingerprintMismatchAndXPCFailure() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusError: AppError.helperResponse("xpc unavailable"))
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "stale")
    )

    let detail = await client.statusDetail()

    XCTAssertEqual(detail.serviceStatus, .enabled)
    XCTAssertTrue(detail.registered)
    XCTAssertTrue(detail.enabled)
    XCTAssertFalse(detail.bootstrapped)
    XCTAssertEqual(detail.fingerprintMatches, false)
    XCTAssertFalse(detail.xpcReachable)
    XCTAssertTrue(detail.message.contains("XPC is unreachable"))
  }

  func testStructuredStatusReportsMissingHelperProtocolAsMigrationRequired() async throws {
    let service = FakeHelperService(status: .enabled)
    let missingProtocolResponse = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: true,
      running: false,
      protocolVersion: nil,
      helperBuildVersion: nil
    ))
    let transport = FakeHelperTransport(statusResponse: missingProtocolResponse)
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    )

    let detail = await client.statusDetail()

    XCTAssertTrue(detail.xpcReachable)
    XCTAssertFalse(detail.bootstrapped)
    XCTAssertNil(detail.protocolVersion)
    XCTAssertFalse(detail.protocolCompatible)
    XCTAssertTrue(detail.migrationRequired)
    XCTAssertEqual(detail.message, try XCTUnwrap(TunnelHelperClient.helperProtocolMigrationMessage(for: missingProtocolResponse)))
  }

  func testUnregisterClearsStoredFingerprintAndServiceRegistration() async throws {
    let service = FakeHelperService(status: .enabled)
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: FakeHelperTransport(),
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    try await client.unregister()

    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.status, .notRegistered)
    XCTAssertNil(recordStore.storedFingerprint)
  }

  func testResetRegistrationStateClearsFingerprintWithoutUnregisteringService() {
    let service = FakeHelperService(status: .enabled)
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: FakeHelperTransport(),
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    client.resetRegistrationState()

    XCTAssertEqual(service.unregisterCount, 0)
    XCTAssertEqual(service.status, .enabled)
    XCTAssertNil(recordStore.storedFingerprint)
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

  func testRegisterRepairsOldHelperProtocolBeforeVerifyingBootstrappedState() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = SequencedHelperTransport(statuses: [
      HelperClientResponse(payload: HelperXPCPayload.response(
        ok: true,
        protocolVersion: ClashMaxHelperProtocolVersion.minimumCompatible - 1,
        helperBuildVersion: "old"
      )),
      HelperClientResponse(payload: HelperXPCPayload.response(
        ok: true,
        protocolVersion: ClashMaxHelperProtocolVersion.current,
        helperBuildVersion: "current"
      ))
    ])
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "same")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "same"),
      registrationRecordStore: recordStore
    )

    try await client.register()

    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testRegisterFailsWithMigrationMessageWhenRepairedHelperProtocolIsStillOld() async throws {
    let service = FakeHelperService(status: .enabled)
    let oldResponse = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: true,
      protocolVersion: ClashMaxHelperProtocolVersion.minimumCompatible - 1,
      helperBuildVersion: "old"
    ))
    let transport = SequencedHelperTransport(statuses: [
      oldResponse,
      oldResponse
    ])
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "same")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "same"),
      registrationRecordStore: recordStore
    )

    do {
      try await client.register()
      XCTFail("Expected helper migration failure")
    } catch {
      let message = UserFacingError.message(for: error)
      XCTAssertEqual(message, try XCTUnwrap(TunnelHelperClient.helperProtocolMigrationMessage(for: oldResponse)))
      XCTAssertEqual(client.statusMessage, message)
    }
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
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

  func testPreparingTunnelReregistersOldHelperProtocolAndUsesRepairedHelper() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = SequencedHelperTransport(statuses: [
      HelperClientResponse(payload: HelperXPCPayload.response(
        ok: true,
        protocolVersion: ClashMaxHelperProtocolVersion.minimumCompatible - 1,
        helperBuildVersion: "old"
      )),
      HelperClientResponse(payload: HelperXPCPayload.response(
        ok: true,
        protocolVersion: ClashMaxHelperProtocolVersion.current,
        helperBuildVersion: "current"
      ))
    ])
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let state = await client.prepareForTunnelStart()

    XCTAssertEqual(state, .ready)
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testPreparingTunnelSurfacesMigrationMessageWhenRepairedHelperIsStillOld() async throws {
    let service = FakeHelperService(status: .enabled)
    let oldResponse = HelperClientResponse(payload: HelperXPCPayload.response(
      ok: true,
      protocolVersion: ClashMaxHelperProtocolVersion.minimumCompatible - 1,
      helperBuildVersion: "old"
    ))
    let transport = SequencedHelperTransport(statuses: [
      oldResponse,
      oldResponse
    ])
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let state = await client.prepareForTunnelStart()

    XCTAssertTrue(state.isFailure)
    XCTAssertEqual(state.message, try XCTUnwrap(TunnelHelperClient.helperProtocolMigrationMessage(for: oldResponse)))
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(client.statusMessage, state.message)
  }

  func testWarmRegistrationKeepsEnabledHelperRegisteredWithoutPingingXPC() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusError: AppError.helperResponse("lookup failed"))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let state = await client.warmRegistration()

    XCTAssertEqual(state, .registered(TunnelHelperClient.registeredMessage))
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(service.registerCount, 0)
    XCTAssertEqual(service.openSettingsCount, 0)
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.registeredMessage)
  }

  func testWarmRegistrationRegistersWithoutOpeningApprovalSettings() async throws {
    let service = FakeHelperService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: nil)
    let client = TunnelHelperClient(
      transport: FakeHelperTransport(),
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let state = await client.warmRegistration()

    XCTAssertEqual(state, .requiresApproval(TunnelHelperClient.statusMessage(for: .requiresApproval)))
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(service.openSettingsCount, 0)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
  }

  func testPreparingTunnelReregistersEnabledHelperOnceWhenXPCStatusFails() async throws {
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

    let state = await client.prepareForTunnelStart()

    XCTAssertEqual(state, .ready)
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(recordStore.storedFingerprint, "current")
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testPreparingTunnelDoesNotRepeatAutomaticReregistrationForSameFingerprint() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = FakeHelperTransport(statusResponse: .failure("xpc unavailable"))
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let firstState = await client.prepareForTunnelStart()
    let secondState = await client.prepareForTunnelStart()

    XCTAssertEqual(firstState, .notBootstrapped("xpc unavailable"))
    XCTAssertEqual(secondState, .notBootstrapped("xpc unavailable"))
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
  }

  func testManualRepairSuccessAllowsSameFingerprintAutomaticReregistrationAgain() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = SequencedHelperTransport(statuses: [
      .failure("xpc unavailable"),
      .failure("xpc unavailable"),
      HelperClientResponse(payload: HelperXPCPayload.response(ok: true)),
      .failure("xpc unavailable"),
      HelperClientResponse(payload: HelperXPCPayload.response(ok: true))
    ])
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let firstState = await client.prepareForTunnelStart()
    try await client.repairRegistration()
    let secondState = await client.prepareForTunnelStart()

    XCTAssertEqual(firstState, .notBootstrapped("xpc unavailable"))
    XCTAssertEqual(secondState, .ready)
    XCTAssertEqual(service.unregisterCount, 2)
    XCTAssertEqual(service.registerCount, 2)
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testHealthyCurrentPreparationStateAllowsSameFingerprintAutomaticReregistrationAgain() async throws {
    let service = FakeHelperService(status: .enabled)
    let transport = SequencedHelperTransport(statuses: [
      .failure("xpc unavailable"),
      .failure("xpc unavailable"),
      HelperClientResponse(payload: HelperXPCPayload.response(ok: true)),
      .failure("xpc unavailable"),
      HelperClientResponse(payload: HelperXPCPayload.response(ok: true))
    ])
    let recordStore = InMemoryHelperRegistrationRecordStore(storedFingerprint: "current")
    let client = TunnelHelperClient(
      transport: transport,
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: recordStore
    )

    let firstState = await client.prepareForTunnelStart()
    let healthyState = await client.currentPreparationState()
    let secondState = await client.prepareForTunnelStart()

    XCTAssertEqual(firstState, .notBootstrapped("xpc unavailable"))
    XCTAssertEqual(healthyState, .ready)
    XCTAssertEqual(secondState, .ready)
    XCTAssertEqual(service.unregisterCount, 2)
    XCTAssertEqual(service.registerCount, 2)
    XCTAssertEqual(client.statusMessage, TunnelHelperClient.bootstrappedMessage)
  }

  func testPreparingTunnelTimesOutStuckEnabledHelperStatus() async throws {
    let service = FakeHelperService(status: .enabled)
    let client = TunnelHelperClient(
      transport: HangingStatusHelperTransport(),
      service: service,
      fingerprintProvider: StaticHelperFingerprintProvider(fingerprint: "current"),
      registrationRecordStore: InMemoryHelperRegistrationRecordStore(storedFingerprint: "current"),
      bootstrapStatusTimeoutSeconds: 0.01
    )
    let startedAt = Date()

    let state = await client.prepareForTunnelStart()

    XCTAssertEqual(state, .notBootstrapped(TunnelHelperClient.notBootstrappedMessage))
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 1)
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(service.registerCount, 1)
  }

  func testNotBootstrappedStateDoesNotPollForApproval() {
    XCTAssertTrue(TunHelperPreparationState.requiresApproval("approve").shouldPollForApproval)
    XCTAssertFalse(TunHelperPreparationState.notBootstrapped("launchd failed").shouldPollForApproval)
  }

  func testAppBundleHelperFingerprintUsesLaunchServicesExecutablePath() throws {
    let bundleURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxFingerprint-\(UUID().uuidString).app", isDirectory: true)
    let helperURL = bundleURL.appendingPathComponent("Contents/Library/LaunchServices/ClashMaxHelper")
    let plistURL = bundleURL.appendingPathComponent("Contents/Library/LaunchDaemons/io.github.clashmax.ClashMax.Helper.plist")
    try FileManager.default.createDirectory(
      at: helperURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: plistURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try "helper".write(to: helperURL, atomically: true, encoding: .utf8)
    try "plist".write(to: plistURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: bundleURL) }

    let fingerprint = try AppBundleHelperFingerprintProvider(bundleURL: bundleURL).currentFingerprint()

    XCTAssertFalse(fingerprint.isEmpty)
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

private actor SequencedHelperState {
  var statuses: [HelperClientResponse]

  init(statuses: [HelperClientResponse]) {
    self.statuses = statuses
  }

  func consume() -> HelperClientResponse {
    if statuses.isEmpty {
      return .failure("unused")
    }
    return statuses.removeFirst()
  }
}

private final class SequencedHelperTransport: HelperXPCTransport, Sendable {
  private let state: SequencedHelperState

  init(statuses: [HelperClientResponse]) {
    self.state = SequencedHelperState(statuses: statuses)
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

private actor HangingStatusHelperTransport: HelperXPCTransport {
  func status() async throws -> HelperClientResponse {
    try await Task.sleep(nanoseconds: 5_000_000_000)
    return HelperClientResponse(payload: HelperXPCPayload.response(ok: true))
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
