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
