import Foundation

/// Proxy delay testing: single-node probes, the coalesced "Test All" batch with its whole-group
/// promotion, and the delay-state cache that carries results across runtime reloads. Split out of
/// `AppModel` (roadmap D1); `AppModel` keeps the same members as facades over this coordinator, so
/// views and tests read them unchanged.
///
/// Results are written into `RuntimeDataStore` and `ProxyPreviewStore` — the collections the views
/// read — through the same setters `AppModel`'s facades use, so a delay result invalidates exactly
/// what it did before the split (and `profilePreviewGroups`' change hook still fires).
@MainActor
@Observable
final class ProxyDelayTestCoordinator {
  /// What only `AppModel` can answer or do. Configured once at the end of its setup.
  struct Hooks {
    var nativePingHost: @MainActor (ProxyNode) -> String? = { _ in nil }
    var publishWarningNotice: @MainActor (_ message: String, _ logMessage: String?) -> Void = { _, _ in }
    var reloadRuntimeData: @MainActor () -> Void = {}
  }

  private(set) var proxyDelayBatchProgress: ProxyDelayBatchProgress?
  @ObservationIgnored private var delayTestTasks: [ProxyNodeKey: Task<Void, Never>] = [:]
  @ObservationIgnored private var delayTestTokens: [ProxyNodeKey: UUID] = [:]
  @ObservationIgnored private var delayStateCache: [ProxyNodeKey: ProxyDelayCacheEntry] = [:]
  @ObservationIgnored private var proxyDelayBatchTask: Task<Void, Never>?
  @ObservationIgnored private var proxyDelayBatchToken: UUID?
  @ObservationIgnored private var hooks = Hooks()
  private let runtimeData: RuntimeDataStore
  private let proxyPreview: ProxyPreviewStore
  private let pingTester: any PingTesting
  private let delayStateCacheTTL: TimeInterval
  private static let proxyDelayBatchConcurrencyLimit = 6
  // Issue #10/#11 upstream: a whole-group probe replaces one HTTP request per node with a single
  // `/group/{name}/delay` call. It is only worth it above this many members. The core holds a
  // group probe open for the entire timeout window, so it yields no partial results, whereas the
  // per-node path finishes a group of `proxyDelayBatchConcurrencyLimit` members in a single
  // concurrency wave — roughly the same wall time, but with results appearing as they land.
  // The threshold is therefore set just past one full wave.
  private static let proxyGroupDelayMinimumMembers = proxyDelayBatchConcurrencyLimit + 2
  // Issue #11: batch delay results are coalesced before touching observable state. A flush
  // happens once `proxyDelayBatchFlushCount` results have accumulated or once
  // `proxyDelayBatchFlushIntervalMs` has elapsed since the last flush, whichever comes first
  // (the very first result flushes immediately so results start appearing without delay).
  private static let proxyDelayBatchFlushCount = 24
  private static let proxyDelayBatchFlushIntervalMs: Double = 120

  init(
    runtimeData: RuntimeDataStore,
    proxyPreview: ProxyPreviewStore,
    pingTester: any PingTesting,
    delayStateCacheTTL: TimeInterval
  ) {
    self.runtimeData = runtimeData
    self.proxyPreview = proxyPreview
    self.pingTester = pingTester
    self.delayStateCacheTTL = delayStateCacheTTL
  }

  func configureHooks(_ hooks: Hooks) {
    self.hooks = hooks
  }

  /// Whether a batch still holds its task. Not the same as `proxyDelayBatchProgress?.isRunning`: the
  /// progress finishes before the task's `defer` clears it, and a new batch must wait for both.
  var isBatchTaskActive: Bool {
    proxyDelayBatchTask != nil
  }

  func cancelBatch() {
    guard proxyDelayBatchProgress?.isRunning == true else { return }
    proxyDelayBatchTask?.cancel()
  }

