@testable import ClashMax
import Foundation
import XCTest

@MainActor
final class CoreRuntimePreflightTests: XCTestCase {
  func testRuntimeConfigValidatorDefaultTimeoutAllowsSlowMihomoInitialization() {
    let validator = MihomoRuntimeConfigValidator()

    XCTAssertEqual(validator.timeout, 30)
  }

  // A self-contained Clash config (inline direct proxy) so materialization needs
  // no network and never touches the real subscription sample.
  private static let syntheticPreflightClashConfig = """
  proxies:
    - name: DIRECT-NODE
      type: direct
  proxy-groups:
    - name: Proxy
      type: select
      proxies: [DIRECT-NODE, DIRECT]
  rules:
    - MATCH,Proxy
  """

  func testSubscriptionPreflightValidatesAgainstPersistentRuntimeDirectoryForGeodataReuse() async throws {
    let fixture = try PreflightPathsFixture()
    let recordingValidator = RecordingRuntimeConfigValidator(result: .success(()))
    let validator = MihomoSubscriptionProfilePreflightValidator(
      paths: fixture.paths,
      overrides: .defaultForLaunch(secret: "secret-token"),
      coreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") },
      runtimeConfigValidator: recordingValidator
    )

    try await validator.validate(
      subscriptionSource: Self.syntheticPreflightClashConfig,
      profileID: nil,
      profileName: "Preflight Test",
      providerOptions: .default
    )

    // Mihomo's geodata cache (GeoSite.dat / geoip.metadb) is downloaded into its
    // `-d` working directory. That must be the persistent Runtime dir so the cache
    // survives and is reused across imports — not the per-run preflight subdir,
    // which is deleted as soon as validation returns.
    XCTAssertEqual(recordingValidator.validatedWorkDirectory, fixture.paths.runtime)
  }

