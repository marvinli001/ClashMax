import XCTest
@testable import ClashMax

@MainActor
final class CoreProcessControllerTests: XCTestCase {
  func testStartTransitionsToRunningAndCrashUpdatesStatus() async throws {
    let launcher = FakeProcessLauncher()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper()
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

    for _ in 0..<20 where !readiness.didStart {
      await Task.yield()
    }
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

  func testStaleProcessTerminationDoesNotOverwriteNewRunStatus() async throws {
    let firstProcess = FakeRunningProcess(processIdentifier: 100)
    let secondProcess = FakeRunningProcess(processIdentifier: 200)
    let launcher = SequencedProcessLauncher(processes: [firstProcess, secondProcess])
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: RecordingCoreReadinessProbe(),
      reaper: RecordingCoreProcessReaper()
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

  func testStartFailsBeforeLaunchWhenControllerOrProxyPortIsOccupiedByExternalProcess() async throws {
    let launcher = FakeProcessLauncher()
    let portChecker = FakePortChecker(listeners: [
      PortListener(port: 9097, pid: 1234, command: "/opt/homebrew/bin/mihomo -f /tmp/other.yaml"),
      PortListener(port: 7890, pid: 4321, command: "/usr/local/bin/proxy")
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

  func testFoundationRunningProcessDeliversCachedTerminationWhenHandlerIsInstalledLate() async throws {
    let launcher = FoundationProcessLauncher()
    let process = try launcher.launch(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "exit 7"],
      environment: [:],
      workDirectory: URL(fileURLWithPath: "/tmp")
    )
    try await Task.sleep(nanoseconds: 100_000_000)

    var receivedExitCode: Int32?
    process.onTermination = { exitCode in
      receivedExitCode = exitCode
    }

    for _ in 0..<20 where receivedExitCode == nil {
      await Task.yield()
    }

    XCTAssertEqual(receivedExitCode, 7)
  }
}

@MainActor
private final class SequencedProcessLauncher: CoreProcessLaunching {
  private var processes: [FakeRunningProcess]

  init(processes: [FakeRunningProcess]) {
    self.processes = processes
  }

  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    processes.removeFirst()
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

  func recentOutputTail(maxBytes: Int) -> String {
    outputTail
  }
}