  /// One node's probe. The caller has already checked the node is testable and resolved the keys;
  /// a newer probe of the same node supersedes this one through the token.
  func testDelay(
    for node: ProxyNode,
    in group: ProxyGroup,
    nodeKey: ProxyNodeKey,
    taskKey: ProxyNodeKey,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    testURL effectiveTestURL: URL,
    reloadAfterCompletion: Bool
  ) {
    delayTestTasks[taskKey]?.cancel()
    let token = UUID()
    delayTestTokens[taskKey] = token
    applyDelayState(.testing, to: nodeKey)
    delayTestTasks[taskKey] = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if delayTestTokens[taskKey] == token {
          delayTestTasks[taskKey] = nil
          delayTestTokens[taskKey] = nil
        }
      }
      do {
        let delay = try await measureDelay(for: node, apiClient: apiClient, settings: settings, testURL: effectiveTestURL)
        guard delayTestTokens[taskKey] == token, !Task.isCancelled else { return }
        applyDelayState(.measured(delay), to: nodeKey)
        if reloadAfterCompletion {
          reloadRuntimeData()
        }
      } catch is CancellationError {
        return
      } catch {
        guard delayTestTokens[taskKey] == token else { return }
        let message = UserFacingError.message(for: error)
        applyDelayState(delayState(message: message), to: nodeKey)
        publishDelayWarning(for: node, in: group, message: message)
      }
    }
  }

  /// Starts a "Test All" batch over items the caller built from the visible groups.
  func startBatch(items: [ProxyDelayBatchItem], apiClient: any MihomoAPIControlling, settings: DelayTestSettings) {
    let pingTester = pingTester
    let token = UUID()
    proxyDelayBatchToken = token
    proxyDelayBatchProgress = .started(total: items.count)
    // Issue #11: mark every node testing in one coalesced write instead of one publish per node.
    var testingStates: [ProxyNodeKey: ProxyDelayState] = [:]
    testingStates.reserveCapacity(items.count)
    for item in items {
      cancelDelayTestTask(for: item.taskKey)
      testingStates[item.nodeKey] = .testing
    }
    applyDelayStates(testingStates)

    proxyDelayBatchTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await runProxyDelayBatch(
        items: items,
        apiClient: apiClient,
        settings: settings,
        pingTester: pingTester,
        token: token
      )
    }
  }

  /// Drops every in-flight probe when the runtime goes away. A finished batch keeps its progress so
  /// the strip can still report how it ended.
  func cancelAll() {
    delayTestTasks.values.forEach { $0.cancel() }
    delayTestTasks.removeAll()
    delayTestTokens.removeAll()
    proxyDelayBatchTask?.cancel()
    proxyDelayBatchTask = nil
    proxyDelayBatchToken = nil
    if proxyDelayBatchProgress?.isRunning == true {
      proxyDelayBatchProgress = nil
    }
  }

  /// The cached delay state for every node in `groups`, so a reload can put it back.
  func delayStateMap(
    from groups: [ProxyGroup],
    nodeKey proxyNodeKey: (_ group: ProxyGroup, _ node: ProxyNode) -> ProxyNodeKey
  ) -> [ProxyNodeKey: ProxyDelayState] {
    pruneExpiredDelayStates()
    return groups.reduce(into: [ProxyNodeKey: ProxyDelayState]()) { result, group in
      for node in group.nodes {
        let key = proxyNodeKey(group, node)
        if let entry = latestDelayCacheEntry(matching: key) {
          result[key] = entry.state
        }
      }
    }
  }

  /// Re-applies cached delay states onto freshly fetched providers so a runtime reload or
  /// provider-metadata refresh does not blank the delay of provider-backed visible nodes
  /// (issue #12). The cache is the source of truth; nodes with no live cache entry stay as-is.
  func providersPreservingKnownDelayStates(
    _ providers: [ProxyProvider],
    activeProfileID: String?
  ) -> [ProxyProvider] {
    guard !providers.isEmpty else { return providers }
    pruneExpiredDelayStates()
    return providers.map { provider in
      guard let providerName = provider.name.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
      else { return provider }
      var provider = provider
      provider.proxies = provider.proxies.map { node in
        guard let entry = latestProviderDelayCacheEntry(
          providerName: providerName,
          nodeName: node.name,
          profileID: activeProfileID
        ) else {
          return node
        }
        var node = node
        node.delayState = entry.state
        if let delay = entry.state.measuredDelay, node.delay == nil {
          node.delay = delay
        }
        return node
      }
      return provider
    }
  }

  private var proxyGroups: [ProxyGroup] {
    get { runtimeData.proxyGroups }
    set { runtimeData.proxyGroups = newValue }
  }

  private var proxyProviders: [ProxyProvider] {
    get { runtimeData.proxyProviders }
    set { runtimeData.proxyProviders = newValue }
  }

  private var profilePreviewGroups: [ProxyGroup] {
    get { proxyPreview.profilePreviewGroups }
    set { proxyPreview.profilePreviewGroups = newValue }
  }

  private func nativePingHost(for node: ProxyNode) -> String? {
    hooks.nativePingHost(node)
  }

  private func publishWarningNotice(_ message: String, logMessage: String? = nil) {
    hooks.publishWarningNotice(message, logMessage)
  }

  private func reloadRuntimeData() {
    hooks.reloadRuntimeData()
  }

  private func runProxyDelayBatch(
    items: [ProxyDelayBatchItem],
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    pingTester: any PingTesting,
    token: UUID
  ) async {
    var completedKeys = Set<ProxyNodeKey>()
    // Issue #11: accumulate per-result node states and progress mutations, then publish them in
    // coalesced flushes (by count or elapsed time) instead of once per result, so the list stays
    // scrollable while "Test All" runs over a large catalog.
    var pendingStates: [ProxyNodeKey: ProxyDelayState] = [:]
    var pendingProgress: [(inout ProxyDelayBatchProgress) -> Void] = []
    var processedSinceFlush = 0
    var lastFlushNanos: UInt64 = 0
    defer {
      if proxyDelayBatchToken == token {
        proxyDelayBatchTask = nil
        proxyDelayBatchToken = nil
      }
    }

    func flushPending() {
      if !pendingStates.isEmpty {
        applyDelayStates(pendingStates)
        pendingStates.removeAll(keepingCapacity: true)
      }
      if !pendingProgress.isEmpty {
        let mutations = pendingProgress
        pendingProgress.removeAll(keepingCapacity: true)
        updateProxyDelayBatchProgress(token: token) { progress in
          for mutate in mutations {
            mutate(&progress)
          }
        }
      }
      processedSinceFlush = 0
      lastFlushNanos = DispatchTime.now().uptimeNanoseconds
    }

    func flushIfThresholdReached() {
      guard processedSinceFlush > 0 else { return }
      // A zero sentinel forces the very first result to flush immediately (so results start
      // appearing right away); subsequent results coalesce up to the count or time threshold.
      let elapsedMs = lastFlushNanos == 0
        ? .greatestFiniteMagnitude
        : Double(DispatchTime.now().uptimeNanoseconds &- lastFlushNanos) / 1_000_000
      if processedSinceFlush >= Self.proxyDelayBatchFlushCount
        || elapsedMs >= Self.proxyDelayBatchFlushIntervalMs
      {
        flushPending()
      }
    }

    // Issue #10/#11 upstream: the batch is scheduled as *units*, not nodes. A unit is either one
    // node (the original per-node probe) or a whole group answered by a single
    // `/group/{name}/delay` call, which is what keeps a 1600-node catalog from issuing 1600
    // requests. A group unit that the core cannot answer degrades into its node units instead of
    // failing, so an older core or a renamed group behaves exactly as it did before.
    var units = Self.proxyDelayBatchUnits(items: items, settings: settings)
    let concurrencyLimit = Self.proxyDelayBatchConcurrencyLimit
    await withTaskGroup(of: ProxyDelayBatchUnitOutcome.self) { taskGroup in
      var nextIndex = 0
      var inFlight = 0

      func scheduleAvailableUnits() {
        // Units are not interchangeable: a group unit costs the whole budget because the core fans
        // out over its members itself (see `ProxyDelayBatchUnit.concurrencyCost`). The
        // `inFlight == 0` arm is what guarantees forward progress — a unit priced at or above the
        // whole budget always runs once the batch has drained, so the loop can never end with
        // units left unscheduled.
        while nextIndex < units.count {
          let unit = units[nextIndex]
          let cost = unit.concurrencyCost(budget: concurrencyLimit)
          guard inFlight == 0 || inFlight + cost <= concurrencyLimit else { break }
          nextIndex += 1
          inFlight += cost
          taskGroup.addTask {
            let result = await Self.measureBatchUnit(
              unit,
              apiClient: apiClient,
              settings: settings,
              pingTester: pingTester
            )
            return ProxyDelayBatchUnitOutcome(concurrencyCost: cost, result: result)
          }
        }
      }

      scheduleAvailableUnits()

      while let unitOutcome = await taskGroup.next() {
        inFlight -= unitOutcome.concurrencyCost
        let unitResult = unitOutcome.result
        guard proxyDelayBatchToken == token else {
          taskGroup.cancelAll()
          break
        }
        guard !Task.isCancelled else {
          taskGroup.cancelAll()
          break
        }

        let results: [ProxyDelayBatchItemResult]
        switch unitResult {
        case let .measured(itemResults):
          results = itemResults
        case let .unsupportedGroup(fallbackItems):
          // The group endpoint refused this group (unknown name, or a core without it). Re-queue
          // its members as ordinary per-node units so the batch never loses coverage.
          units.append(contentsOf: fallbackItems.map { ProxyDelayBatchUnit.node($0) })
          results = []
        }

        for result in results {
          switch result.outcome {
          case let .success(delay):
            completedKeys.insert(result.item.nodeKey)
            pendingStates[result.item.nodeKey] = .measured(delay)
            pendingProgress.append { progress in progress.recordSuccess() }
            processedSinceFlush += 1
          case let .failure(kind, message):
            guard kind != .cancelled else {
              // Restoration is handled in one batch by `restoreCancelledBatchItems` once the loop
              // unwinds, so cancelled in-flight results need no per-item publish here.
              continue
            }
            completedKeys.insert(result.item.nodeKey)
            pendingStates[result.item.nodeKey] = delayState(kind: kind, message: message)
            let failure = ProxyDelayBatchFailure(
              nodeKey: result.item.nodeKey,
              groupName: result.item.groupName,
              nodeName: result.item.node.name,
              providerName: result.item.node.providerName,
              kind: kind,
              message: message
            )
            pendingProgress.append { progress in progress.recordFailure(failure) }
            processedSinceFlush += 1
          }
        }

        flushIfThresholdReached()
        scheduleAvailableUnits()
      }
    }

    // Always force a final flush so completed results / progress land even below the threshold.
    flushPending()

    guard proxyDelayBatchToken == token else { return }

    // Only nodes that never produced a result are genuinely untested. If everything already
    // landed before the cancellation arrived, fall through and report the real completed/partial/
    // failed outcome instead of a misleading "cancelled" (issue #18).
    let cancelledItems: [ProxyDelayBatchItem]
    if Task.isCancelled {
      restoreCancelledBatchItems(items, completedKeys: completedKeys)
      cancelledItems = items.filter { !completedKeys.contains($0.nodeKey) }
    } else {
      cancelledItems = []
    }

    // Record each untested node as a cancelled failure so the strip and diagnostics can name them.
    // Built once and applied in a single coalesced progress update to preserve the issue #11
    // publish budget.
    let cancelledMessage = NSLocalizedString(
      "Cancelled before testing.",
      comment: "Batch delay failure reason shown for nodes skipped because the batch was cancelled."
    )
    let cancelledFailures = cancelledItems.map { item in
      ProxyDelayBatchFailure(
        nodeKey: item.nodeKey,
        groupName: item.groupName,
        nodeName: item.node.name,
        providerName: item.node.providerName,
        kind: .cancelled,
        message: cancelledMessage
      )
    }

    updateProxyDelayBatchProgress(token: token) { progress in
      for failure in cancelledFailures {
        progress.recordFailure(failure)
      }
      progress.finish()
    }

    if cancelledItems.isEmpty,
       let progress = proxyDelayBatchProgress,
       progress.failureCount > 0
    {
      let message = String.localizedStringWithFormat(
        NSLocalizedString("Batch delay test finished with %lld failures.", comment: ""),
        Int64(progress.failureCount)
      )
      publishWarningNotice(message, logMessage: "\(message)\n\(progress.diagnosticText)")
    }
    reloadRuntimeData()
  }

  private func measureDelay(
    for node: ProxyNode,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    testURL: URL
  ) async throws -> Int {
    let attempts = settings.clientSideProbeAttempts
    var lastDelay: Int?
    var lastError: Error?

    for _ in 0..<attempts {
      do {
        lastDelay = try await measureDelayOnce(for: node, apiClient: apiClient, settings: settings, testURL: testURL)
        lastError = nil
      } catch {
        lastError = error
        if attempts == 1 {
          throw error
        }
      }
    }

    if let lastDelay {
      return lastDelay
    }
    throw lastError ?? DelayTestError.noResult(node.name)
  }

  private func measureDelayOnce(
    for node: ProxyNode,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    testURL: URL
  ) async throws -> Int {
    switch settings.mode {
    case .mihomoURL:
      return try await apiClient.testDelay(
        proxy: node.name,
        testURL: testURL,
        timeout: settings.normalizedTimeoutMilliseconds
      )
    case .nativePing:
      let host = nativePingHost(for: node) ?? ""
      guard !host.isEmpty else {
        throw DelayTestError.missingServerHost(node.name)
      }
      return try await pingTester.ping(host: host, timeoutMilliseconds: settings.normalizedTimeoutMilliseconds)
    }
  }

  /// Splits a flat batch into scheduling units, promoting every group large enough to be worth a
  /// single `/group/{name}/delay` call.
  ///
  /// A group is only promoted when all of these hold:
  /// - the probe actually goes through the core (`.nativePing` measures from this process, so
  ///   there is no core endpoint to call);
  /// - the group has a real name — `testDelay(for:)` synthesises an unnamed group for a node that
  ///   belongs to no visible group, and the core has no such group to probe;
  /// - every member shares one test URL, since the endpoint takes a single `url`;
  /// - the group has more than one concurrency wave of members, so the loss of incremental
  ///   results buys a real reduction in requests.
  static func proxyDelayBatchUnits(
    items: [ProxyDelayBatchItem],
    settings: DelayTestSettings
  ) -> [ProxyDelayBatchUnit] {
    guard settings.mode == .mihomoURL else {
      return items.map { .node($0) }
    }

    // Grouping preserves first-seen order so the batch still runs top-to-bottom over the page.
    var order: [String] = []
    var grouped: [String: [ProxyDelayBatchItem]] = [:]
    for item in items {
      if grouped[item.groupName] == nil {
        order.append(item.groupName)
      }
      grouped[item.groupName, default: []].append(item)
    }

    return order.flatMap { groupName -> [ProxyDelayBatchUnit] in
      let members = grouped[groupName] ?? []
      guard !groupName.isEmpty,
            members.count >= proxyGroupDelayMinimumMembers,
            let testURL = members.first?.testURL,
            members.allSatisfy({ $0.testURL == testURL })
      else {
        return members.map { .node($0) }
      }
      return [.group(name: groupName, testURL: testURL, items: members)]
    }
  }

  private static func measureBatchUnit(
    _ unit: ProxyDelayBatchUnit,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    pingTester: any PingTesting
  ) async -> ProxyDelayBatchUnitResult {
    switch unit {
    case let .node(item):
      let result = await measureBatchDelay(
        item: item,
        apiClient: apiClient,
        settings: settings,
        pingTester: pingTester
      )
      return .measured([result])
    case let .group(name, testURL, items):
      return await measureBatchGroupDelay(
        groupName: name,
        testURL: testURL,
        items: items,
        apiClient: apiClient,
        settings: settings
      )
    }
  }

  /// One `/group/{name}/delay` call, mapped back onto the batch items it covers.
  ///
  /// The endpoint's failure model is the opposite of the per-node one and drives everything here
  /// (contract measured against the bundled core, v1.19.30):
  /// - it answers 200 with only the members that succeeded, so **a member missing from the
  ///   response is a failed probe**, reported as a timeout — the same classification the per-node
  ///   path derives from its 504 `Timeout` body, which keeps the issue #18 batch semantics
  ///   (completed / partial / failed) identical across both paths;
  /// - members the core does not know about simply never appear, and members it knows that we did
  ///   not ask about are ignored, so the item list stays authoritative;
  /// - an unknown group is a 404 for the whole call rather than a node failure, so it degrades to
  ///   the per-node path instead of reporting that every member failed.
  ///
  /// Attempt count comes from `DelayTestSettings.clientSideProbeAttempts`, which is 1 here: this
  /// path only runs in `.mihomoURL` mode, where the core honours `unified-delay` itself. The
  /// per-node path uses the same rule, so a batch no longer measures differently either side of
  /// the promotion floor.
  private static func measureBatchGroupDelay(
    groupName: String,
    testURL: URL,
    items: [ProxyDelayBatchItem],
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings
  ) async -> ProxyDelayBatchUnitResult {
    let delays: [String: Int]
    do {
      delays = try await apiClient.testGroupDelay(
        group: groupName,
        testURL: testURL,
        timeout: settings.normalizedTimeoutMilliseconds
      )
    } catch is CancellationError {
      return .measured(items.map {
        ProxyDelayBatchItemResult(item: $0, outcome: .failure(.cancelled, "Cancelled"))
      })
    } catch {
      guard !Task.isCancelled else {
        return .measured(items.map {
          ProxyDelayBatchItemResult(item: $0, outcome: .failure(.cancelled, "Cancelled"))
        })
      }
      // Only "this core has no such group" degrades to the per-node path. That single signal
      // covers both cases the fallback exists for: a group that was renamed out from under the
      // batch, and a core too old to route `/group/{name}/delay` at all — the API client maps the
      // 404 both produce onto `unknownProxyGroup`.
      //
      // Every other error stays a failure of this unit. Re-expanding on a 500, a dropped
      // connection or a client-side timeout would answer one failed request with one request per
      // member at the exact moment the core is least able to serve them, which is a larger version
      // of the request storm this path exists to prevent.
      if let clientError = error as? MihomoAPIClient.ClientError,
         case .unknownProxyGroup = clientError
      {
        return .unsupportedGroup(items)
      }
      let message = UserFacingError.message(for: error)
      let kind = delayFailureKind(for: error, message: message)
      return .measured(items.map {
        ProxyDelayBatchItemResult(item: $0, outcome: .failure(kind, message))
      })
    }

    guard !Task.isCancelled else {
      return .measured(items.map {
        ProxyDelayBatchItemResult(item: $0, outcome: .failure(.cancelled, "Cancelled"))
      })
    }

    let timeoutMessage = NSLocalizedString(
      "The proxy group delay test did not report a result for this node.",
      comment: "Batch delay failure reason for a node omitted from the whole-group delay response."
    )
    return .measured(items.map { item in
      guard let delay = delays[item.node.name] else {
        return ProxyDelayBatchItemResult(item: item, outcome: .failure(.timeout, timeoutMessage))
      }
      return ProxyDelayBatchItemResult(item: item, outcome: .success(delay))
    })
  }

  private static func measureBatchDelay(
    item: ProxyDelayBatchItem,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    pingTester: any PingTesting
  ) async -> ProxyDelayBatchItemResult {
    do {
      let delay = try await measureBatchDelayValue(
        item: item,
        apiClient: apiClient,
        settings: settings,
        pingTester: pingTester
      )
      guard !Task.isCancelled else {
        return ProxyDelayBatchItemResult(item: item, outcome: .failure(.cancelled, "Cancelled"))
      }
      return ProxyDelayBatchItemResult(item: item, outcome: .success(delay))
    } catch is CancellationError {
      return ProxyDelayBatchItemResult(item: item, outcome: .failure(.cancelled, "Cancelled"))
    } catch {
      let message = UserFacingError.message(for: error)
      return ProxyDelayBatchItemResult(
        item: item,
        outcome: .failure(delayFailureKind(for: error, message: message), message)
      )
    }
  }

  private static func measureBatchDelayValue(
    item: ProxyDelayBatchItem,
    apiClient: any MihomoAPIControlling,
    settings: DelayTestSettings,
    pingTester: any PingTesting
  ) async throws -> Int {
    let attempts = settings.clientSideProbeAttempts
    var lastDelay: Int?
    var lastError: Error?

    for _ in 0..<attempts {
      do {
        switch settings.mode {
        case .mihomoURL:
          lastDelay = try await apiClient.testDelay(
            proxy: item.node.name,
            testURL: item.testURL,
            timeout: settings.normalizedTimeoutMilliseconds
          )
        case .nativePing:
          let trimmedHost = item.nativePingHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          guard !trimmedHost.isEmpty else {
            throw DelayTestError.missingServerHost(item.node.name)
          }
          lastDelay = try await pingTester.ping(
            host: trimmedHost,
            timeoutMilliseconds: settings.normalizedTimeoutMilliseconds
          )
        }
        lastError = nil
      } catch {
        lastError = error
        if attempts == 1 {
          throw error
        }
      }
    }

    if let lastDelay {
      return lastDelay
    }
    throw lastError ?? DelayTestError.noResult(item.node.name)
  }

  private func applyDelayState(_ state: ProxyDelayState, to nodeKey: ProxyNodeKey) {
    applyDelayStates([nodeKey: state])
  }

  /// Applies a batch of delay-state updates with at most one observable write per affected
  /// collection.
  ///
  /// Issue #11: `startProxyDelayBatch` / `runProxyDelayBatch` previously called the single-node
  /// `applyDelayState` once per node — each call re-assigned `proxyGroups`,
  /// `profilePreviewGroups`, and `proxyProviders` and re-pruned the cache — so a "Test All" over
  /// 1000+ nodes published thousands of times and froze list scrolling. Coalescing the writes
  /// (cache recorded once, each collection rebuilt in a single pass and only re-assigned when a
  /// node actually changed) keeps the list smooth while the batch runs.
  private func applyDelayStates(_ updates: [ProxyNodeKey: ProxyDelayState], now: Date = Date()) {
    guard !updates.isEmpty else { return }

    // Record every cache entry first, then prune a single time.
    for (key, state) in updates {
      if state == .unknown {
        delayStateCache.removeValue(forKey: key)
      } else {
        delayStateCache[key] = ProxyDelayCacheEntry(state: state, recordedAt: now)
      }
    }
    pruneExpiredDelayStates(now: now)

    // Build lookup indexes that mirror `nodeMatches` / provider matching so each collection can
    // resolve every node's new state in a single O(nodes + updates) pass. A `nil` key provider is
    // a wildcard that matches any node with that name (matching the previous single-node logic).
    var exactByProvider: [String: ProxyDelayState] = [:]
    var wildcardByName: [String: ProxyDelayState] = [:]
    var providerByName: [String: ProxyDelayState] = [:]
    for (key, state) in updates {
      if let providerName = key.providerName {
        exactByProvider[Self.nodeMatchKey(group: key.groupName, node: key.nodeName, provider: providerName)] = state
        providerByName[Self.providerMatchKey(provider: providerName, node: key.nodeName)] = state
      } else {
        wildcardByName[Self.nodeMatchKey(group: key.groupName, node: key.nodeName)] = state
      }
    }

    // Update the runtime + preview group collections, each with at most one publish.
    if !proxyGroups.isEmpty {
      var groups = proxyGroups
      if applyDelayStates(exactByProvider: exactByProvider, wildcardByName: wildcardByName, to: &groups) {
        proxyGroups = groups
      }
    }
    if !profilePreviewGroups.isEmpty {
      var preview = profilePreviewGroups
      if applyDelayStates(exactByProvider: exactByProvider, wildcardByName: wildcardByName, to: &preview) {
        profilePreviewGroups = preview
      }
    }

    // Provider-backed nodes are surfaced in ProxiesView by expanding `proxyProviders`
    // (see ResolvedProxyCatalog), which the group collections never touch. Keep the provider copy
    // in sync so the visible node reflects the live delay state (issue #12).
    if !providerByName.isEmpty, !proxyProviders.isEmpty {
      var providers = proxyProviders
      var didChange = false
      for providerIndex in providers.indices {
        guard let providerName = providers[providerIndex].name
          .trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        else { continue }
        for nodeIndex in providers[providerIndex].proxies.indices {
          let nodeName = providers[providerIndex].proxies[nodeIndex].name
          guard let state = providerByName[Self.providerMatchKey(provider: providerName, node: nodeName)]
          else { continue }
          if applyDelayState(state, to: &providers[providerIndex].proxies[nodeIndex]) {
            didChange = true
          }
        }
      }
      if didChange {
        proxyProviders = providers
      }
    }
  }

  /// Applies the prepared indexes to one group collection in a single pass, returning whether any
  /// node actually changed (so the caller can skip a redundant observable write).
  private func applyDelayStates(
    exactByProvider: [String: ProxyDelayState],
    wildcardByName: [String: ProxyDelayState],
    to groups: inout [ProxyGroup]
  ) -> Bool {
    var didChange = false
    for groupIndex in groups.indices {
      let groupName = groups[groupIndex].name
      for nodeIndex in groups[groupIndex].nodes.indices {
        let node = groups[groupIndex].nodes[nodeIndex]
        let resolved: ProxyDelayState?
        if let providerName = node.providerName,
           let match = exactByProvider[Self.nodeMatchKey(group: groupName, node: node.name, provider: providerName)]
        {
          resolved = match
        } else {
          resolved = wildcardByName[Self.nodeMatchKey(group: groupName, node: node.name)]
        }
        guard let state = resolved else { continue }
        if applyDelayState(state, to: &groups[groupIndex].nodes[nodeIndex]) {
          didChange = true
        }
      }
    }
    return didChange
  }

  private static func nodeMatchKey(group: String, node: String, provider: String) -> String {
    "\(group)\u{1}\(node)\u{1}\(provider)"
  }

  private static func nodeMatchKey(group: String, node: String) -> String {
    "\(group)\u{1}\(node)"
  }

  private static func providerMatchKey(provider: String, node: String) -> String {
    "\(provider)\u{1}\(node)"
  }

  /// Mutates a node's delay state, returning whether anything actually changed so batch callers
  /// can avoid republishing an unchanged collection.
  @discardableResult
  private func applyDelayState(_ state: ProxyDelayState, to node: inout ProxyNode) -> Bool {
    let previousState = node.delayState
    let previousDelay = node.delay
    node.delayState = state
    if case let .measured(delay) = state, delay >= 0 {
      node.delay = delay
    } else if state == .timeout || isErrorDelayState(state) {
      node.delay = nil
    }
    return node.delayState != previousState || node.delay != previousDelay
  }

  private func isErrorDelayState(_ state: ProxyDelayState) -> Bool {
    if case .error = state {
      return true
    }
    return false
  }

  private func cancelDelayTestTask(for taskKey: ProxyNodeKey) {
    delayTestTasks[taskKey]?.cancel()
    delayTestTasks[taskKey] = nil
    delayTestTokens[taskKey] = nil
  }

  private func updateProxyDelayBatchProgress(
    token: UUID,
    _ update: (inout ProxyDelayBatchProgress) -> Void
  ) {
    guard proxyDelayBatchToken == token,
          var progress = proxyDelayBatchProgress
    else { return }
    update(&progress)
    proxyDelayBatchProgress = progress
  }

  private func pruneExpiredDelayStates(now: Date = Date()) {
    guard delayStateCacheTTL > 0 else {
      delayStateCache.removeAll()
      return
    }
    delayStateCache = delayStateCache.filter { _, entry in
      now.timeIntervalSince(entry.recordedAt) <= delayStateCacheTTL
    }
  }

  private func delayState(message: String) -> ProxyDelayState {
    let normalized = message.lowercased()
    if normalized.contains("timeout") || normalized.contains("timed out") {
      return .timeout
    }
    return .error(message)
  }

  private func publishDelayWarning(for node: ProxyNode, in group: ProxyGroup, message: String) {
    let notice = String.localizedStringWithFormat(
      NSLocalizedString("Delay test failed for %@. See Logs for details.", comment: ""),
      node.name
    )
    let targetName = group.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? node.name
      : "\(group.name) / \(node.name)"
    publishWarningNotice(notice, logMessage: "Delay test failed for \(targetName): \(message)")
  }

  private func delayState(kind: ProxyDelayFailureKind, message: String) -> ProxyDelayState {
    switch kind {
    case .timeout:
      return .timeout
    case .cancelled:
      return .unknown
    case .missingEndpoint, .controllerUnavailable, .other:
      return .error(message)
    }
  }

  private static func delayFailureKind(for error: Error, message: String) -> ProxyDelayFailureKind {
    if error is CancellationError {
      return .cancelled
    }
    if let clientError = error as? MihomoAPIClient.ClientError,
       case .delayTestHTTPStatus = clientError
    {
      return .other
    }
    if let delayError = error as? DelayTestError {
      switch delayError {
      case .missingServerHost:
        return .missingEndpoint
      case .noResult:
        break
      }
    }

    let normalized = message.lowercased()
    if normalized.contains("timeout") || normalized.contains("timed out") {
      return .timeout
    }
    if normalized.contains("controller responded")
      || normalized.contains("delay probe returned http")
    {
      return .other
    }
    if normalized.contains("mihomo controller")
      || normalized.contains("controller")
      || normalized.contains("could not connect to the server")
      || normalized.contains("cannot connect to the server")
      || normalized.contains("unable to connect to the server")
      || normalized.contains("无法连接服务器")
      || normalized.contains("127.0.0.1:9097")
    {
      return .controllerUnavailable
    }
    return .other
  }

  private func restoreCancelledBatchItems(_ items: [ProxyDelayBatchItem], completedKeys: Set<ProxyNodeKey>) {
    var updates: [ProxyNodeKey: ProxyDelayState] = [:]
    for item in items where !completedKeys.contains(item.nodeKey) {
      updates[item.nodeKey] = item.previousState == .testing ? .unknown : item.previousState
    }
    applyDelayStates(updates)
  }

  private func latestDelayCacheEntry(matching key: ProxyNodeKey) -> ProxyDelayCacheEntry? {
    delayStateCache
      .filter { cachedKey, _ in
        cachedKey.matchesNodeIdentity(of: key)
      }
      .max { lhs, rhs in
        lhs.value.recordedAt < rhs.value.recordedAt
      }?
      .value
  }

  private func latestProviderDelayCacheEntry(
    providerName: String,
    nodeName: String,
    profileID: String?
  ) -> ProxyDelayCacheEntry? {
    delayStateCache
      .filter { key, _ in
        key.profileID == profileID
          && key.providerName == providerName
          && key.nodeName == nodeName
      }
      .max { lhs, rhs in
        lhs.value.recordedAt < rhs.value.recordedAt
      }?
      .value
  }
}

