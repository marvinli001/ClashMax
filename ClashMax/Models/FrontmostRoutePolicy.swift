import Foundation

/// The app the user was using when they opened the menu bar panel, captured without asking macOS
/// for any permission: `NSWorkspace` reports the frontmost app's bundle and executable freely.
struct FrontmostAppSnapshot: Equatable, Sendable {
  var name: String
  var bundleIdentifier: String?
  var bundleURL: URL?
  var executableURL: URL?

  /// Browsers whose page loads leave the app for WebKit's shared networking service, so neither a
  /// bundle rule nor a path match on the app sees them (see `ProcessRuleCoverage`).
  static let webKitBrowserBundleIdentifiers: Set<String> = [
    "com.apple.Safari",
    "com.apple.SafariTechnologyPreview",
  ]

  /// Apps whose user almost always means "this site" rather than "everything this app does".
  static let browserBundleIdentifiers: Set<String> = webKitBrowserBundleIdentifiers.union([
    "com.google.Chrome",
    "com.google.Chrome.beta",
    "com.google.Chrome.canary",
    "org.chromium.Chromium",
    "com.microsoft.edgemac",
    "org.mozilla.firefox",
    "org.mozilla.firefoxdeveloperedition",
    "company.thebrowser.Browser",
    "com.brave.Browser",
    "com.operasoftware.Opera",
    "com.vivaldi.Vivaldi",
    "app.zen-browser.zen",
  ])

  var isBrowser: Bool {
    bundleIdentifier.map(Self.browserBundleIdentifiers.contains) ?? false
  }

  var loadsPagesThroughWebKit: Bool {
    bundleIdentifier.map(Self.webKitBrowserBundleIdentifiers.contains) ?? false
  }

  /// The `.app` the frontmost process runs from, when it runs from one.
  var appBundleURL: URL? {
    guard let bundleURL, bundleURL.pathExtension.lowercased() == "app" else { return nil }
    return bundleURL.standardizedFileURL
  }
}

/// What "route this site or app" can key a rule on.
enum FrontmostRouteSubject: Hashable, Identifiable, Sendable {
  /// Every connection the app opens, by process — the Connections page's "Route <app> Through…".
  case app(name: String)
  /// One site the app recently talked to, by domain — the Connections page's "Add Rule for <host>…".
  case site(host: String)

  var id: String {
    switch self {
    case let .app(name): "app:\(name)"
    case let .site(host): "site:\(host.lowercased())"
    }
  }
}

/// Where the rule sends the traffic: a policy group, one node, or straight out.
enum FrontmostRouteTarget: Hashable, Sendable {
  case group(String)
  case node(String)
  case direct

  /// The policy field of the rule line.
  var policy: String {
    switch self {
    case let .group(name), let .node(name): name
    case .direct: "DIRECT"
    }
  }
}

/// The pure decisions behind the menu bar's "Route This Site or App…": which subjects to offer for
/// the frontmost app, which targets to offer, and which rule a (subject, target) pair becomes.
///
/// The browser's tab URL is deliberately *not* read. That would need Automation (AppleScript)
/// consent per browser, and Accessibility for the rest — two prompts for a menu item. The core
/// already knows which domains the frontmost app just connected to, so those are offered instead,
/// newest first, and the user picks the one that is the site.
enum FrontmostRoutePolicy {
  /// Enough to find the page's own domain among the CDN and telemetry hosts a load also opens,
  /// few enough to read at a glance in a menu.
  static let maximumSites = 6

  /// Rule types the user cannot target as a node: built-ins are offered as targets of their own
  /// (DIRECT) or not at all (REJECT and friends are not a "route through").
  static let builtInPolicies: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"]

  // MARK: Subjects

  /// The subjects for `app`: the app itself when a process rule can be written for it, then the
  /// domains it connected to most recently.
  static func subjects(for app: FrontmostAppSnapshot, connections: [ConnectionSnapshot]) -> [FrontmostRouteSubject] {
    var subjects: [FrontmostRouteSubject] = []
    if appDraft(for: app) != nil {
      subjects.append(.app(name: app.name))
    }
    subjects += recentSites(for: app, connections: connections).map { .site(host: $0) }
    return subjects
  }

  /// The subject preselected when the panel opens: the newest site for a browser, where the page
  /// is what the user is looking at, and the app itself for everything else.
  static func defaultSubject(
    in subjects: [FrontmostRouteSubject],
    app: FrontmostAppSnapshot
  ) -> FrontmostRouteSubject? {
    if app.isBrowser, let site = subjects.first(where: { if case .site = $0 { true } else { false } }) {
      return site
    }
    return subjects.first
  }

