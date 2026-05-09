import Darwin
import Foundation

@MainActor
protocol RunningCoreProcess: AnyObject {
  var processIdentifier: Int32 { get }
  var isRunning: Bool { get }
  var onTermination: ((Int32) -> Void)? { get set }
  func terminate()
  func kill()
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

struct PortListener: Equatable, Sendable {
  var port: Int
  var pid: Int32
  var command: String
}

struct CoreStopResult {
  var processIdentifier: Int32?
  var didTerminate: Bool
  var didEscalate: Bool
  var message: String?

  static let notRunning = CoreStopResult(
    processIdentifier: nil,
    didTerminate: true,
    didEscalate: false,
    message: nil
  )

  var succeeded: Bool {
    didTerminate
  }

  var error: Error? {
    guard !succeeded else { return nil }
    return AppError.coreStopFailed(message ?? "Could not stop Mihomo cleanly.")
  }
}

protocol RuntimePortChecking: Sendable {
  func listeners(on ports: [Int]) async -> [PortListener]
}

@MainActor
final class CoreProcessController: ObservableObject {
  @Published private(set) var status: CoreStatus = .stopped
  @Published private(set) var recentCoreLog: String = ""
  @Published private(set) var startupDiagnostics: [String] = []
  private let launcher: CoreProcessLaunching
  private let validator: RuntimeConfigValidating
  private let readinessProbe: CoreReadinessProbing
  private let reaper: CoreProcessReaping
  private let portChecker: RuntimePortChecking
  private var runningProcess: RunningCoreProcess?
  private var stopWasRequested = false

  init(
    launcher: CoreProcessLaunching = FoundationProcessLauncher(),
    validator: RuntimeConfigValidating = MihomoRuntimeConfigValidator(),
    readinessProbe: CoreReadinessProbing = MihomoCoreReadinessProbe(),
    reaper: CoreProcessReaping = MihomoOrphanProcessReaper(),
    portChecker: RuntimePortChecking = MihomoRuntimePortChecker()
  ) {
    self.launcher = launcher
    self.validator = validator
    self.readinessProbe = readinessProbe
    self.reaper = reaper
    self.portChecker = portChecker
  }

