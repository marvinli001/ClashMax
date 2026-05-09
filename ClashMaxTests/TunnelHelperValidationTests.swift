import Darwin
import XCTest
@testable import ClashMax

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
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(first.pid):old"), "\(first.pid):old")

    let second = try start(service, fixture: fixture, secret: "new")
    XCTAssertFalse(second.ok)
    XCTAssertTrue(second.running)
    XCTAssertEqual(second.pid, first.pid)
    XCTAssertEqual(second.code, HelperResponseCode.alreadyRunning)
    XCTAssertTrue(second.message.localizedCaseInsensitiveContains("already running"))
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(first.pid):old"), "\(first.pid):old")
  }

  func testHelperRestartTunnelWaitsForOldProcessBeforeStartingReplacement() throws {
    let fixture = try makeRuntimeFixture()
    let service = makeHelperService(fixture: fixture)
    addTeardownBlock { stop(service) }

    let first = try start(service, fixture: fixture, secret: "old")
    XCTAssertTrue(first.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(first.pid):old"), "\(first.pid):old")

    let restarted = try restart(service, fixture: fixture, secret: "new")
    XCTAssertTrue(restarted.ok)
    XCTAssertTrue(restarted.running)
    XCTAssertGreaterThan(restarted.pid, 0)
    XCTAssertFalse(isProcessAlive(pid_t(first.pid)))
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(restarted.pid):new"), "\(restarted.pid):new")
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
          (secret, try start(service, fixture: fixture, secret: secret))
        })
        done.leave()
      }
    }

    startGate.signal()
    startGate.signal()

    XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
    let responses = try responseRecorder.values.map { try $0.get() }
    let accepted = responses.filter { $0.1.ok }
    let rejected = responses.filter { !$0.1.ok }

    XCTAssertEqual(accepted.count, 1)
    XCTAssertEqual(rejected.count, 1)
    let acceptedResponse = try XCTUnwrap(accepted.first)
    let rejectedResponse = try XCTUnwrap(rejected.first).1
    XCTAssertTrue(acceptedResponse.1.running)
    XCTAssertEqual(rejectedResponse.code, HelperResponseCode.alreadyRunning)
    XCTAssertEqual(rejectedResponse.pid, acceptedResponse.1.pid)
    XCTAssertEqual(
      try waitForLaunchState(fixture: fixture, expected: "\(acceptedResponse.1.pid):\(acceptedResponse.0)"),
      "\(acceptedResponse.1.pid):\(acceptedResponse.0)"
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
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):cleanup"), "\(response.pid):cleanup")
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
    printf "%s:%s\\n" "$$" "$CLASHMAX_SECRET" > "$PWD/launch-state.txt"
    exit 0
    """)
    var launchedProcess: Process?
    let service = makeHelperService(fixture: fixture) { process in
      launchedProcess = process
    }
    addTeardownBlock { stop(service) }

    let response = try start(service, fixture: fixture, secret: "exited")
    XCTAssertTrue(response.ok)
    XCTAssertEqual(try waitForLaunchState(fixture: fixture, expected: "\(response.pid):exited"), "\(response.pid):exited")
    let process = try XCTUnwrap(launchedProcess)
    waitForProcessExit(process)
    XCTAssertFalse(process.isRunning)
    let outputHandle = try XCTUnwrap((process.standardOutput as? Pipe)?.fileHandleForReading)

    var payload: NSString?
    service.status { response in
      payload = response
    }
    let status = HelperClientResponse(payload: try XCTUnwrap(payload))

    XCTAssertFalse(status.running)
    XCTAssertNil(outputHandle.readabilityHandler)
    XCTAssertNil(process.terminationHandler)
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
    coreScript: String = """
    #!/bin/sh
    trap 'sleep 1; exit 0' TERM
    printf "%s:%s\\n" "$$" "$CLASHMAX_SECRET" > "$PWD/launch-state.txt"
    while true; do sleep 1; done
    """
  ) throws -> PathFixture {
    let tempRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxHelperRuntime-\(UUID().uuidString)", isDirectory: true)
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
  return HelperClientResponse(payload: try XCTUnwrap(payload))
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
  return HelperClientResponse(payload: try XCTUnwrap(payload))
}

private func stop(_ service: HelperService) {
  service.stopTunnel { _ in }
}

private func waitForLaunchState(fixture: PathFixture, expected: String) throws -> String {
  let stateURL = fixture.runtimeRoot.appendingPathComponent("launch-state.txt")
  let deadline = Date().addingTimeInterval(3)
  var lastState = ""
  while Date() < deadline {
    if let state = try? String(contentsOf: stateURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
       !state.isEmpty {
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
  while process.isRunning && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.02)
  }
}

private struct NoopHelperCoreExecutableValidator: HelperCoreExecutableValidating {
  func validateCoreExecutable(at url: URL) throws {}
}
