import Darwin
import Foundation

struct Socks5Endpoint: Equatable, Sendable {
  enum Host: Equatable, Sendable {
    case ipv4(String)
    case ipv6(String)
    case domain(String)
  }

  var host: Host
  var port: Int
}

enum Socks5ConnectRequestError: LocalizedError, Equatable {
  case invalidPort(Int)
  case invalidIPAddress(String)
  case domainNameTooLong(String)

  var errorDescription: String? {
    switch self {
    case let .invalidPort(port):
      return "SOCKS5 endpoint port is invalid: \(port)"
    case let .invalidIPAddress(address):
      return "SOCKS5 endpoint address is invalid: \(address)"
    case let .domainNameTooLong(domain):
      return "SOCKS5 endpoint domain is too long: \(domain)"
    }
  }
}

struct Socks5Reply: Equatable, Sendable {
  var bindEndpoint: Socks5Endpoint
}

enum Socks5ReplyError: LocalizedError, Equatable {
  case invalidHeader
  case failureReply(UInt8)
  case unsupportedAddressType(UInt8)
  case truncatedReply

  var errorDescription: String? {
    switch self {
    case .invalidHeader:
      return "SOCKS5 server returned an invalid reply header."
    case let .failureReply(code):
      return "SOCKS5 server returned failure reply code \(code)."
    case let .unsupportedAddressType(addressType):
      return "SOCKS5 server returned unsupported address type \(addressType)."
    case .truncatedReply:
      return "SOCKS5 server returned a truncated reply."
    }
  }
}

enum Socks5UDPDatagramError: LocalizedError, Equatable {
  case invalidHeader
  case unsupportedFragment(UInt8)
  case unsupportedAddressType(UInt8)
  case truncatedDatagram

  var errorDescription: String? {
    switch self {
    case .invalidHeader:
      return "SOCKS5 UDP datagram has an invalid header."
    case let .unsupportedFragment(fragment):
      return "SOCKS5 UDP fragmentation is not supported: \(fragment)"
    case let .unsupportedAddressType(addressType):
      return "SOCKS5 UDP datagram uses unsupported address type \(addressType)."
    case .truncatedDatagram:
      return "SOCKS5 UDP datagram is truncated."
    }
  }
}

struct Socks5UDPDatagram: Equatable, Sendable {
  var endpoint: Socks5Endpoint
  var payload: Data
}

enum Socks5ConnectRequest {
  static let noAuthenticationGreeting = Data([0x05, 0x01, 0x00])
  static let zeroAddressEndpoint = Socks5Endpoint(host: .ipv4("0.0.0.0"), port: 0)

  static func bytes(for endpoint: Socks5Endpoint) throws -> Data {
    try bytes(command: 0x01, endpoint: endpoint, allowsZeroPort: false)
  }

  static func udpAssociateBytes(for endpoint: Socks5Endpoint = zeroAddressEndpoint) throws -> Data {
    try bytes(command: 0x03, endpoint: endpoint, allowsZeroPort: true)
  }

  private static func bytes(command: UInt8, endpoint: Socks5Endpoint, allowsZeroPort: Bool) throws -> Data {
    let validPorts = allowsZeroPort ? 0...65_535 : 1...65_535
    guard validPorts.contains(endpoint.port) else {
      throw Socks5ConnectRequestError.invalidPort(endpoint.port)
    }

    var request = Data([0x05, command, 0x00])
    try appendEncodedEndpoint(endpoint, to: &request)
    return request
  }

  static func appendEncodedEndpoint(_ endpoint: Socks5Endpoint, to data: inout Data) throws {
    switch endpoint.host {
    case let .ipv4(address):
      data.append(0x01)
      data.append(try bytes(forIPv4Address: address))
    case let .domain(domain):
      let bytes = Array(domain.utf8)
      guard bytes.count <= 255 else {
        throw Socks5ConnectRequestError.domainNameTooLong(domain)
      }
      data.append(0x03)
      data.append(UInt8(bytes.count))
      data.append(contentsOf: bytes)
    case let .ipv6(address):
      data.append(0x04)
      data.append(try bytes(forIPv6Address: address))
    }

    guard let portValue = UInt16(exactly: endpoint.port) else {
      throw Socks5ConnectRequestError.invalidPort(endpoint.port)
    }
    let port = portValue.bigEndian
    withUnsafeBytes(of: port) { data.append(contentsOf: $0) }
  }

