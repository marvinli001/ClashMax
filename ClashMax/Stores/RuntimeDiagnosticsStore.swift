import Foundation

/// The facts the diagnostics verdicts are judged against: what the applied runtime config actually
/// says (`sniffer`, `dns`, `listeners`, `find-process-mode`, TUN congestion control), the fake-ip
/// baselines, and the DNS resolution panel. Split out of `AppModel` (roadmap D1); `AppModel` keeps
/// the same members as facades over this store, so views and tests read them unchanged.
@MainActor
@Observable
final class RuntimeDiagnosticsStore {
  /// The `sniffer` block of the config the core is running. `nil` means "not read yet", which the
  /// diagnostics report as unknown rather than as sniffing being off (roadmap A1c).
  private(set) var activeSnifferSettings: SnifferSettings?
  /// When the sniffer configuration last *changed*, not when it was last read. A connection opened
  /// before that moment never ran under these settings, and the verdict says so instead of judging
  /// it by a configuration it never saw — otherwise applying a fix from the Connections panel would
  /// immediately produce a new, false verdict on the very row it repaired.
  private(set) var activeSnifferSettingsChangedAt: Date?
  @ObservationIgnored private var activeSnifferSettingsTask: Task<Void, Never>?
  /// The `dns` block of the config the core is running. `nil` means "not read yet"; the fake-ip
  /// diagnosis reports that as unknown rather than as "not in fake-ip mode" (roadmap A3). It has to
  /// come from the file because `GET /configs` carries no `dns` key at all.
  private(set) var activeDNSFacts: DNSRuntimeFacts?
  @ObservationIgnored private var activeDNSFactsTask: Task<Void, Never>?
  /// Read from the applied YAML so a profile value or raw snippet is shown instead of the picker
  /// default. Nil means the read is pending or unavailable, not that the core is using cubic.
  private(set) var activeTunCongestionController: String?
  @ObservationIgnored private var activeTunCongestionControllerTask: Task<Void, Never>?
  /// The `listeners` and `authentication` blocks of the config the core is running. `nil` means
  /// "not read yet"; the exposure verdict reports that as unknown rather than as "nothing is
  /// listening" (roadmap C3). It has to come from the file because `GET /configs` carries no
  /// `listeners` key at all.
  private(set) var activeListenerFacts: ListenerRuntimeFacts?
  @ObservationIgnored private var activeListenerFactsTask: Task<Void, Never>?
  /// `find-process-mode` from the running config; nil when unset (the core's default, which looks
  /// processes up when a rule needs one) or when nothing is running.
  private(set) var activeFindProcessMode: String?
  @ObservationIgnored private var activeFindProcessModeTask: Task<Void, Never>?
  /// The name the DNS resolution panel is asking about, and what came back (roadmap A2).
  var dnsResolutionQuery = ""
  var dnsResolutionQueryType: DNSQueryType = .a
  private(set) var dnsResolutionOutcome: DNSResolutionOutcome = .idle
  /// Deliberately ignored, as it was on `AppModel`: the outcome moves to `.querying` and back in the
  /// same turns this handle is set and cleared, so readers of `isResolvingDNS` are invalidated
  /// through `dnsResolutionOutcome`.
  @ObservationIgnored private var dnsResolutionTask: Task<Void, Never>?
  /// When a core process last started on a ClashMax config. A new process starts with an empty
  /// fake-ip table (Mihomo's `profile.store-fake-ip` defaults to off and ClashMax never turns it
  /// on), so it is the baseline every later invalidating event is compared against. A hot reload
  /// is deliberately not one: Mihomo clones the old table into the reloaded config, and since
  /// v1.19.33 its allocation cursor too, so a reload empties nothing.
  private(set) var lastCoreLaunchAt: Date?
  private(set) var lastFakeIPFlushAt: Date?
  private(set) var lastNetworkEnvironmentChangeAt: Date?

  var isResolvingDNS: Bool {
    dnsResolutionTask != nil
  }

  func recordCoreLaunch() {
    lastCoreLaunchAt = Date()
  }

  func recordFakeIPFlush() {
    lastFakeIPFlushAt = Date()
  }

  func recordNetworkEnvironmentChange() {
    lastNetworkEnvironmentChangeAt = Date()
  }

  /// Re-reads every block of the applied config the verdicts depend on. Nothing waits on these
  /// reads; until each lands its verdict reports "unknown" rather than guessing.
  func refreshAppliedConfigFacts(from url: URL) {
    refreshActiveSnifferSettings(from: url)
    refreshActiveDNSFacts(from: url)
    refreshActiveTunCongestionController(from: url)
    refreshActiveListenerFacts(from: url)
    refreshActiveFindProcessMode(from: url)
  }

