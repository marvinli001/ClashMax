import Darwin
import Foundation
import Testing
@testable import ClashMax

struct ProcessOutputCaptureTests {
  @Test func capturesOutputLargerThanPipeBufferWithoutDeadlocking() async throws {
    let output = try await ProcessOutputCapture.run(
      executable: URL(fileURLWithPath: "/bin/sh"),
      arguments: ["-c", "/usr/bin/yes 1234567890 | /usr/bin/head -c 200000"]
    )

    #expect(output.terminationStatus == 0)
    #expect(output.text.count == 200_000)
  }

  @Test func timesOutAndTerminatesHangingProcess() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxProcessOutputCaptureTimeout-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let scriptURL = directory.appendingPathComponent("hang.sh")
    let pidURL = directory.appendingPathComponent("pid.txt")
    try """
    #!/bin/sh
    printf "%s\\n" "$$" > "$1"
    exec sleep 30
    """.write(to: scriptURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

    let startedAt = Date()
    let task = Task {
      try await ProcessOutputCapture.run(
        executable: scriptURL,
        arguments: [pidURL.path],
        timeout: 1
      )
    }
    let pid = try await waitForRecordedPID(at: pidURL)
    defer { terminateTestProcessIfNeeded(pid) }

    var didTimeout = false
    do {
      _ = try await task.value
    } catch {
      didTimeout = error.localizedDescription.contains("timed out")
    }

    #expect(didTimeout)
    #expect(Date().timeIntervalSince(startedAt) < 2)
    let didExit = await waitForProcessExit(pid, timeout: 1)
    #expect(didExit)
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
  guard pid > 1, isProcessAlive(pid) else { return }
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
