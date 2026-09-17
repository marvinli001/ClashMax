import Darwin
import Foundation

struct ProxyPortReadinessRequest: Equatable, Sendable {
  var host: String
  var port: Int
  var serviceName: String = "SOCKS5 mixed-port"
}

@MainActor
protocol ProxyPortReadinessProbing {
  func waitUntilReady(host: String, port: Int) async throws
  func waitUntilOpen(host: String, port: Int, serviceName: String) async throws
  /// One connect attempt: is anything accepting TCP on `host:port` right now? Used after a stop
  /// to confirm the ports a queued start will bind are actually free (issue #33).
  func isAcceptingConnections(host: String, port: Int) async -> Bool
  /// One bind attempt: would Mihomo be able to `bind` `host:port` right now? A port can refuse a
  /// bind while nothing accepts on it (issue #33, root cause B), which the connect probe cannot see.
  func isPortBindable(host: String, port: Int) async -> Bool
}

extension ProxyPortReadinessProbing {
  /// Test doubles never hold a real port, so by default nothing is accepting and everything is
  /// bindable. The live probe overrides both with real sockets.
  func isAcceptingConnections(host: String, port: Int) async -> Bool {
    false
  }

  func isPortBindable(host: String, port: Int) async -> Bool {
    true
  }
}

/// Why one SOCKS5 greeting attempt failed. The distinction matters more than the errno: a
/// refused connect means nobody listens, while an accepted connect with no reply means *something
/// else* owns the port (issue #33: the profile's own HTTP listener on 7890 accepted the TCP
/// connection and then waited forever for a request line, and the user saw the localized
/// EAGAIN text "资源暂时不可用" instead of anything actionable).
enum SocksGreetingFailure: Error, Equatable, Sendable {
  /// TCP connect failed; nobody is accepting on the port.
  case connectFailed(errno: Int32)
  /// The connection was accepted but no SOCKS5 reply arrived before `timeout` elapsed.
  case noReply(timeout: TimeInterval)
  /// The peer closed the connection before answering.
  case closedWithoutReply
  /// A reply arrived and it is not the no-authentication acceptance `05 00`.
  case unexpectedReply([UInt8])
  case sendFailed(errno: Int32)
  /// `recv` failed for a reason other than the timeout or the peer closing.
  case receiveFailed(errno: Int32)
  case lookupFailed(String)

  func explanation(host: String, port: Int) -> String {
    let endpoint = "\(host):\(port)"
    switch self {
    case let .connectFailed(code):
      let reason = String(cString: strerror(code))
      return "Nothing is listening on \(endpoint) (\(reason)); Mihomo did not open its mixed-port."
    case let .noReply(timeout):
      let seconds = String(format: "%.1f", timeout)
      return "Something accepted the TCP connection on \(endpoint) but did not answer a SOCKS5 greeting within \(seconds)s; that listener is not Mihomo's mixed-port. Another program, or a plain HTTP proxy, is holding the port."
    case .closedWithoutReply:
      return "Something accepted the TCP connection on \(endpoint) and closed it without a SOCKS5 reply; that listener is not Mihomo's mixed-port."
    case let .unexpectedReply(bytes):
      let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
      return "The listener on \(endpoint) answered the SOCKS5 greeting with \(hex) instead of 05 00; it is not Mihomo's mixed-port, or it requires authentication."
    case let .sendFailed(code):
      return "Could not send a SOCKS5 greeting to \(endpoint): \(String(cString: strerror(code)))."
    case let .receiveFailed(code):
      return "Could not read the SOCKS5 reply from \(endpoint): \(String(cString: strerror(code)))."
    case let .lookupFailed(message):
      return "Could not resolve \(host): \(message)."
    }
  }
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

