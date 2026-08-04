import Foundation

/// Removes credentials and user identity from log text at the producer boundary.
///
/// Redaction happens *before* a line is retained anywhere, so a secret never reaches the
/// in-memory ring, the on-disk JSONL, or a copied bug report. The rules deliberately
/// over-redact where a proxy client's real leaks live — subscription URLs, share links,
/// auth headers, and profile file names — while keeping the parts that make a log useful:
/// schemes, hosts, ports, directory structure, error domains, and error codes.
enum StructuredLogRedactor {

  /// The single replacement token. Every rule reuses it so a second pass over already
  /// redacted text is a no-op, which is what makes redaction idempotent.
  static let placeholder = "<redacted>"

  /// Metadata keys whose value is always a secret, regardless of its shape.
  private static let sensitiveKeys: Set<String> = [
    "auth", "authorization", "proxy-authorization",
    "cookie", "set-cookie",
    "password", "passwd", "pwd",
    "secret", "secret-key", "secret_key",
    "token", "access-token", "access_token", "refresh-token", "refresh_token",
    "api-key", "api_key", "apikey", "x-api-key", "access-key", "access_key",
    "private-key", "private_key", "privatekey",
    "pre-shared-key", "preshared-key", "psk",
    "credential", "credentials",
    "session", "session-id", "sessionid",
    "signature", "uuid",
  ]

  /// The same names as an ordered regex alternation. Longest spellings come first so
  /// `authorization` wins over `auth` at the same start position.
  private static let sensitiveKeyPattern = [
    "proxy-authorization", "authorization",
    "pre-shared-key", "preshared-key",
    "refresh-token", "refresh_token", "access-token", "access_token",
    "private-key", "private_key", "privatekey",
    "secret-key", "secret_key", "access-key", "access_key",
    "x-api-key", "api-key", "api_key", "apikey",
    "credentials", "credential",
    "set-cookie", "cookie",
    "session-id", "sessionid", "session",
    "signature", "password", "passwd", "secret", "token", "uuid",
    "psk", "pwd", "auth",
  ].joined(separator: "|")

  /// Share-link schemes whose entire authority is the credential.
  private static let shareLinkSchemePattern = [
    "hysteria2", "hysteria", "vmess", "vless", "trojan-go", "trojan",
    "juicity", "anytls", "snell", "ssr", "tuic", "hy2", "ss",
  ].joined(separator: "|")

  // NSRegularExpression is documented as thread-safe and these are immutable after
  // construction, so sharing one compiled copy across producers is safe.
  nonisolated(unsafe) private static let shareLinkRegex = compile(
    "\\b(\(shareLinkSchemePattern))://\\S+"
  )
  nonisolated(unsafe) private static let webURLRegex = compile(
    "\\b(https?)://(?:([^\\s/@]*)@)?([^\\s/?#]+)([^\\s?#]*)(\\?[^\\s#]*)?(#\\S*)?"
  )
  nonisolated(unsafe) private static let userinfoRegex = compile(
    "\\b([a-z][a-z0-9+.-]*)://[^\\s/@]+@"
  )
  nonisolated(unsafe) private static let keyColonRegex = compile(
    "\\b(\(sensitiveKeyPattern))[\"']?\\s*:\\s*\\S[^\\n]*",
    options: [.caseInsensitive, .anchorsMatchLines]
  )
  nonisolated(unsafe) private static let keyEqualsRegex = compile(
    "\\b(\(sensitiveKeyPattern))[\"']?\\s*=\\s*[\"']?[^\\s&;,\"']+"
  )
  nonisolated(unsafe) private static let bearerRegex = compile(
    "\\bbearer\\s+[A-Za-z0-9._~+/=-]+"
  )
  // A user-owned path root followed by up to 64 components. A component may contain
  // spaces ("Application Support") only when another `/` follows it, which keeps the
  // match from swallowing the prose after a path. Both repetitions are bounded so a
  // hostile remote string cannot turn this into a backtracking bomb.
  nonisolated(unsafe) private static let homePathRegex = compile(
    "(/Users/[^/\\s]+|/private/var/root|/var/root|~)"
      + "((?:/(?:[^\\s/]+(?: [^\\s/]+){0,8}(?=/)|[^\\s/]+)){0,64})"
  )

  private static func compile(
    _ pattern: String,
    options: NSRegularExpression.Options = [.caseInsensitive]
  ) -> NSRegularExpression {
    // Every pattern here is a compile-time literal; a throw would be a programmer error.
    // swiftlint:disable:next force_try
    return try! NSRegularExpression(pattern: pattern, options: options)
  }

  // MARK: - Public API

  /// Redacts credentials and user identity from a single log string.
  ///
  /// Applying this to already-redacted text returns it unchanged.
  static func redactCredentials(in value: String, homeDirectory: String? = nil) -> String {
    guard !value.isEmpty else { return value }
    var result = value

    // Fold the caller's real home away first so the generic path rule only ever sees `~`.
    if let home = normalizedHome(homeDirectory) {
      result = result.replacingOccurrences(of: home + "/", with: "~/")
    }

    result = redactShareLinks(in: result)
    result = redactWebURLs(in: result)
    result = replaceAll(userinfoRegex, in: result, template: "$1://\(placeholder)@")
    result = replaceAll(keyColonRegex, in: result, template: "$1: \(placeholder)")
    result = replaceAll(keyEqualsRegex, in: result, template: "$1=\(placeholder)")
    result = replaceAll(bearerRegex, in: result, template: "Bearer \(placeholder)")
    result = redactHomePaths(in: result)
    return result
  }