  /// Distinct domains `app` connected to, newest first. IP-only connections are skipped: an
  /// address is not "the site", and a CIDR rule for one CDN edge would not follow the site anyway.
  static func recentSites(
    for app: FrontmostAppSnapshot,
    connections: [ConnectionSnapshot],
    limit: Int = maximumSites
  ) -> [String] {
    let owned = connections.enumerated()
      .filter { belongs($0.element, to: app) }
      .sorted { lhs, rhs in
        let left = lhs.element.startedAt ?? lhs.element.lastSeenAt ?? .distantPast
        let right = rhs.element.startedAt ?? rhs.element.lastSeenAt ?? .distantPast
        // The core lists connections oldest first, so a later position is the tiebreak for "newer".
        return left == right ? lhs.offset > rhs.offset : left > right
      }
    var seen = Set<String>()
    var sites: [String] = []
    for (_, connection) in owned {
      guard let domain = connection.domain?.trimmingCharacters(in: .whitespacesAndNewlines),
            !domain.isEmpty,
            seen.insert(domain.lowercased()).inserted
      else { continue }
      sites.append(domain)
      if sites.count >= max(0, limit) { break }
    }
    return sites
  }

  /// Whether `connection` was opened by `app`. A process inside the app's bundle counts — that is
  /// how Chrome's network helper and Electron renderers are attributed to their app. For Safari the
  /// page loads come from WebKit's networking service instead, which only Safari-like apps use
  /// while frontmost, so those connections are attributed to it as well.
  static func belongs(_ connection: ConnectionSnapshot, to app: FrontmostAppSnapshot) -> Bool {
    guard let path = connection.processPath, path.hasPrefix("/") else {
      return app.loadsPagesThroughWebKit && isWebKitNetworkingProcess(name: connection.processName, path: nil)
    }
    if let bundle = app.appBundleURL,
       let owner = AppProcessRule.owningAppBundle(ofProcessPath: path)?.standardizedFileURL,
       owner.path.compare(bundle.path, options: .caseInsensitive) == .orderedSame
    {
      return true
    }
    if app.appBundleURL == nil, let executable = app.executableURL?.standardizedFileURL.path, executable == path {
      return true
    }
    return app.loadsPagesThroughWebKit && isWebKitNetworkingProcess(name: connection.processName, path: path)
  }

  static func isWebKitNetworkingProcess(name: String?, path: String?) -> Bool {
    let marker = "com.apple.WebKit.Networking"
    return name?.hasPrefix(marker) == true || path?.contains(marker) == true
  }

  // MARK: Targets

  struct NodeGroup: Equatable, Sendable {
    var group: String
    var nodes: [String]
  }

  struct TargetOptions: Equatable, Sendable {
    /// Policy groups, in profile order.
    var groups: [String]
    /// The real proxies under each group, in profile order, for "route through this one node".
    var nodesByGroup: [NodeGroup]
  }

  /// Every group is a valid rule policy, whatever its type: a rule naming a url-test group follows
  /// whichever node that group picks. GLOBAL is left out — it is the global-mode selector, and a
  /// rule naming it would route by a choice the user only makes in another mode.
  static func targetOptions(groups: [ProxyGroup]) -> TargetOptions {
    let routable = groups.filter { $0.name.caseInsensitiveCompare(MenuBarNodeSelection.globalGroupName) != .orderedSame }
    let groupNames = Set(groups.map { $0.name.lowercased() })
    let nodesByGroup: [NodeGroup] = routable.compactMap { group in
      var seen = Set<String>()
      let nodes = group.nodes.map(\.name).filter { name in
        let key = name.lowercased()
        return !groupNames.contains(key)
          && !builtInPolicies.contains(name.uppercased())
          && seen.insert(key).inserted
      }
      return nodes.isEmpty ? nil : NodeGroup(group: group.name, nodes: nodes)
    }
    return TargetOptions(groups: routable.map(\.name), nodesByGroup: nodesByGroup)
  }

  // MARK: Rules

  /// The process rule for the app, the same one the Connections page writes for a row from it: the
  /// bundle pattern for an app, the exact path for a bare executable. `nil` when macOS reported no
  /// location to match on.
  static func appDraft(for app: FrontmostAppSnapshot) -> QuickRuleDraft? {
    if let bundleURL = app.appBundleURL {
      return AppProcessRule.draft(
        for: InstalledApp(
          bundleURL: bundleURL,
          name: app.name,
          bundleIdentifier: app.bundleIdentifier,
          executableURL: app.executableURL
        )
      )
    }
    return AppProcessRule.draft(forProcessPath: app.executableURL?.path)
  }

  /// The rule `subject` → `target` becomes, prepended so it wins over the profile's own rules.
  static func draft(
    for subject: FrontmostRouteSubject,
    app: FrontmostAppSnapshot,
    target: FrontmostRouteTarget
  ) -> QuickRuleDraft? {
    switch subject {
    case .app:
      guard var draft = appDraft(for: app) else { return nil }
      draft.rule.policy = target.policy
      return draft
    case let .site(host):
      return QuickRuleDraft.targeting(host: host, policy: target.policy)
    }
  }
}