    let message: String
    if let failure = lastError as? SocksGreetingFailure {
      message = failure.explanation(host: host, port: port)
    } else {
      message = lastError.map(UserFacingError.message) ?? "Timed out waiting for mixed-port SOCKS5 response."
    }
    throw AppError.coreNotReady("Mihomo mixed-port \(host):\(port) did not accept SOCKS5 traffic. \(message)")
  }

  func waitUntilOpen(host: String, port: Int, serviceName: String) async throws {
    var lastError: Error?
    for _ in 0..<attempts {
      do {
        try await attemptOpen(host: host, port: port)
        return
      } catch {
        lastError = error
        try await Task.sleep(nanoseconds: delayNanoseconds)
      }
    }

    let message = lastError.map(UserFacingError.message) ?? "Timed out waiting for TCP listener."
    throw AppError.coreNotReady("\(serviceName) \(host):\(port) did not accept TCP connections. \(message)")
  }

  func isAcceptingConnections(host: String, port: Int) async -> Bool {
    let timeout = timeout
    return await Task.detached(priority: .utility) {
      Self.isAcceptingConnections(host: host, port: port, timeout: timeout)
    }.value
  }

  func isPortBindable(host: String, port: Int) async -> Bool {
    // The bind probe knows loopback only, which is where ClashMax binds both of its ports.
    guard host == "127.0.0.1" || host == "localhost" else { return true }
    return await Task.detached(priority: .utility) {
      MihomoRuntimePortChecker.canBindLoopback(port: port)
    }.value
  }

  private func attemptGreeting(host: String, port: Int) async throws {
    let timeout = timeout
    try await Task.detached(priority: .utility) {
      try Self.performGreeting(host: host, port: port, timeout: timeout)
    }.value
  }

  private func attemptOpen(host: String, port: Int) async throws {
    let timeout = timeout
    try await Task.detached(priority: .utility) {
      try Self.performConnect(host: host, port: port, timeout: timeout)
    }.value
  }

  private nonisolated static func performGreeting(host: String, port: Int, timeout: TimeInterval) throws {
    var hints = addrinfo()
    hints.ai_family = AF_UNSPEC
    hints.ai_socktype = SOCK_STREAM
    hints.ai_protocol = IPPROTO_TCP

    var result: UnsafeMutablePointer<addrinfo>?
    let lookup = getaddrinfo(host, String(port), &hints, &result)
    guard lookup == 0, let result else {
      throw SocksGreetingFailure.lookupFailed(String(cString: gai_strerror(lookup)))
    }
    defer { freeaddrinfo(result) }

    var lastError: Error?
    var current: UnsafeMutablePointer<addrinfo>? = result
    while let candidate = current {
      do {
        try connectAndVerifySOCKS(candidate: candidate, timeout: timeout)
        return
      } catch {
        // Prefer the most specific failure across address candidates: a listener that accepted
        // and stayed silent on one address says more than a refused connect on the other.
        if lastError == nil || !(error is POSIXError) {
          lastError = error
        }
      }
      current = candidate.pointee.ai_next
    }

    if let posixError = lastError as? POSIXError {
      throw SocksGreetingFailure.connectFailed(errno: posixError.code.rawValue)
    }
    throw lastError ?? SocksGreetingFailure.connectFailed(errno: ECONNREFUSED)
  }

  /// One greeting attempt, classified. Exposed for tests that stand up their own listeners.
  nonisolated static func probeGreeting(host: String, port: Int, timeout: TimeInterval) -> SocksGreetingFailure? {
    do {
      try performGreeting(host: host, port: port, timeout: timeout)
      return nil
    } catch let failure as SocksGreetingFailure {
      return failure
    } catch {
      // performGreeting converts every POSIXError; anything else is a programming error.
      return .connectFailed(errno: EIO)
    }
  }

  /// True when something accepts a TCP connection on `host:port`. Unlike
  /// `lsof`, this sees listeners owned by any user.
  nonisolated static func isAcceptingConnections(host: String, port: Int, timeout: TimeInterval) -> Bool {
    (try? performConnect(host: host, port: port, timeout: timeout)) != nil
  }

  private nonisolated static func performConnect(host: String, port: Int, timeout: TimeInterval) throws {
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
        let descriptor = try connect(candidate: candidate, timeout: timeout)
        close(descriptor)
        return
      } catch {
        lastError = error
      }
      current = candidate.pointee.ai_next
    }

    throw lastError ?? AppError.coreNotReady("Could not connect to TCP listener.")
  }

  private nonisolated static func connectAndVerifySOCKS(candidate: UnsafeMutablePointer<addrinfo>, timeout: TimeInterval) throws {
    let descriptor = try connect(candidate: candidate, timeout: timeout)
    defer { close(descriptor) }

    let greeting: [UInt8] = [0x05, 0x01, 0x00]
    let sent = greeting.withUnsafeBytes {
      Darwin.send(descriptor, $0.baseAddress, $0.count, 0)
    }
    guard sent == greeting.count else {
      // errno is only meaningful after a failed call; a short write of a 3-byte greeting on a
      // fresh loopback socket does not happen, but it must not report a stale errno either.
      throw SocksGreetingFailure.sendFailed(errno: sent < 0 ? errno : EIO)
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
      if count == 0 {
        throw SocksGreetingFailure.closedWithoutReply
      }
      guard count > 0 else {
        let code = errno
        // SO_RCVTIMEO expired: the peer accepted the connection and is waiting for *us* — the
        // signature of an HTTP listener that wants a request line, not a SOCKS5 server.
        if code == EAGAIN || code == EWOULDBLOCK {
          throw SocksGreetingFailure.noReply(timeout: timeout)
        }
        if code == EINTR {
          continue
        }
        // ECONNRESET: the peer accepted and then tore the connection down.
        if code == ECONNRESET {
          throw SocksGreetingFailure.closedWithoutReply
        }
        throw SocksGreetingFailure.receiveFailed(errno: code)
      }
      received += count
    }

    guard response == [0x05, 0x00] else {
      throw SocksGreetingFailure.unexpectedReply(response)
    }
  }

  private nonisolated static func connect(candidate: UnsafeMutablePointer<addrinfo>, timeout: TimeInterval) throws -> Int32 {
    let address = candidate.pointee
    let descriptor = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    setTimeout(timeout, descriptor: descriptor, option: SO_RCVTIMEO)
    setTimeout(timeout, descriptor: descriptor, option: SO_SNDTIMEO)

    var noSigPipe: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

    guard Darwin.connect(descriptor, address.ai_addr, address.ai_addrlen) == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
      close(descriptor)
      throw error
    }
    return descriptor
  }

  private nonisolated static func setTimeout(_ timeout: TimeInterval, descriptor: Int32, option: Int32) {
    let seconds = Int(timeout)
    let microseconds = Int((timeout - TimeInterval(seconds)) * 1_000_000)
    var value = timeval(tv_sec: seconds, tv_usec: Int32(microseconds))
    setsockopt(descriptor, SOL_SOCKET, option, &value, socklen_t(MemoryLayout<timeval>.size))
  }
}
