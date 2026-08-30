import Foundation
import Yams

/// Reads the `listeners` block back out of the runtime config the core was actually handed.
///
/// Same reasoning as `ActiveSnifferConfigReader` and `ActiveDNSConfigReader`, with more at stake:
/// `GET /configs` carries **no `listeners` key at all** (verified against the bundled core,
/// v1.19.30), so the generated file is the only source that can answer "did this profile open a
/// port other machines can reach?" — the question roadmap C3 makes the condition of supporting the
/// key at all. It reads `authentication` from the same file because a listener's exposure and
/// whether it demands credentials are one fact, not two.
enum ActiveListenerConfigReader {
  /// `nil` when the file is gone or unreadable — reported as "unknown" rather than collapsed into
  /// "nothing is listening", which would be the one wrong answer that matters. A readable file with
  /// no `listeners:` block returns an empty, present value: the core opened no extra inbounds.
  static func facts(at url: URL) async -> ListenerRuntimeFacts? {
    await Task.detached(priority: .utility) {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let root = (try? Yams.load(yaml: text)) as? [String: Any]
      else { return nil }
      return ListenerRuntimeFacts.facts(from: root)
    }.value
  }
}