  static func bytes(forIPv4Address address: String) throws -> Data {
    var storage = in_addr()
    guard inet_pton(AF_INET, address, &storage) == 1 else {
      throw Socks5ConnectRequestError.invalidIPAddress(address)
    }
    return withUnsafeBytes(of: storage.s_addr) { Data($0) }
  }

  static func bytes(forIPv6Address address: String) throws -> Data {
    var storage = in6_addr()
    guard inet_pton(AF_INET6, address, &storage) == 1 else {
      throw Socks5ConnectRequestError.invalidIPAddress(address)
    }
    return withUnsafeBytes(of: storage) { Data($0) }
  }
}

enum Socks5ReplyParser {
  static func parse(_ data: Data) throws -> Socks5Reply {
    guard data.count >= 4, data[0] == 0x05, data[2] == 0x00 else {
      throw Socks5ReplyError.invalidHeader
    }
    guard data[1] == 0x00 else {
      throw Socks5ReplyError.failureReply(data[1])
    }
    let endpoint = try endpoint(from: data, addressOffset: 3, errorMapper: Socks5ReplyParser.mapAddressError)
    return Socks5Reply(bindEndpoint: endpoint)
  }

  static func addressRemainderLength(addressType: UInt8, domainLength: UInt8? = nil) throws -> Int {
    switch addressType {
    case 0x01:
      return 6
    case 0x03:
      if let domainLength {
        return Int(domainLength) + 2
      }
      return 1
    case 0x04:
      return 18
    default:
      throw Socks5ReplyError.unsupportedAddressType(addressType)
    }
  }

  private static func mapAddressError(_ error: Socks5AddressParseError) -> Error {
    switch error {
    case .truncated:
      return Socks5ReplyError.truncatedReply
    case let .unsupportedAddressType(addressType):
      return Socks5ReplyError.unsupportedAddressType(addressType)
    }
  }
}

enum Socks5UDPDatagramCodec {
  static func encode(_ datagram: Socks5UDPDatagram) throws -> Data {
    guard (1...65_535).contains(datagram.endpoint.port) else {
      throw Socks5ConnectRequestError.invalidPort(datagram.endpoint.port)
    }

    var data = Data([0x00, 0x00, 0x00])
    try Socks5ConnectRequest.appendEncodedEndpoint(datagram.endpoint, to: &data)
    data.append(datagram.payload)
    return data
  }

  static func decode(_ data: Data) throws -> Socks5UDPDatagram {
    guard data.count >= 4 else {
      throw Socks5UDPDatagramError.truncatedDatagram
    }
    guard data[0] == 0x00, data[1] == 0x00 else {
      throw Socks5UDPDatagramError.invalidHeader
    }
    guard data[2] == 0x00 else {
      throw Socks5UDPDatagramError.unsupportedFragment(data[2])
    }

    let endpoint = try endpoint(from: data, addressOffset: 3, errorMapper: mapAddressError)
    let payloadOffset = try payloadOffset(for: data)
    return Socks5UDPDatagram(endpoint: endpoint, payload: Data(data[payloadOffset...]))
  }

  private static func payloadOffset(for data: Data) throws -> Int {
    guard data.count >= 4 else { throw Socks5UDPDatagramError.truncatedDatagram }
    switch data[3] {
    case 0x01:
      let offset = 4 + 4 + 2
      guard data.count >= offset else { throw Socks5UDPDatagramError.truncatedDatagram }
      return offset
    case 0x03:
      guard data.count >= 5 else { throw Socks5UDPDatagramError.truncatedDatagram }
      let offset = 4 + 1 + Int(data[4]) + 2
      guard data.count >= offset else { throw Socks5UDPDatagramError.truncatedDatagram }
      return offset
    case 0x04:
      let offset = 4 + 16 + 2
      guard data.count >= offset else { throw Socks5UDPDatagramError.truncatedDatagram }
      return offset
    default:
      throw Socks5UDPDatagramError.unsupportedAddressType(data[3])
    }
  }

