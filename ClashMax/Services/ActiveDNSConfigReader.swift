import Foundation
import Yams

/// Reads the `dns` block back out of the runtime config the core was actually handed.
///
/// Same reasoning as `ActiveSnifferConfigReader`: `GET /configs` reports the core's inbound, geo and
/// TUN settings but carries **no `dns` key at all** (verified against the bundled core, v1.19.30),
/// so the generated file is the only source that can answer "is this core in fake-ip mode?" — the
/// question roadmap A3 needs answered before offering to flush the fake-ip table.
enum ActiveDNSConfigReader {
  /// `nil` when the file is gone or unreadable — reported as "unknown" rather than collapsed into
  /// "DNS is off", which would be a guess. A file with no `dns:` block returns `.absent`, which is a
  /// real answer: the core was handed nothing about DNS.
  static func facts(at url: URL) async -> DNSRuntimeFacts? {
    await Task.detached(priority: .utility) {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let root = (try? Yams.load(yaml: text)) as? [String: Any]
      else { return nil }
      return DNSRuntimeFacts.facts(from: root["dns"])
    }.value
  }
}