  /// Drops everything learned about the previous runtime. The network-change stamp survives on
  /// purpose: it is about the Mac, not about the core.
  func clearRuntimeFacts() {
    activeFindProcessModeTask?.cancel()
    activeFindProcessModeTask = nil
    activeFindProcessMode = nil
    activeSnifferSettingsTask?.cancel()
    activeSnifferSettingsTask = nil
    activeSnifferSettings = nil
    activeSnifferSettingsChangedAt = nil
    activeDNSFactsTask?.cancel()
    activeDNSFactsTask = nil
    activeDNSFacts = nil
    activeTunCongestionControllerTask?.cancel()
    activeTunCongestionControllerTask = nil
    activeTunCongestionController = nil
    activeListenerFactsTask?.cancel()
    activeListenerFactsTask = nil
    activeListenerFacts = nil
    dnsResolutionTask?.cancel()
    dnsResolutionTask = nil
    dnsResolutionOutcome = .idle
    lastCoreLaunchAt = nil
    lastFakeIPFlushAt = nil
  }

  /// Asks the running core to resolve the panel's name through its **own** resolver — the same
  /// nameservers and policies that decide routing, which is why a `dig` on this Mac answers a
  /// different question (roadmap A2).
  func resolveDNSQuery(using apiClient: (any MihomoAPIControlling)?) {
    guard dnsResolutionTask == nil, let apiClient else { return }
    let name = dnsResolutionQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    // The core resolves an empty `name` against the root zone and answers 200, so a blank query
    // would come back looking like a successful answer about nothing.
    guard !name.isEmpty else { return }
    let type = dnsResolutionQueryType
    dnsResolutionOutcome = .querying
    dnsResolutionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer { dnsResolutionTask = nil }
      do {
        let result = try await apiClient.dnsQuery(name: name, type: type.rawValue)
        guard !Task.isCancelled else { return }
        dnsResolutionOutcome = .answered(result)
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        dnsResolutionOutcome = .failed(UserFacingError.message(for: error))
      }
    }
  }

  /// Whether the config the core was handed lets process rules match at all (roadmap B1).
  private func refreshActiveFindProcessMode(from url: URL) {
    activeFindProcessModeTask?.cancel()
    activeFindProcessModeTask = Task { @MainActor [weak self] in
      let mode = await FindProcessModeConfigReader.mode(at: url)
      guard !Task.isCancelled, let self else { return }
      activeFindProcessMode = mode
    }
  }

  /// Reads the applied config's `sniffer` block in the background so the Connections verdict can be
  /// about what is running. Nothing waits on it: until it lands, a domainless connection is reported
  /// as "sniffer settings unknown" instead of being blamed on a configuration nobody has read.
  private func refreshActiveSnifferSettings(from url: URL) {
    activeSnifferSettingsTask?.cancel()
    activeSnifferSettingsTask = Task { [weak self] in
      let settings = await ActiveSnifferConfigReader.snifferSettings(at: url)
      guard !Task.isCancelled, let self else { return }
      // Only a real change is stamped. The first read of a runtime is not a change: the core came
      // up with these settings, so every connection it has ever had ran under them.
      if let activeSnifferSettings, activeSnifferSettings != settings {
        activeSnifferSettingsChangedAt = Date()
      }
      activeSnifferSettings = settings
    }
  }

  /// Reads the applied config's `dns` block in the background, for the same reason as the sniffer
  /// block: `GET /configs` carries no `dns` key at all, so the generated file is the only source
  /// that can say whether the core is in fake-ip mode (roadmap A3). Nothing waits on it; until it
  /// lands the fake-ip verdict reports "unknown" rather than guessing.
  private func refreshActiveDNSFacts(from url: URL) {
    activeDNSFactsTask?.cancel()
    activeDNSFactsTask = Task { @MainActor [weak self] in
      let facts = await ActiveDNSConfigReader.facts(at: url)
      guard !Task.isCancelled, let self else { return }
      activeDNSFacts = facts
    }
  }

  private func refreshActiveTunCongestionController(from url: URL) {
    activeTunCongestionControllerTask?.cancel()
    activeTunCongestionController = nil
    activeTunCongestionControllerTask = Task { @MainActor [weak self] in
      let value = await TunCongestionControllerConfigReader.value(at: url)
      guard !Task.isCancelled, let self else { return }
      activeTunCongestionController = value
    }
  }

  /// Reads the applied config's `listeners` block in the background, for the same reason as the
  /// `dns` block and with more at stake: `GET /configs` carries no `listeners` key, so nothing else
  /// can tell the user that the running config opened a port other machines can reach (roadmap C3).
  private func refreshActiveListenerFacts(from url: URL) {
    activeListenerFactsTask?.cancel()
    activeListenerFactsTask = Task { @MainActor [weak self] in
      let facts = await ActiveListenerConfigReader.facts(at: url)
      guard !Task.isCancelled, let self else { return }
      activeListenerFacts = facts
    }
  }
}
