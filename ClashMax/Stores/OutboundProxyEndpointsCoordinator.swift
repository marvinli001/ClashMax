import Foundation

/// The shared outbound proxy endpoints as the Profiles page shows them: the list, whether each
/// one's password is in place, its last connection test, and why the list could not be read.
/// Split out of `AppModel` (roadmap D1); it wraps `OutboundProxyEndpointStore` (the persistence
/// actor) and `AppModel` keeps the same members as facades over it, so views and tests read them
/// unchanged. Anything that touches profiles or the running core (reference checks, preflight,
/// reloads, `lastError`) stays on `AppModel`.
@MainActor
@Observable
final class OutboundProxyEndpointsCoordinator {
  private(set) var endpoints: [OutboundProxyEndpoint] = []
  private(set) var secretStates: [UUID: OutboundProxyEndpointSecretState] = [:]
  private(set) var testStates: [UUID: OutboundProxyEndpointTestState] = [:]
  private(set) var loadError: String?

  let store: OutboundProxyEndpointStore
  @ObservationIgnored private var loadTask: Task<Void, Never>?

  init(store: OutboundProxyEndpointStore) {
    self.store = store
  }

  /// The launch-time read. `waitForLoad()` lets callers (and tests) wait for it to land.
  func startLoad() {
    loadTask = Task { @MainActor [weak self] in
      await self?.refresh()
    }
  }

  func waitForLoad() async {
    await loadTask?.value
  }

  func refresh() async {
    do {
      let endpoints = try await store.endpoints()
      var secretStates: [UUID: OutboundProxyEndpointSecretState] = [:]
      for endpoint in endpoints {
        secretStates[endpoint.id] = try await store.resolve(id: endpoint.id).secretState
      }
      self.endpoints = endpoints
      self.secretStates = secretStates
      // A refresh keeps an endpoint's last test result; only endpoints without one start untested.
      for endpoint in endpoints where testStates[endpoint.id] == nil {
        testStates[endpoint.id] = .untested
      }
      testStates = testStates.filter { entry in
        endpoints.contains(where: { $0.id == entry.key })
      }
      loadError = nil
    } catch {
      endpoints = []
      secretStates = [:]
      testStates = [:]
      loadError = UserFacingError.message(for: error)
    }
  }

  func add(_ endpoint: OutboundProxyEndpoint, password: String?) async throws {
    try await store.add(endpoint, password: password)
    await refresh()
    testStates[endpoint.id] = .untested
  }

  /// Deletes the endpoint. Whether a profile still uses it is checked by the caller first.
  func delete(id endpointID: UUID) async throws {
    try await store.delete(id: endpointID)
    await refresh()
    testStates[endpointID] = nil
  }

  /// An edited endpoint has not been tested in its new shape.
  func markUntested(_ endpointID: UUID) {
    testStates[endpointID] = .untested
  }

  /// Fetches the delay test URL through the endpoint. Returns nil when it answered, or the message
  /// to show when it did not; the test state is already updated either way.
  func test(_ endpointID: UUID) async -> String? {
    testStates[endpointID] = .testing
    do {
      let endpoint = try await store.resolve(id: endpointID)
      let configuration = try SubscriptionProxySessionFactory.configuration(
        for: endpoint,
        timeout: 10
      )
      let session = URLSession(configuration: configuration)
      defer { session.finishTasksAndInvalidate() }
      var request = URLRequest(url: AppConstants.defaultDelayTestURL)
      request.timeoutInterval = 10
      let (_, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode)
      else {
        throw URLError(.badServerResponse)
      }
      testStates[endpointID] = .ready
      return nil
    } catch {
      let message = String(localized: "Connection test failed. You can still save this endpoint for offline use.")
      testStates[endpointID] = .unreachable(message)
      return message
    }
  }
}
