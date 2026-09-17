@testable import ClashMax
import Darwin
import XCTest

final class TunnelHelperValidationTests: XCTestCase {
  func testBundledCoreRootUsesExecutableURLWhenLaunchDaemonProgramIsRelative() {
    let root = HelperBundleLocator.bundledCoreRoot(
      executableURL: URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Library/LaunchServices/ClashMaxHelper"),
      commandPath: "Contents/Library/LaunchServices/ClashMaxHelper",
      currentDirectoryURL: URL(fileURLWithPath: "/Users/test/Developer/ClashMax", isDirectory: true)
    )

    XCTAssertEqual(root.path, "/Applications/ClashMax.app/Contents/Resources/Core")
  }

  func testHelperRejectsPathsOutsideAllowedRoots() {
    let fixture = try! makePathFixture()
    let validator = HelperPathValidator(
      runtimeRoot: fixture.runtimeRoot,
      bundledCoreRoot: fixture.bundledCoreRoot
    )

    XCTAssertThrowsError(
      try validator.validate(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: fixture.configURL,
        workDirectory: fixture.runtimeRoot
      )
    )
  }

  func testHelperAcceptsBundledCoreAndAppManagedConfig() throws {
    let fixture = try makePathFixture()
    let validator = HelperPathValidator(
      runtimeRoot: fixture.runtimeRoot,
      bundledCoreRoot: fixture.bundledCoreRoot
    )

    XCTAssertNoThrow(
      try validator.validate(
        coreURL: fixture.coreURL,
        configURL: fixture.configURL,
        workDirectory: fixture.runtimeRoot
      )
    )
  }

  func testHelperRejectsCoreFromAppSupportEvenWhenRuntimePathsAreValid() throws {
    let fixture = try makePathFixture()
    let appSupportCoreRoot = fixture.appSupportRoot.appendingPathComponent("Core", isDirectory: true)
    try FileManager.default.createDirectory(at: appSupportCoreRoot, withIntermediateDirectories: true)
    let appSupportCore = appSupportCoreRoot.appendingPathComponent("mihomo-darwin-arm64")
    try "#!/bin/sh\n".write(to: appSupportCore, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: appSupportCore.path)

    let validator = HelperPathValidator(
      runtimeRoot: fixture.runtimeRoot,
      bundledCoreRoot: fixture.bundledCoreRoot
    )

    XCTAssertThrowsError(
      try validator.validate(
        coreURL: appSupportCore,
        configURL: fixture.configURL,
        workDirectory: fixture.runtimeRoot
      )
    )
  }

  func testHelperRejectsNonAllowlistedBundledCoreFilename() throws {
    let fixture = try makePathFixture()
    let unapprovedCore = fixture.bundledCoreRoot.appendingPathComponent("mihomo-wrapper")
    try "#!/bin/sh\n".write(to: unapprovedCore, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unapprovedCore.path)
    let validator = HelperPathValidator(
      runtimeRoot: fixture.runtimeRoot,
      bundledCoreRoot: fixture.bundledCoreRoot
    )

    XCTAssertThrowsError(
      try validator.validate(
        coreURL: unapprovedCore,
        configURL: fixture.configURL,
        workDirectory: fixture.runtimeRoot
      )
    ) { error in
      guard case let HelperPathValidator.ValidationError.untrustedCoreExecutableName(name) = error else {
        return XCTFail("Expected untrusted core filename, got \(error)")
      }
      XCTAssertEqual(name, "mihomo-wrapper")
    }
  }

  func testHelperRejectsConfigOutsideRuntimeRoot() throws {
    let fixture = try makePathFixture()
    let outsideConfig = fixture.tempRoot.appendingPathComponent("outside.yaml")
    try "port: 7890\n".write(to: outsideConfig, atomically: true, encoding: .utf8)
    let validator = HelperPathValidator(
      runtimeRoot: fixture.runtimeRoot,
      bundledCoreRoot: fixture.bundledCoreRoot
    )

    XCTAssertThrowsError(
      try validator.validate(
        coreURL: fixture.coreURL,
        configURL: outsideConfig,
        workDirectory: fixture.runtimeRoot
      )
    ) { error in
      guard case HelperPathValidator.ValidationError.pathEscapesAllowedRoots = error else {
        return XCTFail("Expected config root rejection, got \(error)")
      }
    }
  }

  func testHelperRejectsNonFixedWorkDirectory() throws {
    let fixture = try makePathFixture()
    let nestedWorkDirectory = fixture.runtimeRoot.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nestedWorkDirectory, withIntermediateDirectories: true)
    let validator = HelperPathValidator(
      runtimeRoot: fixture.runtimeRoot,
      bundledCoreRoot: fixture.bundledCoreRoot
    )

