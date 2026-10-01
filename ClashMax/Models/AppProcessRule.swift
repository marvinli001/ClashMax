import Foundation
import Yams

// Roadmap B1: route an app, not a process name typed from memory. Everything here is pure so the
// rule the picker writes, the app a connection belongs to, and what the UI warns about can be
// tested without real applications.

/// An application bundle the picker can turn into a process rule.
struct InstalledApp: Identifiable, Hashable, Sendable {
  var bundleURL: URL
  var name: String
  var bundleIdentifier: String?
  /// `Contents/MacOS/<CFBundleExecutable>`, when the bundle declares one.
  var executableURL: URL?

  var id: String {
    bundleURL.path
  }
}

enum InstalledAppScanner {
  /// Where macOS installs applications: the shared folder, the user's own, and the system's.
  static var standardDirectories: [URL] {
    [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
      URL(fileURLWithPath: "/System/Applications", isDirectory: true),
    ]
  }

  /// Every `.app` directly in `directories`, plus one level of ordinary subfolders (`Utilities`).
  /// Never descends into a bundle: the helper apps inside one are covered by the bundle's own rule.
  /// Sorted by name; a bundle reachable twice (a symlinked folder) is listed once.
  static func scan(directories: [URL], fileManager: FileManager = .default) -> [InstalledApp] {
    var seen = Set<String>()
    var apps: [InstalledApp] = []
    func append(_ url: URL) {
      let key = url.resolvingSymlinksInPath().standardizedFileURL.path
      guard seen.insert(key).inserted, let app = app(at: url, fileManager: fileManager) else { return }
      apps.append(app)
    }
    for directory in directories {
      for entry in contents(of: directory, fileManager: fileManager) {
        if isAppBundle(entry) {
          append(entry)
        } else if isPlainDirectory(entry, fileManager: fileManager) {
          for nested in contents(of: entry, fileManager: fileManager) where isAppBundle(nested) {
            append(nested)
          }
        }
      }
    }
    return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Reads one bundle. `nil` when it is not an application bundle at all.
  static func app(at bundleURL: URL, fileManager: FileManager = .default) -> InstalledApp? {
    let bundleURL = bundleURL.standardizedFileURL
    guard isAppBundle(bundleURL) else { return nil }
    let info = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
    let executable = (info?["CFBundleExecutable"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    // The Finder name, which is what people recognize — "Visual Studio Code", not its `Code`
    // bundle name — and is localized for system apps.
    var name = fileManager.displayName(atPath: bundleURL.path)
    if name.lowercased().hasSuffix(".app") {
      name = String(name.dropLast(4))
    }
    return InstalledApp(
      bundleURL: bundleURL,
      name: name,
      bundleIdentifier: info?["CFBundleIdentifier"] as? String,
      executableURL: executable.flatMap { $0.isEmpty ? nil : bundleURL.appendingPathComponent("Contents/MacOS/\($0)") }
    )
  }

  private static func contents(of directory: URL, fileManager: FileManager) -> [URL] {
    (try? fileManager.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
      options: [.skipsHiddenFiles]
    )) ?? []
  }

  private static func isAppBundle(_ url: URL) -> Bool {
    url.pathExtension.caseInsensitiveCompare("app") == .orderedSame
  }

  private static func isPlainDirectory(_ url: URL, fileManager: FileManager) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
      && url.pathExtension.isEmpty
  }
}

enum AppProcessRule {
  /// `^<bundle path>/`: every process launched from inside the bundle, the main executable and the
  /// helper apps alike. Measured against core v1.19.31 through the mixed port: this pattern caught
  /// a helper app nested under `Contents/Frameworks`, while `PROCESS-PATH` on the main executable and
  /// `PROCESS-NAME` both let the helper through — which is how Chrome, Electron apps and anything
  /// else with renderer or network helpers keep escaping a by-name rule.
  static func bundlePathPattern(for bundleURL: URL) -> String {
    "^" + escapedRegexLiteral(bundleURL.standardizedFileURL.path) + "/"
  }

  /// A regular-expression literal that matches `text` exactly and is safe as a rule field.
  ///
  /// Metacharacters are escaped the way Go's `regexp.QuoteMeta` does. A comma would end the rule
  /// field — `PROCESS-PATH-REGEX,<pattern>,<policy>` is split on commas before the pattern is
  /// compiled — so it is written as `\x2C`, which the core accepted and matched in a probe.
  static func escapedRegexLiteral(_ text: String) -> String {
    var escaped = ""
    for character in text {
      switch character {
      case "\\", ".", "+", "*", "?", "(", ")", "|", "[", "]", "{", "}", "^", "$":
        escaped.append("\\")
        escaped.append(character)
      case ",":
        escaped.append("\\x2C")
      default:
        escaped.append(character)
      }
    }
    return escaped
  }

