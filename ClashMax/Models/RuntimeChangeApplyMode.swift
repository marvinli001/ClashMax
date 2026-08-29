import Foundation

/// What committing a pending configuration edit will actually do to the runtime.
///
/// Issue #15: every rule and DNS edit looked identical in the UI whether it reloaded the running
/// core in place, needed a full restart, or merely sat in defaults until the next start — so a
/// change that silently did nothing was indistinguishable from one that worked. The boundary is
/// resolved from the same facts the apply path already acts on (`AppModel.applyRunningRuntimeSettings`),
/// kept here as a pure value so both the promise shown before Apply and the outcome shown after it
/// come from one testable place.
enum RuntimeChangeApplyMode: Equatable, Sendable {
  /// Mihomo reloads the generated runtime config in place; the change is live once Apply returns.
  case hotReload
  /// The change cannot be reloaded into the running process, so the runtime has to be restarted.
  case requiresRestart(RuntimeRestartReason)
  /// Nothing reads this value right now — it is persisted and materialized at the next start.
  case appliesOnNextStart

  var requiresRestart: Bool {
    if case .requiresRestart = self { return true }
    return false
  }

  /// One line describing what pressing Apply will do, for the editor that is about to commit.
  var pendingSummary: String {
    switch self {
    case .hotReload:
      return String(localized: "Running: applying reloads Mihomo, so the change takes effect immediately.")
    case let .requiresRestart(reason):
      return String(
        format: String(localized: "Running: applying needs a runtime restart — %@."),
        reason.explanation
      )
    case .appliesOnNextStart:
      return String(localized: "Not applied to a running runtime: the change takes effect the next time the core starts.")
    }
  }
}

/// Why a change cannot be folded into the running process. Each case matches a branch the runtime
/// apply path really takes, so the copy can never promise something the code does not do.
enum RuntimeRestartReason: String, Equatable, Sendable {
  /// The NE transparent proxy was configured with the inbound port and controller endpoint when it
  /// started, so changing either has to tear the tunnel down (`networkExtensionRuntimeRestartRequired`).
  case networkExtensionEndpointPinned
  /// NE routing settings are read when the transparent proxy is configured, not on config reload
  /// (`updateNetworkExtensionRoutingSettings`).
  case networkExtensionRoutingPinned

  var explanation: String {
    switch self {
    case .networkExtensionEndpointPinned:
      return String(localized: "NE Proxy captured the current inbound port and controller endpoint when it started")
    case .networkExtensionRoutingPinned:
      return String(localized: "NE Proxy reads its routing settings when the tunnel starts")
    }
  }
}

/// The kinds of edit whose apply boundary the UI describes. Deliberately coarse: it names what the
/// user is editing, not which YAML keys move.
enum RuntimeChangeKind: Equatable, Sendable {
  /// Rule overlays and rule snippets — prepended, appended, and disabled rules.
  case rules
  /// DNS patches and the managed DNS override.
  case dns
  /// The `sniffer` block — which protocols and ports are sniffed for a domain.
  case sniffer
  /// A raw YAML snippet — arbitrary Mihomo keys merged in after everything the app manages.
  case rawYAML
  /// The order of the runtime overlay snippets, which decides which rule wins.
  case snippetOrder
  /// A profile's own provider options, which carry its per-profile rule overlay.
  case profileOptions
  /// The Mihomo inbound (mixed) port.
  case inboundPort
  /// The external controller host/port pair.
  case controllerEndpoint
  /// NE Proxy routing settings (DNS capture, fake-IP, system DNS override).
  case networkExtensionRouting
}

/// The runtime facts the boundary depends on, snapshotted so the resolver stays pure.
struct RuntimeApplyContext: Equatable, Sendable {
  var runtimeOwner: RuntimeOwner
  var previewRuntimeActive: Bool

  init(runtimeOwner: RuntimeOwner, previewRuntimeActive: Bool = false) {
    self.runtimeOwner = runtimeOwner
    self.previewRuntimeActive = previewRuntimeActive
  }

  static let stopped = RuntimeApplyContext(runtimeOwner: .stopped)

  /// A preview runtime serves the Proxies preview, not the user's traffic: the real runtime is not
  /// up, so any edit here is a next-start edit no matter what it touches.
  var servesUserTraffic: Bool {
    guard !previewRuntimeActive else { return false }
    switch runtimeOwner {
    case .user, .tunnel, .networkExtension:
      return true
    case .stopped, .preview:
      return false
    }
  }
}

