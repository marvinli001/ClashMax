import Foundation

struct RuntimePaths: Sendable {
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
  static let appcastURL = URL(string: "https://marvinli001.github.io/ClashMax/appcast.xml")!
  static let sparklePublicEDKeyPlaceholder = "REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY"
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
  case coreStopFailed(String)
  case portUnavailable(String)
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
      return "Mihomo controller did not become ready. \(message)"
    case let .coreStopFailed(message):
      return message
    case let .portUnavailable(message):
      return message
    case let .helperResponse(message):
      return message
    }
  }
}

extension AppError: LocalizedError {
  var errorDescription: String? {
    description
  }
}

enum UserFacingError {
  private static let helperCodeSigningRecovery = "TUN helper could not be registered because ClashMax or its helper is not correctly signed, notarized, or approved by macOS. Verify signing, approve the helper in System Settings, then retry."
  private static let helperOperationNotPermittedRecovery = "macOS did not permit TUN helper registration yet. Approve ClashMax in System Settings > General > Login Items & Extensions, then click Status. If this exported/notarized app is already approved and the helper still will not start, restart macOS or reset the Background Items approval state before retrying."
  private static let networkExtensionAppRegistrationRecovery = "macOS has not registered /Applications/ClashMax.app for this Network Extension configuration yet. ClashMax refreshes LaunchServices before starting NE mode; retry once, and restart macOS if the stale system extension state still reports the VPN app is not installed."

  static func message(for error: Error) -> String {
    if let appError = error as? AppError {
      return message(from: appError.description)
    }

    let nsError = error as NSError
    let localized = nsError.localizedDescription
    let described = String(describing: error)
    if let helperMessage = helperRegistrationMessage(domain: nsError.domain, code: nsError.code, message: "\(localized) \(described)") {
      return helperMessage
    }

    if let networkMessage = networkMessage(for: nsError) {
      return networkMessage
    }

    if localized.contains("The operation couldn") && !described.isEmpty {
      return message(from: described)
    }
    return message(from: localized)
  }

  static func message(from rawMessage: String) -> String {
    if let helperMessage = helperRegistrationMessage(domain: nil, code: nil, message: rawMessage) {
      return helperMessage
    }
    if networkExtensionAppRegistrationMessage(rawMessage) {
      return networkExtensionAppRegistrationRecovery
    }

    if rawMessage.contains("NSURLErrorDomain") || rawMessage.contains("Could not connect to the server") {
      return "Could not connect to the Mihomo controller at 127.0.0.1:9097. The core may still be starting or failed to open its controller port."
    }

    let trimmed = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > 220 else { return trimmed }
    return "\(trimmed.prefix(217))..."
  }

  private static func helperRegistrationMessage(domain: String?, code: Int?, message: String) -> String? {
    if domain == "SMAppServiceErrorDomain" && code == 1 {
      return helperOperationNotPermittedRecovery
    }
    let helperRegistrationFailed = domain == "SMAppServiceErrorDomain" && code == 3
    if helperRegistrationFailed
      || message.localizedCaseInsensitiveContains("Codesigning failure")
      || message.contains("-67056") {
      return helperCodeSigningRecovery
    }
    return nil
  }

  private static func networkExtensionAppRegistrationMessage(_ message: String) -> Bool {
    message.localizedCaseInsensitiveContains("The VPN app used by the VPN configuration is not installed")
      || message.contains("VPN配置所使用的VPN App尚未安装")
  }

  private static func networkMessage(for error: NSError) -> String? {
    guard error.domain == NSURLErrorDomain else { return nil }

    switch error.code {
    case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet:
      return "Could not connect to the Mihomo controller at \(controllerAddress(from: error)). The core may still be starting or failed to open its controller port."
    default:
      return nil
    }
  }

  private static func controllerAddress(from error: NSError) -> String {
    let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL
    guard let url, let host = url.host else {
      return "127.0.0.1:9097"
    }

    if let port = url.port {
      return "\(host):\(port)"
    }
    return host
  }
}
