import Foundation

struct PublicIPInfo: Equatable, Sendable {
  var ipAddress: String
  var countryCode: String?
  var countryName: String?
  var region: String?
  var city: String?
  var asn: String?
  var isp: String?
  var organization: String?
  var timezone: String?
  var latitude: Double?
  var longitude: Double?
  var sourceName: String
  var fetchedAt: Date
}

enum PublicIPInfoState: Equatable {
  case idle
  case loading(previous: PublicIPInfo?, startedAt: Date)
  case loaded(PublicIPInfo)
  case failed(message: String, previous: PublicIPInfo?, failedAt: Date)

  var info: PublicIPInfo? {
    switch self {
    case .idle:
      return nil
    case let .loading(previous, _):
      return previous
    case let .loaded(info):
      return info
    case let .failed(_, previous, _):
      return previous
    }
  }

  var isLoading: Bool {
    if case .loading = self { return true }
    return false
  }

  var refreshAnchor: Date? {
    switch self {
    case .idle:
      return nil
    case let .loading(_, startedAt):
      return startedAt
    case let .loaded(info):
      return info.fetchedAt
    case let .failed(_, _, failedAt):
      return failedAt
    }
  }

  var errorMessage: String? {
    if case let .failed(message, _, _) = self { return message }
    return nil
  }
}
