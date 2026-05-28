import Foundation

@MainActor
final class ProviderAnalyticsStore: ObservableObject {
  private struct RecordKey: Hashable {
    var profileID: Profile.ID
    var kind: ProviderKind
    var providerName: String
  }

  private static let retainedAttemptCount = 50
  private static let retainedSnapshotCount = 2
  private static let successRateWindow = 20

  @Published private(set) var records: [ProviderAnalyticsRecord] = []

  private let fileURL: URL
  private let fileManager: FileManager

  init(paths: RuntimePaths, fileManager: FileManager = .default) {
    self.fileURL = paths.providerAnalyticsURL
    self.fileManager = fileManager
    load()
  }

  func recordUpdateAttempt(
    profileID: Profile.ID?,
    kind: ProviderKind,
    providerName: String,
    succeeded: Bool,
    errorMessage: String? = nil,
    at date: Date = Date()
  ) {
    guard let profileID, let providerName = normalizedProviderName(providerName) else { return }
    let attempt = ProviderUpdateAttempt(
      profileID: profileID,
      kind: kind,
      providerName: providerName,
      attemptedAt: date,
      succeeded: succeeded,
      errorMessage: errorMessage
    )
    mutateRecord(profileID: profileID, kind: kind, providerName: providerName) { record in
      record.attempts.append(attempt)
      record.attempts = Array(record.attempts.suffix(Self.retainedAttemptCount))
    }
    persist()
  }

  func recordSnapshots(
    profileID: Profile.ID?,
    proxyProviders: [ProxyProvider]?,
    ruleProviders: [RuleProvider]?,
    at date: Date = Date()
  ) {
    guard let profileID else { return }
    var didMutate = false

    if let proxyProviders {
      for provider in proxyProviders {
        guard let providerName = normalizedProviderName(provider.name) else { continue }
        let snapshot = ProviderSnapshot(
          profileID: profileID,
          kind: .proxy,
          providerName: providerName,
          capturedAt: date,
          itemCount: provider.proxies.count,
          subscriptionInfo: provider.subscriptionInfo,
          providerUpdatedAt: provider.updatedAt
        )
        mutateRecord(profileID: profileID, kind: .proxy, providerName: providerName) { record in
          record.snapshots.append(snapshot)
          record.snapshots = Array(record.snapshots.suffix(Self.retainedSnapshotCount))
        }
        didMutate = true
      }
    }

    if let ruleProviders {
      for provider in ruleProviders {
        guard let providerName = normalizedProviderName(provider.name) else { continue }
        let snapshot = ProviderSnapshot(
          profileID: profileID,
          kind: .rule,
          providerName: providerName,
          capturedAt: date,
          itemCount: provider.ruleCount,
          providerUpdatedAt: provider.updatedAt
        )
        mutateRecord(profileID: profileID, kind: .rule, providerName: providerName) { record in
          record.snapshots.append(snapshot)
          record.snapshots = Array(record.snapshots.suffix(Self.retainedSnapshotCount))
        }
        didMutate = true
      }
    }

    if didMutate {
      persist()
    }
  }

  func prune(validProfileIDs: Set<Profile.ID>) {
    let nextRecords = records.filter { validProfileIDs.contains($0.profileID) }
    guard nextRecords != records else { return }
    records = nextRecords
    persist()
  }

  func summary(
    profileID: Profile.ID,
    profileTraffic: SubscriptionTrafficUsage?,
    currentProxyProviders: [ProxyProvider]?,
    currentRuleProviders: [RuleProvider]?,
    now: Date = Date()
  ) -> ProviderAnalyticsProfileSummary {
    let profileRecords = records.filter { $0.profileID == profileID }
    let currentSnapshots = makeCurrentSnapshots(
      profileID: profileID,
      proxyProviders: currentProxyProviders,
      ruleProviders: currentRuleProviders
    )
    let currentByKey = Dictionary(uniqueKeysWithValues: currentSnapshots.map { (key(for: $0), $0) })
    let allKeys = Set(profileRecords.map(key(for:))).union(currentByKey.keys)
    let fallbackSubscriptionInfo = profileTraffic.map(ProviderSubscriptionInfo.init(traffic:))

    let rows = allKeys.compactMap { key -> ProviderAnalyticsSummary? in
      let record = profileRecords.first { self.key(for: $0) == key }
      let currentSnapshot = currentByKey[key]
      return makeSummary(
        key: key,
        record: record,
        currentSnapshot: currentSnapshot,
        fallbackSubscriptionInfo: fallbackSubscriptionInfo,
        now: now
      )
    }
    .sorted { lhs, rhs in
      if lhs.kind != rhs.kind {
        return lhs.kind.rawValue < rhs.kind.rawValue
      }
      return lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
    }

    let recentAttempts = profileRecords
      .flatMap(\.attempts)
      .sorted { $0.attemptedAt > $1.attemptedAt }
    let window = Array(recentAttempts.prefix(Self.successRateWindow))
    let successRate = Self.successRate(from: window)
    let recentFailure = recentAttempts.first { !$0.succeeded }
    let reminders = rows
      .compactMap(\.reminder)
      .sorted { lhs, rhs in
        if lhs.severity != rhs.severity {
          return lhs.severity > rhs.severity
        }
        return lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
      }

    return ProviderAnalyticsProfileSummary(
      rows: rows,
      updateSuccessRate: successRate,
      updateAttemptCount: window.count,
      recentFailure: recentFailure,
      reminders: reminders
    )
  }