private enum DelayTestError: LocalizedError {
  case missingServerHost(String)
  case noResult(String)

  var errorDescription: String? {
    switch self {
    case let .missingServerHost(nodeName):
      return "Native ping needs a server host for \(nodeName). Refresh runtime data or switch to Mihomo URL Delay."
    case let .noResult(nodeName):
      return "Delay test for \(nodeName) finished without a result."
    }
  }
}

private struct ProxyDelayCacheEntry {
  var state: ProxyDelayState
  var recordedAt: Date
}

struct ProxyDelayBatchItem: Sendable {
  var groupName: String
  var node: ProxyNode
  var nodeKey: ProxyNodeKey
  var taskKey: ProxyNodeKey
  var testURL: URL
  var previousState: ProxyDelayState
  var nativePingHost: String?
}

/// One scheduling slot in a batch delay run: either a single node probe or a whole-group probe.
enum ProxyDelayBatchUnit: Sendable {
  case node(ProxyDelayBatchItem)
  case group(name: String, testURL: URL, items: [ProxyDelayBatchItem])

  /// How much of the batch's concurrency budget this unit occupies while it is in flight.
  ///
  /// A node unit is one request measuring one node, so it costs one slot. A group unit is one
  /// request that makes the **core** probe every member at once — mihomo's group `URLTest` starts
  /// one goroutine per member with no internal wave limit, which the A6 measurement confirmed by
  /// resolving all 1200 members of a synthetic group inside a single 5 s timeout window.
  ///
  /// Charging a group unit one slot like a node would therefore let the scheduler put six *whole
  /// groups* in flight against a six-slot budget: a catalog with several large groups would turn
  /// into thousands of simultaneous probes, which is a bigger burst than the per-node fan-out this
  /// path replaced. Charging it the whole budget keeps at most one group's worth of probes running
  /// and still costs one request per group.
  func concurrencyCost(budget: Int) -> Int {
    switch self {
    case .node:
      return 1
    case .group:
      return max(1, budget)
    }
  }
}

private enum ProxyDelayBatchUnitResult: Sendable {
  case measured([ProxyDelayBatchItemResult])
  /// The core could not answer a whole-group probe for these items; run them one by one instead.
  case unsupportedGroup([ProxyDelayBatchItem])
}

/// A finished unit together with the concurrency budget it was holding, so the scheduler returns
/// exactly what it charged instead of assuming every unit costs one slot.
private struct ProxyDelayBatchUnitOutcome: Sendable {
  var concurrencyCost: Int
  var result: ProxyDelayBatchUnitResult
}

private struct ProxyDelayBatchItemResult: Sendable {
  var item: ProxyDelayBatchItem
  var outcome: ProxyDelayBatchItemOutcome
}

private enum ProxyDelayBatchItemOutcome: Sendable {
  case success(Int)
  case failure(ProxyDelayFailureKind, String)
}

private extension ProxyNodeKey {
  func matchesNodeIdentity(of other: ProxyNodeKey) -> Bool {
    profileID == other.profileID
      && groupName == other.groupName
      && nodeName == other.nodeName
      && providerName == other.providerName
  }
}
