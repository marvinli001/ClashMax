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
  /// Host of the GeoIP provider that produced this result (e.g. `api.ip.sb`). Used as the probe host
  /// for proxy-effect rule simulation so the diagnostics can flag an IP-check target routed to DIRECT
  /// (issue #13).
  var sourceHost: String?
  var fetchedAt: Date

  init(
    ipAddress: String,
    countryCode: String? = nil,
    countryName: String? = nil,
    region: String? = nil,
    city: String? = nil,
    asn: String? = nil,
    isp: String? = nil,
    organization: String? = nil,
    timezone: String? = nil,
    latitude: Double? = nil,
    longitude: Double? = nil,
    sourceName: String,
    sourceHost: String? = nil,
    fetchedAt: Date
  ) {
    self.ipAddress = ipAddress
    self.countryCode = countryCode
    self.countryName = countryName
    self.region = region
    self.city = city
    self.asn = asn
    self.isp = isp
    self.organization = organization
    self.timezone = timezone
    self.latitude = latitude
    self.longitude = longitude
    self.sourceName = sourceName
    self.sourceHost = sourceHost
    self.fetchedAt = fetchedAt
  }

  /// Partially masked address for compact display and for the copyable diagnostics report. The
  /// public egress IP is treated as sensitive-by-default (the dashboard hides it behind a toggle), so
  /// the shared report never includes the full address.
  var maskedAddress: String {
    let parts = ipAddress.split(separator: ".")
    if parts.count == 4, let first = parts.first, let last = parts.last {
      return "\(first).xxx.xxx.\(last)"
    }
    guard ipAddress.count > 10 else { return "xxxx" }
    return "\(ipAddress.prefix(6))...\(ipAddress.suffix(4))"
  }
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
