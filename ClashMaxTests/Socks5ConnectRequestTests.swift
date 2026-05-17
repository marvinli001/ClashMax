import XCTest
@testable import ClashMax

final class Socks5ConnectRequestTests: XCTestCase {
  func testIPv4ConnectRequestEncoding() throws {
    let bytes = try Socks5ConnectRequest.bytes(
      for: Socks5Endpoint(host: .ipv4("1.2.3.4"), port: 443)
    )

    XCTAssertEqual(
      Array(bytes),
      [0x05, 0x01, 0x00, 0x01, 0x01, 0x02, 0x03, 0x04, 0x01, 0xbb]
    )
  }

  func testDomainConnectRequestEncoding() throws {
    let bytes = try Socks5ConnectRequest.bytes(
      for: Socks5Endpoint(host: .domain("example.com"), port: 7890)
    )

    XCTAssertEqual(Array(bytes.prefix(5)), [0x05, 0x01, 0x00, 0x03, 0x0b])
    XCTAssertEqual(String(decoding: bytes.dropFirst(5).prefix(11), as: UTF8.self), "example.com")
    XCTAssertEqual(Array(bytes.suffix(2)), [0x1e, 0xd2])
  }

  func testIPv6ConnectRequestEncoding() throws {
    let bytes = try Socks5ConnectRequest.bytes(
      for: Socks5Endpoint(host: .ipv6("2001:db8::1"), port: 53)
    )

    XCTAssertEqual(Array(bytes.prefix(4)), [0x05, 0x01, 0x00, 0x04])
    XCTAssertEqual(Array(bytes.suffix(2)), [0x00, 0x35])
    XCTAssertEqual(bytes.count, 22)
  }

  func testInvalidPortThrows() {
    XCTAssertThrowsError(
      try Socks5ConnectRequest.bytes(for: Socks5Endpoint(host: .domain("example.com"), port: 0))
    ) { error in
      XCTAssertEqual(error as? Socks5ConnectRequestError, .invalidPort(0))
    }
  }

  func testInvalidIPAddressThrows() {
    XCTAssertThrowsError(
      try Socks5ConnectRequest.bytes(for: Socks5Endpoint(host: .ipv4("not-an-ip"), port: 443))
    ) { error in
      XCTAssertEqual(error as? Socks5ConnectRequestError, .invalidIPAddress("not-an-ip"))
    }
  }

  func testLongDomainThrows() {
    let domain = String(repeating: "a", count: 256)

    XCTAssertThrowsError(
      try Socks5ConnectRequest.bytes(for: Socks5Endpoint(host: .domain(domain), port: 443))
    ) { error in
      XCTAssertEqual(error as? Socks5ConnectRequestError, .domainNameTooLong(domain))
    }
  }
}
