import Foundation

struct OperationTimedOutError: Error, CustomStringConvertible {
  let seconds: TimeInterval
  var description: String { "Operation timed out after \(Int(seconds.rounded()))s." }
}

func withTimeout<T: Sendable>(
  seconds: TimeInterval,
  operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw OperationTimedOutError(seconds: seconds)
    }
    let result = try await group.next()!
    group.cancelAll()
    return result
  }
}
