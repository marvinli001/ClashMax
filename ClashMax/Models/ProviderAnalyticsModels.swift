import Foundation

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case proxy
  case rule

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .proxy:
      String(localized: "Proxy")
    case .rule:
      String(localized: "Rule")
    }
  }

  var countUnit: String {
    switch self {
    case .proxy:
      String(localized: "nodes")
    case .rule:
      String(localized: "rules")
    }
  }
}

struct ProviderUpdateAttempt: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var profileID: Profile.ID
  var kind: ProviderKind
  var providerName: String
  var attemptedAt: Date
  var succeeded: Bool
  var errorMessage: String?

  init(
    id: UUID = UUID(),
    profileID: Profile.ID,
    kind: ProviderKind,
    providerName: String,
    attemptedAt: Date = Date(),
    succeeded: Bool,
    errorMessage: String? = nil
  ) {
    self.id = id
    self.profileID = profileID
    self.kind = kind
    self.providerName = providerName
    self.attemptedAt = attemptedAt
    self.succeeded = succeeded
    let trimmedError = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.errorMessage = trimmedError.isEmpty ? nil : trimmedError
  }
}

struct ProviderSnapshot: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var profileID: Profile.ID
  var kind: ProviderKind
  var providerName: String
  var capturedAt: Date
  var itemCount: Int?
  var subscriptionInfo: ProviderSubscriptionInfo?
  var providerUpdatedAt: Date?

  init(
    id: UUID = UUID(),
    profileID: Profile.ID,
    kind: ProviderKind,
    providerName: String,
    capturedAt: Date = Date(),
    itemCount: Int?,
    subscriptionInfo: ProviderSubscriptionInfo? = nil,
    providerUpdatedAt: Date? = nil
  ) {
    self.id = id
    self.profileID = profileID
    self.kind = kind
    self.providerName = providerName
    self.capturedAt = capturedAt
    self.itemCount = itemCount
    self.subscriptionInfo = subscriptionInfo
    self.providerUpdatedAt = providerUpdatedAt
  }
}

struct ProviderAnalyticsRecord: Codable, Equatable, Sendable {
  var profileID: Profile.ID
  var kind: ProviderKind
  var providerName: String
  var attempts: [ProviderUpdateAttempt]
  var snapshots: [ProviderSnapshot]

  init(
    profileID: Profile.ID,
    kind: ProviderKind,
    providerName: String,
    attempts: [ProviderUpdateAttempt] = [],
    snapshots: [ProviderSnapshot] = []
  ) {
    self.profileID = profileID
    self.kind = kind
    self.providerName = providerName
    self.attempts = attempts
    self.snapshots = snapshots
  }
}

struct ProviderSubscriptionReminder: Identifiable, Equatable, Sendable {
  enum Severity: Int, Comparable, Sendable {
    case warning
    case critical

    static func < (lhs: Severity, rhs: Severity) -> Bool {
      lhs.rawValue < rhs.rawValue
    }
  }

  var id: String { "\(severity.rawValue)-\(providerName)-\(message)" }
  var providerName: String
  var severity: Severity
  var message: String

  static func reminder(
    providerName: String,
    subscriptionInfo: ProviderSubscriptionInfo?,
    now: Date = Date()
  ) -> ProviderSubscriptionReminder? {
    guard let subscriptionInfo else { return nil }
    var reminders: [ProviderSubscriptionReminder] = []

    if let expireAt = subscriptionInfo.expireAt {
      if expireAt <= now {
        reminders.append(
          ProviderSubscriptionReminder(
            providerName: providerName,
            severity: .critical,
            message: String(localized: "Subscription expired")
          )
        )
      } else if expireAt.timeIntervalSince(now) <= 7 * 24 * 60 * 60 {
        reminders.append(
          ProviderSubscriptionReminder(
            providerName: providerName,
            severity: .warning,
            message: String(localized: "Subscription expires within 7 days")
          )
        )
      }
    }

    if let total = subscriptionInfo.total {
      let used = (subscriptionInfo.upload ?? 0) + (subscriptionInfo.download ?? 0)
      let remaining = total - used
      if remaining <= 0 {
        reminders.append(
          ProviderSubscriptionReminder(
            providerName: providerName,
            severity: .critical,
            message: String(localized: "Subscription quota exhausted")
          )
        )
      } else if total > 0, Double(remaining) / Double(total) <= 0.1 {
        reminders.append(
          ProviderSubscriptionReminder(
            providerName: providerName,
            severity: .warning,
            message: String(localized: "Subscription quota below 10%")
          )
        )
      }
    }

    return reminders.max { lhs, rhs in
      if lhs.severity != rhs.severity {
        return lhs.severity < rhs.severity
      }
      return lhs.message.localizedStandardCompare(rhs.message) == .orderedDescending
    }
  }
}

struct ProviderAnalyticsSummary: Identifiable, Equatable, Sendable {
  var id: String { "\(kind.rawValue)-\(providerName)" }
  var kind: ProviderKind
  var providerName: String
  var itemCount: Int?
  var previousItemCount: Int?
  var successRate: Double?
  var successRateSampleCount: Int
  var lastFailure: ProviderUpdateAttempt?
  var lastAttemptAt: Date?
  var lastSnapshotAt: Date?
  var subscriptionInfo: ProviderSubscriptionInfo?
  var reminder: ProviderSubscriptionReminder?
  var isCurrentRuntimeData: Bool

  var itemCountDelta: Int? {
    guard let itemCount, let previousItemCount else { return nil }
    return itemCount - previousItemCount
  }

  var successRateLabel: String {
    guard let successRate else { return "-" }
    return "\(Int((successRate * 100).rounded()))%"
  }

  var countLabel: String {
    guard let itemCount else { return "-" }
    return "\(itemCount) \(kind.countUnit)"
  }

  var deltaLabel: String {
    guard let itemCountDelta else { return String(localized: "Unknown") }
    if itemCountDelta > 0 {
      return "+\(itemCountDelta)"
    }
    if itemCountDelta < 0 {
      return "\(itemCountDelta)"
    }
    return String(localized: "No change")
  }
}

struct ProviderAnalyticsProfileSummary: Equatable, Sendable {
  var rows: [ProviderAnalyticsSummary]
  var updateSuccessRate: Double?
  var updateAttemptCount: Int
  var recentFailure: ProviderUpdateAttempt?
  var reminders: [ProviderSubscriptionReminder]

  var providerCount: Int { rows.count }
  var hasData: Bool { !rows.isEmpty || updateAttemptCount > 0 }

  var successRateLabel: String {
    guard let updateSuccessRate else { return "-" }
    return "\(Int((updateSuccessRate * 100).rounded()))%"
  }
}

extension ProviderSubscriptionInfo {
  var remainingBytes: Int? {
    guard let total else { return nil }
    let used = (upload ?? 0) + (download ?? 0)
    return max(0, total - used)
  }

  var remainingSummary: String? {
    guard let remainingBytes else { return nil }
    return "\(String(localized: "Remaining")) \(TrafficSample.formatBytes(remainingBytes))"
  }

  init(traffic: SubscriptionTrafficUsage) {
    self.init(
      upload: traffic.upload,
      download: traffic.download,
      total: traffic.total,
      expireAt: traffic.expireAt
    )
  }
}
