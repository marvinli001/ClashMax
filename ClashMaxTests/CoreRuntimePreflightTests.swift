import Foundation
import XCTest
@testable import ClashMax

@MainActor
final class CoreRuntimePreflightTests: XCTestCase {
  func testBundledMihomoAcceptsAdvancedProviderRuntimeMaterialization() async throws {
    guard let coreURL = Self.bundledCoreURL() else {
      throw XCTSkip("Bundled Mihomo core is unavailable in Resources/Core.")
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxAdvancedRuntime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let providerURL = directory.appendingPathComponent("provider.txt")
    try "ss://YWVzLTEyOC1nY206cGFzc3dvcmQ@127.0.0.1:8388#HK%20Node\n"
      .write(to: providerURL, atomically: true, encoding: .utf8)

    let source = """
    proxy-providers:
      BaseProvider: &baseProvider
        type: file
        path: ./provider.txt
        interval: 3600
        filter: "HK|JP"
        exclude-filter: "expired"
        exclude-type: "direct"
        override:
          udp: true
          additional-prefix: "[Remote] "
        health-check:
          enable: false
      Remote:
        <<: *baseProvider
    proxy-groups:
      - name: Proxy
        type: select
        use: [Remote]
        proxies: [DIRECT]
    rules:
      - MATCH,Proxy
    """

    let runtimeYAML = try ConfigNormalizer().runtimeConfig(
      from: source,
      overrides: .defaultForLaunch(secret: "secret-token")
    )
    let configURL = directory.appendingPathComponent("runtime.yaml")
    try runtimeYAML.write(to: configURL, atomically: true, encoding: .utf8)

    let validator = MihomoRuntimeConfigValidator(timeout: 10)
    try await validator.validate(coreURL: coreURL, configURL: configURL, workDirectory: directory)
  }

  func testGeneratedRuntimeConfigIsValidatedBeforeLaunch() async throws {
    let launcher = FakeProcessLauncher()
    let validator = RecordingRuntimeConfigValidator(result: .failure(AppError.configValidationFailed("bad config")))
    let reaper = RecordingCoreProcessReaper()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: validator,
      reaper: reaper,
      portChecker: EmptyRuntimePortChecker()
    )

    await XCTAssertThrowsErrorAsync {
      try await controller.startUserMode(
        coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
        configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
        workDirectory: URL(fileURLWithPath: "/tmp"),
        api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
      )
    }

    XCTAssertTrue(validator.didValidate)
    XCTAssertFalse(reaper.didReap)
    XCTAssertTrue(launcher.lastArguments.isEmpty)
    XCTAssertEqual(controller.status, .crashed(message: "bad config"))
  }

