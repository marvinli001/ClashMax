import Darwin
import Foundation

@MainActor
protocol RunningCoreProcess: AnyObject {
  var processIdentifier: Int32 { get }
  var onTermination: ((Int32) -> Void)? { get set }
  func terminate()
  func recentOutputTail(maxBytes: Int) -> String
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
protocol CoreProcessReaping {
  func reapOrphans(coreURL: URL, configURL: URL, workDirectory: URL) async
}

@MainActor
final class CoreProcessController: ObservableObject {
  @Published private(set) var status: CoreStatus = .stopped
  @Published private(set) var recentCoreLog: String = ""
  private let launcher: CoreProcessLaunching
  private let validator: RuntimeConfigValidating
  private let readinessProbe: CoreReadinessProbing
  private let reaper: CoreProcessReaping
  private var runningProcess: RunningCoreProcess?
  private var stopWasRequested = false

  init(
    launcher: CoreProcessLaunching = FoundationProcessLauncher(),
    validator: RuntimeConfigValidating = MihomoRuntimeConfigValidator(),
    readinessProbe: CoreReadinessProbing = MihomoCoreReadinessProbe(),
    reaper: CoreProcessReaping = MihomoOrphanProcessReaper()
  ) {
    self.launcher = launcher
    self.validator = validator
    self.readinessProbe = readinessProbe
    self.reaper = reaper
  }

  func startUserMode(coreURL: URL, configURL: URL, workDirectory: URL, api: CoreAPIEndpoint) async throws {
    stop()
    stopWasRequested = false
    status = .starting
    recentCoreLog = ""

    do {
      try Task.checkCancellation()
      try await validator.validate(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
      try Task.checkCancellation()

      await reaper.reapOrphans(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
      try Task.checkCancellation()

      let process = try launcher.launch(
        executable: coreURL,
        arguments: ["-f", configURL.path, "-d", workDirectory.path],
        environment: [
          "SAFE_PATHS": workDirectory.path,
          "CLASHMAX_API_HOST": api.host,
          "CLASHMAX_API_PORT": String(api.port)
        ],
        workDirectory: workDirectory
      )

      let launchedProcessID = process.processIdentifier
      process.onTermination = { [weak self] exitCode in
        guard let self else { return }
        guard self.runningProcess?.processIdentifier == launchedProcessID else { return }
        if self.stopWasRequested || exitCode == 0 {
          self.status = .stopped
        } else {
          let tail = process.recentOutputTail(maxBytes: 4096)
          let detail = tail.isEmpty ? "" : "\n\(tail)"
          self.status = .crashed(message: "mihomo exited with code \(exitCode)\(detail)")
        }
        self.runningProcess = nil
      }
      runningProcess = process

      try Task.checkCancellation()
      do {
        let version = try await readinessProbe.waitUntilReady(api: api)
        try Task.checkCancellation()
        guard !stopWasRequested, runningProcess?.processIdentifier == launchedProcessID else {
          throw CancellationError()
        }
        status = .running(version: version)
      } catch let appError as AppError {
        if case let .coreNotReady(message) = appError {
          let tail = process.recentOutputTail(maxBytes: 4096)
          let combined = tail.isEmpty ? message : "\(message)\n---\n\(tail)"
          throw AppError.coreNotReady(combined)
        }
        throw appError
      }
    } catch is CancellationError {
      stopWasRequested = true
      runningProcess?.terminate()
      runningProcess = nil
      status = .stopped
      throw CancellationError()
    } catch {
      let message = userFacingMessage(for: error)
      status = .crashed(message: message)
      if let runningProcess {
        recentCoreLog = runningProcess.recentOutputTail(maxBytes: 8192)
      }
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
    return UserFacingError.message(for: error)
  }
}

struct MihomoOrphanProcessReaper: CoreProcessReaping {
  func reapOrphans(coreURL: URL, configURL: URL, workDirectory: URL) async {
    await Task.detached(priority: .utility) {
      let processRows = Self.processRows()
      let currentPID = getpid()
      let managedPIDs = processRows.compactMap { row -> Int32? in
        guard row.pid != currentPID,
              Self.isManagedCoreCommand(
                row.command,
                coreURL: coreURL,
                configURL: configURL,
                workDirectory: workDirectory
              )
        else {
          return nil
        }
        return row.pid
      }

      guard !managedPIDs.isEmpty else { return }

      managedPIDs.forEach { kill($0, SIGTERM) }
      let deadline = Date().addingTimeInterval(1)
      while Date() < deadline && managedPIDs.contains(where: Self.isProcessAlive) {
        usleep(50_000)
      }
      managedPIDs.filter(Self.isProcessAlive).forEach { kill($0, SIGKILL) }
    }.value
  }

  nonisolated static func isManagedCoreCommand(_ command: String, coreURL: URL, configURL: URL, workDirectory: URL) -> Bool {
    let lowercasedCommand = command.lowercased()
    guard lowercasedCommand.contains("mihomo") else {
      return false
    }

    if command.contains(configURL.path) {
      return true
    }

    let pathComponents = workDirectory.pathComponents
    let isClashMaxRuntime = pathComponents.suffix(2) == ["ClashMax", "Runtime"]
    if isClashMaxRuntime && command.contains(workDirectory.path) {
      return true
    }

    return command.contains(coreURL.path) && command.contains(workDirectory.path)
  }

  private nonisolated static func processRows() -> [(pid: Int32, command: String)] {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-axo", "pid=,command="]
    process.standardOutput = pipe
    process.standardError = Pipe()

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return []
    }

    guard process.terminationStatus == 0 else {
      return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    return output.split(separator: "\n").compactMap { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard let separator = trimmed.firstIndex(where: { $0.isWhitespace }) else {
        return nil
      }
      let pidText = trimmed[..<separator]
      let command = trimmed[separator...].trimmingCharacters(in: .whitespaces)
      guard let pid = Int32(pidText), !command.isEmpty else {
        return nil
      }
      return (pid, command)
    }
  }

  private nonisolated static func isProcessAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
  }
}

struct MihomoRuntimeConfigValidator: RuntimeConfigValidating {
  let timeout: TimeInterval

  init(timeout: TimeInterval = 5) {
    self.timeout = timeout
  }

  func validate(coreURL: URL, configURL: URL, workDirectory: URL) async throws {
    let timeout = timeout
    try await Task.detached(priority: .userInitiated) {
      try Self.validateSynchronously(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, timeout: timeout)
    }.value
  }

  nonisolated private static func validateSynchronously(coreURL: URL, configURL: URL, workDirectory: URL, timeout: TimeInterval) throws {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = coreURL
    process.arguments = ["-t", "-f", configURL.path, "-d", workDirectory.path]
    process.currentDirectoryURL = workDirectory
    process.environment = ProcessInfo.processInfo.environment.merging([
      "SAFE_PATHS": workDirectory.path
    ]) { _, new in new }
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let drain = LiveOutputDrain()
    drain.attach(stdoutPipe.fileHandleForReading)
    drain.attach(stderrPipe.fileHandleForReading)

    try process.run()
    let waitGroup = DispatchGroup()
    waitGroup.enter()
    DispatchQueue.global(qos: .userInitiated).async {
      process.waitUntilExit()
      waitGroup.leave()
    }

    if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
      process.terminate()
      if waitGroup.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        waitGroup.wait()
      }

      let output = drain.flush()
      throw NSError(
        domain: "ClashMax.CoreValidation",
        code: Int(ETIMEDOUT),
        userInfo: [
          NSLocalizedDescriptionKey: "Runtime config validation timed out after \(timeout)s.\(output.isEmpty ? "" : "\n\(output)")"
        ]
      )
    }

    let output = drain.flush()
    guard process.terminationStatus == 0 else {
      throw AppError.configValidationFailed(output.isEmpty ? "mihomo exited with code \(process.terminationStatus)" : output)
    }
  }
}

struct MihomoCoreReadinessProbe: CoreReadinessProbing {
  let attempts: Int
  let delayNanoseconds: UInt64
  let requestTimeout: TimeInterval
  let session: URLSession

