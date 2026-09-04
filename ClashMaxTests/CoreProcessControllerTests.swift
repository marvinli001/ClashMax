@testable import ClashMax
import Foundation
import XCTest

@MainActor
final class CoreProcessControllerTests: XCTestCase {
  func testStartTransitionsToRunningAndCrashUpdatesStatus() async throws {
    let launcher = FakeProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: FakePortChecker(listeners: [])
    )

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
      workDirectory: URL(fileURLWithPath: "/tmp"),
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    XCTAssertEqual(controller.status, .running(version: "v-test"))
    XCTAssertEqual(launcher.lastArguments, ["-f", "/tmp/config.yaml", "-d", "/tmp"])

    launcher.process.finish(exitCode: 2)
    XCTAssertEqual(controller.status, .crashed(message: "mihomo exited with code 2"))
  }

  func testCancellingStartWhileWaitingForReadinessStopsWithoutCrash() async throws {
    let launcher = FakeProcessLauncher()
    let readiness = CancellableCoreReadinessProbe()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: readiness,
      reaper: RecordingCoreProcessReaper(),
      portChecker: FakePortChecker(listeners: [])
    )
    let api = CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")

    let startTask = Task { @MainActor in
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: api
      )
    }

    await waitUntil { readiness.didStart }
    XCTAssertTrue(readiness.didStart)
    XCTAssertEqual(controller.status, .starting)

    startTask.cancel()
    await XCTAssertThrowsCancellationErrorAsync {
      try await startTask.value
    }

    XCTAssertTrue(launcher.process.didTerminate)
    XCTAssertEqual(controller.status, .stopped)
  }

  func testOrphanReaperMatchesOnlyClashMaxManagedMihomoCommands() {
    let coreURL = URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Resources/Core/mihomo-darwin-arm64")
    let configURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/Runtime/profile.runtime.yaml")
    let workDirectory = URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/Runtime")

    XCTAssertTrue(MihomoOrphanProcessReaper.isManagedCoreCommand(
      "/Applications/ClashMax.app/Contents/Resources/Core/mihomo-darwin-arm64 -f /Users/test/Library/Application Support/ClashMax/Runtime/profile.runtime.yaml -d /Users/test/Library/Application Support/ClashMax/Runtime",
      coreURL: coreURL,
      configURL: configURL,
      workDirectory: workDirectory
    ))
    XCTAssertTrue(MihomoOrphanProcessReaper.isManagedCoreCommand(
      "/old/ClashMax.app/Contents/Resources/Core/mihomo-darwin-arm64 -f /old/config.yaml -d /Users/test/Library/Application Support/ClashMax/Runtime",
      coreURL: coreURL,
      configURL: configURL,
      workDirectory: workDirectory
    ))
    XCTAssertFalse(MihomoOrphanProcessReaper.isManagedCoreCommand(
      "/usr/local/bin/mihomo -f /Users/test/other.yaml -d /tmp",
      coreURL: coreURL,
      configURL: configURL,
      workDirectory: workDirectory
    ))
    XCTAssertFalse(MihomoOrphanProcessReaper.isManagedCoreCommand(
      "/Applications/ClashMax.app/Contents/MacOS/ClashMax",
      coreURL: coreURL,
      configURL: configURL,
      workDirectory: workDirectory
    ))
  }

  func testOrphanReaperDoesNotEscalateWhenSigtermIsNotPermitted() async {
    let fixture = orphanReaperFixture(pid: 4242)
    let signalSpy = ReaperSignalSpy(mode: .denySIGTERM)
    let sleepSpy = ReaperSleepSpy()
    let eventRecorder = ReaperEventRecorder()
    let reaper = MihomoOrphanProcessReaper(
      processRowsProvider: {
        [(pid: fixture.pid, command: fixture.command)]
      },
      signalSender: { pid, signal in
        signalSpy.send(pid: pid, signal: signal)
      },
      sleeper: { nanoseconds in
        await sleepSpy.sleep(nanoseconds)
      },
      eventLogger: { message in
        eventRecorder.record(message)
      }
    )

    await reaper.reapOrphans(
      coreURL: fixture.coreURL,
      configURL: fixture.configURL,
      workDirectory: fixture.workDirectory
    )

    XCTAssertEqual(signalSpy.sentSignals(), [SIGTERM])
    XCTAssertTrue(eventRecorder.messages().contains { message in
      message.contains("EPERM")
        && message.contains("SIGTERM")
        && message.contains("Privileged helper fallback is not implemented")
    })
    let sleepCallCount = await sleepSpy.callCount()
    XCTAssertEqual(sleepCallCount, 0)
  }

  func testOrphanReaperDoesNotEscalateWhenAliveProbeIsNotPermitted() async {
    let fixture = orphanReaperFixture(pid: 4243)
    let signalSpy = ReaperSignalSpy(mode: .denyAliveProbe)
    let sleepSpy = ReaperSleepSpy()
    let eventRecorder = ReaperEventRecorder()
    let reaper = MihomoOrphanProcessReaper(
      processRowsProvider: {
        [(pid: fixture.pid, command: fixture.command)]
      },
      signalSender: { pid, signal in
        signalSpy.send(pid: pid, signal: signal)
      },
      sleeper: { nanoseconds in
        await sleepSpy.sleep(nanoseconds)
      },
      eventLogger: { message in
        eventRecorder.record(message)
      }
    )

    await reaper.reapOrphans(
      coreURL: fixture.coreURL,
      configURL: fixture.configURL,
      workDirectory: fixture.workDirectory
    )

    XCTAssertEqual(signalSpy.sentSignals(), [SIGTERM, 0, 0])
    XCTAssertFalse(signalSpy.didSend(SIGKILL))
    XCTAssertEqual(eventRecorder.messages().filter { $0.contains("EPERM") }.count, 2)
    XCTAssertTrue(eventRecorder.messages().allSatisfy { message in
      message.contains("signal probe")
        && message.contains("Privileged helper fallback is not implemented")
    })
    let sleepCallCount = await sleepSpy.callCount()
    XCTAssertEqual(sleepCallCount, 0)
  }

  func testOrphanReaperRevalidatesManagedCommandBeforeEscalatingToSIGKILL() async {
    let fixture = orphanReaperFixture(pid: 4244)
    let signalSpy = ReaperSignalSpy(mode: .allow)
    let rowsProvider = ReaperRowsProvider(rows: [
      [(pid: fixture.pid, command: fixture.command)],
      [(pid: fixture.pid, command: "/usr/bin/yes")],
    ])
    let reaper = MihomoOrphanProcessReaper(
      terminationGracePeriod: 0,
      processRowsProvider: {
        await rowsProvider.nextRows()
      },
      signalSender: { pid, signal in
        signalSpy.send(pid: pid, signal: signal)
      }
    )

    await reaper.reapOrphans(
      coreURL: fixture.coreURL,
      configURL: fixture.configURL,
      workDirectory: fixture.workDirectory
    )

    XCTAssertEqual(signalSpy.sentSignals(), [SIGTERM])
  }

  func testStaleProcessTerminationDoesNotOverwriteNewRunStatus() async throws {
    let firstProcess = FakeRunningProcess(processIdentifier: 100)
    let secondProcess = FakeRunningProcess(processIdentifier: 200)
    let launcher = SequencedProcessLauncher(processes: [firstProcess, secondProcess])
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: FakePortChecker(listeners: [])
    )

    let api = CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
      workDirectory: URL(fileURLWithPath: "/tmp"),
      api: api
    )
    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
      workDirectory: URL(fileURLWithPath: "/tmp"),
      api: api
    )

    firstProcess.finish(exitCode: 15)

    XCTAssertEqual(controller.status, .running(version: "v-test"))
    XCTAssertTrue(firstProcess.didTerminate)
  }

  func testStartUserModeWaitsForPreviousProcessTerminationBeforeRelaunching() async throws {
    let firstProcess = DeferredTerminationRunningProcess(processIdentifier: 100)
    let secondProcess = DeferredTerminationRunningProcess(processIdentifier: 200)
    let launcher = SequencedProcessLauncher(processes: [firstProcess, secondProcess])
    let portChecker = RecordingRuntimePortChecker()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: portChecker
    )
    let api = CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
      workDirectory: URL(fileURLWithPath: "/tmp"),
      api: api
    )
    XCTAssertEqual(launcher.launchCount, 1)
    let initialPortCheckCount = await portChecker.currentCallCount()
    XCTAssertEqual(initialPortCheckCount, 1)

    let secondStart = Task { @MainActor in
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: api
      )
    }

    for _ in 0..<20 where !firstProcess.didTerminate {
      await Task.yield()
      try? await Task.sleep(nanoseconds: 1_000_000)
    }

    XCTAssertTrue(firstProcess.didTerminate)
    XCTAssertEqual(launcher.launchCount, 1)
    let portCheckCountBeforeTermination = await portChecker.currentCallCount()
    XCTAssertEqual(portCheckCountBeforeTermination, 1)

    firstProcess.finish(exitCode: 15)
    try await secondStart.value

    XCTAssertEqual(launcher.launchCount, 2)
    let finalPortCheckCount = await portChecker.currentCallCount()
    XCTAssertEqual(finalPortCheckCount, 2)
    XCTAssertEqual(controller.status, .running(version: "v-test"))
  }

  func testStartFailsBeforeLaunchWhenControllerOrProxyPortIsOccupiedByExternalProcess() async throws {
    let launcher = FakeProcessLauncher()
    let portChecker = FakePortChecker(listeners: [
      PortListener(port: 9097, pid: 1234, command: "/opt/homebrew/bin/mihomo -f /tmp/other.yaml"),
      PortListener(port: 7890, pid: 4321, command: "/usr/local/bin/proxy"),
    ])
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: portChecker
    )

    do {
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Resources/Core/mihomo-darwin-arm64"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc"),
        proxyPort: 7890
      )
      XCTFail("Expected occupied port failure")
    } catch let error as AppError {
      guard case let .portUnavailable(message) = error else {
        XCTFail("Expected portUnavailable, got \(error)")
        return
      }
      XCTAssertTrue(message.contains("9097"))
      XCTAssertTrue(message.contains("pid 1234"))
      XCTAssertTrue(message.contains("/opt/homebrew/bin/mihomo"))
      XCTAssertTrue(message.contains("7890"))
      XCTAssertTrue(message.contains("pid 4321"))
    }

    XCTAssertEqual(launcher.lastArguments, [])
    XCTAssertTrue(controller.startupDiagnostics.contains { $0.contains("Port 9097 is occupied by pid 1234") })
  }

  func testReadinessFailureWithLiveCoreExplainsControllerBindFailure() async throws {
    // Issue #33: mihomo keeps running when it cannot bind its external
    // controller, so the readiness probe times out while the process is alive.
    let launcher = FakeProcessLauncher()
    launcher.process.stubbedOutputTail = """
    time="2026-09-04T22:03:14.680271000+12:00" level=info msg="Start initial configuration in progress"
    time="2026-09-04T22:03:14.681025000+12:00" level=error msg="External controller listen error: listen tcp 127.0.0.1:9097: bind: address already in use"
    time="2026-09-04T22:03:14.682439000+12:00" level=info msg="Mixed(http+socks) proxy listening at: 127.0.0.1:7890"
    """
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: FailingCoreReadinessProbe(
        message: "Could not connect to the Mihomo controller at 127.0.0.1:9097. The core may still be starting or failed to open its controller port."
      ),
      reaper: RecordingCoreProcessReaper(),
      portChecker: FakePortChecker(listeners: [])
    )

    do {
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc"),
        proxyPort: 7890
      )
      XCTFail("Expected readiness failure")
    } catch let error as AppError {
      guard case let .coreNotReady(message) = error else {
        XCTFail("Expected coreNotReady, got \(error)")
        return
      }
      XCTAssertTrue(message.contains("could not open its controller port 127.0.0.1:9097: address already in use"), message)
      XCTAssertTrue(message.contains("TUN mode"), message)

      let banner = UserFacingError.message(for: error)
      XCTAssertEqual(
        banner,
        "Mihomo controller did not become ready. Mihomo started but could not open its controller port 127.0.0.1:9097: address already in use. Another process, probably a root-owned Mihomo left behind by TUN mode, is holding it. Open Details for how to release it."
      )

      let details = try XCTUnwrap(UserFacingError.details(for: error))
      XCTAssertTrue(details.contains("Mihomo reported: External controller listen error: listen tcp 127.0.0.1:9097: bind: address already in use"), details)
      XCTAssertTrue(details.contains("sudo lsof -nP -iTCP:9097 -sTCP:LISTEN"), details)
      XCTAssertTrue(details.contains("Core output:"), details)
      XCTAssertTrue(details.contains("Mixed(http+socks) proxy listening at: 127.0.0.1:7890"), details)
      XCTAssertFalse(details.contains("---"), details)
    }

    XCTAssertTrue(launcher.process.didTerminate)
    XCTAssertTrue(controller.startupDiagnostics.contains { $0.hasPrefix("Readiness failed: Mihomo started but could not open its controller port") })
  }

  func testReadinessFailureWithoutBindErrorKeepsGenericMessage() async throws {
    let launcher = FakeProcessLauncher()
    launcher.process.stubbedOutputTail = "level=info msg=\"Start initial configuration in progress\""
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: FailingCoreReadinessProbe(message: "Could not connect to the Mihomo controller at 127.0.0.1:9097."),
      reaper: RecordingCoreProcessReaper(),
      portChecker: FakePortChecker(listeners: [])
    )

    do {
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
      )
      XCTFail("Expected readiness failure")
    } catch let error as AppError {
      guard case let .coreNotReady(message) = error else {
        XCTFail("Expected coreNotReady, got \(error)")
        return
      }
      XCTAssertTrue(message.hasPrefix("Could not connect to the Mihomo controller at 127.0.0.1:9097."), message)
      XCTAssertEqual(
        UserFacingError.message(for: error),
        "Mihomo controller did not become ready. Could not connect to the Mihomo controller at 127.0.0.1:9097."
      )
      XCTAssertEqual(
        UserFacingError.details(for: error),
        "Core output:\nlevel=info msg=\"Start initial configuration in progress\""
      )
    }
  }

  func testStartFailsWhenPortIsHeldByListenerLsofCannotIdentify() async throws {
    let launcher = FakeProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: FakePortChecker(listeners: [.unidentified(port: 9097)])
    )

    do {
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc"),
        proxyPort: 7890
      )
      XCTFail("Expected occupied port failure")
    } catch let error as AppError {
      guard case let .portUnavailable(message) = error else {
        XCTFail("Expected portUnavailable, got \(error)")
        return
      }
      XCTAssertEqual(
        UserFacingError.message(for: error),
        "Cannot start Mihomo because required runtime ports are already in use: port 9097 is held by a process this account cannot inspect, probably a root-owned Mihomo left behind by TUN mode. Open Details for how to release it."
      )
      let details = try XCTUnwrap(UserFacingError.details(for: error))
      XCTAssertTrue(details.hasPrefix("To release port 9097:"), details)
      XCTAssertTrue(details.contains("sudo lsof -nP -iTCP:9097 -sTCP:LISTEN"), details)
      XCTAssertTrue(details.contains("Switch back to TUN mode and click Stop"), details)
      XCTAssertFalse(UserFacingError.message(for: error).contains("pid "), "no fake pid for a listener lsof cannot see: \(message)")
    }

    XCTAssertEqual(launcher.lastArguments, [])
    XCTAssertTrue(controller.startupDiagnostics.contains { $0.hasPrefix("Port 9097 accepts TCP connections but lsof lists no owner") })
  }

  func testPortConflictMessageWithIdentifiedProcessesKeepsTheShortForm() {
    let message = CoreProcessController.portConflictMessage(for: [
      PortListener(port: 9097, pid: 1234, command: "/opt/homebrew/bin/mihomo"),
    ])

    XCTAssertEqual(
      message,
      "Cannot start Mihomo because required runtime ports are already in use: port 9097 is used by pid 1234 (/opt/homebrew/bin/mihomo). Quit the conflicting process or change ClashMax's controller/mixed port settings."
    )
    XCTAssertNil(UserFacingError.details(for: AppError.portUnavailable(message)))
  }

  func testRuntimePortCheckerFallsBackToConnectProbeWhenLsofSeesNothing() async {
    let checker = MihomoRuntimePortChecker(
      lookupListeners: { port in
        port == 7890 ? [PortListener(port: 7890, pid: 4321, command: "/usr/local/bin/proxy")] : []
      },
      acceptsConnections: { port in port == 9097 || port == 7890 }
    )

    let listeners = await checker.listeners(on: [9097, 7890, 1053])

    XCTAssertEqual(listeners, [
      .unidentified(port: 9097),
      PortListener(port: 7890, pid: 4321, command: "/usr/local/bin/proxy"),
    ])
  }

  func testIsAcceptingConnectionsSeesARealListenerAndNotAClosedPort() throws {
    let (descriptor, port) = try Self.openLoopbackListener()
    XCTAssertTrue(SocksProxyReadinessProbe.isAcceptingConnections(host: "127.0.0.1", port: port, timeout: 0.5))
    close(descriptor)
    XCTAssertFalse(SocksProxyReadinessProbe.isAcceptingConnections(host: "127.0.0.1", port: port, timeout: 0.5))
  }

  func testRealRuntimePortCheckerIdentifiesThisProcessThroughLsofAndReportsNothingForAFreePort() async throws {
    let (descriptor, port) = try Self.openLoopbackListener()
    defer { close(descriptor) }
    let checker = MihomoRuntimePortChecker()

    let listeners = await checker.listeners(on: [port])

    XCTAssertEqual(listeners.count, 1, "\(listeners)")
    XCTAssertEqual(listeners.first?.port, port)
    XCTAssertEqual(listeners.first?.pid, getpid(), "our own listener is visible to lsof, so it must not be reported as unidentified")
    XCTAssertFalse(listeners.first?.isUnidentified ?? true)

    close(descriptor)
    let afterClose = await checker.listeners(on: [port])
    XCTAssertEqual(afterClose, [])
  }

  private static func openLoopbackListener() throws -> (descriptor: Int32, port: Int) {
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
    let nameResult = withUnsafeMutablePointer(to: &bound) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    XCTAssertEqual(nameResult, 0)
    let port = Int(UInt16(bigEndian: bound.sin_port))
    XCTAssertGreaterThan(port, 0)
    return (descriptor, port)
  }

  func testProcessExitBeforeTerminationHandlerIsInstalledFailsStartupImmediately() async throws {
    let process = AlreadyTerminatedRunningProcess(exitCode: 7, outputTail: "fatal: bind failed")
    let controller = CoreProcessController(
      launcher: SingleProcessLauncher(process: process),
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: CancellableCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper(),
      portChecker: FakePortChecker(listeners: [])
    )

    do {
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
      )
      XCTFail("Expected early core termination to fail startup.")
    } catch let error as AppError {
      guard case let .coreNotReady(message) = error else {
        XCTFail("Expected coreNotReady, got \(error)")
        return
      }
      XCTAssertTrue(message.contains("mihomo exited with code 7"))
      XCTAssertTrue(message.contains("fatal: bind failed"))
    }

    XCTAssertEqual(controller.status, .crashed(message: "mihomo exited with code 7\nfatal: bind failed"))
  }

  /// Polls a condition in wall-clock time, which a `Task.yield()` spin cannot do.
  ///
  /// The launcher's termination chain parks in `LiveOutputDrain.waitForOutputEnd`, sleeping in 1ms
  /// steps until a Dispatch-driven pipe EOF arrives. Yielding only reschedules the current task, so
  /// a yield-spin completes in microseconds with the chain no further along. The budget has to clear
  /// that drain wait (1s by default) plus CI contention.
  private func waitUntil(
    _ isSatisfied: () -> Bool,
    timeout: TimeInterval = 5
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !isSatisfied(), Date() < deadline {
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
  }

  func testFoundationRunningProcessDeliversTerminationWhenHandlerIsInstalledAfterExit() async throws {
    let launcher = FoundationProcessLauncher()
    let process = try launcher.launch(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 7"],
      environment: [:],
      workDirectory: URL(fileURLWithPath: "/tmp")
    )

    // Wait on the observable fact — the child is gone — instead of guessing how long the exit takes.
    await waitUntil { !process.isRunning }

    var receivedExitCode: Int32?
    process.onTermination = { exitCode in
      receivedExitCode = exitCode
    }

    // Whether this lands via the cached branch or the live one depends on whether the drain wait has
    // finished, which is not observable from here. Assert the outcome both branches owe us; the
    // cached branch itself is pinned deterministically by the two synthetic tests below.
    await waitUntil { receivedExitCode != nil }

    XCTAssertEqual(receivedExitCode, 7)
  }

  func testFoundationRunningProcessClearsHandlersAfterTerminationNotification() throws {
    let process = Process()
    let pipe = Pipe()
    let drain = LiveOutputDrain()
    process.standardOutput = pipe
    process.standardError = pipe
    process.terminationHandler = { _ in }
    drain.attach(pipe.fileHandleForReading)
    let runningProcess = FoundationRunningProcess(process: process, drain: drain)
    var receivedExitCode: Int32?
    runningProcess.onTermination = { exitCode in
      receivedExitCode = exitCode
    }

    runningProcess.notifyTermination(exitCode: 9)

    XCTAssertEqual(receivedExitCode, 9)
    XCTAssertNil(process.terminationHandler)
    XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
  }

  func testFoundationRunningProcessClearsHandlersAfterLateTerminationHandlerReceivesCachedExit() throws {
    let process = Process()
    let pipe = Pipe()
    let drain = LiveOutputDrain()
    process.standardOutput = pipe
    process.standardError = pipe
    process.terminationHandler = { _ in }
    drain.attach(pipe.fileHandleForReading)
    let runningProcess = FoundationRunningProcess(process: process, drain: drain)

    runningProcess.notifyTermination(exitCode: 10)
    XCTAssertNil(process.terminationHandler)
    XCTAssertNotNil(pipe.fileHandleForReading.readabilityHandler)

    var receivedExitCode: Int32?
    runningProcess.onTermination = { exitCode in
      receivedExitCode = exitCode
    }

    XCTAssertEqual(receivedExitCode, 10)
    XCTAssertNil(pipe.fileHandleForReading.readabilityHandler)
  }

  func testSanitizedDrainRedactsSecretsThatStraddleChunkBoundaries() {
    let drain = LiveOutputDrain(sanitized: true, homeDirectory: "/Users/tester")

    drain.append(Data("level=info msg=\"loading sub".utf8), stream: .stdout)
    drain.append(Data("scription https://feed.example.com/link?token=abc123\"\n".utf8), stream: .stdout)

    let tail = drain.tail(maxBytes: 4_096)
    XCTAssertFalse(tail.contains("abc123"), tail)
    XCTAssertFalse(tail.contains("/link"), tail)
    XCTAssertTrue(tail.contains("https://feed.example.com"), tail)
    XCTAssertTrue(tail.contains("loading subscription"), tail)
  }

  func testSanitizedDrainKeepsStdoutAndStderrLinesDistinctAndInOrder() {
    let recorder = OutputLineRecorder()
    let drain = LiveOutputDrain(sanitized: true) { [recorder] line in
      recorder.record(line)
    }

    drain.append(Data("starting core\n".utf8), stream: .stdout)
    drain.append(Data("bind failed\n".utf8), stream: .stderr)

    let snapshot = recorder.lines
    XCTAssertEqual(snapshot.map(\.stream), [.stdout, .stderr])
    XCTAssertEqual(snapshot.map(\.text), ["starting core", "bind failed"])
    XCTAssertEqual(drain.retainedLines().map(\.stream), [.stdout, .stderr])
  }

  func testSanitizedDrainRedactsHomePathsAndProfileNamesBeforeRetention() {
    let drain = LiveOutputDrain(sanitized: true, homeDirectory: "/Users/tester")

    drain.append(
      Data("cfg /Users/tester/Library/Application Support/ClashMax/my-subscription.yaml\n".utf8),
      stream: .stderr
    )

    let tail = drain.tail(maxBytes: 4_096)
    XCTAssertFalse(tail.contains("/Users/tester"), tail)
    XCTAssertFalse(tail.contains("my-subscription"), tail)
    XCTAssertTrue(tail.contains("~/Library/Application Support/ClashMax/<redacted>.yaml"), tail)
  }

  func testSanitizedDrainTruncatesAnEndlessLineAndCountsIt() {
    let drain = LiveOutputDrain(sanitized: true, maximumLineBytes: 4_096)

    drain.append(Data(String(repeating: "a", count: 32_768).utf8), stream: .stdout)

    XCTAssertEqual(drain.truncatedLineCount, 1)
    let tail = drain.tail(maxBytes: 65_536)
    XCTAssertTrue(tail.hasSuffix(SanitizedLineAccumulator.truncationMarker), String(tail.suffix(40)))
    XCTAssertLessThanOrEqual(
      tail.utf8.count,
      4_096 + SanitizedLineAccumulator.truncationMarker.utf8.count
    )
  }

  func testSanitizedDrainTailIncludesThePendingLineWithoutConsumingIt() {
    let drain = LiveOutputDrain(sanitized: true)

    drain.append(Data("first\nfatal: no route".utf8), stream: .stdout)

    XCTAssertTrue(drain.tail(maxBytes: 4_096).contains("fatal: no route"))
    XCTAssertTrue(drain.tail(maxBytes: 4_096).contains("fatal: no route"))
  }

  func testSanitizedDrainDropsOldestLinesWhenTheRetentionBudgetIsExceeded() {
    let drain = LiveOutputDrain(maxRetainedBytes: 24, sanitized: true)

    for index in 0..<20 {
      drain.append(Data("line-\(index)\n".utf8), stream: .stdout)
    }

    let retained = drain.retainedLines()
    XCTAssertLessThanOrEqual(retained.reduce(0) { $0 + $1.text.utf8.count }, 24)
    XCTAssertEqual(retained.last?.text, "line-19")
    XCTAssertFalse(drain.tail(maxBytes: 4_096).contains("line-0\n"))
  }

  func testRawDrainStillReturnsProcessOutputByteForByte() {
    let drain = LiveOutputDrain(maxRetainedBytes: nil)

    drain.append(Data("token=abc123 /Users/tester/profile.yaml\n".utf8), stream: .stdout)

    XCTAssertEqual(drain.flush(trimmed: false), "token=abc123 /Users/tester/profile.yaml\n")
  }

  private func orphanReaperFixture(pid: Int32) -> (
    pid: Int32,
    coreURL: URL,
    configURL: URL,
    workDirectory: URL,
    command: String
  ) {
    let coreURL = URL(fileURLWithPath: "/Applications/ClashMax.app/Contents/Resources/Core/mihomo-darwin-arm64")
    let configURL = URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/Runtime/profile.runtime.yaml")
    let workDirectory = URL(fileURLWithPath: "/Users/test/Library/Application Support/ClashMax/Runtime")
    let command = "\(coreURL.path) -f \(configURL.path) -d \(workDirectory.path)"
    return (pid, coreURL, configURL, workDirectory, command)
  }
}