    XCTAssertThrowsError(
      try validator.validate(
        coreURL: fixture.coreURL,
        configURL: fixture.configURL,
        workDirectory: nestedWorkDirectory
      )
    ) { error in
      guard case HelperPathValidator.ValidationError.unexpectedWorkDirectory = error else {
        return XCTFail("Expected fixed work-directory rejection, got \(error)")
      }
    }
  }

  func testHelperRejectsConfigSymlinkThatEscapesRuntimeRoot() throws {
    let fixture = try makePathFixture()
    let outside = fixture.tempRoot.appendingPathComponent("outside.yaml")
    try "port: 7890\n".write(to: outside, atomically: true, encoding: .utf8)
    let symlink = fixture.runtimeRoot.appendingPathComponent("linked.yaml")
    try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)

    let validator = HelperPathValidator(
      runtimeRoot: fixture.runtimeRoot,
      bundledCoreRoot: fixture.bundledCoreRoot
    )

    XCTAssertThrowsError(
      try validator.validate(
        coreURL: fixture.coreURL,
        configURL: symlink,
        workDirectory: fixture.runtimeRoot
      )
    )
  }

  func testHelperLaunchesPathsWithSpacesQuotesBackticksAndDollarSubstitutionLiterally() throws {
    let fixture = try makeRuntimeFixture(
      rootComponent: "ClashMax Helper 'single' \"double\" `backtick` $()-\(UUID().uuidString)"
    )
    let service = makeHelperService(fixture: fixture)
    addTeardownBlock { stop(service) }

    let response = try start(service, fixture: fixture, secret: "not-exported")

    XCTAssertTrue(response.ok)
    XCTAssertTrue(response.running)
    XCTAssertGreaterThan(response.pid, 0)
    XCTAssertEqual(
      try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"),
      "\(response.pid):1:unset"
    )
  }

  func testHelperClientSignaturePolicyRequiresExpectedBundleIdentifierAndTeam() {
    let policy = HelperCodeSignaturePolicy(
      expectedClientBundleIdentifier: "io.github.clashmax.ClashMax",
      helperBundleIdentifier: "io.github.clashmax.ClashMax.Helper",
      trustedTeamIdentifier: "TEAM12345",
      allowsLocalDevelopmentFallback: false
    )

    XCTAssertTrue(policy.allowsClient(HelperCodeSignatureInfo(
      bundleIdentifier: "io.github.clashmax.ClashMax",
      teamIdentifier: "TEAM12345"
    )))
    XCTAssertFalse(policy.allowsClient(HelperCodeSignatureInfo(
      bundleIdentifier: "io.github.clashmax.ClashMax",
      teamIdentifier: "OTHERTEAM"
    )))
    XCTAssertFalse(policy.allowsClient(HelperCodeSignatureInfo(
      bundleIdentifier: "com.example.Attacker",
      teamIdentifier: "TEAM12345"
    )))
  }

  func testHelperCodeSignaturePolicyDoesNotUseLooseFallbackForReleasePolicy() {
    let releasePolicy = HelperCodeSignaturePolicy(
      expectedClientBundleIdentifier: "io.github.clashmax.ClashMax",
      helperBundleIdentifier: "io.github.clashmax.ClashMax.Helper",
      trustedTeamIdentifier: nil,
      allowsLocalDevelopmentFallback: false
    )
    let debugPolicy = HelperCodeSignaturePolicy(
      expectedClientBundleIdentifier: "io.github.clashmax.ClashMax",
      helperBundleIdentifier: "io.github.clashmax.ClashMax.Helper",
      trustedTeamIdentifier: nil,
      allowsLocalDevelopmentFallback: true
    )
    let devClient = HelperCodeSignatureInfo(
      bundleIdentifier: "io.github.clashmax.ClashMax",
      teamIdentifier: nil
    )
    let adHocDebugClient = HelperCodeSignatureInfo(
      bundleIdentifier: "ClashMax",
      teamIdentifier: nil
    )

    XCTAssertFalse(releasePolicy.allowsClient(devClient))
    XCTAssertFalse(releasePolicy.allowsClient(adHocDebugClient))
    XCTAssertTrue(debugPolicy.allowsClient(devClient))
    XCTAssertTrue(debugPolicy.allowsClient(adHocDebugClient))
  }

  func testHelperCoreSignaturePolicyRequiresTrustedTeamWhenHelperIsTeamSigned() {
    let policy = HelperCodeSignaturePolicy(
      expectedClientBundleIdentifier: "io.github.clashmax.ClashMax",
      helperBundleIdentifier: "io.github.clashmax.ClashMax.Helper",
      trustedTeamIdentifier: "TEAM12345",
      allowsLocalDevelopmentFallback: false
    )

    XCTAssertTrue(policy.allowsCore(HelperCodeSignatureInfo(
      bundleIdentifier: "mihomo-darwin-arm64",
      teamIdentifier: "TEAM12345"
    )))
    XCTAssertFalse(policy.allowsCore(HelperCodeSignatureInfo(
      bundleIdentifier: "mihomo-darwin-arm64",
      teamIdentifier: "OTHERTEAM"
    )))
    XCTAssertFalse(policy.allowsCore(HelperCodeSignatureInfo(
      bundleIdentifier: nil,
      teamIdentifier: nil
    )))
  }

  func testHelperStartTunnelRejectsSecondStartWhenProcessIsAlreadyRunning() throws {
    let fixture = try makeRuntimeFixture()
    let service = makeHelperService(fixture: fixture)
    addTeardownBlock { stop(service) }

    let first = try start(service, fixture: fixture, secret: "old")
    XCTAssertTrue(first.ok)
    XCTAssertTrue(first.running)
    XCTAssertGreaterThan(first.pid, 0)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(first.pid):1:unset"), "\(first.pid):1:unset")

    let second = try start(service, fixture: fixture, secret: "new")
    XCTAssertFalse(second.ok)
    XCTAssertTrue(second.running)
    XCTAssertEqual(second.pid, first.pid)
    XCTAssertEqual(second.code, HelperResponseCode.alreadyRunning)
    XCTAssertTrue(second.message.localizedCaseInsensitiveContains("already running"))
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(first.pid):1:unset"), "\(first.pid):1:unset")
  }

  func testHelperRestartTunnelWaitsForOldProcessBeforeStartingReplacement() throws {
    let fixture = try makeRuntimeFixture()
    let service = makeHelperService(fixture: fixture)
    addTeardownBlock { stop(service) }

    let first = try start(service, fixture: fixture, secret: "old")
    XCTAssertTrue(first.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(first.pid):1:unset"), "\(first.pid):1:unset")

    let restarted = try restart(service, fixture: fixture, secret: "new")
    XCTAssertTrue(restarted.ok)
    XCTAssertTrue(restarted.running)
    XCTAssertGreaterThan(restarted.pid, 0)
    XCTAssertFalse(isProcessAlive(pid_t(first.pid)))
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(restarted.pid):1:unset"), "\(restarted.pid):1:unset")
  }

  func testHelperConcurrentStartTunnelAllowsOnlyOneRunningProcess() throws {
    let fixture = try makeRuntimeFixture()
    let service = makeHelperService(fixture: fixture)
    addTeardownBlock { stop(service) }

    let responseRecorder = ThreadSafeStartResponseRecorder()
    let startGate = DispatchSemaphore(value: 0)
    let done = DispatchGroup()

    for secret in ["first", "second"] {
      done.enter()
      DispatchQueue.global().async {
        startGate.wait()
        responseRecorder.append(Result {
          try (secret, start(service, fixture: fixture, secret: secret))
        })
        done.leave()
      }
    }

    startGate.signal()
    startGate.signal()

    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    let responses = try responseRecorder.values.map { try $0.get() }
    let accepted = responses.filter(\.1.ok)
    let rejected = responses.filter { !$0.1.ok }

    XCTAssertEqual(accepted.count, 1)
    XCTAssertEqual(rejected.count, 1)
    let acceptedResponse = try XCTUnwrap(accepted.first)
    let rejectedResponse = try XCTUnwrap(rejected.first).1
    XCTAssertTrue(acceptedResponse.1.running)
    XCTAssertEqual(rejectedResponse.code, HelperResponseCode.alreadyRunning)
    XCTAssertEqual(rejectedResponse.pid, acceptedResponse.1.pid)
    XCTAssertEqual(
      try waitForLaunchState(fixture: fixture, expected: "\(acceptedResponse.1.pid):1:unset"),
      "\(acceptedResponse.1.pid):1:unset"
    )
  }

  func testHelperOutputHandlerClearsItselfAtEOF() throws {
    let pipe = Pipe()
    let logs = ThreadSafeStringRecorder()
    HelperProcessOutputHandlers.install(on: pipe) { line in
      logs.append(line)
    }
    let handler = try XCTUnwrap(pipe.fileHandleForReading.readabilityHandler)

    pipe.fileHandleForWriting.closeFile()
    handler(pipe.fileHandleForReading)

    XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
    XCTAssertTrue(logs.isEmpty)
  }

  func testHelperStopTunnelClearsOutputAndTerminationHandlersOnTrackedProcess() throws {
    let fixture = try makeRuntimeFixture()
    var launchedProcess: Process?
    let service = makeHelperService(fixture: fixture) { process in
      launchedProcess = process
    }
    addTeardownBlock { stop(service) }

    let response = try start(service, fixture: fixture, secret: "cleanup")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")
    let process = try XCTUnwrap(launchedProcess)
    let outputHandle = try XCTUnwrap((process.standardOutput as? Pipe)?.fileHandleForReading)
    let errorHandle = try XCTUnwrap((process.standardError as? Pipe)?.fileHandleForReading)
    XCTAssertTrue(outputHandle === errorHandle)
    XCTAssertNotNil(outputHandle.readabilityHandler)
    XCTAssertNotNil(errorHandle.readabilityHandler)
    XCTAssertNotNil(process.terminationHandler)

    stop(service)

    XCTAssertNil(outputHandle.readabilityHandler)
    XCTAssertNil(errorHandle.readabilityHandler)
    XCTAssertNil(process.terminationHandler)
  }

  func testHelperStatusClearsOutputAndTerminationHandlersForExitedTrackedProcess() throws {
    let fixture = try makeRuntimeFixture(coreScript: """
    #!/bin/sh
    printf "%s:%s:%s\\n" "$$" "${CLASHMAX_HELPER:-0}" "${CLASHMAX_SECRET-unset}" > "$PWD/launch-state.txt"
    exit 0
    """)
    var launchedProcess: Process?
    let service = makeHelperService(fixture: fixture) { process in
      launchedProcess = process
    }
    addTeardownBlock { stop(service) }

    let response = try start(service, fixture: fixture, secret: "exited")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")
    let process = try XCTUnwrap(launchedProcess)
    waitForProcessExit(process)
    XCTAssertFalse(process.isRunning)
    let outputHandle = try XCTUnwrap((process.standardOutput as? Pipe)?.fileHandleForReading)

    var payload: NSString?
    service.status { response in
      payload = response
    }
    let status = try HelperClientResponse(payload: XCTUnwrap(payload))

    XCTAssertFalse(status.running)
    XCTAssertNil(outputHandle.readabilityHandler)
    XCTAssertNil(process.terminationHandler)
  }

  // MARK: - Issue #33: stopTunnel must not report "stopped" while the root Mihomo still runs

  func testHelperStopReplyWaitsForAProcessThatExitsLateAfterSIGKILL() throws {
    // The core ignores SIGTERM (a Mihomo mid TUN teardown does not react to it either) and only
    // dies from a SIGKILL that the test delays: the stop reply must not arrive before that exit.
    let fixture = try makeRuntimeFixture(coreScript: """
    #!/bin/sh
    trap '' TERM
    printf "%s:%s:%s\\n" "$$" "${CLASHMAX_HELPER:-0}" "${CLASHMAX_SECRET-unset}" > "$PWD/launch-state.txt"
    while true; do sleep 1; done
    """)
    // Past the old fixed 1s SIGKILL budget, inside the new 3s one.
    let killDelay: TimeInterval = 1.2
    var launchedProcess: Process?
    let service = HelperService(
      trustedPathsProvider: { _ in
        HelperTrustedPaths(runtimeRoot: fixture.runtimeRoot, bundledCoreRoot: fixture.bundledCoreRoot)
      },
      coreExecutableValidator: NoopHelperCoreExecutableValidator(),
      clientUserIDProvider: { getuid() },
      processTerminationTimeout: 0.1,
      processKillTimeout: 3,
      processDidLaunch: { launchedProcess = $0 },
      killSignalSender: { pid, signal in
        DispatchQueue.global().asyncAfter(deadline: .now() + killDelay) {
          _ = kill(pid, signal)
        }
        return 0
      }
    )
    addTeardownBlock { stop(service) }

    let response = try start(service, fixture: fixture, secret: "late-exit")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")
    let process = try XCTUnwrap(launchedProcess)

    let stopStarted = Date()
    let stopped = try stopResponse(service)
    let stopDuration = Date().timeIntervalSince(stopStarted)

    XCTAssertTrue(stopped.ok)
    XCTAssertFalse(stopped.running)
    XCTAssertFalse(process.isRunning, "the reply must be sent only after the process is gone")
    XCTAssertFalse(isProcessAlive(pid_t(response.pid)))
    XCTAssertGreaterThanOrEqual(stopDuration, killDelay, "the reply came back before the delayed SIGKILL could have landed")
  }

  func testHelperStopReportsRunningWhenTheProcessOutlivesSIGKILLBudget() throws {
    // Withholding the SIGKILL entirely stands in for a process the kernel has not torn down yet.
    let fixture = try makeRuntimeFixture(coreScript: """
    #!/bin/sh
    trap '' TERM
    printf "%s:%s:%s\\n" "$$" "${CLASHMAX_HELPER:-0}" "${CLASHMAX_SECRET-unset}" > "$PWD/launch-state.txt"
    while true; do sleep 1; done
    """)
    var launchedProcess: Process?
    let service = HelperService(
      trustedPathsProvider: { _ in
        HelperTrustedPaths(runtimeRoot: fixture.runtimeRoot, bundledCoreRoot: fixture.bundledCoreRoot)
      },
      coreExecutableValidator: NoopHelperCoreExecutableValidator(),
      clientUserIDProvider: { getuid() },
      processTerminationTimeout: 0.1,
      processKillTimeout: 0.2,
      processDidLaunch: { launchedProcess = $0 },
      killSignalSender: { _, _ in 0 }
    )
    let response = try start(service, fixture: fixture, secret: "immortal")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")
    let process = try XCTUnwrap(launchedProcess)
    addTeardownBlock {
      kill(pid_t(response.pid), SIGKILL)
      waitForProcessExit(process)
    }

    let stopped = try stopResponse(service)

    XCTAssertFalse(stopped.ok)
    XCTAssertTrue(stopped.running)
    XCTAssertEqual(stopped.pid, response.pid)
    XCTAssertEqual(stopped.code, HelperResponseCode.stopTimedOut)
    XCTAssertTrue(stopped.message.contains("still running"), stopped.message)
    XCTAssertTrue(process.isRunning)
    XCTAssertTrue(stopped.userFacingMessage.contains("PID \(response.pid)"), stopped.userFacingMessage)
    XCTAssertTrue(stopped.userFacingMessage.contains("click Stop again"), stopped.userFacingMessage)

    // The process stays tracked: status still sees it, a start is still refused, and a restart
    // must not launch a second core next to the one that will not die.
    var statusPayload: NSString?
    service.status { statusPayload = $0 }
    let status = try HelperClientResponse(payload: XCTUnwrap(statusPayload))
    XCTAssertTrue(status.running)
    XCTAssertEqual(status.pid, response.pid)

    let secondStart = try start(service, fixture: fixture, secret: "again")
    XCTAssertFalse(secondStart.ok)
    XCTAssertEqual(secondStart.code, HelperResponseCode.alreadyRunning)

    let restarted = try restart(service, fixture: fixture, secret: "again")
    XCTAssertFalse(restarted.ok)
    XCTAssertTrue(restarted.running)
    XCTAssertEqual(restarted.code, HelperResponseCode.stopTimedOut, "a restart that could not stop the old core says so, not 'already running'")
    XCTAssertEqual(restarted.pid, response.pid)
    XCTAssertTrue(restarted.userFacingMessage.contains("click Stop again"), restarted.userFacingMessage)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")

    // Once it really dies, the next stop succeeds and tracking is cleared.
    kill(pid_t(response.pid), SIGKILL)
    waitForProcessExit(process)
    let finalStop = try stopResponse(service)
    XCTAssertTrue(finalStop.ok)
    XCTAssertFalse(finalStop.running)
  }

  func testHelperStopWaitsForTheTrackedListenerPortsToStopAccepting() throws {
    let fixture = try makeRuntimeFixture()
    try """
    mixed-port: 7890
    external-controller: 127.0.0.1:9097
    secret: abc
    """.write(to: fixture.configURL, atomically: true, encoding: .utf8)
    let probeLog = ThreadSafeIntRecorder()
    let service = HelperService(
      trustedPathsProvider: { _ in
        HelperTrustedPaths(runtimeRoot: fixture.runtimeRoot, bundledCoreRoot: fixture.bundledCoreRoot)
      },
      coreExecutableValidator: NoopHelperCoreExecutableValidator(),
      clientUserIDProvider: { getuid() },
      processTerminationTimeout: 2,
      portReleaseTimeout: 2,
      portProbe: { port in
        // Both ports look busy for the first two rounds, then release.
        probeLog.append(port)
        return probeLog.count(of: port) <= 2
      }
    )
    addTeardownBlock { stop(service) }

    let response = try start(service, fixture: fixture, secret: "ports")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")

    let stopped = try stopResponse(service)

    XCTAssertTrue(stopped.ok)
    XCTAssertFalse(stopped.running)
    XCTAssertEqual(probeLog.count(of: 7890), 3, "\(probeLog.values)")
    XCTAssertEqual(probeLog.count(of: 9097), 3, "\(probeLog.values)")
    XCTAssertEqual(Set(probeLog.values), [7890, 9097])
  }

  func testHelperStopDoesNotBlockForeverOnAPortThatNeverReleases() throws {
    let fixture = try makeRuntimeFixture()
    try "mixed-port: 7890\nexternal-controller: 127.0.0.1:9097\n".write(to: fixture.configURL, atomically: true, encoding: .utf8)
    let service = HelperService(
      trustedPathsProvider: { _ in
        HelperTrustedPaths(runtimeRoot: fixture.runtimeRoot, bundledCoreRoot: fixture.bundledCoreRoot)
      },
      coreExecutableValidator: NoopHelperCoreExecutableValidator(),
      clientUserIDProvider: { getuid() },
      processTerminationTimeout: 2,
      portReleaseTimeout: 0.2,
      portProbe: { _ in true }
    )
    addTeardownBlock { stop(service) }

    let response = try start(service, fixture: fixture, secret: "stuck-port")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")

    let started = Date()
    let stopped = try stopResponse(service)

    XCTAssertTrue(stopped.ok, "a busy port after exit is logged, not fatal")
    XCTAssertFalse(stopped.running)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    var logsPayload: NSString?
    service.recentLogs { logsPayload = $0 }
    let logs = try HelperXPCPayload.logLines(from: XCTUnwrap(logsPayload))
    XCTAssertTrue(logs.contains { $0.contains("port 7890,9097 still accepts connections") }, "\(logs)")
  }

  func testHelperStatusAnswersWhileAStopIsStillWaitingForTheProcess() throws {
    // The stop waits several seconds for a core tearing down TUN; a status call in that window
    // must report the process as running right away, not queue behind the wait.
    let fixture = try makeRuntimeFixture(coreScript: """
    #!/bin/sh
    trap '' TERM
    printf "%s:%s:%s\\n" "$$" "${CLASHMAX_HELPER:-0}" "${CLASHMAX_SECRET-unset}" > "$PWD/launch-state.txt"
    while true; do sleep 1; done
    """)
    var launchedProcess: Process?
    let service = HelperService(
      trustedPathsProvider: { _ in
        HelperTrustedPaths(runtimeRoot: fixture.runtimeRoot, bundledCoreRoot: fixture.bundledCoreRoot)
      },
      coreExecutableValidator: NoopHelperCoreExecutableValidator(),
      clientUserIDProvider: { getuid() },
      processTerminationTimeout: 1.5,
      processKillTimeout: 0.2,
      processDidLaunch: { launchedProcess = $0 },
      killSignalSender: { _, _ in 0 }
    )
    let response = try start(service, fixture: fixture, secret: "slow-stop")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):1:unset"), "\(response.pid):1:unset")
    let process = try XCTUnwrap(launchedProcess)
    addTeardownBlock {
      kill(pid_t(response.pid), SIGKILL)
      waitForProcessExit(process)
    }

    let stopFinished = DispatchSemaphore(value: 0)
    let stopResult = ThreadSafeStartResponseRecorder()
    DispatchQueue.global().async {
      stopResult.append(Result { try ("stop", stopResponse(service)) })
      stopFinished.signal()
    }
    Thread.sleep(forTimeInterval: 0.3)

    let statusStarted = Date()
    var statusPayload: NSString?
    service.status { statusPayload = $0 }
    let statusDuration = Date().timeIntervalSince(statusStarted)
    let status = try HelperClientResponse(payload: XCTUnwrap(statusPayload))

    XCTAssertLessThan(statusDuration, 0.5, "status() must not wait behind the stop's SIGTERM/SIGKILL budget")
    XCTAssertTrue(status.running)
    XCTAssertEqual(status.pid, response.pid)

    XCTAssertEqual(stopFinished.wait(timeout: .now() + 5), .success)
    let stopped = try XCTUnwrap(stopResult.values.first).get().1
    XCTAssertEqual(stopped.code, HelperResponseCode.stopTimedOut)
  }

  func testHelperRuntimeListenerPortsParseTheFileClashMaxActuallyGenerates() throws {
    // The helper parses lines, not YAML; pin that to what Yams emits for the app's own config.
    var overrides = RuntimeOverrides.defaultForLaunch(secret: "secret-token")
    overrides.mixedPort = 7899
    overrides.externalControllerPort = 9199
    let yaml = try ConfigNormalizer().runtimeConfig(
      from: """
      proxies:
        - name: Direct
          type: direct
      proxy-groups:
        - name: Proxy
          type: select
          proxies: [Direct]
      rules:
        - MATCH,DIRECT
      """,
      overrides: overrides
    )

    XCTAssertEqual(HelperRuntimeListenerPorts.parse(configText: yaml), [7899, 9199])
  }

  func testHelperRuntimeListenerPortsParseOnlyTheRootPortKeys() {
    let text = """
    # generated by ClashMax
    mixed-port: 7890
    external-controller: '127.0.0.1:9097'
    secret: "abc:def"
    dns:
      listen: 127.0.0.1:1053
      external-controller: 0.0.0.0:1
    tun:
      mixed-port: 1
    listeners:
      - name: extra
        port: 7899
    """

    XCTAssertEqual(HelperRuntimeListenerPorts.parse(configText: text), [7890, 9097])
    XCTAssertEqual(HelperRuntimeListenerPorts.parse(configText: "external-controller: 127.0.0.1:9097\n"), [9097])
    XCTAssertEqual(HelperRuntimeListenerPorts.parse(configText: "external-controller: unix:/tmp/sock\nmixed-port: abc\n"), [])
    XCTAssertEqual(HelperRuntimeListenerPorts.parse(configText: "mixed-port: 70000\n"), [])
    XCTAssertEqual(HelperRuntimeListenerPorts.parse(configText: ""), [])
  }

  func testHelperLoopbackPortProbeSeesARealListener() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    XCTAssertGreaterThanOrEqual(descriptor, 0)
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bindResult, 0)
    XCTAssertEqual(Darwin.listen(descriptor, 4), 0)
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    let port = Int(UInt16(bigEndian: bound.sin_port))

    XCTAssertTrue(HelperLoopbackPortProbe.isAccepting(port: port, timeout: 0.5))
    close(descriptor)
    XCTAssertFalse(HelperLoopbackPortProbe.isAccepting(port: port, timeout: 0.5))
  }

  private func makePathFixture() throws -> PathFixture {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxHelperValidation-\(UUID().uuidString)", isDirectory: true)
    let appSupportRoot = tempRoot.appendingPathComponent("Application Support/ClashMax", isDirectory: true)
    let runtimeRoot = appSupportRoot.appendingPathComponent("Runtime", isDirectory: true)
    let bundledCoreRoot = tempRoot.appendingPathComponent("ClashMax.app/Contents/Resources/Core", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundledCoreRoot, withIntermediateDirectories: true)

    let configURL = runtimeRoot.appendingPathComponent("config.yaml")
    try "port: 7890\n".write(to: configURL, atomically: true, encoding: .utf8)

    let coreURL = bundledCoreRoot.appendingPathComponent("mihomo-darwin-arm64")
    try "#!/bin/sh\n".write(to: coreURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: coreURL.path)

    addTeardownBlock {
      try? FileManager.default.removeItem(at: tempRoot)
    }

    return PathFixture(
      tempRoot: tempRoot,
      appSupportRoot: appSupportRoot,
      runtimeRoot: runtimeRoot,
      bundledCoreRoot: bundledCoreRoot,
      coreURL: coreURL,
      configURL: configURL
    )
  }

  private func makeRuntimeFixture(
    rootComponent: String = "ClashMaxHelperRuntime-\(UUID().uuidString)",
    coreScript: String = """
    #!/bin/sh
    trap 'sleep 1; exit 0' TERM
    printf "%s:%s:%s\\n" "$$" "${CLASHMAX_HELPER:-0}" "${CLASHMAX_SECRET-unset}" > "$PWD/launch-state.txt"
    while true; do sleep 1; done
    """
  ) throws -> PathFixture {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent(rootComponent, isDirectory: true)
    let appSupportRoot = tempRoot.appendingPathComponent("Application Support/ClashMax", isDirectory: true)
    let runtimeRoot = appSupportRoot.appendingPathComponent("Runtime", isDirectory: true)
    let bundledCoreRoot = tempRoot.appendingPathComponent("ClashMax.app/Contents/Resources/Core", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bundledCoreRoot, withIntermediateDirectories: true)

    let configURL = runtimeRoot.appendingPathComponent("config.yaml")
    try "port: 7890\n".write(to: configURL, atomically: true, encoding: .utf8)

    let coreURL = bundledCoreRoot.appendingPathComponent("mihomo-darwin-arm64")
    try coreScript.write(to: coreURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: coreURL.path)

    addTeardownBlock {
      try? FileManager.default.removeItem(at: tempRoot)
    }

    return PathFixture(
      tempRoot: tempRoot,
      appSupportRoot: appSupportRoot,
      runtimeRoot: runtimeRoot,
      bundledCoreRoot: bundledCoreRoot,
      coreURL: coreURL,
      configURL: configURL
    )
  }

  private func makeHelperService(
    fixture: PathFixture,
    processDidLaunch: ((Process) -> Void)? = nil
  ) -> HelperService {
    HelperService(
      trustedPathsProvider: { _ in
        HelperTrustedPaths(runtimeRoot: fixture.runtimeRoot, bundledCoreRoot: fixture.bundledCoreRoot)
      },
      coreExecutableValidator: NoopHelperCoreExecutableValidator(),
      clientUserIDProvider: { getuid() },
      processTerminationTimeout: 2,
      processDidLaunch: processDidLaunch
    )
  }
}