  init(
    attempts: Int = 40,
    delayNanoseconds: UInt64 = 250_000_000,
    requestTimeout: TimeInterval = 0.5,
    session: URLSession = .shared
  ) {
    self.attempts = attempts
    self.delayNanoseconds = delayNanoseconds
    self.requestTimeout = requestTimeout
    self.session = session
  }

  func waitUntilReady(api: CoreAPIEndpoint) async throws -> String {
    let client = MihomoAPIClient(
      baseURL: api.baseURL,
      secret: api.secret,
      session: session,
      requestTimeout: requestTimeout
    )
    var lastError: Error?

    for _ in 0..<attempts {
      do {
        return try await client.version()
      } catch {
        lastError = error
        try await Task.sleep(nanoseconds: delayNanoseconds)
      }
    }

    throw AppError.coreNotReady(lastError.map { UserFacingError.message(for: $0) } ?? "Timed out waiting for controller response.")
  }
}

@MainActor
final class FoundationProcessLauncher: CoreProcessLaunching {
  func launch(executable: URL, arguments: [String], environment: [String: String], workDirectory: URL) throws -> RunningCoreProcess {
    let process = Process()
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.currentDirectoryURL = workDirectory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let drain = LiveOutputDrain()
    drain.attach(stdoutPipe.fileHandleForReading)
    drain.attach(stderrPipe.fileHandleForReading)

    let wrapper = FoundationRunningProcess(process: process, drain: drain)
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
  private let drain: LiveOutputDrain
  var onTermination: ((Int32) -> Void)?

  init(process: Process, drain: LiveOutputDrain) {
    self.process = process
    self.drain = drain
  }

  var processIdentifier: Int32 {
    process.processIdentifier
  }

  func terminate() {
    guard process.isRunning else { return }
    process.terminate()
  }

  func recentOutputTail(maxBytes: Int) -> String {
    drain.tail(maxBytes: maxBytes)
  }
}

final class LiveOutputDrain: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let maxRetainedBytes = 65_536
  private var attached: [FileHandle] = []

  func attach(_ handle: FileHandle) {
    handle.readabilityHandler = { [weak self] handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else {
        handle.readabilityHandler = nil
        return
      }
      self?.append(chunk)
    }
    lock.lock()
    attached.append(handle)
    lock.unlock()
  }

  private func append(_ data: Data) {
    lock.lock()
    buffer.append(data)
    if buffer.count > maxRetainedBytes {
      buffer.removeFirst(buffer.count - maxRetainedBytes)
    }
    lock.unlock()
  }

  func flush() -> String {
    lock.lock()
    let data = buffer
    buffer.removeAll(keepingCapacity: false)
    lock.unlock()
    return String(data: data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func tail(maxBytes: Int) -> String {
    lock.lock()
    let snapshot = buffer
    lock.unlock()
    let trimmed = snapshot.suffix(maxBytes)
    return String(data: trimmed, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  deinit {
    for handle in attached {
      handle.readabilityHandler = nil
    }
  }
}