private final class OutputLineRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [ProcessOutputLine] = []

  var lines: [ProcessOutputLine] {
    lock.lock()
    defer { lock.unlock() }
    return storage
  }

  func record(_ line: ProcessOutputLine) {
    lock.lock()
    storage.append(line)
    lock.unlock()
  }
}

private final class ReaperSignalSpy: @unchecked Sendable {
  enum Mode {
    case allow
    case denySIGTERM
    case denyAliveProbe
  }

  private let mode: Mode
  private let lock = NSLock()
  private var calls: [Int32] = []

  init(mode: Mode) {
    self.mode = mode
  }

  func send(pid: Int32, signal: Int32) -> ProcessSignalResult {
    lock.withLock {
      calls.append(signal)
    }

    switch (mode, signal) {
    case (.denySIGTERM, SIGTERM), (.denyAliveProbe, 0):
      return ProcessSignalResult(returnCode: -1, errnoCode: EPERM)
    default:
      return .success
    }
  }

  func sentSignals() -> [Int32] {
    lock.withLock {
      calls
    }
  }

  func didSend(_ signal: Int32) -> Bool {
    lock.withLock {
      calls.contains(signal)
    }
  }
}

private final class ReaperEventRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedMessages: [String] = []

  func record(_ message: String) {
    lock.withLock {
      recordedMessages.append(message)
    }
  }

  func messages() -> [String] {
    lock.withLock {
      recordedMessages
    }
  }
}