  private func load() {
    guard fileManager.fileExists(atPath: fileURL.path),
          let data = try? Data(contentsOf: fileURL)
    else { return }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let loadedRecords = try? decoder.decode([ProviderAnalyticsRecord].self, from: data) else { return }
    records = loadedRecords.map(Self.normalizedRecord(_:))
  }

  private func persist() {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(records.sorted(by: Self.recordSort)) else { return }
    try? SecureFileIO.writePrivateData(data, to: fileURL, fileManager: fileManager)
  }

  private func mutateRecord(
    profileID: Profile.ID,
    kind: ProviderKind,
    providerName: String,
    mutation: (inout ProviderAnalyticsRecord) -> Void
  ) {
    var nextRecords = records
    if let index = nextRecords.firstIndex(where: {
      $0.profileID == profileID && $0.kind == kind && $0.providerName == providerName
    }) {
      mutation(&nextRecords[index])
    } else {
      var record = ProviderAnalyticsRecord(profileID: profileID, kind: kind, providerName: providerName)
      mutation(&record)
      nextRecords.append(record)
    }
    records = nextRecords
  }

  private func makeCurrentSnapshots(
    profileID: Profile.ID,
    proxyProviders: [ProxyProvider]?,
    ruleProviders: [RuleProvider]?
  ) -> [ProviderSnapshot] {
    var snapshots: [ProviderSnapshot] = []
    if let proxyProviders {
      snapshots += proxyProviders.compactMap { provider in
        guard let providerName = normalizedProviderName(provider.name) else { return nil }
        return ProviderSnapshot(
          profileID: profileID,
          kind: .proxy,
          providerName: providerName,
          itemCount: provider.proxies.count,
          subscriptionInfo: provider.subscriptionInfo,
          providerUpdatedAt: provider.updatedAt
        )
      }
    }
    if let ruleProviders {
      snapshots += ruleProviders.compactMap { provider in
        guard let providerName = normalizedProviderName(provider.name) else { return nil }
        return ProviderSnapshot(
          profileID: profileID,
          kind: .rule,
          providerName: providerName,
          itemCount: provider.ruleCount,
          providerUpdatedAt: provider.updatedAt
        )
      }
    }
    return snapshots
  }

  private func makeSummary(
    key: RecordKey,
    record: ProviderAnalyticsRecord?,
    currentSnapshot: ProviderSnapshot?,
    fallbackSubscriptionInfo: ProviderSubscriptionInfo?,
    now: Date
  ) -> ProviderAnalyticsSummary? {
    let snapshots = record?.snapshots.sorted { $0.capturedAt > $1.capturedAt } ?? []
    let latestSnapshot = currentSnapshot ?? snapshots.first
    let itemCount = latestSnapshot?.itemCount
    let previousSnapshot: ProviderSnapshot?
    if currentSnapshot != nil {
      if let first = snapshots.first, first.itemCount == itemCount {
        previousSnapshot = snapshots.dropFirst().first
      } else {
        previousSnapshot = snapshots.first
      }
    } else {
      previousSnapshot = snapshots.dropFirst().first
    }

    let attempts = record?.attempts.sorted { $0.attemptedAt > $1.attemptedAt } ?? []
    let window = Array(attempts.prefix(Self.successRateWindow))
    let subscriptionInfo = latestSnapshot?.subscriptionInfo ?? fallbackSubscriptionInfo
    let reminder = ProviderSubscriptionReminder.reminder(
      providerName: key.providerName,
      subscriptionInfo: subscriptionInfo,
      now: now
    )

    guard latestSnapshot != nil || !attempts.isEmpty else { return nil }
    return ProviderAnalyticsSummary(
      kind: key.kind,
      providerName: key.providerName,
      itemCount: itemCount,
      previousItemCount: previousSnapshot?.itemCount,
      successRate: Self.successRate(from: window),
      successRateSampleCount: window.count,
      lastFailure: attempts.first { !$0.succeeded },
      lastAttemptAt: attempts.first?.attemptedAt,
      lastSnapshotAt: latestSnapshot?.capturedAt,
      subscriptionInfo: subscriptionInfo,
      reminder: reminder,
      isCurrentRuntimeData: currentSnapshot != nil
    )
  }

  private func key(for record: ProviderAnalyticsRecord) -> RecordKey {
    RecordKey(profileID: record.profileID, kind: record.kind, providerName: record.providerName)
  }

  private func key(for snapshot: ProviderSnapshot) -> RecordKey {
    RecordKey(profileID: snapshot.profileID, kind: snapshot.kind, providerName: snapshot.providerName)
  }

  private func normalizedProviderName(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func successRate(from attempts: [ProviderUpdateAttempt]) -> Double? {
    guard !attempts.isEmpty else { return nil }
    let successCount = attempts.filter(\.succeeded).count
    return Double(successCount) / Double(attempts.count)
  }

  private static func normalizedRecord(_ record: ProviderAnalyticsRecord) -> ProviderAnalyticsRecord {
    var record = record
    record.attempts = Array(record.attempts.sorted { $0.attemptedAt < $1.attemptedAt }.suffix(retainedAttemptCount))
    record.snapshots = Array(record.snapshots.sorted { $0.capturedAt < $1.capturedAt }.suffix(retainedSnapshotCount))
    return record
  }

  private static func recordSort(_ lhs: ProviderAnalyticsRecord, _ rhs: ProviderAnalyticsRecord) -> Bool {
    if lhs.profileID != rhs.profileID {
      return lhs.profileID.uuidString < rhs.profileID.uuidString
    }
    if lhs.kind != rhs.kind {
      return lhs.kind.rawValue < rhs.kind.rawValue
    }
    return lhs.providerName.localizedStandardCompare(rhs.providerName) == .orderedAscending
  }
}
