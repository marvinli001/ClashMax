import Foundation

/// Pure, `Sendable` search pipeline for the Proxies page.
///
/// Issue #10: the proxy search work (provider expansion, per-group node sort, query filtering)
/// used to run synchronously inside `ProxiesView.body`, so every keystroke — and every per-node
/// delay update during a batch test — re-ran the whole thing on the main thread. With 1600+ nodes
/// that froze the UI.
///
/// `ProxySearchPipeline.run` is a free function over value types, so `ProxySearchCoordinator` can
/// hop it onto a background task and the main thread only publishes the finished snapshot.
enum ProxySearchPipeline {
  struct Input: Sendable, Equatable {
    var groups: [ProxyGroup]
    var providers: [ProxyProvider]
    var sortOrder: ProxyNodeSort
    var searchText: String

    init(
      groups: [ProxyGroup],
      providers: [ProxyProvider],
      sortOrder: ProxyNodeSort,
      searchText: String
    ) {
      self.groups = groups
      self.providers = providers
      self.sortOrder = sortOrder
      self.searchText = searchText
    }
  }

  /// Resolve providers → sort nodes per group → filter by query. Mirrors the exact order the view
  /// body used previously (`ResolvedProxyCatalog` → `sortedGroups` → `ProxyGroupSearchFilter`) so
  /// existing semantics are preserved.
  static func run(_ input: Input) -> ProxySearchSnapshot {
    let startNanos = DispatchTime.now().uptimeNanoseconds

    let resolved = ResolvedProxyCatalog(groups: input.groups, providers: input.providers).groups
    let sorted = resolved.map { group -> ProxyGroup in
      var group = group
      group.nodes = ProxyNodeSorter.sorted(group.nodes, by: input.sortOrder)
      return group
    }
    let query = ProxySearchQuery(rawValue: input.searchText)
    let filtered = ProxyGroupSearchFilter.filteredGroups(from: sorted, searchQuery: query)

    let durationMs = Double(DispatchTime.now().uptimeNanoseconds &- startNanos) / 1_000_000

    return ProxySearchSnapshot(
      searchText: input.searchText,
      query: query,
      sortOrder: input.sortOrder,
      unfilteredGroups: sorted,
      filteredGroups: filtered,
      resultIdentity: Self.identity(of: filtered),
      unfilteredIdentity: Self.identity(of: sorted),
      sourceNodeCount: sorted.reduce(0) { $0 + $1.nodes.count },
      resultNodeCount: filtered.reduce(0) { $0 + $1.nodes.count },
      durationMs: durationMs,
      hasResolved: true
    )
  }

  /// A stable fingerprint of the displayed result, used to drive selection/expansion updates
  /// without diffing the full node payload.
  static func identity(of groups: [ProxyGroup]) -> [String] {
    var identity: [String] = []
    identity.reserveCapacity(groups.count * 2)
    for group in groups {
      identity.append("g:\(group.id)#\(group.selected ?? "")")
      for node in group.nodes {
        identity.append(node.id)
      }
    }
    return identity
  }
}

/// Immutable result the view renders. Excludes `durationMs` and derived counts from equality so a
/// re-run that produces identical display content doesn't churn `@Published` subscribers.
struct ProxySearchSnapshot: Sendable {
  var searchText: String
  var query: ProxySearchQuery
  var sortOrder: ProxyNodeSort
  /// Resolved + sorted groups with no query applied (drives empty-state copy / counts).
  var unfilteredGroups: [ProxyGroup]
  /// Resolved + sorted + filtered groups actually shown.
  var filteredGroups: [ProxyGroup]
  var resultIdentity: [String]
  /// Structural fingerprint of `unfilteredGroups` (group/selection/node ids, *no* delay values).
  /// Lets equality detect node add/remove/selection changes while ignoring delay-only churn on
  /// nodes that are currently filtered out of the displayed result (issue #11).
  var unfilteredIdentity: [String]
  var sourceNodeCount: Int
  var resultNodeCount: Int
  var durationMs: Double
  /// `false` for the initial placeholder snapshot, before the pipeline has produced real output.
  var hasResolved: Bool

  static let empty = ProxySearchSnapshot(
    searchText: "",
    query: ProxySearchQuery(rawValue: ""),
    sortOrder: .profile,
    unfilteredGroups: [],
    filteredGroups: [],
    resultIdentity: [],
    unfilteredIdentity: [],
    sourceNodeCount: 0,
    resultNodeCount: 0,
    durationMs: 0,
    hasResolved: false
  )

  var isSearchActive: Bool { !query.isEmpty }
}

extension ProxySearchSnapshot: Equatable {
  static func == (lhs: ProxySearchSnapshot, rhs: ProxySearchSnapshot) -> Bool {
    // `filteredGroups` is compared in full (it carries the delays of the *displayed* nodes), while
    // the unfiltered side is compared only by its structural identity. So when a search is active,
    // a delay change on a filtered-*out* node leaves both `filteredGroups` and `unfilteredIdentity`
    // unchanged and the snapshot is considered equal — the coordinator then skips a redundant
    // publish (issue #11). Node add/remove/selection still alters `unfilteredIdentity` and republishes.
    lhs.searchText == rhs.searchText
      && lhs.sortOrder == rhs.sortOrder
      && lhs.hasResolved == rhs.hasResolved
      && lhs.resultIdentity == rhs.resultIdentity
      && lhs.unfilteredIdentity == rhs.unfilteredIdentity
      && lhs.filteredGroups == rhs.filteredGroups
  }
}