  private static func mapAddressError(_ error: Socks5AddressParseError) -> Error {
    switch error {
    case .truncated:
      return Socks5UDPDatagramError.truncatedDatagram
    case let .unsupportedAddressType(addressType):
      return Socks5UDPDatagramError.unsupportedAddressType(addressType)
    }
  }
}

private struct DNSQuestionCorrelationKey: Hashable, Sendable {
  var labels: [String]
  var queryType: UInt16
  var queryClass: UInt16
}

private struct DNSMessageCorrelationKey: Hashable, Sendable {
  var transactionID: UInt16
  var questions: [DNSQuestionCorrelationKey]
}

struct DNSResponseEndpointMapper: Sendable {
  private var pendingEndpoints: [DNSMessageCorrelationKey: [Socks5Endpoint]] = [:]
  private var insertionOrder: [DNSMessageCorrelationKey] = []
  private var pendingCount = 0
  private let retainedPendingLimit: Int

  init(retainedPendingLimit: Int = 256) {
    self.retainedPendingLimit = max(1, retainedPendingLimit)
  }

  mutating func recordQueryPayload(_ payload: Data, originalEndpoint: Socks5Endpoint) -> Bool {
    guard let key = DNSMessageCorrelationKey(payload: payload) else {
      return false
    }
    pendingEndpoints[key, default: []].append(originalEndpoint)
    insertionOrder.append(key)
    pendingCount += 1
    evictPendingEndpointsIfNeeded()
    return true
  }

  mutating func responseEndpoint(for payload: Data) -> Socks5Endpoint? {
    guard let key = DNSMessageCorrelationKey(payload: payload),
          var endpoints = pendingEndpoints[key],
          !endpoints.isEmpty else {
      return nil
    }
    let endpoint = endpoints.removeFirst()
    pendingCount = max(0, pendingCount - 1)
    if endpoints.isEmpty {
      pendingEndpoints.removeValue(forKey: key)
    } else {
      pendingEndpoints[key] = endpoints
    }
    removeFirstInsertionOrderMatch(for: key)
    return endpoint
  }

  private mutating func evictPendingEndpointsIfNeeded() {
    while pendingCount > retainedPendingLimit, let key = insertionOrder.first {
      insertionOrder.removeFirst()
      guard var endpoints = pendingEndpoints[key], !endpoints.isEmpty else {
        continue
      }
      endpoints.removeFirst()
      pendingCount = max(0, pendingCount - 1)
      if endpoints.isEmpty {
        pendingEndpoints.removeValue(forKey: key)
      } else {
        pendingEndpoints[key] = endpoints
      }
    }
  }

  private mutating func removeFirstInsertionOrderMatch(for key: DNSMessageCorrelationKey) {
    guard let index = insertionOrder.firstIndex(of: key) else { return }
    insertionOrder.remove(at: index)
  }
}

private extension DNSMessageCorrelationKey {
  init?(payload: Data) {
    guard payload.count >= 12 else { return nil }
    let questionCount = Int(Self.uint16(from: payload, at: 4))
    guard questionCount > 0 else { return nil }

    var offset = 12
    var questions: [DNSQuestionCorrelationKey] = []
    questions.reserveCapacity(questionCount)

    for _ in 0..<questionCount {
      guard let name = Self.domainName(from: payload, at: offset) else { return nil }
      offset = name.nextOffset
      guard offset + 4 <= payload.count else { return nil }
      let queryType = Self.uint16(from: payload, at: offset)
      let queryClass = Self.uint16(from: payload, at: offset + 2)
      offset += 4
      questions.append(
        DNSQuestionCorrelationKey(
          labels: name.labels,
          queryType: queryType,
          queryClass: queryClass
        )
      )
    }

    self.init(transactionID: Self.uint16(from: payload, at: 0), questions: questions)
  }