private struct PathFixture {
  let tempRoot: URL
  let appSupportRoot: URL
  let runtimeRoot: URL
  let bundledCoreRoot: URL
  let coreURL: URL
  let configURL: URL
}

private final class ThreadSafeStringRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [String] = []

  var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return values.isEmpty
  }

  func append(_ value: String) {
    lock.lock()
    values.append(value)
    lock.unlock()
  }
}

private final class ThreadSafeIntRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [Int] = []

  var values: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func append(_ value: Int) {
    lock.lock()
    storage.append(value)
    lock.unlock()
  }

  func count(of value: Int) -> Int {
    lock.lock()
    defer { lock.unlock() }
    return storage.filter { $0 == value }.count
  }
}

private final class ThreadSafeStartResponseRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var results: [Result<(String, HelperClientResponse), Error>] = []

  var values: [Result<(String, HelperClientResponse), Error>] {
    lock.lock()
    defer { lock.unlock() }
    return results
  }

  func append(_ result: Result<(String, HelperClientResponse), Error>) {
    lock.lock()
    results.append(result)
    lock.unlock()
  }
}

private func start(_ service: HelperService, fixture: PathFixture, secret: String) throws -> HelperClientResponse {
  var payload: NSString?
  service.startTunnel(
    corePath: fixture.coreURL.path as NSString,
    configPath: fixture.configURL.path as NSString,
    workDirectoryPath: fixture.runtimeRoot.path as NSString,
    secret: secret as NSString
  ) { response in
    payload = response
  }
  return try HelperClientResponse(payload: XCTUnwrap(payload))
}

