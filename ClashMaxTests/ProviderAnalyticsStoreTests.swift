import XCTest
@testable import ClashMax

@MainActor
final class ProviderAnalyticsStoreTests: XCTestCase {
  func testPersistsAndLoadsProviderAnalytics() throws {
    let paths = try Self.makeRuntimePaths()
    let profileID = UUID()
    let store = ProviderAnalyticsStore(paths: paths)
    let provider = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: "HTTP",
      updatedAt: Date(timeIntervalSince1970: 100),
      subscriptionInfo: ProviderSubscriptionInfo(
        upload: 10,
        download: 20,
        total: 100,
        expireAt: Date(timeIntervalSince1970: 200)
      ),
      proxies: [Self.proxyNode(name: "Japan", type: "Vless")]
    )

    store.recordUpdateAttempt(profileID: profileID, kind: .proxy, providerName: "Remote", succeeded: true)
    store.recordSnapshots(profileID: profileID, proxyProviders: [provider], ruleProviders: [])

    let reloaded = ProviderAnalyticsStore(paths: paths)
    let summary = reloaded.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: nil,
      currentRuleProviders: nil,
      now: Date(timeIntervalSince1970: 120)
    )

    XCTAssertEqual(summary.providerCount, 1)
    XCTAssertEqual(summary.updateSuccessRate, 1)
    XCTAssertEqual(summary.rows.first?.providerName, "Remote")
    XCTAssertEqual(summary.rows.first?.itemCount, 1)
    XCTAssertEqual(summary.rows.first?.subscriptionInfo?.total, 100)
  }

  func testRetainsFiftyAttemptsAndComputesSuccessRateFromLatestTwenty() throws {
    let paths = try Self.makeRuntimePaths()
    let profileID = UUID()
    let store = ProviderAnalyticsStore(paths: paths)

    for index in 0..<55 {
      store.recordUpdateAttempt(
        profileID: profileID,
        kind: .proxy,
        providerName: "Remote",
        succeeded: index % 2 == 0,
        at: Date(timeIntervalSince1970: TimeInterval(index))
      )
    }

    let summary = store.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: nil,
      currentRuleProviders: nil
    )

    XCTAssertEqual(store.records.first?.attempts.count, 50)
    XCTAssertEqual(summary.updateAttemptCount, 20)
    XCTAssertEqual(summary.updateSuccessRate, 0.5)
    XCTAssertEqual(summary.rows.first?.successRateSampleCount, 20)
    XCTAssertEqual(summary.rows.first?.successRate, 0.5)
  }

  func testRecentFailureAndCountDeltaUseLatestSnapshots() throws {
    let paths = try Self.makeRuntimePaths()
    let profileID = UUID()
    let store = ProviderAnalyticsStore(paths: paths)
    let first = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: nil,
      updatedAt: nil,
      proxies: (0..<5).map { Self.proxyNode(name: "Node \($0)", type: "Vless") }
    )
    let second = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: nil,
      updatedAt: nil,
      proxies: (0..<8).map { Self.proxyNode(name: "Node \($0)", type: "Vless") }
    )

    store.recordSnapshots(
      profileID: profileID,
      proxyProviders: [first],
      ruleProviders: nil,
      at: Date(timeIntervalSince1970: 10)
    )
    store.recordSnapshots(
      profileID: profileID,
      proxyProviders: [second],
      ruleProviders: nil,
      at: Date(timeIntervalSince1970: 20)
    )
    store.recordUpdateAttempt(
      profileID: profileID,
      kind: .proxy,
      providerName: "Remote",
      succeeded: false,
      errorMessage: "provider refused",
      at: Date(timeIntervalSince1970: 30)
    )

    let row = try XCTUnwrap(store.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: nil,
      currentRuleProviders: nil
    ).rows.first)

    XCTAssertEqual(row.itemCount, 8)
    XCTAssertEqual(row.previousItemCount, 5)
    XCTAssertEqual(row.itemCountDelta, 3)
    XCTAssertEqual(row.lastFailure?.errorMessage, "provider refused")
  }

  func testSubscriptionReminderUsesProviderInfoThenProfileFallback() throws {
    let paths = try Self.makeRuntimePaths()
    let profileID = UUID()
    let store = ProviderAnalyticsStore(paths: paths)
    let provider = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: nil,
      updatedAt: nil,
      proxies: []
    )
    let traffic = SubscriptionTrafficUsage(
      upload: 95,
      download: 0,
      total: 100,
      expireAt: Date(timeIntervalSince1970: 1_000_000)
    )

    store.recordSnapshots(profileID: profileID, proxyProviders: [provider], ruleProviders: nil)
    let summary = store.summary(
      profileID: profileID,
      profileTraffic: traffic,
      currentProxyProviders: nil,
      currentRuleProviders: nil,
      now: Date(timeIntervalSince1970: 100)
    )

    XCTAssertEqual(summary.reminders.first?.severity, .warning)
    XCTAssertEqual(summary.reminders.first?.message, String(localized: "Subscription quota below 10%"))
    XCTAssertEqual(summary.rows.first?.subscriptionInfo?.remainingBytes, 5)
  }

  func testSummaryPrefersCurrentRuntimeDataAndAllowsUnknownRuleCount() throws {
    let paths = try Self.makeRuntimePaths()
    let profileID = UUID()
    let store = ProviderAnalyticsStore(paths: paths)
    let oldProxyProvider = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: nil,
      updatedAt: nil,
      proxies: [Self.proxyNode(name: "Old", type: "Vless")]
    )
    let currentProxyProvider = ProxyProvider(
      name: "Remote",
      type: "http",
      vehicleType: nil,
      updatedAt: nil,
      proxies: [
        Self.proxyNode(name: "Japan", type: "Vless"),
        Self.proxyNode(name: "Singapore", type: "Vless")
      ]
    )
    let currentRuleProvider = RuleProvider(
      name: "Rules",
      type: "http",
      vehicleType: nil,
      behavior: "domain",
      format: "yaml",
      updatedAt: nil,
      ruleCount: nil
    )

    store.recordSnapshots(
      profileID: profileID,
      proxyProviders: [oldProxyProvider],
      ruleProviders: nil,
      at: Date(timeIntervalSince1970: 10)
    )
    let summary = store.summary(
      profileID: profileID,
      profileTraffic: nil,
      currentProxyProviders: [currentProxyProvider],
      currentRuleProviders: [currentRuleProvider]
    )
    let proxyRow = try XCTUnwrap(summary.rows.first { $0.kind == ProviderKind.proxy })
    let ruleRow = try XCTUnwrap(summary.rows.first { $0.kind == ProviderKind.rule })

    XCTAssertTrue(proxyRow.isCurrentRuntimeData)
    XCTAssertEqual(proxyRow.itemCount, 2)
    XCTAssertEqual(proxyRow.itemCountDelta, 1)
    XCTAssertTrue(ruleRow.isCurrentRuntimeData)
    XCTAssertNil(ruleRow.itemCount)
    XCTAssertEqual(ruleRow.countLabel, "-")
  }

  func testProfileTrafficFallbackAppliesToRuleProvidersWithoutProviderSubscriptionInfo() throws {
    let paths = try Self.makeRuntimePaths()
    let profileID = UUID()
    let store = ProviderAnalyticsStore(paths: paths)
    let ruleProvider = RuleProvider(
      name: "Rules",
      type: "http",
      vehicleType: nil,
      behavior: "domain",
      format: "yaml",
      updatedAt: nil,
      ruleCount: 8
    )
    let traffic = SubscriptionTrafficUsage(
      upload: 100,
      download: 0,
      total: 100,
      expireAt: Date(timeIntervalSince1970: 1_000_000)
    )

    store.recordSnapshots(profileID: profileID, proxyProviders: nil, ruleProviders: [ruleProvider])
    let summary = store.summary(
      profileID: profileID,
      profileTraffic: traffic,
      currentProxyProviders: nil,
      currentRuleProviders: nil,
      now: Date(timeIntervalSince1970: 100)
    )
    let row = try XCTUnwrap(summary.rows.first { $0.kind == .rule })

    XCTAssertEqual(row.subscriptionInfo?.total, 100)
    XCTAssertEqual(row.reminder?.severity, .critical)
    XCTAssertEqual(row.reminder?.message, String(localized: "Subscription quota exhausted"))
  }

  func testPruneRemovesDeletedProfileHistory() throws {
    let paths = try Self.makeRuntimePaths()
    let keptID = UUID()
    let deletedID = UUID()
    let store = ProviderAnalyticsStore(paths: paths)
    store.recordUpdateAttempt(profileID: keptID, kind: .proxy, providerName: "Kept", succeeded: true)
    store.recordUpdateAttempt(profileID: deletedID, kind: .rule, providerName: "Deleted", succeeded: false)

    store.prune(validProfileIDs: [keptID])

    XCTAssertEqual(store.records.map(\.profileID), [keptID])
  }

  private static func makeRuntimePaths() throws -> RuntimePaths {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxProviderAnalyticsTests-\(UUID().uuidString)", isDirectory: true)
    let paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    try paths.prepareDirectories()
    return paths
  }

  private static func proxyNode(name: String, type: String) -> ProxyNode {
    ProxyNode(name: name, type: type, delay: nil, isSelectable: true)
  }
}