  func startUserMode(
    coreURL: URL,
    configURL: URL,
    workDirectory: URL,
    api: CoreAPIEndpoint,
    proxyPort: Int? = nil
  ) async throws {
    let stopResult = await stop()
    guard stopResult.succeeded else {
      throw stopResult.error ?? AppError.coreStopFailed("Could not stop the previous Mihomo process.")
    }
    stopWasRequested = false
    status = .starting
    recentCoreLog = ""
    startupDiagnostics = []

    do {
      try Task.checkCancellation()
      recordStartup("Validating runtime config: \(configURL.path)")
      recordStartup("Using Mihomo core: \(coreURL.path)")
      try await validator.validate(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
      try Task.checkCancellation()

      recordStartup("Reaping stale ClashMax-managed Mihomo processes in \(workDirectory.path)")
      await reaper.reapOrphans(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
      try Task.checkCancellation()

      let portsToCheck = Array(Set(([api.port] + [proxyPort].compactMap { $0 }))).sorted()
      recordStartup("Checking runtime ports: \(portsToCheck.map(String.init).joined(separator: ", "))")
      let listeners = await portChecker.listeners(on: portsToCheck)
      if !listeners.isEmpty {
        for listener in listeners {
          recordStartup("Port \(listener.port) is occupied by pid \(listener.pid): \(listener.command)")
        }
        throw AppError.portUnavailable(Self.portConflictMessage(for: listeners))
      }

      recordStartup("Launching Mihomo with config: \(configURL.path)")
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
      var startupCompleted = false
      var startupTerminationMessage: String?
      recordStartup("Mihomo launch pid: \(launchedProcessID)")
      runningProcess = process
      process.onTermination = { [weak self] exitCode in
        guard let self else { return }
        guard self.runningProcess?.processIdentifier == launchedProcessID else { return }
        if self.stopWasRequested || (startupCompleted && exitCode == 0) {
          self.status = .stopped
        } else {
          let tail = process.recentOutputTail(maxBytes: 4096)
          let message = Self.processExitMessage(exitCode: exitCode, outputTail: tail)
          if !startupCompleted {
            startupTerminationMessage = message
            self.recentCoreLog = tail
          }
          self.status = .crashed(message: message)
        }
        self.runningProcess = nil
      }
      if let startupTerminationMessage {
        recordStartup("Mihomo exited before controller readiness: \(startupTerminationMessage)")
        throw AppError.coreNotReady(startupTerminationMessage)
      }

      try Task.checkCancellation()
      do {
        let version = try await readinessProbe.waitUntilReady(api: api)
        try Task.checkCancellation()
        if let startupTerminationMessage {
          recordStartup("Mihomo exited before controller readiness: \(startupTerminationMessage)")
          throw AppError.coreNotReady(startupTerminationMessage)
        }
        guard !stopWasRequested, runningProcess?.processIdentifier == launchedProcessID else {
          throw CancellationError()
        }
        recordStartup("Mihomo controller ready: \(api.host):\(api.port), version \(version)")
        startupCompleted = true
        status = .running(version: version)
      } catch let appError as AppError {
        if case let .coreNotReady(message) = appError {
          let tail = process.recentOutputTail(maxBytes: 4096)
          recentCoreLog = tail
          let combined = tail.isEmpty ? message : "\(message)\n---\n\(tail)"
          recordStartup("Readiness failed: \(combined)")
          throw AppError.coreNotReady(combined)
        }
        throw appError
      }
    } catch is CancellationError {
      stopWasRequested = true
      let stopResult = await stopRunningProcess()
      if stopResult.succeeded {
        status = .stopped
      }
      throw CancellationError()
    } catch {
      let message = userFacingMessage(for: error)
      status = .crashed(message: message)
      if let runningProcess {
        recentCoreLog = runningProcess.recentOutputTail(maxBytes: 8192)
        if !recentCoreLog.isEmpty {
          recordStartup("Core tail: \(recentCoreLog)")
        }
      }
      if runningProcess != nil {
        stopWasRequested = true
        let stopResult = await stopRunningProcess()
        if stopResult.succeeded {
          status = .crashed(message: message)
        } else if let stopMessage = stopResult.message {
          status = .crashed(message: "\(message)\n\(stopMessage)")
        }
      }
      throw error
    }
  }

  func restart(coreURL: URL, configURL: URL, workDirectory: URL, api: CoreAPIEndpoint) async throws {
    status = .restarting
    let stopResult = await stop()
    guard stopResult.succeeded else {
      throw stopResult.error ?? AppError.coreStopFailed("Could not stop the previous Mihomo process.")
    }
    try await startUserMode(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, api: api)
  }

  @discardableResult
  func stop() async -> CoreStopResult {
    stopWasRequested = true
    let result = await stopRunningProcess()
    if result.succeeded {
      status = .stopped
    }
    return result
  }

  private func stopRunningProcess() async -> CoreStopResult {
    guard let process = runningProcess else {
      return .notRunning
    }

    let processIdentifier = process.processIdentifier
    process.terminate()

    let terminatedAfterTerm: Bool
    if process.isRunning {
      terminatedAfterTerm = await waitForExit(process, processIdentifier: processIdentifier, timeout: 2)
    } else {
      terminatedAfterTerm = true
    }
    if terminatedAfterTerm {
      clearStoppedProcess(processIdentifier: processIdentifier)
      return CoreStopResult(
        processIdentifier: processIdentifier,
        didTerminate: true,
        didEscalate: false,
        message: nil
      )
    }

    recordStartup("Mihomo pid \(processIdentifier) did not exit after SIGTERM; sending SIGKILL.")
    process.kill()

    let terminatedAfterKill: Bool
    if process.isRunning {
      terminatedAfterKill = await waitForExit(process, processIdentifier: processIdentifier, timeout: 1)
    } else {
      terminatedAfterKill = true
    }
    if terminatedAfterKill {
      clearStoppedProcess(processIdentifier: processIdentifier)
      return CoreStopResult(
        processIdentifier: processIdentifier,
        didTerminate: true,
        didEscalate: true,
        message: nil
      )
    }

    let message = "Could not stop Mihomo pid \(processIdentifier); the process is still running after SIGTERM and SIGKILL."
    recentCoreLog = process.recentOutputTail(maxBytes: 8192)
    status = .crashed(message: message)
    return CoreStopResult(
      processIdentifier: processIdentifier,
      didTerminate: false,
      didEscalate: true,
      message: message
    )
  }

  private func clearStoppedProcess(processIdentifier: Int32) {
    guard runningProcess?.processIdentifier == processIdentifier else { return }
    runningProcess = nil
  }

  private func waitForExit(_ process: RunningCoreProcess, processIdentifier: Int32, timeout: TimeInterval) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      if runningProcess?.processIdentifier != processIdentifier {
        return true
      }
      await Self.sleepIgnoringCancellation(nanoseconds: 50_000_000)
    }
    return !process.isRunning
  }

