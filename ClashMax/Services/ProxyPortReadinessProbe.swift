import Darwin
import Foundation

struct ProxyPortReadinessRequest: Equatable, Sendable {
  var host: String
  var port: Int
}

@MainActor
protocol ProxyPortReadinessProbing {
  func waitUntilReady(host: String, port: Int) async throws
}

struct SocksProxyReadinessProbe: ProxyPortReadinessProbing {
  let attempts: Int
  let delayNanoseconds: UInt64
  let timeout: TimeInterval

  init(
    attempts: Int = 20,
    delayNanoseconds: UInt64 = 100_000_000,
    timeout: TimeInterval = 0.5
  ) {
    self.attempts = attempts
    self.delayNanoseconds = delayNanoseconds
    self.timeout = timeout
  }

  func waitUntilReady(host: String, port: Int) async throws {
    var lastError: Error?
    for _ in 0..<attempts {
      do {
        try await attemptGreeting(host: host, port: port)
        return
      } catch {
        lastError = error
        try await Task.sleep(nanoseconds: delayNanoseconds)
      }
    }

    let message = lastError.map(UserFacingError.message) ?? "Timed out waiting for mixed-port SOCKS5 response."
    throw AppError.coreNotReady("Mihomo mixed-port \(host):\(port) did not accept SOCKS5 traffic. \(message)")
  }

  private func attemptGreeting(host: String, port: Int) async throws {
    let timeout = timeout
    try await Task.detached(priority: .utility) {
      try Self.performGreeting(host: host, port: port, timeout: timeout)
    }.value
  }

  nonisolated private static func performGreeting(host: String, port: Int, timeout: TimeInterval) throws {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP

    var result: UnsafeMutablePointer<addrinfo>?
    let lookup = getaddrinfo(host, String(port), &hints, &result)
    guard lookup == 0, let result else {
      throw AppError.coreNotReady(String(cString: gai_strerror(lookup)))
    }
    defer { freeaddrinfo(result) }

    var lastError: Error?
    var current: UnsafeMutablePointer<addrinfo>? = result
    while let candidate = current {
      do {
        try connectAndVerify(candidate: candidate, timeout: timeout)
        return
      } catch {
        lastError = error
      }
      current = candidate.pointee.ai_next
    }

    throw lastError ?? AppError.coreNotReady("Could not connect to mixed-port.")
  }

  nonisolated private static func connectAndVerify(candidate: UnsafeMutablePointer<addrinfo>, timeout: TimeInterval) throws {
    let address = candidate.pointee
    let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }

    setTimeout(timeout, descriptor: descriptor, option: SO_RCVTIMEO)
    setTimeout(timeout, descriptor: descriptor, option: SO_SNDTIMEO)

    var noSigPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    guard connect(descriptor, address.ai_addr, address.ai_addrlen) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
    }

    let greeting: [UInt8] = [0x05, 0x01, 0x00]
    let sent = greeting.withUnsafeBytes {
      Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard sent == greeting.count else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    var response = [UInt8](repeating: 0, count: 2)
    var received = 0
    let expectedResponseLength = response.count
    while received < expectedResponseLength {
      let remaining = expectedResponseLength - received
      let count = response.withUnsafeMutableBytes { buffer in
        Darwin.recv(
          descriptor,
          buffer.baseAddress!.advanced(by: received),
          remaining,
          0
        )
      }
      guard count > 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNRESET)
      }
      received += count
    }

    guard response == [0x05, 0x00] else {
      throw AppError.coreNotReady("SOCKS5 server rejected no-authentication greeting.")
    }
  }

  nonisolated private static func setTimeout(_ timeout: TimeInterval, descriptor: Int32, option: Int32) {
    let seconds = Int(timeout)
    let microseconds = Int((timeout - TimeInterval(seconds)) * 1_000_000)
    var value = timeval(tv_sec: seconds, tv_usec: Int32(microseconds))
    setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
  }
}
