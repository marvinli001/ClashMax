import Foundation
import XCTest
@testable import ClashMax

final class Socks5ConnectRequestTests: XCTestCase {
  func testBuildsDomainConnectRequest() throws {
    let request = try Socks5ConnectRequest.make(host: "example.com", port: 443)

    XCTAssertEqual(
      Array(request),
      [0x05, 0x01, 0x00, 0x03, 0x0b]
        + Array("example.com".utf8)
        + [0x01, 0xbb]
    )
  }

  func testBuildsIPv4ConnectRequest() throws {
    let request = try Socks5ConnectRequest.make(host: "1.2.3.4", port: 8080)

    XCTAssertEqual(Array(request), [0x05, 0x01, 0x00, 0x01, 0x01, 0x02, 0x03, 0x04, 0x1f, 0x90])
  }

  func testBuildsIPv6ConnectRequest() throws {
    let request = try Socks5ConnectRequest.make(host: "2001:db8::1", port: 53)

    XCTAssertEqual(Array(request.prefix(4)), [0x05, 0x01, 0x00, 0x04])
    XCTAssertEqual(request.count, 22)
    XCTAssertEqual(Array(request.suffix(2)), [0x00, 0x35])
  }

  func testRejectsInvalidPortAndEmptyHost() {
    XCTAssertThrowsError(try Socks5ConnectRequest.make(host: "example.com", port: 0))
    XCTAssertThrowsError(try Socks5ConnectRequest.make(host: " ", port: 443))
  }

  func testRejectsTooLongDomain() {
    let host = String(repeating: "a", count: 256)

    XCTAssertThrowsError(try Socks5ConnectRequest.make(host: host, port: 443)) { error in
      XCTAssertEqual(error as? Socks5ConnectRequestError, .domainTooLong(host))
    }
  }

  func testComputesSocks5ConnectReplyLengthForAddressTypes() throws {
    XCTAssertEqual(
      try Socks5ConnectReply.expectedLength(forPrefix: Data([0x05, 0x00, 0x00, 0x01, 0x7f])),
      10
    )
    XCTAssertEqual(
      try Socks5ConnectReply.expectedLength(forPrefix: Data([0x05, 0x00, 0x00, 0x03, 0x0b])),
      18
    )
    XCTAssertEqual(
      try Socks5ConnectReply.expectedLength(forPrefix: Data([0x05, 0x00, 0x00, 0x04, 0x20])),
      22
    )
  }

  func testRejectsInvalidSocks5ConnectReplyPrefix() {
    XCTAssertThrowsError(try Socks5ConnectReply.expectedLength(forPrefix: Data([0x05, 0x00, 0x00, 0x01]))) { error in
      XCTAssertEqual(error as? Socks5ConnectReplyError, .incompletePrefix(4))
    }
    XCTAssertThrowsError(try Socks5ConnectReply.expectedLength(forPrefix: Data([0x04, 0x00, 0x00, 0x01, 0x7f]))) { error in
      XCTAssertEqual(error as? Socks5ConnectReplyError, .invalidVersion(0x04))
    }
    XCTAssertThrowsError(try Socks5ConnectReply.expectedLength(forPrefix: Data([0x05, 0x05, 0x00, 0x01, 0x7f]))) { error in
      XCTAssertEqual(error as? Socks5ConnectReplyError, .failureReply(0x05))
    }
    XCTAssertThrowsError(try Socks5ConnectReply.expectedLength(forPrefix: Data([0x05, 0x00, 0x00, 0x02, 0x7f]))) { error in
      XCTAssertEqual(error as? Socks5ConnectReplyError, .unsupportedAddressType(0x02))
    }
  }
}
