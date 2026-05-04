import Foundation

let clashMaxHelperMachServiceName = "io.github.clashmax.ClashMax.Helper"

@objc(ClashMaxHelperXPCProtocol)
protocol ClashMaxHelperXPCProtocol {
  func status(withReply reply: @escaping (NSDictionary) -> Void)
  func startTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSDictionary) -> Void
  )
  func stopTunnel(withReply reply: @escaping (NSDictionary) -> Void)
  func restartTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSDictionary) -> Void
  )
  func recentLogs(withReply reply: @escaping (NSArray) -> Void)
}

enum HelperResponseKey {
  static let ok = "ok"
  static let running = "running"
  static let pid = "pid"
  static let message = "message"
}

struct HelperPathValidator {
  enum ValidationError: Error, CustomStringConvertible {
    case pathEscapesAllowedRoots(String)

    var description: String {
      switch self {
      case let .pathEscapesAllowedRoots(path):
        return "Path is outside ClashMax-managed locations: \(path)"
      }
    }
  }

  let appSupportRoot: URL
  let bundledCoreRoot: URL

  func validate(coreURL: URL, configURL: URL, workDirectory: URL) throws {
    guard isInside(coreURL, root: bundledCoreRoot) || isInside(coreURL, root: appSupportRoot) else {
      throw ValidationError.pathEscapesAllowedRoots(coreURL.path)
    }
    guard isInside(configURL, root: appSupportRoot) else {
      throw ValidationError.pathEscapesAllowedRoots(configURL.path)
    }
    guard isInside(workDirectory, root: appSupportRoot) else {
      throw ValidationError.pathEscapesAllowedRoots(workDirectory.path)
    }
  }

  private func isInside(_ candidate: URL, root: URL) -> Bool {
    let candidatePath = candidate.standardizedFileURL.path
    let rootPath = root.standardizedFileURL.path
    return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
  }
}
