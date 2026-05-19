import Darwin
import Foundation

enum Socks5ConnectRequestError: Error, LocalizedError, Equatable {
  case invalidPort(Int)
  case emptyHost
  case domainTooLong(String)
  case invalidIPAddress(String)

  var errorDescription: String? {
    switch self {
    case let .invalidPort(port):
      return "Invalid SOCKS5 destination port: \(port)."
    case .emptyHost:
      return "SOCKS5 destination host is empty."
    case let .domainTooLong(host):
      return "SOCKS5 destination domain is too long: \(host)."
    case let .invalidIPAddress(host):
      return "Invalid SOCKS5 IP address: \(host)."
    }
  }
}

struct Socks5ConnectDestination: Equatable, Sendable {
  var host: String
  var port: UInt16
}

enum Socks5ConnectRequest {
  static let noAuthenticationGreeting = Data([0x05, 0x01, 0x00])

  static func make(host: String, port: Int) throws -> Data {
    guard (1...65_535).contains(port) else {
      throw Socks5ConnectRequestError.invalidPort(port)
    }
    return try make(destination: Socks5ConnectDestination(host: host, port: UInt16(port)))
  }

  static func make(destination: Socks5ConnectDestination) throws -> Data {
    let host = destination.host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !host.isEmpty else {
      throw Socks5ConnectRequestError.emptyHost
    }

    var request = Data([0x05, 0x01, 0x00])
    request.append(try encodedAddress(host))
    request.append(UInt8(destination.port >> 8))
    request.append(UInt8(destination.port & 0xff))
    return request
  }

  private static func encodedAddress(_ host: String) throws -> Data {
    if host.contains(":") {
      var address = in6_addr()
      let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
      guard normalized.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else {
        throw Socks5ConnectRequestError.invalidIPAddress(host)
      }
      var data = Data([0x04])
      withUnsafeBytes(of: &address) { data.append(contentsOf: $0) }
      return data
    }

    var ipv4 = in_addr()
    if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      var data = Data([0x01])
      withUnsafeBytes(of: &ipv4.s_addr) { data.append(contentsOf: $0) }
      return data
    }

    guard let encoded = host.data(using: .utf8), encoded.count <= 255 else {
      throw Socks5ConnectRequestError.domainTooLong(host)
    }

    var data = Data([0x03, UInt8(encoded.count)])
    data.append(encoded)
    return data
  }
}

enum Socks5ConnectReplyError: Error, Equatable {
  case incompletePrefix(Int)
  case invalidVersion(UInt8)
  case failureReply(UInt8)
  case invalidReserved(UInt8)
  case unsupportedAddressType(UInt8)
}

enum Socks5ConnectReply {
  static let minimumPrefixLength = 5

  static func expectedLength(forPrefix prefix: Data) throws -> Int {
    let bytes = Array(prefix)
    guard bytes.count >= minimumPrefixLength else {
      throw Socks5ConnectReplyError.incompletePrefix(bytes.count)
    }
    guard bytes[0] == 0x05 else {
      throw Socks5ConnectReplyError.invalidVersion(bytes[0])
    }
    guard bytes[1] == 0x00 else {
      throw Socks5ConnectReplyError.failureReply(bytes[1])
    }
    guard bytes[2] == 0x00 else {
      throw Socks5ConnectReplyError.invalidReserved(bytes[2])
    }

    switch bytes[3] {
    case 0x01:
      return 4 + 4 + 2
    case 0x03:
      return 4 + 1 + Int(bytes[4]) + 2
    case 0x04:
      return 4 + 16 + 2
    default:
      throw Socks5ConnectReplyError.unsupportedAddressType(bytes[3])
    }
  }
}
