import Foundation
import XCTest
@testable import ClashMax

@MainActor
final class CoreRuntimePreflightTests: XCTestCase {
  func testGeneratedRuntimeConfigIsValidatedBeforeLaunch() async throws {
    let launcher = FakeProcessLauncher()
    let validator = RecordingRuntimeConfigValidator(result: .failure(AppError.configValidationFailed("bad config")))
    let reaper = RecordingCoreProcessReaper()
    let controller = CoreProcessController(launcher: launcher, validator: validator, reaper: reaper)

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
      reaper: reaper
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