private actor ReaperRowsProvider {
  private var rows: [[(pid: Int32, command: String)]]

  init(rows: [[(pid: Int32, command: String)]]) {
    self.rows = rows
  }

  func nextRows() -> [(pid: Int32, command: String)] {
    guard rows.count > 1 else {
      return rows.first ?? []
    }
    return rows.removeFirst()
  }
}

private actor ReaperSleepSpy {
  private var calls: [UInt64] = []

  func sleep(_ nanoseconds: UInt64) {
    calls.append(nanoseconds)
  }

  func callCount() -> Int {
    calls.count
  }
}

@MainActor
private final class SequencedProcessLauncher: CoreProcessLaunching {
  private var processes: [RunningCoreProcess]
  private(set) var launchCount = 0

  init(processes: [RunningCoreProcess]) {
    self.processes = processes
  }

  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    launchCount += 1
    return processes.removeFirst()
  }
}

private actor RecordingRuntimePortChecker: RuntimePortChecking {
  private(set) var callCount = 0

  func listeners(on ports: [Int]) async -> [PortListener] {
    callCount += 1
    return []
  }

  func currentCallCount() -> Int {
    callCount
  }
}

@MainActor
private final class CancellableCoreReadinessProbe: CoreReadinessProbing {
  private(set) var didStart = false