  private static func uint16(from data: Data, at offset: Int) -> UInt16 {
    (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
  }

  private static func domainName(from data: Data, at offset: Int) -> (labels: [String], nextOffset: Int)? {
    var labels: [String] = []
    var cursor = offset
    var nextOffset = offset
    var followedPointer = false
    var visitedPointers: Set<Int> = []

    for _ in 0..<64 {
      guard cursor < data.count else { return nil }
      let length = data[cursor]
      if length == 0 {
        cursor += 1
        if !followedPointer {
          nextOffset = cursor
        }
        return (labels, nextOffset)
      }

      if length & 0xc0 == 0xc0 {
        guard cursor + 1 < data.count else { return nil }
        let pointer = (Int(length & 0x3f) << 8) | Int(data[cursor + 1])
        guard pointer < data.count, !visitedPointers.contains(pointer) else { return nil }
        visitedPointers.insert(pointer)
        if !followedPointer {
          nextOffset = cursor + 2
        }
        cursor = pointer
        followedPointer = true
        continue
      }

      guard length & 0xc0 == 0x00 else { return nil }
      cursor += 1
      let labelLength = Int(length)
      guard labelLength <= 63, cursor + labelLength <= data.count else { return nil }
      labels.append(String(decoding: data[cursor..<(cursor + labelLength)], as: UTF8.self).lowercased())
      cursor += labelLength
      if !followedPointer {
        nextOffset = cursor
      }
    }

    return nil
  }
}

private enum Socks5AddressParseError: Error {
  case truncated
  case unsupportedAddressType(UInt8)
}

private func endpoint(
  from data: Data,
  addressOffset: Int,
  errorMapper: (Socks5AddressParseError) -> Error
) throws -> Socks5Endpoint {
  guard data.count > addressOffset else {
    throw errorMapper(.truncated)
  }

  let addressType = data[addressOffset]
  switch addressType {
  case 0x01:
    let start = addressOffset + 1
    let portStart = start + 4
    guard data.count >= portStart + 2 else {
      throw errorMapper(.truncated)
    }
    let address = try ipv4String(from: data[start..<portStart])
    return Socks5Endpoint(host: .ipv4(address), port: port(from: data, at: portStart))
  case 0x03:
    let lengthOffset = addressOffset + 1
    guard data.count > lengthOffset else {
      throw errorMapper(.truncated)
    }
    let length = Int(data[lengthOffset])
    let start = lengthOffset + 1
    let portStart = start + length
    guard data.count >= portStart + 2 else {
      throw errorMapper(.truncated)
    }
    let domain = String(decoding: data[start..<portStart], as: UTF8.self)
    return Socks5Endpoint(host: .domain(domain), port: port(from: data, at: portStart))
  case 0x04:
    let start = addressOffset + 1
    let portStart = start + 16
    guard data.count >= portStart + 2 else {
      throw errorMapper(.truncated)
    }
    let address = try ipv6String(from: data[start..<portStart])
    return Socks5Endpoint(host: .ipv6(address), port: port(from: data, at: portStart))
  default:
    throw errorMapper(.unsupportedAddressType(addressType))
  }
}

private func port(from data: Data, at offset: Int) -> Int {
  (Int(data[offset]) << 8) | Int(data[offset + 1])
}

private func ipv4String(from bytes: Data.SubSequence) throws -> String {
  guard bytes.count == 4 else {
    throw Socks5ReplyError.truncatedReply
  }
  var storage = in_addr()
  let data = Data(bytes)
  data.withUnsafeBytes { buffer in
    if let baseAddress = buffer.baseAddress {
      memcpy(&storage.s_addr, baseAddress, 4)
    }
  }
  var output = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
  guard inet_ntop(AF_INET, &storage, &output, socklen_t(INET_ADDRSTRLEN)) != nil else {
    throw Socks5ConnectRequestError.invalidIPAddress(String(decoding: bytes, as: UTF8.self))
  }
  return string(fromNullTerminatedBuffer: output)
}

private func ipv6String(from bytes: Data.SubSequence) throws -> String {
  guard bytes.count == 16 else {
    throw Socks5ReplyError.truncatedReply
  }
  var storage = in6_addr()
  let data = Data(bytes)
  data.withUnsafeBytes { buffer in
    if let baseAddress = buffer.baseAddress {
      memcpy(&storage, baseAddress, 16)
    }
  }
  var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
  guard inet_ntop(AF_INET6, &storage, &output, socklen_t(INET6_ADDRSTRLEN)) != nil else {
    throw Socks5ConnectRequestError.invalidIPAddress(String(decoding: bytes, as: UTF8.self))
  }
  return string(fromNullTerminatedBuffer: output)
}

private func string(fromNullTerminatedBuffer buffer: [CChar]) -> String {
  let endIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
  let bytes = buffer[..<endIndex].map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}