private func restart(_ service: HelperService, fixture: PathFixture, secret: String) throws -> HelperClientResponse {
  var payload: NSString?
  service.restartTunnel(
    corePath: fixture.coreURL.path as NSString,
    configPath: fixture.configURL.path as NSString,
    workDirectoryPath: fixture.runtimeRoot.path as NSString,
    secret: secret as NSString
  ) { response in
    payload = response
  }
  return try HelperClientResponse(payload: XCTUnwrap(payload))
}

private func stop(_ service: HelperService) {
  service.stopTunnel { _ in }
}

private func stopResponse(_ service: HelperService) throws -> HelperClientResponse {
  var payload: NSString?
  service.stopTunnel { response in
    payload = response
  }
  return try HelperClientResponse(payload: XCTUnwrap(payload))
}

private func waitForLaunchState(fixture: PathFixture, expected: String) throws -> String {
  let stateURL = fixture.runtimeRoot.appendingPathComponent("launch-state.txt")
  let deadline = Date().addingTimeInterval(3)
  var lastState = ""
  while Date() < deadline {
    if let state = try? String(contentsOf: stateURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !state.isEmpty
    {
      lastState = state
      if state == expected {
        return state
      }
    }
    Thread.sleep(forTimeInterval: 0.02)
  }
  if !lastState.isEmpty {
    return lastState
  }
  return try String(contentsOf: stateURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
  kill(pid, 0) == 0 || errno == EPERM
}

private func waitForProcessExit(_ process: Process) {
  let deadline = Date().addingTimeInterval(3)
  while process.isRunning, Date() < deadline {
    Thread.sleep(forTimeInterval: 0.02)
  }
}

private struct NoopHelperCoreExecutableValidator: HelperCoreExecutableValidating {
  func validateCoreExecutable(at url: URL) throws {}
}
