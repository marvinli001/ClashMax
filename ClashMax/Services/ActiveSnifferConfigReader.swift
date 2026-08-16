import Foundation
import Yams

/// Reads the `sniffer` block back out of the runtime config the core was actually handed.
///
/// INV-1, one truth: the Connections verdict has to be about what is running, not about what the app
/// meant to write. `GET /configs` reports a single `sniffing: true|false` and nothing about which
/// protocols, ports or exceptions are in play (roadmap A1.0), so the generated file is the only
/// source that can answer "could this connection's domain have been recovered?" — and it is the same
/// file `EffectiveRuntimeConfigBuilder` reads for the Routing layer view.
enum ActiveSnifferConfigReader {
  /// `nil` when the file is gone, unreadable, or carries no `sniffer` block at all — reported as
  /// "unknown" rather than collapsed into "sniffing is off", which would be a guess.
  static func snifferSettings(at url: URL) async -> SnifferSettings? {
    await Task.detached(priority: .utility) {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let root = (try? Yams.load(yaml: text)) as? [String: Any],
            let mapping = root["sniffer"] as? [String: Any]
      else { return nil }
      return SnifferSettings(runtimeMapping: mapping)
    }.value
  }
}