  private nonisolated static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
    let sleeper = Task.detached {
      try? await Task.sleep(nanoseconds: nanoseconds)
    }
    await sleeper.value
  }

  private func userFacingMessage(for error: Error) -> String {
    if let appError = error as? AppError {
      switch appError {
      case let .configValidationFailed(message), let .coreNotReady(message), let .coreStopFailed(message), let .helperResponse(message), let .portUnavailable(message):
        return message
      default:
        return appError.description
      }
    }
    return UserFacingError.message(for: error)
  }

  private func recordStartup(_ message: String) {
    startupDiagnostics.append(message)
    if startupDiagnostics.count > 80 {
      startupDiagnostics.removeFirst(startupDiagnostics.count - 80)
    }
  }

  private static func portConflictMessage(for listeners: [PortListener]) -> String {
    let details = listeners
      .sorted { lhs, rhs in
        lhs.port == rhs.port ? lhs.pid < rhs.pid : lhs.port < rhs.port
      }
      .map { "port \($0.port) is used by pid \($0.pid) (\($0.command))" }
      .joined(separator: "; ")
    return "Cannot start Mihomo because required runtime ports are already in use: \(details). Quit the conflicting process or change ClashMax's controller/mixed port settings."
  }

  private static func processExitMessage(exitCode: Int32, outputTail: String) -> String {
    let detail = outputTail.isEmpty ? "" : "\n\(outputTail)"
    return "mihomo exited with code \(exitCode)\(detail)"
  }
}

struct MihomoRuntimePortChecker: RuntimePortChecking {
  private static let commandTimeoutSeconds: TimeInterval = 3

  func listeners(on ports: [Int]) async -> [PortListener] {
    var listeners: [PortListener] = []
    for port in ports {
      listeners.append(contentsOf: await Self.listeners(on: port))
    }
    return listeners
  }

  private static func listeners(on port: Int) async -> [PortListener] {
    guard let output = await run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]) else {
      return []
    }

    var listeners: [PortListener] = []
    for line in output.split(separator: "\n").dropFirst() {
      let fields = line.split(whereSeparator: \.isWhitespace)
      guard fields.count >= 2, let pid = Int32(fields[1]) else {
        continue
      }
      let command = await processCommand(pid: pid) ?? String(fields[0])
      listeners.append(PortListener(port: port, pid: pid, command: command))
    }
    return listeners
  }

  private static func processCommand(pid: Int32) async -> String? {
    await run("/bin/ps", ["-p", String(pid), "-o", "command="])?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func run(_ executable: String, _ arguments: [String]) async -> String? {
    do {
      let output = try await ProcessOutputCapture.run(
        executable: URL(fileURLWithPath: executable),
        arguments: arguments,
        timeout: commandTimeoutSeconds
      )
      guard output.terminationStatus == 0 else {
        return nil
      }
      return output.text
    } catch {
      return nil
    }
  }
}

struct ProcessOutputCapture: Sendable {
  let terminationStatus: Int32
  let text: String

  static func run(
    executable: URL,
    arguments: [String],
    timeout: TimeInterval = 5
  ) async throws -> ProcessOutputCapture {
    let process = Process()
    let outputPipe = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.standardOutput = outputPipe
    process.standardError = outputPipe

    let drain = LiveOutputDrain(maxRetainedBytes: nil)
    drain.attach(outputPipe.fileHandleForReading)
    let command = ([executable.path] + arguments).joined(separator: " ")
    let result = try await CancellableProcessExecution(
      process: process,
      timeout: timeout,
      timeoutError: { output in
        NSError(
          domain: "ClashMax.ProcessOutputCapture",
          code: Int(ETIMEDOUT),
          userInfo: [
            NSLocalizedDescriptionKey: "Command timed out after \(timeout)s: \(command)\(output.isEmpty ? "" : "\n\(output)")"
          ]
        )
      },
      output: {
        drain.flush(trimmed: false)
      },
      cleanup: {
        drain.detachAll()
      }
    ).run()

    return ProcessOutputCapture(
      terminationStatus: result.terminationStatus,
      text: result.output
    )
  }
}

