import Foundation

struct RuntimePaths {
  let appSupport: URL
  let profiles: URL
  let runtime: URL
  let subscriptions: URL
  let logs: URL

  static func live(fileManager: FileManager = .default) throws -> RuntimePaths {
    let root = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    ).appendingPathComponent("ClashMax", isDirectory: true)

    let paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )

    for directory in [paths.appSupport, paths.profiles, paths.runtime, paths.subscriptions, paths.logs] {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    return paths
  }

  var manifestURL: URL {
    appSupport.appendingPathComponent("profiles.json")
  }

  func runtimeConfigURL(for profile: Profile) -> URL {
    runtime.appendingPathComponent("\(profile.id.uuidString).runtime.yaml")
  }

  func runtimeProviderContentURL(for profile: Profile) -> URL {
    runtime.appendingPathComponent("\(profile.id.uuidString).provider.txt")
  }
}

enum AppConstants {
  static let bundleIdentifier = "io.github.clashmax.ClashMax"
  static let helperBundleIdentifier = "io.github.clashmax.ClashMax.Helper"
  static let defaultDelayTestURL = URL(string: "https://www.gstatic.com/generate_204")!
  static let retainedLogLimit = 1000
  static let retainedConnectionLimit = 500

  static var bundledCoreRoot: URL {
    Bundle.main.resourceURL?.appendingPathComponent("Core", isDirectory: true)
      ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Core", isDirectory: true)
  }
}

enum AppError: Error, CustomStringConvertible {
  case missingBundledCore
  case noActiveProfile
  case invalidSubscriptionResponse
  case invalidProfileConfig(String)
  case configValidationFailed(String)
  case coreNotReady(String)
  case helperResponse(String)

  var description: String {
    switch self {
    case .missingBundledCore:
      return "No Mihomo core binary was found in the app bundle. Install a pinned core into Resources/Core."
    case .noActiveProfile:
      return "No active profile is selected."
    case .invalidSubscriptionResponse:
      return "The subscription did not return a readable profile response."
    case let .invalidProfileConfig(message):
      return "Invalid profile config: \(message)"
    case let .configValidationFailed(message):
      return "Mihomo config validation failed: \(message)"
    case let .coreNotReady(message):
      return "Mihomo controller did not become ready: \(message)"
    case let .helperResponse(message):
      return message
    }
  }
}
