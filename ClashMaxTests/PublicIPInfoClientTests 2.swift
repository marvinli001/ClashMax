import XCTest
@testable import ClashMax

final class PublicIPInfoClientTests: XCTestCase {
  func testMapsAllConfiguredGeoIPProviders() async throws {
    let cases: [(String, String)] = [
      ("api.ip.sb", """
      {"ip":"203.0.113.1","country_code":"NZ","country":"New Zealand","region":"Auckland","city":"Auckland","asn":23655,"isp":"2degrees","organization":"Two Degrees Networks Limited","timezone":"Pacific/Auckland","latitude":-36.85,"longitude":174.76}
      """),
      ("ipapi.co", """
      {"ip":"203.0.113.1","country_code":"NZ","country_name":"New Zealand","region":"Auckland","city":"Auckland","asn":"AS23655","org":"Two Degrees Networks Limited","timezone":"Pacific/Auckland","latitude":-36.85,"longitude":174.76}
      """),
      ("ipapi.is", """
      {"ip":"203.0.113.1","location":{"country_code":"NZ","country":"New Zealand","state":"Auckland","city":"Auckland","timezone":"Pacific/Auckland","latitude":-36.85,"longitude":174.76},"asn":{"asn":23655,"isp":"2degrees","org":"Two Degrees Networks Limited"}}
      """),
      ("ipwho.is", """
      {"success":true,"ip":"203.0.113.1","country_code":"NZ","country":"New Zealand","region":"Auckland","city":"Auckland","connection":{"asn":23655,"isp":"2degrees","org":"Two Degrees Networks Limited"},"timezone":{"id":"Pacific/Auckland"},"latitude":-36.85,"longitude":174.76}
      """),
      ("skk cf-geoip", """
      {"ip":"203.0.113.1","countryCode":"NZ","country":"New Zealand","region":"Auckland","city":"Auckland","asn":"23655","isp":"2degrees","asOrganization":"Two Degrees Networks Limited","timezone":"Pacific/Auckland","latitude":"-36.85","longitude":"174.76"}
      """),
      ("geojs", """
      {"ip":"203.0.113.1","country_code":"NZ","country":"New Zealand","region":"Auckland","city":"Auckland","asn":"23655","organization":"Two Degrees Networks Limited","timezone":"Pacific/Auckland","latitude":"-36.85","longitude":"174.76"}
      """)
    ]

    for (providerName, body) in cases {
      PublicIPInfoURLProtocol.configure([.init(body: body)])
      let provider = try XCTUnwrap(PublicIPInfoClient.Provider.defaultProviders.first { $0.name == providerName })
      let client = PublicIPInfoClient(
        providers: [provider],
        session: Self.makeSession(),
        userAgent: "ClashMax/1.0.0",
        shuffleProviders: false
      )

      let info = try await client.fetchPublicIPInfo()

      XCTAssertEqual(info.ipAddress, "203.0.113.1", providerName)
      XCTAssertEqual(info.countryCode, "NZ", providerName)
      XCTAssertEqual(info.countryName, "New Zealand", providerName)
      XCTAssertEqual(info.region, "Auckland", providerName)
      XCTAssertEqual(info.city, "Auckland", providerName)
      XCTAssertEqual(info.asn, "AS23655", providerName)
      XCTAssertEqual(info.sourceName, providerName)
      XCTAssertEqual(info.timezone, "Pacific/Auckland", providerName)
      XCTAssertEqual(try XCTUnwrap(info.latitude), -36.85, accuracy: 0.01, providerName)
      XCTAssertEqual(try XCTUnwrap(info.longitude), 174.76, accuracy: 0.01, providerName)
    }
  }

  func testRequestUsesClashMaxUserAgentAndFiveSecondTimeout() async throws {
    PublicIPInfoURLProtocol.configure([
      .init(body: #"{"ip":"203.0.113.1"}"#)
    ])
    let provider = PublicIPInfoClient.Provider.defaultProviders[0]
    let client = PublicIPInfoClient(
      providers: [provider],
      session: Self.makeSession(),
      timeout: 5,
      userAgent: "ClashMax/1.0.0",
      shuffleProviders: false
    )

    _ = try await client.fetchPublicIPInfo()

    let request = try XCTUnwrap(PublicIPInfoURLProtocol.recordedRequests().last)
    XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "ClashMax/1.0.0")
    XCTAssertEqual(request.timeoutInterval, 5, accuracy: 0.01)
  }

  func testFallsBackToNextProviderAfterFailure() async throws {
    PublicIPInfoURLProtocol.configure([
      .init(statusCode: 503, body: #"{"error":"down"}"#),
      .init(body: #"{"ip":"198.51.100.9","country_code":"US","country":"United States"}"#)
    ])
    let providers = Array(PublicIPInfoClient.Provider.defaultProviders.prefix(2))
    let client = PublicIPInfoClient(
      providers: providers,
      session: Self.makeSession(),
      userAgent: "ClashMax/1.0.0",
      shuffleProviders: false
    )

    let info = try await client.fetchPublicIPInfo()

    XCTAssertEqual(info.ipAddress, "198.51.100.9")
    XCTAssertEqual(info.sourceName, providers[1].name)
    XCTAssertEqual(PublicIPInfoURLProtocol.recordedRequests().map(\.url?.absoluteString), providers.map(\.url.absoluteString))
  }

  func testAllProvidersFailedReturnsUserReadableError() async throws {
    PublicIPInfoURLProtocol.configure([
      .init(statusCode: 500, body: #"{"error":"one"}"#),
      .init(statusCode: 502, body: #"{"error":"two"}"#)
    ])
    let client = PublicIPInfoClient(
      providers: Array(PublicIPInfoClient.Provider.defaultProviders.prefix(2)),
      session: Self.makeSession(),
      userAgent: "ClashMax/1.0.0",
      shuffleProviders: false
    )

    do {
      _ = try await client.fetchPublicIPInfo()
      XCTFail("Expected all providers to fail.")
    } catch {
      XCTAssertEqual(error.localizedDescription, "Could not refresh public IP information. All GeoIP services failed.")
    }
  }

  private static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PublicIPInfoURLProtocol.self]
    return URLSession(configuration: configuration)
  }
}

private struct PublicIPMockResponse {
  var statusCode: Int = 200
  var body: String
}

private final class PublicIPInfoURLProtocol: URLProtocol, @unchecked Sendable {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var responses: [PublicIPMockResponse] = []
  nonisolated(unsafe) private static var requests: [URLRequest] = []

  static func configure(_ newResponses: [PublicIPMockResponse]) {
    lock.lock()
    responses = newResponses
    requests = []
    lock.unlock()
  }

  static func recordedRequests() -> [URLRequest] {
    lock.lock()
    defer { lock.unlock() }
    return requests
  }

  override class func canInit(with request: URLRequest) -> Bool { true }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response: PublicIPMockResponse
    Self.lock.lock()
    Self.requests.append(request)
    response = Self.responses.isEmpty
      ? PublicIPMockResponse(statusCode: 500, body: #"{"error":"missing mock"}"#)
      : Self.responses.removeFirst()
    Self.lock.unlock()

    let httpResponse = HTTPURLResponse(
      url: request.url!,
      statusCode: response.statusCode,
      httpVersion: nil,
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(response.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