  func testStartWaitsForControllerReadinessBeforeRunning() async throws {
    let launcher = FakeProcessLauncher()
    let readiness = RecordingCoreReadinessProbe()
    let reaper = RecordingCoreProcessReaper()
    let controller = CoreProcessController(
      launcher: launcher,
      validator: RecordingRuntimeConfigValidator(result: .success(())),
      readinessProbe: readiness,
      reaper: reaper,
      portChecker: EmptyRuntimePortChecker()
    )

    try await controller.startUserMode(
      coreURL: URL(fileURLWithPath: "/tmp/mihomo"),
      configURL: URL(fileURLWithPath: "/tmp/config.yaml"),
      workDirectory: URL(fileURLWithPath: "/tmp"),
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc")
    )

    XCTAssertEqual(readiness.checkedEndpoint, CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc"))
    XCTAssertEqual(reaper.reapedConfigURL, URL(fileURLWithPath: "/tmp/config.yaml"))
    XCTAssertEqual(reaper.reapedWorkDirectory, URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(controller.status, .running(version: "v-test"))
  }

  func testReadinessProbeUsesShortVersionRequestTimeout() async throws {
    let recorder = URLProtocolRecorder(responseBody: #"{"version":"v-ready"}"#)
    let session = URLSession(configuration: recorder.configuration)
    let probe = MihomoCoreReadinessProbe(
      attempts: 1,
      delayNanoseconds: 0,
      requestTimeout: 0.5,
      session: session
    )

    let version = try await probe.waitUntilReady(api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "abc"))

    XCTAssertEqual(version, "v-ready")
    let request = try XCTUnwrap(recorder.lastRequest)
    XCTAssertEqual(request.timeoutInterval, 0.5, accuracy: 0.01)
  }

  func testRuntimeConfigValidationTimesOutHangingCoreTestMode() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxValidatorTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hangingCore = directory.appendingPathComponent("mihomo-hang")
    let configURL = directory.appendingPathComponent("config.yaml")
    let pidURL = directory.appendingPathComponent("pid.txt")
    try """
    #!/bin/sh
    printf "%s\\n" "$$" > "\(pidURL.path)"
    exec sleep 30
    """.write(to: hangingCore, atomically: true, encoding: .utf8)
    try "mixed-port: 7890\n".write(to: configURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hangingCore.path)

    let validator = MihomoRuntimeConfigValidator(timeout: 1)
    let startedAt = Date()
    let task = Task {
      try await validator.validate(coreURL: hangingCore, configURL: configURL, workDirectory: directory)
    }
    let pid = try await waitForRecordedPID(at: pidURL)
    defer { terminateTestProcessIfNeeded(pid) }

    do {
      try await task.value
      XCTFail("Expected runtime config validation to time out.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("timed out"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    let didExit = await waitForProcessExit(pid, timeout: 1)
    XCTAssertTrue(didExit)
  }

  func testRuntimeConfigValidationTerminatesCoreTestModeWhenCancelled() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxValidatorCancel-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let hangingCore = directory.appendingPathComponent("mihomo-cancel")
    let configURL = directory.appendingPathComponent("config.yaml")
    let pidURL = directory.appendingPathComponent("pid.txt")
    try """
    #!/bin/sh
    printf "%s\\n" "$$" > "\(pidURL.path)"
    exec sleep 30
    """.write(to: hangingCore, atomically: true, encoding: .utf8)
    try "mixed-port: 7890\n".write(to: configURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hangingCore.path)

    let validator = MihomoRuntimeConfigValidator(timeout: 10)
    let task = Task {
      try await validator.validate(coreURL: hangingCore, configURL: configURL, workDirectory: directory)
    }
    let pid = try await waitForRecordedPID(at: pidURL)
    defer { terminateTestProcessIfNeeded(pid) }

    task.cancel()

    do {
      _ = try await withTimeout(seconds: 1) {
        try await task.value
      }
      XCTFail("Expected runtime config validation cancellation.")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }
    let didExit = await waitForProcessExit(pid, timeout: 1)
    XCTAssertTrue(didExit)
  }

  private static func bundledCoreURL() -> URL? {
    let architecture: String
    #if arch(arm64)
      architecture = "arm64"
    #elseif arch(x86_64)
      architecture = "amd64"
    #else
      return nil
    #endif

    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let coreURL = repositoryRoot
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("Core", isDirectory: true)
      .appendingPathComponent("mihomo-darwin-\(architecture)")
    return FileManager.default.isExecutableFile(atPath: coreURL.path) ? coreURL : nil
  }
}

private struct EmptyRuntimePortChecker: RuntimePortChecking {
  func listeners(on ports: [Int]) async -> [PortListener] {
    []
  }
}

final class RecordingRuntimeConfigValidator: RuntimeConfigValidating {
  let result: Result<Void, Error>
  private(set) var didValidate = false

  init(result: Result<Void, Error>) {
    self.result = result
  }

  func validate(coreURL: URL, configURL: URL, workDirectory: URL) async throws {
    didValidate = true
    try result.get()
  }
}

final class RecordingCoreReadinessProbe: CoreReadinessProbing {
  private(set) var checkedEndpoint: CoreAPIEndpoint?

  func waitUntilReady(api: CoreAPIEndpoint) async throws -> String {
    checkedEndpoint = api
    return "v-test"
  }
}

@MainActor
final class RecordingCoreProcessReaper: CoreProcessReaping {
  private(set) var didReap = false
  private(set) var reapedCoreURL: URL?
  private(set) var reapedConfigURL: URL?
  private(set) var reapedWorkDirectory: URL?

  func reapOrphans(coreURL: URL, configURL: URL, workDirectory: URL) async {
    didReap = true
    reapedCoreURL = coreURL
    reapedConfigURL = configURL
    reapedWorkDirectory = workDirectory
  }
}

private func waitForRecordedPID(at url: URL, timeout: TimeInterval = 1) async throws -> pid_t {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if let text = try? String(contentsOf: url, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines),
      let pid = pid_t(text),
      pid > 1 {
      return pid
    }
    try await Task.sleep(nanoseconds: 20_000_000)
  }
  throw NSError(
    domain: "ClashMaxTests.ProcessPID",
    code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for process PID at \(url.path)."]
  )
}

private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if !isProcessAlive(pid) {
      return true
    }
    try? await Task.sleep(nanoseconds: 20_000_000)
  }
  return !isProcessAlive(pid)
}

private func terminateTestProcessIfNeeded(_ pid: pid_t) {
  guard pid > 1 else { return }
  guard isProcessAlive(pid) else { return }
  kill(pid, SIGTERM)
  let deadline = Date().addingTimeInterval(1)
  while Date() < deadline && isProcessAlive(pid) {
    usleep(20_000)
  }
  if isProcessAlive(pid) {
    kill(pid, SIGKILL)
  }
}

private func isProcessAlive(_ pid: pid_t) -> Bool {
  guard pid > 1 else { return false }
  return kill(pid, 0) == 0 || errno == EPERM
}
