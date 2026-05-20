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

  func testUDPAssociateRequestUsesCommandThreeAndAllowsZeroAddress() throws {
    let bytes = try Socks5ConnectRequest.udpAssociateBytes()

    XCTAssertEqual(
      Array(bytes),
      [0x05, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    )
  }

  func testUDPAssociateRequestCanEncodeDomainEndpoint() throws {
    let bytes = try Socks5ConnectRequest.udpAssociateBytes(
      for: Socks5Endpoint(host: .domain("relay.example"), port: 5353)
    )

    XCTAssertEqual(Array(bytes.prefix(5)), [0x05, 0x03, 0x00, 0x03, 0x0d])
    XCTAssertEqual(String(decoding: bytes.dropFirst(5).prefix(13), as: UTF8.self), "relay.example")
    XCTAssertEqual(Array(bytes.suffix(2)), [0x14, 0xe9])
  }

  func testReplyParserDecodesIPv4BindEndpoint() throws {
    let reply = try Socks5ReplyParser.parse(
      Data([0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1e, 0xd2])
    )

    XCTAssertEqual(reply.bindEndpoint, Socks5Endpoint(host: .ipv4("127.0.0.1"), port: 7890))
  }

  func testReplyParserDecodesDomainBindEndpoint() throws {
    var data = Data([0x05, 0x00, 0x00, 0x03, 0x0b])
    data.append(contentsOf: Array("example.com".utf8))
    data.append(contentsOf: [0x1e, 0xd2])

    let reply = try Socks5ReplyParser.parse(data)

    XCTAssertEqual(reply.bindEndpoint, Socks5Endpoint(host: .domain("example.com"), port: 7890))
  }

  func testReplyParserDecodesIPv6BindEndpoint() throws {
    var data = Data([0x05, 0x00, 0x00, 0x04])
    data.append(try Socks5ConnectRequest.bytes(forIPv6Address: "2001:db8::1"))
    data.append(contentsOf: [0x00, 0x35])

    let reply = try Socks5ReplyParser.parse(data)

    XCTAssertEqual(reply.bindEndpoint, Socks5Endpoint(host: .ipv6("2001:db8::1"), port: 53))
  }

  func testReplyParserReportsFailureReplyCode() {
    XCTAssertThrowsError(try Socks5ReplyParser.parse(Data([0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]))) { error in
      XCTAssertEqual(error as? Socks5ReplyError, .failureReply(0x07))
    }
  }

  func testReplyAddressRemainderLengthIncludesVariableDomainLength() throws {
    XCTAssertEqual(try Socks5ReplyParser.addressRemainderLength(addressType: 0x01), 6)
    XCTAssertEqual(try Socks5ReplyParser.addressRemainderLength(addressType: 0x03), 1)
    XCTAssertEqual(try Socks5ReplyParser.addressRemainderLength(addressType: 0x03, domainLength: 11), 13)
    XCTAssertEqual(try Socks5ReplyParser.addressRemainderLength(addressType: 0x04), 18)
  }

  func testUDPDatagramCodecEncodesAndDecodesHeader() throws {
    let encoded = try Socks5UDPDatagramCodec.encode(
      Socks5UDPDatagram(
        endpoint: Socks5Endpoint(host: .domain("dns.example"), port: 53),
        payload: Data([0xde, 0xad, 0xbe, 0xef])
      )
    )

    XCTAssertEqual(Array(encoded.prefix(5)), [0x00, 0x00, 0x00, 0x03, 0x0b])
    let decoded = try Socks5UDPDatagramCodec.decode(encoded)
    XCTAssertEqual(decoded.endpoint, Socks5Endpoint(host: .domain("dns.example"), port: 53))
    XCTAssertEqual(decoded.payload, Data([0xde, 0xad, 0xbe, 0xef]))
  }

  func testUDPDatagramCodecEncodesAndDecodesIPv4Header() throws {
    let encoded = try Socks5UDPDatagramCodec.encode(
      Socks5UDPDatagram(
        endpoint: Socks5Endpoint(host: .ipv4("8.8.8.8"), port: 53),
        payload: Data([0x01, 0x02])
      )
    )

    XCTAssertEqual(Array(encoded.prefix(10)), [0x00, 0x00, 0x00, 0x01, 8, 8, 8, 8, 0x00, 0x35])
    let decoded = try Socks5UDPDatagramCodec.decode(encoded)
    XCTAssertEqual(decoded.endpoint, Socks5Endpoint(host: .ipv4("8.8.8.8"), port: 53))
    XCTAssertEqual(decoded.payload, Data([0x01, 0x02]))
  }

  func testUDPDatagramCodecEncodesAndDecodesIPv6Header() throws {
    let encoded = try Socks5UDPDatagramCodec.encode(
      Socks5UDPDatagram(
        endpoint: Socks5Endpoint(host: .ipv6("2001:db8::1"), port: 5353),
        payload: Data([0xfe, 0xed])
      )
    )

    XCTAssertEqual(Array(encoded.prefix(4)), [0x00, 0x00, 0x00, 0x04])
    XCTAssertEqual(encoded.count, 24)
    let decoded = try Socks5UDPDatagramCodec.decode(encoded)
    XCTAssertEqual(decoded.endpoint, Socks5Endpoint(host: .ipv6("2001:db8::1"), port: 5353))
    XCTAssertEqual(decoded.payload, Data([0xfe, 0xed]))
  }

  func testUDPDatagramCodecRejectsFragments() {
    XCTAssertThrowsError(try Socks5UDPDatagramCodec.decode(Data([0x00, 0x00, 0x01, 0x01, 1, 2, 3, 4, 0, 53]))) { error in
      XCTAssertEqual(error as? Socks5UDPDatagramError, .unsupportedFragment(0x01))
    }
  }

  func testUDPDatagramCodecRejectsTruncatedDatagrams() {
    let truncatedSamples = [
      Data([0x00, 0x00, 0x00]),
      Data([0x00, 0x00, 0x00, 0x01, 8, 8, 8, 8, 0x00]),
      Data([0x00, 0x00, 0x00, 0x03, 0x03, 0x64, 0x6e, 0x73, 0x00]),
      Data([0x00, 0x00, 0x00, 0x04] + Array(repeating: 0x00, count: 15))
    ]

    for sample in truncatedSamples {
      XCTAssertThrowsError(try Socks5UDPDatagramCodec.decode(sample)) { error in
        XCTAssertEqual(error as? Socks5UDPDatagramError, .truncatedDatagram)
      }
    }
  }

  func testNetworkExtensionDNSCapturePolicyRetargetsPort53OnlyWhenEnabled() {
    let policy = NetworkExtensionDNSCapturePolicy.clashMax(settings: .default)
    let dnsEndpoint = Socks5Endpoint(host: .ipv4("8.8.8.8"), port: 53)
    let httpsEndpoint = Socks5Endpoint(host: .domain("example.com"), port: 443)

    XCTAssertEqual(
      policy.targetEndpoint(for: dnsEndpoint),
      Socks5Endpoint(host: .ipv4("127.0.0.1"), port: 1053)
    )
    XCTAssertEqual(policy.targetEndpoint(for: httpsEndpoint), httpsEndpoint)
    XCTAssertEqual(NetworkExtensionDNSCapturePolicy.disabled.targetEndpoint(for: dnsEndpoint), dnsEndpoint)
  }

  func testNetworkExtensionDNSCapturePolicySupportsCustomListenPort() {
    let settings = NetworkExtensionRoutingSettings(dnsListenPort: 2053)
    let policy = NetworkExtensionDNSCapturePolicy.clashMax(settings: settings)
    let originalEndpoint = Socks5Endpoint(host: .domain("resolver.example"), port: 53)
    let capturedEndpoint = Socks5Endpoint(host: .ipv4("127.0.0.1"), port: 2053)

    XCTAssertEqual(policy.targetEndpoint(for: originalEndpoint), capturedEndpoint)
    XCTAssertTrue(policy.isCaptureEndpoint(capturedEndpoint))
  }

  func testDNSResponseEndpointMapperUsesTransactionIDAndQuestionForOutOfOrderReplies() {
    var mapper = DNSResponseEndpointMapper()
    let firstResolver = Socks5Endpoint(host: .ipv4("8.8.8.8"), port: 53)
    let secondResolver = Socks5Endpoint(host: .ipv4("1.1.1.1"), port: 53)
    let firstQuery = dnsMessage(transactionID: 0x1001, labels: ["alpha", "example"], flags: 0x0100)
    let secondQuery = dnsMessage(transactionID: 0x1002, labels: ["beta", "example"], flags: 0x0100)
    let firstResponse = dnsMessage(transactionID: 0x1001, labels: ["alpha", "example"], flags: 0x8180)
    let secondResponse = dnsMessage(transactionID: 0x1002, labels: ["beta", "example"], flags: 0x8180)

    XCTAssertTrue(mapper.recordQueryPayload(firstQuery, originalEndpoint: firstResolver))
    XCTAssertTrue(mapper.recordQueryPayload(secondQuery, originalEndpoint: secondResolver))

    XCTAssertEqual(mapper.responseEndpoint(for: secondResponse), secondResolver)
    XCTAssertEqual(mapper.responseEndpoint(for: firstResponse), firstResolver)
    XCTAssertNil(mapper.responseEndpoint(for: firstResponse))
  }

  func testDNSResponseEndpointMapperIncludesQuestionInCorrelationKey() {
    var mapper = DNSResponseEndpointMapper()
    let firstResolver = Socks5Endpoint(host: .ipv4("8.8.4.4"), port: 53)
    let secondResolver = Socks5Endpoint(host: .ipv4("9.9.9.9"), port: 53)
    let firstQuery = dnsMessage(transactionID: 0x2001, labels: ["one", "example"], flags: 0x0100)
    let secondQuery = dnsMessage(transactionID: 0x2001, labels: ["two", "example"], flags: 0x0100)
    let firstResponse = dnsMessage(transactionID: 0x2001, labels: ["one", "example"], flags: 0x8180)
    let secondResponse = dnsMessage(transactionID: 0x2001, labels: ["two", "example"], flags: 0x8180)

    XCTAssertTrue(mapper.recordQueryPayload(firstQuery, originalEndpoint: firstResolver))
    XCTAssertTrue(mapper.recordQueryPayload(secondQuery, originalEndpoint: secondResolver))

    XCTAssertEqual(mapper.responseEndpoint(for: secondResponse), secondResolver)
    XCTAssertEqual(mapper.responseEndpoint(for: firstResponse), firstResolver)
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

  private func dnsMessage(transactionID: UInt16, labels: [String], flags: UInt16) -> Data {
    var data = Data()
    append(transactionID, to: &data)
    append(flags, to: &data)
    append(1, to: &data)
    append(0, to: &data)
    append(0, to: &data)
    append(0, to: &data)
    for label in labels {
      let bytes = Array(label.utf8)
      data.append(UInt8(bytes.count))
      data.append(contentsOf: bytes)
    }
    data.append(0)
    append(1, to: &data)
    append(1, to: &data)
    return data
  }

  private func append(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value >> 8))
    data.append(UInt8(value & 0x00ff))
  }
}
