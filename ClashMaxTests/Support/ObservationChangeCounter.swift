import Foundation

/// Counts Observation mutations to whatever `access` reads, replacing a Combine
/// `Published.Publisher` subscriber now that the stores are `@Observable`.
///
/// `withObservationTracking`'s `onChange` is one-shot, so we re-arm *synchronously*
/// from inside it. The firing `willSet` snapshots its observer list before invoking
/// the callback, so the fresh registration only triggers on the *next* mutation —
/// every change is tallied with no misses. An async re-arm (`Task { arm() }`) would
/// instead drop mutations landing between the callback and the re-arm, undercounting
/// publishes and hiding the coalescing regressions issue #11 fixed. Keep it synchronous.
///
/// All mutations and reads happen on the MainActor (the stores and their mutators are
/// `@MainActor`), so the actor hop-free re-arm via `assumeIsolated` is sound. The counter
/// starts at 0: unlike a Combine publisher it does not emit the current value on subscription.
///
/// Usage:
/// ```swift
/// let counter = ObservationChangeCounter { _ = model.overrides }
/// model.setMode(model.overrides.mode)
/// XCTAssertEqual(counter.count, 0)
/// ```
@MainActor
final class ObservationChangeCounter {
  private(set) var count = 0
  private let access: () -> Void

  init(_ access: @escaping () -> Void) {
    self.access = access
    arm()
  }

  private func arm() {
    withObservationTracking(access) { [self] in
      MainActor.assumeIsolated {
        count += 1
        arm()
      }
    }
  }
}
