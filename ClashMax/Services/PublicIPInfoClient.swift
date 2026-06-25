import Foundation

protocol PublicIPInfoFetching: Sendable {
  func fetchPublicIPInfo() async throws -> PublicIPInfo
}

struct PublicIPInfoClient: PublicIPInfoFetching, Sendable {
  enum ClientError: Error, LocalizedError {
    case invalidResponse(String)
    case httpStatus(Int, String)
    case allProvidersFailed([String])

    var errorDescription: String? {
      switch self {
      case let .invalidResponse(source):
        return "\(source) did not return readable public IP information."
      case let .httpStatus(status, source):
        return "\(source) returned HTTP \(status)."
      case .allProvidersFailed:
        return "Could not refresh public IP information. All GeoIP services failed."
      }
    }
  }

  struct Provider: Sendable {
    let name: String
    let url: URL
    let mapper: @Sendable ([String: Any], Date) throws -> PublicIPInfo
  }

  var providers: [Provider]
  var session: URLSession
  var timeout: TimeInterval
  var userAgent: String
  var shuffleProviders: Bool

  init(
    providers: [Provider] = Provider.defaultProviders,
    session: URLSession? = nil,
    timeout: TimeInterval = 5,
    userAgent: String = PublicIPInfoClient.defaultUserAgent(),
    shuffleProviders: Bool = true
  ) {
    self.providers = providers
    self.session = session ?? Self.makeSession(timeout: timeout)
    self.timeout = timeout
    self.userAgent = userAgent
    self.shuffleProviders = shuffleProviders
  }

  func fetchPublicIPInfo() async throws -> PublicIPInfo {
    var failures: [String] = []
    let orderedProviders = shuffleProviders ? providers.shuffled() : providers

    for provider in orderedProviders {
      do {
        return try await fetch(from: provider, fetchedAt: Date())
      } catch {
        failures.append("\(provider.name): \(error.localizedDescription)")
      }
    }

    throw ClientError.allProvidersFailed(failures)
  }

  private func fetch(from provider: Provider, fetchedAt: Date) async throws -> PublicIPInfo {
    var request = URLRequest(url: provider.url)
    request.httpMethod = "GET"
    request.timeoutInterval = timeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json, */*", forHTTPHeaderField: "Accept")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else {
      throw ClientError.invalidResponse(provider.name)
    }
    guard (200..<300).contains(http.statusCode) else {
      throw ClientError.httpStatus(http.statusCode, provider.name)
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ClientError.invalidResponse(provider.name)
    }
    return try provider.mapper(object, fetchedAt)
  }

  private static func makeSession(timeout: TimeInterval) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    return URLSession(configuration: configuration)
  }

  static func defaultUserAgent(bundle: Bundle = .main) -> String {
    let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let normalizedVersion = version?.isEmpty == false ? version : nil
    return "ClashMax/\(normalizedVersion ?? "1.0.0")"
  }
}

extension PublicIPInfoClient.Provider {
  static let defaultProviders: [PublicIPInfoClient.Provider] = [
    provider("api.ip.sb", "https://api.ip.sb/geoip"),
    provider("ipapi.co", "https://ipapi.co/json"),
    provider("ipapi.is", "https://api.ipapi.is/"),
    provider("ipwho.is", "https://ipwho.is/"),
    provider("skk cf-geoip", "https://ip.api.skk.moe/cf-geoip"),
    provider("geojs", "https://get.geojs.io/v1/ip/geo.json")
  ]

  private static func provider(_ name: String, _ urlString: String) -> PublicIPInfoClient.Provider {
    let url = URL(string: urlString)!
    return PublicIPInfoClient.Provider(name: name, url: url) { object, fetchedAt in
      var info = try PublicIPInfoMapper.map(object, sourceName: name, fetchedAt: fetchedAt)
      info.sourceHost = url.host
      return info
    }
  }
}

private enum PublicIPInfoMapper {
  static func map(_ object: [String: Any], sourceName: String, fetchedAt: Date) throws -> PublicIPInfo {
    if let success = object["success"] as? Bool, !success {
      throw PublicIPInfoClient.ClientError.invalidResponse(sourceName)
    }

    guard let ip = string(in: object, keys: ["ip", "query"]) else {
      throw PublicIPInfoClient.ClientError.invalidResponse(sourceName)
    }

    let location = dictionary(in: object, keys: ["location"])
    let connection = dictionary(in: object, keys: ["connection"])
    let asnObject = dictionary(in: object, keys: ["asn"])
    let timezoneObject = dictionary(in: object, keys: ["timezone"])

    return PublicIPInfo(
      ipAddress: ip,
      countryCode: firstString([
        string(in: object, keys: ["country_code", "countryCode", "countryCodeAlpha2"]),
        string(in: location, keys: ["country_code", "countryCode"])
      ]),
      countryName: firstString([
        string(in: object, keys: ["country", "country_name", "countryName"]),
        string(in: location, keys: ["country", "country_name"])
      ]),
      region: firstString([
        string(in: object, keys: ["region", "regionName", "state"]),
        string(in: location, keys: ["region", "regionName", "state"])
      ]),
      city: firstString([
        string(in: object, keys: ["city"]),
        string(in: location, keys: ["city"])
      ]),
      asn: normalizedASN(firstString([
        string(in: object, keys: ["asn", "as"]),
        string(in: connection, keys: ["asn"]),
        string(in: asnObject, keys: ["asn", "number"])
      ])),
      isp: firstString([
        string(in: object, keys: ["isp"]),
        string(in: connection, keys: ["isp"]),
        string(in: asnObject, keys: ["isp"])
      ]),
      organization: firstString([
        string(in: object, keys: ["organization", "org", "asOrganization"]),
        string(in: connection, keys: ["org", "organization"]),
        string(in: asnObject, keys: ["org", "organization", "name"])
      ]),
      timezone: firstString([
        string(in: object, keys: ["timezone", "time_zone"]),
        string(in: timezoneObject, keys: ["id", "name"]),
        string(in: location, keys: ["timezone", "time_zone"])
      ]),
      latitude: firstDouble([
        double(in: object, keys: ["latitude", "lat"]),
        double(in: location, keys: ["latitude", "lat"])
      ]),
      longitude: firstDouble([
        double(in: object, keys: ["longitude", "lon", "lng"]),
        double(in: location, keys: ["longitude", "lon", "lng"])
      ]),
      sourceName: sourceName,
      fetchedAt: fetchedAt
    )
  }

  private static func dictionary(in object: [String: Any], keys: [String]) -> [String: Any] {
    for key in keys {
      if let value = object[key] as? [String: Any] {
        return value
      }
    }
    return [:]
  }

  private static func string(in object: [String: Any], keys: [String]) -> String? {
    for key in keys {
      if let value = object[key] as? String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
      }
      if let value = object[key] as? NSNumber {
        return value.stringValue
      }
    }
    return nil
  }

  private static func double(in object: [String: Any], keys: [String]) -> Double? {
    for key in keys {
      if let value = object[key] as? Double {
        return value
      }
      if let value = object[key] as? NSNumber {
        return value.doubleValue
      }
      if let value = object[key] as? String,
         let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return parsed
      }
    }
    return nil
  }

  private static func firstString(_ values: [String?]) -> String? {
    values.compactMap { $0 }.first
  }

  private static func firstDouble(_ values: [Double?]) -> Double? {
    values.compactMap { $0 }.first
  }

  private static func normalizedASN(_ value: String?) -> String? {
    guard var value else { return nil }
    value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.uppercased().hasPrefix("AS") { return value.uppercased() }
    return value.isEmpty ? nil : "AS\(value)"
  }
}