  /// Redacts every metadata value, keeping the keys so the event stays greppable.
  ///
  /// A value under a known-sensitive key is dropped whole, because such a value is a
  /// secret even when it has no recognizable shape.
  static func redactCredentials(
    in metadata: [String: String],
    homeDirectory: String? = nil
  ) -> [String: String] {
    guard !metadata.isEmpty else { return metadata }
    var result: [String: String] = [:]
    result.reserveCapacity(metadata.count)
    for (key, value) in metadata {
      if sensitiveKeys.contains(key.lowercased()) {
        result[key] = placeholder
      } else {
        result[key] = redactCredentials(in: value, homeDirectory: homeDirectory)
      }
    }
    return result
  }

  // MARK: - Rules

  private static func normalizedHome(_ homeDirectory: String?) -> String? {
    guard var home = homeDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
          !home.isEmpty, home != "/" else { return nil }
    while home.count > 1, home.hasSuffix("/") { home.removeLast() }
    return home
  }

  /// `vmess://…` and friends carry the whole node credential after the scheme.
  private static func redactShareLinks(in value: String) -> String {
    replaceAll(shareLinkRegex, in: value, template: "$1://\(placeholder)")
  }

  /// Keeps `scheme://host:port` — the diagnostic part — and drops userinfo, path,
  /// query, and fragment, which is where subscription tokens actually live.
  private static func redactWebURLs(in value: String) -> String {
    rewrite(webURLRegex, in: value) { match, source in
      let scheme = capture(match, 1, in: source) ?? "https"
      let userinfo = capture(match, 2, in: source)
      let host = capture(match, 3, in: source) ?? ""
      let path = capture(match, 4, in: source) ?? ""
      let query = capture(match, 5, in: source)
      let fragment = capture(match, 6, in: source)

      var rebuilt = "\(scheme)://"
      if userinfo != nil { rebuilt += "\(placeholder)@" }
      rebuilt += host
      if path == "/" {
        rebuilt += path
      } else if !path.isEmpty {
        rebuilt += "/\(placeholder)"
      }
      if query != nil { rebuilt += "?\(placeholder)" }
      if fragment != nil { rebuilt += "#\(placeholder)" }
      return rebuilt
    }
  }

  /// Replaces a user-owned path root with `~` and redacts the file name.
  ///
  /// Directory structure survives because it is generic and useful; the leaf name does
  /// not, because in this app it is the profile/subscription name. Only a leaf that
  /// looks like a file (it has an extension) is redacted, so directory paths stay
  /// readable.
  private static func redactHomePaths(in value: String) -> String {
    // Group 1 is the user-owned root of any supported shape; group 2 is everything
    // below it. Only the root is replaced, so the path's depth is never altered.
    rewrite(homePathRegex, in: value) { match, source in
      let tail = capture(match, 2, in: source) ?? ""
      guard let lastSlash = tail.lastIndex(of: "/") else { return "~" + tail }
      let leaf = String(tail[tail.index(after: lastSlash)...])
      guard let redactedLeaf = redactingFileName(leaf) else { return "~" + tail }
      return "~" + tail[..<tail.index(after: lastSlash)] + redactedLeaf
    }
  }

  /// Returns `nil` when the component is not file-shaped and should be left alone.
  private static func redactingFileName(_ component: String) -> String? {
    guard let dot = component.lastIndex(of: "."), dot != component.startIndex else { return nil }
    let ext = component[component.index(after: dot)...]
    guard (1...10).contains(ext.count),
          ext.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
    return placeholder + "." + ext
  }

  // MARK: - Regex helpers

  private static func replaceAll(
    _ regex: NSRegularExpression,
    in value: String,
    template: String
  ) -> String {
    regex.stringByReplacingMatches(
      in: value,
      options: [],
      range: NSRange(value.startIndex..., in: value),
      withTemplate: template
    )
  }

  /// Rewrites matches back-to-front so earlier ranges stay valid.
  private static func rewrite(
    _ regex: NSRegularExpression,
    in value: String,
    using transform: (NSTextCheckingResult, String) -> String
  ) -> String {
    let full = NSRange(value.startIndex..., in: value)
    let matches = regex.matches(in: value, options: [], range: full)
    guard !matches.isEmpty else { return value }
    var result = value
    for match in matches.reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      result.replaceSubrange(range, with: transform(match, value))
    }
    return result
  }

  private static func capture(
    _ match: NSTextCheckingResult,
    _ index: Int,
    in source: String
  ) -> String? {
    guard index < match.numberOfRanges else { return nil }
    let range = match.range(at: index)
    guard range.location != NSNotFound, let swiftRange = Range(range, in: source) else {
      return nil
    }
    return String(source[swiftRange])
  }
}