  static func draft(for app: InstalledApp, policy: String = "") -> QuickRuleDraft {
    var draft = QuickRuleDraft(
      rule: ManagedRuleOverlayRule(kind: .processPathRegex, value: bundlePathPattern(for: app.bundleURL), policy: policy),
      placement: .beforeProfileRules
    )
    draft.verificationProcessPath = (app.executableURL ?? app.bundleURL.appendingPathComponent("Contents/MacOS/\(app.name)")).path
    return draft
  }

  /// The outermost `.app` a process runs from: Chrome's renderer lives in
  /// `Google Chrome.app/…/Google Chrome Helper (Renderer).app/…`, and the app the user means is the
  /// outer one. `nil` for a process that is not inside an application bundle.
  static func owningAppBundle(ofProcessPath path: String) -> URL? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return nil }
    var components: [String] = []
    for component in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
      components.append(String(component))
      if component.lowercased().hasSuffix(".app"), component.count > 4 {
        return URL(fileURLWithPath: "/" + components.joined(separator: "/"), isDirectory: true)
      }
    }
    return nil
  }

  /// The owning app's name for a connection menu: Chrome, not "Google Chrome Helper (Renderer)".
  static func appName(forProcessPath path: String?) -> String? {
    guard let path, let bundleURL = owningAppBundle(ofProcessPath: path) else { return nil }
    return bundleURL.deletingPathExtension().lastPathComponent
  }

  /// The rule for "route this app through…" on a connection: the owning app's bundle rule when the
  /// process lives in one, otherwise that one executable, by path. `nil` when the core reported no
  /// process path at all.
  static func draft(forProcessPath path: String?, fileManager: FileManager = .default) -> QuickRuleDraft? {
    guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return nil }
    if let bundleURL = owningAppBundle(ofProcessPath: path) {
      let app = InstalledAppScanner.app(at: bundleURL, fileManager: fileManager)
        ?? InstalledApp(bundleURL: bundleURL, name: bundleURL.deletingPathExtension().lastPathComponent)
      var draft = draft(for: app)
      // The process that was actually seen is the best probe for the verdict.
      draft.verificationProcessPath = path
      return draft
    }
    // A plain executable (`/usr/bin/curl`, a Homebrew binary). `PROCESS-PATH` cannot carry a comma,
    // so a path with one falls back to an anchored literal pattern.
    let rule = path.contains(",")
      ? ManagedRuleOverlayRule(kind: .processPathRegex, value: "^" + escapedRegexLiteral(path) + "$", policy: "")
      : ManagedRuleOverlayRule(kind: .processPath, value: path, policy: "")
    var draft = QuickRuleDraft(rule: rule, placement: .beforeProfileRules)
    draft.verificationProcessPath = path
    return draft
  }
}

/// What can stop a process rule from ever matching, for the text shown next to one.
enum ProcessRuleCoverage {
  struct Note: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
      /// No process rule can match in this configuration.
      case blocking
      /// Some traffic from the app will not be attributed to it.
      case partial
    }

    var severity: Severity
    var text: String
  }

  static func notes(routingMode: ProxyRoutingMode, findProcessMode: String?) -> [Note] {
    var notes: [Note] = []
    if findProcessMode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "off" {
      // Measured against v1.19.31: with `off`, a bundle pattern that otherwise caught both the app
      // and its helper matched nothing, and every connection fell through to MATCH.
      notes.append(Note(
        severity: .blocking,
        text: String(localized: "The running config sets find-process-mode: off, so Mihomo never looks up which app opened a connection and no process rule can match. A Raw YAML snippet can set it back to strict.")
      ))
    }
    if routingMode == .neProxy {
      // From the extension's code: it relays every flow over its own SOCKS connection to the core.
      notes.append(Note(
        severity: .blocking,
        text: String(localized: "In NE Proxy routing, ClashMax's network extension relays every connection to the core, so a process rule sees the extension, never the app. Use System Proxy or TUN routing for per-app rules.")
      ))
    }
    if routingMode == .systemProxy {
      notes.append(Note(
        severity: .partial,
        text: String(localized: "In System Proxy routing, only apps that use the system proxy reach the core at all. An app that ignores it is not routed by any rule, process rules included.")
      ))
    }
    notes.append(Note(
      severity: .partial,
      text: String(localized: "Some apps hand their networking to a system process: Safari loads pages through WebKit's networking service, and background downloads go through nsurlsessiond. That traffic belongs to the system process, not the app, so an app rule does not see it.")
    ))
    return notes
  }
}

/// Reads `find-process-mode` back out of the runtime config the core was handed. The key is not in
/// `GET /configs`, so the file is the only place to learn whether a subscription switched it off.
enum FindProcessModeConfigReader {
  static func mode(at url: URL) async -> String? {
    await Task.detached(priority: .utility) {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
            let root = (try? Yams.load(yaml: text)) as? [String: Any]
      else { return nil }
      return root["find-process-mode"] as? String
    }.value
  }
}