struct CancellableProcessResult: Sendable {
  let terminationStatus: Int32
  let output: String
}

final class CancellableProcessExecution: @unchecked Sendable {
  private enum StopReason {
    case cancelled
    case timedOut
  }

  private let process: Process
  private let timeout: TimeInterval
  private let timeoutError: (String) -> Error
  private let output: () -> String
  private let cleanup: () -> Void
  private let lock = NSLock()
  private var isStarted = false
  private var completedStatus: Int32?
  private var stopReason: StopReason?
  private var waitContinuation: CheckedContinuation<Int32, Never>?

  init(
    process: Process,
    timeout: TimeInterval,
    timeoutError: @escaping (String) -> Error,
    output: @escaping () -> String,
    cleanup: @escaping () -> Void = {}
  ) {
    self.process = process
    self.timeout = timeout
    self.timeoutError = timeoutError
    self.output = output
    self.cleanup = cleanup
  }

  func run() async throws -> CancellableProcessResult {
    try await withTaskCancellationHandler {
      try await runWithCancellationHandler()
    } onCancel: {
      self.requestStop(.cancelled)
    }
  }

  private func runWithCancellationHandler() async throws -> CancellableProcessResult {
    do {
      try Task.checkCancellation()
    } catch {
      cleanup()
      throw error
    }
    process.terminationHandler = { [weak self] process in
      self?.complete(status: process.terminationStatus)
    }

    do {
      try process.run()
    } catch {
      process.terminationHandler = nil
      cleanup()
      throw error
    }

    if markStartedAndNeedsStop() || Task.isCancelled {
      requestStop(.cancelled)
    }

    let timeoutTask = makeTimeoutTask()
    let terminationStatus = await waitForTermination()
    timeoutTask.cancel()

    let resultOutput = output()
    process.terminationHandler = nil
    cleanup()

    switch currentStopReason() {
    case .cancelled:
      throw CancellationError()
    case .timedOut:
      throw timeoutError(resultOutput)
    case nil:
      return CancellableProcessResult(terminationStatus: terminationStatus, output: resultOutput)
    }
  }

  private func makeTimeoutTask() -> Task<Void, Never> {
    Task { [weak self] in
      do {
        try await Task.sleep(nanoseconds: Self.nanoseconds(for: self?.timeout ?? 0))
        self?.requestStop(.timedOut)
      } catch {
      }
    }
  }

  private func markStartedAndNeedsStop() -> Bool {
    lock.lock()
    isStarted = true
    let shouldStop = completedStatus == nil && stopReason != nil
    lock.unlock()
    return shouldStop
  }

  private func waitForTermination() async -> Int32 {
    await withCheckedContinuation { continuation in
      let status: Int32?
      lock.lock()
      if let completedStatus {
        status = completedStatus
      } else {
        status = nil
        waitContinuation = continuation
      }
      lock.unlock()

      if let status {
        continuation.resume(returning: status)
      }
    }
  }

  private func complete(status: Int32) {
    let continuationToResume: CheckedContinuation<Int32, Never>?

    lock.lock()
    guard completedStatus == nil else {
      lock.unlock()
      return
    }
    completedStatus = status
    continuationToResume = waitContinuation
    waitContinuation = nil
    lock.unlock()

    continuationToResume?.resume(returning: status)
  }

  private func requestStop(_ reason: StopReason) {
    let shouldTerminate: Bool

    lock.lock()
    if completedStatus == nil {
      if stopReason == nil || reason == .cancelled {
        stopReason = reason
      }
      shouldTerminate = isStarted
    } else {
      shouldTerminate = false
    }
    lock.unlock()

    guard shouldTerminate else { return }
    terminateRunningProcess()
  }

  private func terminateRunningProcess() {
    guard process.isRunning else { return }
    process.terminate()
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.5) { [process] in
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
      }
    }
  }

  private func currentStopReason() -> StopReason? {
    lock.lock()
    let reason = stopReason
    lock.unlock()
    return reason
  }

  private static func nanoseconds(for seconds: TimeInterval) -> UInt64 {
    UInt64(max(seconds, 0) * 1_000_000_000)
  }
}