  func testSubscriptionPreflightKeepsArtifactsInDeletableSubdirectoryThatIsCleanedUp() async throws {
    let fixture = try PreflightPathsFixture()
    let recordingValidator = RecordingRuntimeConfigValidator(result: .success(()))
    let validator = MihomoSubscriptionProfilePreflightValidator(
      paths: fixture.paths,
      overrides: .defaultForLaunch(secret: "secret-token"),
      coreURLProvider: { URL(fileURLWithPath: "/tmp/mihomo") },
      runtimeConfigValidator: recordingValidator
    )

    try await validator.validate(
      subscriptionSource: Self.syntheticPreflightClashConfig,
      profileID: nil,
      profileName: "Preflight Test",
      providerOptions: .default
    )

    let configURL = try XCTUnwrap(recordingValidator.validatedConfigURL)
    let artifactDirectory = configURL.deletingLastPathComponent()

    // The generated runtime YAML (and any provider artifact) stays isolated in a
    // per-run `subscription-preflight-*` subdir of the persistent Runtime dir...
    XCTAssertEqual(
      artifactDirectory.deletingLastPathComponent().standardizedFileURL.path,
      fixture.paths.runtime.standardizedFileURL.path
    )
    XCTAssertTrue(artifactDirectory.lastPathComponent.hasPrefix("subscription-preflight-"))

    // ...which is removed once preflight completes, while the persistent Runtime
    // dir (home of the reusable geodata cache) survives.
    XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.runtime.path))
  }

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

    // Generous timeout: validation finishes in ~0.15s in isolation, but spawning the
    // bundled core can exceed 10s under full-suite CPU load. The timeout only guards
    // against a hung process; the assertion is that validation succeeds.
    let validator = MihomoRuntimeConfigValidator(timeout: 30)
    try await validator.validate(coreURL: coreURL, configURL: configURL, workDirectory: directory)
  }

  func testBundledMihomoAcceptsGeneratedManualSOCKS5Profile() async throws {
    guard let coreURL = Self.bundledCoreURL() else {
      throw XCTSkip("Bundled Mihomo core is unavailable in Resources/Core.")
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxManualOutboundPreflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "Manual SOCKS",
        kind: .socks5,
        host: "127.0.0.1",
        port: 10_880,
        authentication: OutboundProxyAuthentication(username: "manual-user"),
        socks5Options: OutboundProxySOCKS5Options(udpEnabled: true)
      ),
      password: "manual-runtime-secret"
    )
    let runtimeYAML = try ConfigNormalizer().runtimeConfig(
      from: "This source must not be parsed for a manual profile.",
      overrides: .defaultForLaunch(secret: "controller-secret"),
      options: RuntimeConfigOptions(manualProxyEndpoint: endpoint)
    )
    let configURL = directory.appendingPathComponent("manual-runtime.yaml")
    try SecureFileIO.writePrivateString(runtimeYAML, to: configURL)

    let validator = MihomoRuntimeConfigValidator(timeout: 30)
    try await validator.validate(coreURL: coreURL, configURL: configURL, workDirectory: directory)
  }

  func testBundledMihomoAcceptsGeneratedProfileUpstreamForNodesAndProviders() async throws {
    guard let coreURL = Self.bundledCoreURL() else {
      throw XCTSkip("Bundled Mihomo core is unavailable in Resources/Core.")
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxUpstreamPreflight-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try SecureFileIO.writePrivateString(
      """
      proxies:
        - name: Cached
          type: ss
          server: 127.0.0.1
          port: 8389
          cipher: aes-128-gcm
          password: cached-secret
      """,
      to: directory.appendingPathComponent("proxy-provider.yaml")
    )
    try SecureFileIO.writePrivateString(
      """
      payload:
        - DOMAIN-SUFFIX,provider.example
      """,
      to: directory.appendingPathComponent("rule-provider.yaml")
    )

    let source = """
    proxies:
      - name: Explicit
        type: ss
        server: 127.0.0.1
        port: 8388
        cipher: aes-128-gcm
        password: explicit-secret
    proxy-providers:
      RemoteNodes:
        type: http
        url: https://provider.invalid/proxies
        path: ./proxy-provider.yaml
        interval: 3600
    rule-providers:
      RemoteRules:
        type: http
        behavior: classical
        url: https://provider.invalid/rules
        path: ./rule-provider.yaml
        interval: 3600
    proxy-groups:
      - name: Proxy
        type: select
        proxies: [Explicit, DIRECT]
        use: [RemoteNodes]
    rules:
      - RULE-SET,RemoteRules,Proxy
      - MATCH,DIRECT
    """
    let endpoint = ResolvedOutboundProxyEndpoint(
      endpoint: OutboundProxyEndpoint(
        name: "HTTP upstream",
        kind: .http,
        host: "127.0.0.1",
        port: 8_080,
        authentication: OutboundProxyAuthentication(username: "upstream-user"),
        httpOptions: OutboundProxyHTTPOptions(
          tlsEnabled: true,
          serverName: "proxy.example",
          skipCertificateVerification: true
        )
      ),
      password: "upstream-runtime-secret"
    )
    let runtimeYAML = try ConfigNormalizer().runtimeConfig(
      from: source,
      overrides: .defaultForLaunch(secret: "controller-secret"),
      options: RuntimeConfigOptions(upstreamProxyEndpoint: endpoint)
    )
    let configURL = directory.appendingPathComponent("upstream-runtime.yaml")
    try SecureFileIO.writePrivateString(runtimeYAML, to: configURL)

    let validator = MihomoRuntimeConfigValidator(timeout: 30)
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

  /// A rejecting core explains itself on stdout and then exits, so the explanation can
  /// become readable only after `terminationHandler` has already fired. When that output is
  /// dropped the user is told nothing but "mihomo exited with code 1". The grandchild here
  /// makes the timing deterministic; under CPU load the core's own final chunk lands in the
  /// same window.
  func testRuntimeConfigValidationReportsCoreOutputThatArrivesAfterExit() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxValidatorLateOutput-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let rejectingCore = directory.appendingPathComponent("mihomo-reject")
    let configURL = directory.appendingPathComponent("config.yaml")
    try """
    #!/bin/sh
    ( sleep 0.1; echo "rejected by test core" ) &
    exit 1
    """.write(to: rejectingCore, atomically: true, encoding: .utf8)
    try "mixed-port: 7890\n".write(to: configURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rejectingCore.path)

    let validator = MihomoRuntimeConfigValidator(timeout: 5)

    do {
      try await validator.validate(coreURL: rejectingCore, configURL: configURL, workDirectory: directory)
      XCTFail("Expected runtime config validation to fail.")
    } catch {
      XCTAssertTrue(
        error.localizedDescription.contains("rejected by test core"),
        "Expected the core's own rejection message, got: \(error.localizedDescription)"
      )
    }
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
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let coreURL = repositoryRoot
      .appendingPathComponent("Resources", isDirectory: true)
      .appendingPathComponent("Core", isDirectory: true)
      .appendingPathComponent("mihomo")
    return FileManager.default.isExecutableFile(atPath: coreURL.path) ? coreURL : nil
  }
}

private struct EmptyRuntimePortChecker: RuntimePortChecking {
  func listeners(on ports: [Int]) async -> [PortListener] {
    []
  }
}

private struct PreflightPathsFixture {
  let root: URL
  let paths: RuntimePaths

  init() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxPreflightTests-\(UUID().uuidString)", isDirectory: true)
    self.root = root
    paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    try paths.prepareDirectories()
  }
}

final class RecordingRuntimeConfigValidator: RuntimeConfigValidating {
  let result: Result<Void, Error>
  private(set) var didValidate = false
  private(set) var validatedCoreURL: URL?
  private(set) var validatedConfigURL: URL?
  private(set) var validatedWorkDirectory: URL?
  private(set) var validatedConfigContent: String?

  init(result: Result<Void, Error>) {
    self.result = result
  }

  func validate(coreURL: URL, configURL: URL, workDirectory: URL) async throws {
    didValidate = true
    validatedCoreURL = coreURL
    validatedConfigURL = configURL
    validatedWorkDirectory = workDirectory
    validatedConfigContent = try? String(contentsOf: configURL, encoding: .utf8)
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
      pid > 1
    {
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
  while Date() < deadline, isProcessAlive(pid) {
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
