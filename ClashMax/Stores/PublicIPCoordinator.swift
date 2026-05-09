import Foundation

@MainActor
final class PublicIPCoordinator: ObservableObject {
  @Published private(set) var state: PublicIPInfoState = .idle

  private let client: any PublicIPInfoFetching
  private var task: Task<Void, Never>?
  private let refreshInterval: TimeInterval

  init(
    client: any PublicIPInfoFetching = PublicIPInfoClient(),
    refreshInterval: TimeInterval = 300
  ) {
    self.client = client
    self.refreshInterval = refreshInterval
  }

  func needsRefresh(isCoreRunning: Bool, now: Date = Date()) -> Bool {
    guard isCoreRunning else { return false }
    if state.isLoading { return false }
    guard let anchor = state.refreshAnchor else { return true }
    return now.timeIntervalSince(anchor) >= refreshInterval
  }

  func refresh(isCoreRunning: Bool, force: Bool = false, now: Date = Date()) {
    guard isCoreRunning else {
      cancel(clearState: true)
      return
    }
    guard force || needsRefresh(isCoreRunning: isCoreRunning, now: now) else { return }
    guard !state.isLoading else { return }

    let previous = state.info
    state = .loading(previous: previous, startedAt: now)
    task = Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let info = try await self.client.fetchPublicIPInfo()
        guard !Task.isCancelled else { return }
        self.state = .loaded(info)
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        self.state = .failed(
          message: UserFacingError.message(for: error),
          previous: previous,
          failedAt: Date()
        )
      }
      self.task = nil
    }
  }

  func cancel(clearState: Bool) {
    task?.cancel()
    task = nil
    if clearState {
      state = .idle
    }
  }
}
