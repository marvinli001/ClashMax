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

enum Socks5ConnectRequest {
  static let noAuthenticationGreeting = Data([0x05, 0x01, 0x00])

  static func bytes(for endpoint: Socks5Endpoint) throws -> Data {
    guard (1...65_535).contains(endpoint.port) else {
      throw Socks5ConnectRequestError.invalidPort(endpoint.port)
    }

    var request = Data([0x05, 0x01, 0x00])
    switch endpoint.host {
    case let .ipv4(address):
      request.append(0x01)
      request.append(try bytes(forIPv4Address: address))
    case let .domain(domain):
      let bytes = Array(domain.utf8)
      guard bytes.count <= 255 else {
        throw Socks5ConnectRequestError.domainNameTooLong(domain)
      }
      request.append(0x03)
      request.append(UInt8(bytes.count))
      request.append(contentsOf: bytes)
    case let .ipv6(address):
      request.append(0x04)
      request.append(try bytes(forIPv6Address: address))
    }

    let port = UInt16(endpoint.port).bigEndian
    withUnsafeBytes(of: port) { request.append(contentsOf: $0) }
    return request
  }

  private static func bytes(forIPv4Address address: String) throws -> Data {
    var storage = in_addr()
    guard inet_pton(AF_INET, address, &storage) == 1 else {
      throw Socks5ConnectRequestError.invalidIPAddress(address)
    }
    return withUnsafeBytes(of: storage.s_addr) { Data($0) }
  }

  private static func bytes(forIPv6Address address: String) throws -> Data {
    var storage = in6_addr()
    guard inet_pton(AF_INET6, address, &storage) == 1 else {
      throw Socks5ConnectRequestError.invalidIPAddress(address)
    }
    return withUnsafeBytes(of: storage) { Data($0) }
  }
}