struct MihomoOrphanProcessReaper: CoreProcessReaping {
  private static let processListTimeoutSeconds: TimeInterval = 3

  func reapOrphans(coreURL: URL, configURL: URL, workDirectory: URL) async {
    await Self.reapOrphansAsync(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory)
  }

  private nonisolated static func reapOrphansAsync(coreURL: URL, configURL: URL, workDirectory: URL) async {
    let processRows = await Self.processRows()
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
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    managedPIDs.filter(Self.isProcessAlive).forEach { kill($0, SIGKILL) }
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

  private nonisolated static func processRows() async -> [(pid: Int32, command: String)] {
    do {
      let output = try await ProcessOutputCapture.run(
        executable: URL(fileURLWithPath: "/bin/ps"),
        arguments: ["-axo", "pid=,command="],
        timeout: processListTimeoutSeconds
      )
      guard output.terminationStatus == 0 else {
        return []
      }
      return output.text.split(separator: "\n").compactMap { line in
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
    } catch {
      return []
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
    try await Self.validateAsync(coreURL: coreURL, configURL: configURL, workDirectory: workDirectory, timeout: timeout)
  }

  nonisolated private static func validateAsync(coreURL: URL, configURL: URL, workDirectory: URL, timeout: TimeInterval) async throws {
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

    let execution = CancellableProcessExecution(
      process: process,
      timeout: timeout,
      timeoutError: { output in
        NSError(
          domain: "ClashMax.CoreValidation",
          code: Int(ETIMEDOUT),
          userInfo: [
            NSLocalizedDescriptionKey: "Runtime config validation timed out after \(timeout)s.\(output.isEmpty ? "" : "\n\(output)")"
          ]
        )
      },
      output: {
        drain.flush()
      },
      cleanup: {
        drain.detachAll()
      }
    )

    let result = try await execution.run()
    guard result.terminationStatus == 0 else {
      throw AppError.configValidationFailed(
        result.output.isEmpty ? "mihomo exited with code \(result.terminationStatus)" : result.output
      )
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
      baseURL: try api.baseURL,
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
        wrapper.notifyTermination(exitCode: exitCode)
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
  private var pendingTerminationStatus: Int32?
  var onTermination: ((Int32) -> Void)? {
    didSet {
      if let pendingTerminationStatus {
        self.pendingTerminationStatus = nil
        onTermination?(pendingTerminationStatus)
      }
    }
  }

  init(process: Process, drain: LiveOutputDrain) {
    self.process = process
    self.drain = drain
  }

  var processIdentifier: Int32 {
    process.processIdentifier
  }

  var isRunning: Bool {
    process.isRunning
  }

  func terminate() {
    guard process.isRunning else { return }
    process.terminate()
  }

  func kill() {
    guard process.isRunning else { return }
    Darwin.kill(process.processIdentifier, SIGKILL)
  }

  func recentOutputTail(maxBytes: Int) -> String {
    drain.tail(maxBytes: maxBytes)
  }

  func notifyTermination(exitCode: Int32) {
    if let onTermination {
      onTermination(exitCode)
    } else {
      pendingTerminationStatus = exitCode
    }
  }
}

final class LiveOutputDrain: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let maxRetainedBytes: Int?
  private var attached: [FileHandle] = []

  init(maxRetainedBytes: Int? = 65_536) {
    self.maxRetainedBytes = maxRetainedBytes
  }

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
    if let maxRetainedBytes, buffer.count > maxRetainedBytes {
      buffer.removeFirst(buffer.count - maxRetainedBytes)
    }
    lock.unlock()
  }

  func flush(trimmed: Bool = true) -> String {
    lock.lock()
    let data = buffer
    buffer.removeAll(keepingCapacity: false)
    lock.unlock()
    let text = String(data: data, encoding: .utf8) ?? ""
    return trimmed ? text.trimmingCharacters(in: .whitespacesAndNewlines) : text
  }

  func tail(maxBytes: Int) -> String {
    lock.lock()
    let snapshot = buffer
    lock.unlock()
    let trimmed = snapshot.suffix(maxBytes)
    return String(data: trimmed, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  func detachAll() {
    lock.lock()
    let handles = attached
    attached.removeAll()
    lock.unlock()

    for handle in handles {
      handle.readabilityHandler = nil
    }
  }

  deinit {
    detachAll()
  }
}