  func waitUntilReady(api: CoreAPIEndpoint) async throws -> String {
    didStart = true
    try await Task.sleep(nanoseconds: 10_000_000_000)
    return "v-test"
  }
}

@MainActor
private final class FailingCoreReadinessProbe: CoreReadinessProbing {
  private let message: String

  init(message: String) {
    self.message = message
  }

  func waitUntilReady(api: CoreAPIEndpoint) async throws -> String {
    throw AppError.coreNotReady(message)
  }
}

private struct FakePortChecker: RuntimePortChecking {
  let listeners: [PortListener]

  func listeners(on ports: [Int]) async -> [PortListener] {
    listeners.filter { ports.contains($0.port) }
  }
}

@MainActor
private final class SingleProcessLauncher: CoreProcessLaunching {
  private let process: RunningCoreProcess

  init(process: RunningCoreProcess) {
    self.process = process
  }

  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    process
  }
}

@MainActor
private final class AlreadyTerminatedRunningProcess: RunningCoreProcess {
  let processIdentifier: Int32 = 777
  let isRunning = false
  private let exitCode: Int32
  private let outputTail: String

  init(exitCode: Int32, outputTail: String) {
    self.exitCode = exitCode
    self.outputTail = outputTail
  }

  var onTermination: ((Int32) -> Void)? {
    didSet {
      onTermination?(exitCode)
    }
  }

  func terminate() {}

  func kill() {}

  func recentOutputTail(maxBytes: Int) -> String {
    outputTail
  }
}

@MainActor
private final class DeferredTerminationRunningProcess: RunningCoreProcess {
  let processIdentifier: Int32
  var onTermination: ((Int32) -> Void)?
  private(set) var didTerminate = false
  private(set) var didKill = false
  private(set) var isRunning = true

  init(processIdentifier: Int32) {
    self.processIdentifier = processIdentifier
  }

  func terminate() {
    didTerminate = true
  }

  func kill() {
    didKill = true
  }

  func finish(exitCode: Int32) {
    isRunning = false
    onTermination?(exitCode)
  }

  func recentOutputTail(maxBytes: Int) -> String {
    ""
  }
}