/// Monotonic generation guard. Each scheduled search calls `begin()`; a completed computation may
/// only `commit()` if it is still the newest generation, so a slow stale result can never clobber
/// a newer query's snapshot.
struct ProxySearchGenerationGate: Sendable {
  private(set) var latest = 0
  private(set) var published = 0
  private(set) var staleDropped = 0

  mutating func begin() -> Int {
    latest += 1
    return latest
  }

  mutating func commit(_ token: Int) -> Bool {
    guard token >= latest, token > published else {
      staleDropped += 1
      return false
    }
    published = token
    return true
  }
}

/// Decides whether the lightweight in-line search spinner is shown. Deliberately independent of the
/// loading-skeleton policy: searching must never swap in a skeleton (issue #10 + AGENTS.md).
enum ProxySearchActivityPolicy {
  static func showsSearchProgress(searchText: String, isComputing: Bool) -> Bool {
    guard isComputing else { return false }
    return !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// Expands `provider`-typed group members into the provider's nodes, then de-duplicates by node id.
///
/// Moved out of `ProxiesView` so the pipeline can run it off the main thread. Group identity is
/// preserved 1:1 (a group is never added or dropped), which is why `ProxiesView` can keep using the
/// cheap raw `visibleProxyGroups.count` for its skeleton/empty-state gates instead of resolving.
struct ResolvedProxyCatalog {
  var groups: [ProxyGroup]

  init(groups: [ProxyGroup], providers: [ProxyProvider]) {
    let providerNodes = Dictionary(uniqueKeysWithValues: providers.map { provider in
      (provider.name, provider.proxies.map { node -> ProxyNode in
        var node = node
        node.providerName = provider.name
        return node
      })
    })

    self.groups = groups.map { group in
      var group = group
      var expandedNodes: [ProxyNode] = []
      for node in group.nodes {
        if node.type.caseInsensitiveCompare("provider") == .orderedSame,
           let providerName = Self.providerName(from: node),
           let nodes = providerNodes[providerName],
           !nodes.isEmpty {
          expandedNodes.append(contentsOf: nodes.map { providerNode in
            var providerNode = providerNode
            providerNode.isSelectable = group.allowsManualProxySelection
            return providerNode
          })
        } else {
          expandedNodes.append(node)
        }
      }
      group.nodes = Self.deduplicated(expandedNodes)
      return group
    }
  }

  private static func providerName(from node: ProxyNode) -> String? {
    if let providerName = node.providerName?.trimmingCharacters(in: .whitespacesAndNewlines), !providerName.isEmpty {
      return providerName
    }
    let prefix = "Provider:"
    guard node.name.hasPrefix(prefix) else { return nil }
    return String(node.name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func deduplicated(_ nodes: [ProxyNode]) -> [ProxyNode] {
    var seen = Set<String>()
    var result: [ProxyNode] = []
    for node in nodes {
      guard seen.insert(node.id).inserted else { continue }
      result.append(node)
    }
    return result
  }
}

/// Cheap fingerprint of the raw group/provider data that feeds the search pipeline.
///
/// Computed in `body` (O(node count) of integer/string hashes — far cheaper than the resolve/sort/
/// filter it replaces) and watched with `.onChange` so a coordinator only reschedules a recompute
/// when something that actually affects results changed (names, types, providers, selection, or a
/// node's resolved delay state). Bursty per-node delay-batch updates therefore coalesce into a few
/// debounced background recomputes instead of recomputing on the main thread per node.
///
/// Shared by the Proxies page and the dashboard Current Node card so both react to the same data
/// changes through one off-main pipeline (issue #14 reuses this for the dashboard).
struct ProxySearchInputSignature: Equatable {
  let groupCount: Int
  let providerCount: Int
  let nodeCount: Int
  let contentHash: Int

  init(groups: [ProxyGroup], providers: [ProxyProvider]) {
    var hasher = Hasher()
    var nodeCount = 0
    for group in groups {
      hasher.combine(group.name)
      hasher.combine(group.type)
      hasher.combine(group.selected)
      for node in group.nodes {
        Self.combine(node: node, into: &hasher)
        nodeCount += 1
      }
    }
    for provider in providers {
      hasher.combine(provider.name)
      for node in provider.proxies {
        Self.combine(node: node, into: &hasher)
        nodeCount += 1
      }
    }
    self.groupCount = groups.count
    self.providerCount = providers.count
    self.nodeCount = nodeCount
    self.contentHash = hasher.finalize()
  }

  private static func combine(node: ProxyNode, into hasher: inout Hasher) {
    hasher.combine(node.name)
    hasher.combine(node.type)
    hasher.combine(node.providerName)
    hasher.combine(node.isSelectable)
    switch node.resolvedDelayState {
    case .unknown:
      hasher.combine(0)
    case .testing:
      hasher.combine(1)
    case .timeout:
      hasher.combine(2)
    case let .measured(delay):
      hasher.combine(3)
      hasher.combine(delay)
    case let .error(message):
      hasher.combine(4)
      hasher.combine(message)
    }
  }
}
