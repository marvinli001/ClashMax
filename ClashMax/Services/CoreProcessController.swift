import Foundation

@MainActor
protocol RunningCoreProcess: AnyObject {
  var processIdentifier: Int32 { get }
  var onTermination: ((Int32) -> Void)? { get set }
  func terminate()
}

@MainActor
protocol CoreProcessLaunching {
  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess
}

@MainActor
protocol RuntimeConfigValidating {
  func validate(coreURL: URL, configURL: URL, workDirectory: URL) async throws
}

@MainActor
protocol CoreReadinessProbing {
  func waitUntilReady(api: CoreAPIEndpoint) async throws -> String
}

@MainActor
final class CoreProcessController: ObservableObject {
  @Published private(set) var status: CoreStatus = .stopped
  private let launcher: CoreProcessLaunching
  private let validator: RuntimeConfigValidating
  private let readinessProbe: CoreReadinessProbing
  private var runningProcess: RunningCoreProcess?
  private var stopWasRequested = false

  init(
    launcher: CoreProcessLaunching = FoundationProcessLauncher(),
    validator: RuntimeConfigValidating = MihomoRuntimeConfigValidator(),
    readinessProbe: CoreReadinessProbing = MihomoCoreReadinessProbe()
  ) {
    self.launcher = launcher
    self.validator = validator
    self.readinessProbe = readinessProbe
  }

  func startUserMode(coreURL: URL, configURL: URL, workDirectory: URL, api: CoreAPIEndpoint) async throws {
    stop()
    stopWasRequested = false
    status = .starting

    do {
      try await validator.validate(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
    } catch {
      let message = userFacingMessage(for: error)
      status = .crashed(message: message)
      throw error
    }

    let process: RunningCoreProcess
    do {
      process = try launcher.launch(
        executable: coreURL,
        arguments: ["-f", configURL.path, "-d", workDirectory.path],
        environment: [
          "SAFE_PATHS": workDirectory.path,
          "CLASHMAX_API_HOST": api.host,
          "CLASHMAX_API_PORT": String(api.port)
        ],
        workDirectory: workDirectory
      )
    } catch {
      let message = userFacingMessage(for: error)
      status = .crashed(message: message)
      throw error
    }

    process.onTermination = { [weak self] exitCode in
      guard let self else { return }
      if self.stopWasRequested || exitCode == 0 {
        self.status = .stopped
      } else {
        self.status = .crashed(message: "mihomo exited with code \(exitCode)")
      }
      self.runningProcess = nil
    }
    runningProcess = process

    do {
      let version = try await readinessProbe.waitUntilReady(api: api)
      status = .running(version: version)
    } catch {
      let message = userFacingMessage(for: error)
      status = .crashed(message: message)
      runningProcess?.terminate()
      runningProcess = nil
      throw error
    }
  }

  func restart(coreURL: URL, configURL: URL, workDirectory: URL, api: CoreAPIEndpoint) async throws {
    status = .restarting
    stop()
    try await startUserMode(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, api: api)
  }

  func stop() {
    stopWasRequested = true
    runningProcess?.terminate()
    runningProcess = nil
    status = .stopped
  }

  private func userFacingMessage(for error: Error) -> String {
    if let appError = error as? AppError {
      switch appError {
      case let .configValidationFailed(message), let .coreNotReady(message), let .helperResponse(message):
        return message
      default:
        return appError.description
      }
    }
    return error.localizedDescription
  }
}

struct MihomoRuntimeConfigValidator: RuntimeConfigValidating {
  func validate(coreURL: URL, configURL: URL, workDirectory: URL) async throws {
    try await Task.detached(priority: .userInitiated) {
      let process = Process()
      let pipe = Pipe()
      process.executableURL = coreURL
      process.arguments = ["-t", "-f", configURL.path, "-d", workDirectory.path]
      process.currentDirectoryURL = workDirectory
      process.environment = ProcessInfo.processInfo.environment.merging([
        "SAFE_PATHS": workDirectory.path
      ]) { _, new in new }
      process.standardOutput = pipe
      process.standardError = pipe

      try process.run()
      process.waitUntilExit()

      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard process.terminationStatus == 0 else {
        throw AppError.configValidationFailed(output.isEmpty ? "mihomo exited with code \(process.terminationStatus)" : output)
      }
    }.value
  }
}

struct MihomoCoreReadinessProbe: CoreReadinessProbing {
  let attempts: Int
  let delayNanoseconds: UInt64

  init(attempts: Int = 40, delayNanoseconds: UInt64 = 250_000_000) {
    self.attempts = attempts
    self.delayNanoseconds = delayNanoseconds
  }

  func waitUntilReady(api: CoreAPIEndpoint) async throws -> String {
    let client = MihomoAPIClient(baseURL: api.baseURL, secret: api.secret)
    var lastError: Error?

    for _ in 0..<attempts {
      do {
        return try await client.version()
      } catch {
        lastError = error
        try await Task.sleep(nanoseconds: delayNanoseconds)
      }
    }

    throw AppError.coreNotReady(lastError.map { String(describing: $0) } ?? "timed out")
  }
}

@MainActor
final class FoundationProcessLauncher: CoreProcessLaunching {
  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

    let wrapper = FoundationRunningProcess(process: process)
    process.terminationHandler = { process in
      let exitCode = process.terminationStatus
      Task { @MainActor in
        wrapper.onTermination?(exitCode)
      }
    }

    try process.run()
    return wrapper
  }
}

@MainActor
final class FoundationRunningProcess: RunningCoreProcess {
  private let process: Process
  var onTermination: ((Int32) -> Void)?

  init(process: Process) {
    self.process = process
  }

  var processIdentifier: Int32 {
    process.processIdentifier
  }

  func terminate() {
    guard process.isRunning else { return }
    process.terminate()
  }
}