extension RuntimeChangeApplyMode {
  static func resolve(_ change: RuntimeChangeKind, in context: RuntimeApplyContext) -> RuntimeChangeApplyMode {
    guard context.servesUserTraffic else { return .appliesOnNextStart }
    switch change {
    case .rules, .dns, .sniffer, .rawYAML, .snippetOrder, .profileOptions:
      // All are materialized into the generated runtime YAML, which every owner reloads in place.
      // Verified for the sniffer on 2026-08-15: `PUT /configs?force=true` with a sniffer-off config
      // flipped `/configs.sniffing` from true to false on a running core, with no restart.
      // A raw snippet belongs here rather than in the restart branch because the two keys NE Proxy
      // pins at start — `mixed-port` and `external-controller` — are the ones `RawYAMLPatchPolicy`
      // refuses, so a raw patch can never move them out from under a running tunnel.
      return .hotReload
    case .inboundPort, .controllerEndpoint:
      return context.runtimeOwner == .networkExtension
        ? .requiresRestart(.networkExtensionEndpointPinned)
        : .hotReload
    case .networkExtensionRouting:
      return context.runtimeOwner == .networkExtension
        ? .requiresRestart(.networkExtensionRoutingPinned)
        : .appliesOnNextStart
    }
  }
}

/// What a commit actually did, published after the fact so the UI can confirm it rather than
/// leaving "no red text" as the only evidence. `rolledBack` is the important one: a silently
/// reverted edit reads as lost work, which is worse than an error.
enum RuntimeApplyOutcome: Equatable, Sendable {
  case applied(RuntimeChangeKind)
  case restartNeeded(RuntimeChangeKind, RuntimeRestartReason)
  case savedForNextStart(RuntimeChangeKind)
  case rolledBack(RuntimeChangeKind, message: String)

  var change: RuntimeChangeKind {
    switch self {
    case let .applied(change),
         let .restartNeeded(change, _),
         let .savedForNextStart(change),
         let .rolledBack(change, _):
      return change
    }
  }

  var isFailure: Bool {
    if case .rolledBack = self { return true }
    return false
  }

  var title: String {
    switch self {
    case .applied:
      return String(localized: "Applied to the running runtime")
    case .restartNeeded:
      return String(localized: "Saved, restart required")
    case .savedForNextStart:
      return String(localized: "Saved for the next start")
    case .rolledBack:
      return String(localized: "Rolled back")
    }
  }

  var detail: String {
    switch self {
    case let .applied(change):
      return String(format: String(localized: "Mihomo reloaded, so the %@ change is live now."), change.displayName)
    case let .restartNeeded(change, reason):
      return String(
        format: String(localized: "The %@ change is saved but needs a runtime restart — %@."),
        change.displayName,
        reason.explanation
      )
    case let .savedForNextStart(change):
      return String(
        format: String(localized: "The %@ change is saved and takes effect the next time the core starts."),
        change.displayName
      )
    case let .rolledBack(change, message):
      return String(
        format: String(localized: "The %@ change was reverted because the runtime rejected it: %@"),
        change.displayName,
        message
      )
    }
  }

  var systemImage: String {
    switch self {
    case .applied:
      return "checkmark.circle.fill"
    case .restartNeeded:
      return "arrow.clockwise.circle.fill"
    case .savedForNextStart:
      return "clock.badge.checkmark.fill"
    case .rolledBack:
      return "arrow.uturn.backward.circle.fill"
    }
  }
}

extension RuntimeChangeKind {
  /// The kind a runtime snippet edit changes, so the boundary copy names what was actually edited.
  init(_ payloadKind: RuntimeSnippetPayloadKind) {
    switch payloadKind {
    case .rules:
      self = .rules
    case .dnsPatch:
      self = .dns
    case .sniffer:
      self = .sniffer
    case .rawYAML:
      self = .rawYAML
    }
  }

  var displayName: String {
    switch self {
    case .rules:
      return String(localized: "rule")
    case .dns:
      return String(localized: "DNS")
    case .sniffer:
      return String(localized: "sniffer")
    case .rawYAML:
      return String(localized: "raw YAML")
    case .snippetOrder:
      return String(localized: "overlay order")
    case .profileOptions:
      return String(localized: "profile options")
    case .inboundPort:
      return String(localized: "inbound port")
    case .controllerEndpoint:
      return String(localized: "controller endpoint")
    case .networkExtensionRouting:
      return String(localized: "NE Proxy routing")
    }
  }
}
