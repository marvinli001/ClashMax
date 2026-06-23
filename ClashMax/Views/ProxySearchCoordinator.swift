import Combine
import Foundation
import os

/// Debounces proxy-search requests, runs `ProxySearchPipeline` off the main thread, and publishes
/// only the newest finished snapshot. The view observes `snapshot` / `isComputing` and never runs
/// the heavy resolve/sort/filter itself.
///
/// Issue #10: the main thread now only (1) schedules work, (2) awaits a background `Task.detached`,
/// and (3) applies the published snapshot — proven by the `category: "ProxySearch"` os_signpost
/// interval and debug logs (query, source/result counts, durationMs, staleDropped).
@MainActor
final class ProxySearchCoordinator: ObservableObject {
  enum Reason: Sendable {
    /// First population / explicit refresh.
    case initial
    /// The search field text changed (longer debounce — coalesces fast typing/deleting).
    case searchText
    /// Sort order changed.
    case sort
    /// The underlying group/provider data changed (e.g. a delay batch updating nodes).
    case data
  }

  @Published private(set) var snapshot: ProxySearchSnapshot = .empty
  /// True while a request is scheduled or computing and has not yet published.
  @Published private(set) var isComputing: Bool = false

  /// Total stale results dropped by the generation gate (newer query superseded them).
  private(set) var staleResultsDropped: Int = 0

  /// Debounce for search-field typing. Kept in the 150–250ms band the issue calls for.
  var searchDebounce: Duration = .milliseconds(180)
  /// Shorter debounce for non-typing refreshes so they feel immediate while still coalescing
  /// bursty delay-batch updates instead of recomputing per node.
  var dataDebounce: Duration = .milliseconds(40)

  private let run: @Sendable (ProxySearchPipeline.Input) -> ProxySearchSnapshot
  private let logger = Logger(subsystem: AppConstants.bundleIdentifier, category: "ProxySearch")
  private let signposter: OSSignposter
  private var gate = ProxySearchGenerationGate()
  /// Scheduled work keyed by generation token. Tasks remove themselves on completion so the map
  /// (and the large `Input` each task captures) never accumulates across a session.
  private var pending: [Int: Task<Void, Never>] = [:]

  init(run: @escaping @Sendable (ProxySearchPipeline.Input) -> ProxySearchSnapshot = { ProxySearchPipeline.run($0) }) {
    self.run = run
    self.signposter = OSSignposter(logger: logger)
  }

  /// Schedule a search. Any in-flight request is cancelled so only the newest generation publishes.
  func submit(_ input: ProxySearchPipeline.Input, reason: Reason) {
    cancelInFlight()
    let token = gate.begin()
    isComputing = true

    let debounce = debounceInterval(for: reason)
    let run = self.run
    let signposter = self.signposter

    let task = Task { [weak self] in
      defer { self?.pending[token] = nil }

      if debounce > .zero {
        try? await Task.sleep(for: debounce)
      }
      if Task.isCancelled { return }

      let interval = signposter.beginInterval("ProxySearchCompute")
      let snapshot = await Self.compute(input: input, run: run)
      signposter.endInterval("ProxySearchCompute", interval)

      if Task.isCancelled { return }
      self?.publish(snapshot, token: token)
    }
    pending[token] = task
  }

  /// Runs the pure pipeline on a background task so the main thread stays free.
  private static func compute(
    input: ProxySearchPipeline.Input,
    run: @escaping @Sendable (ProxySearchPipeline.Input) -> ProxySearchSnapshot
  ) async -> ProxySearchSnapshot {
    await Task.detached(priority: .userInitiated) {
      run(input)
    }.value
  }

  private func publish(_ snapshot: ProxySearchSnapshot, token: Int) {
    let committed = gate.commit(token)
    staleResultsDropped = gate.staleDropped

    if committed {
      // Skip re-assigning `snapshot` when a recompute resolves to display content identical to
      // what's already published (e.g. a redundant re-submit of the same query/data), so the
      // snapshot publisher doesn't emit a no-op `objectWillChange`. This does NOT suppress
      // re-renders driven by `appModel` updates or the `isComputing` toggle — those are separate
      // publishers. Equality is over the display fields only (see `ProxySearchSnapshot.==`).
      if snapshot != self.snapshot {
        self.snapshot = snapshot
      }
      logger.debug(
        "proxy-search published query=\"\(snapshot.searchText, privacy: .public)\" source=\(snapshot.sourceNodeCount) result=\(snapshot.resultNodeCount) durationMs=\(snapshot.durationMs, format: .fixed(precision: 2)) staleDropped=\(self.gate.staleDropped) (filtered off main thread)"
      )
    } else {
      logger.debug(
        "proxy-search dropped stale token=\(token) latest=\(self.gate.latest) staleDropped=\(self.gate.staleDropped)"
      )
    }

    // Only the newest generation clears the computing flag; an older straggler leaves it set so the
    // spinner keeps showing until the latest query lands.
    if token >= gate.latest {
      isComputing = false
    }
  }

  private func cancelInFlight() {
    for task in pending.values {
      task.cancel()
    }
  }

  private func debounceInterval(for reason: Reason) -> Duration {
    switch reason {
    case .searchText:
      return searchDebounce
    case .initial, .sort, .data:
      return dataDebounce
    }
  }

  /// Test hook: await every scheduled task (including cancelled ones) so assertions observe a
  /// settled state without sleeping on wall-clock time.
  func settleForTesting() async {
    while !pending.isEmpty {
      let tasks = Array(pending.values)
      for task in tasks {
        await task.value
      }
    }
  }
}
