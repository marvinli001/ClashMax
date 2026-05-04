import Foundation

let clashMaxHelperMachServiceName = "io.github.clashmax.ClashMax.Helper"

@objc(ClashMaxHelperXPCProtocol)
protocol ClashMaxHelperXPCProtocol {
  func status(withReply reply: @escaping (NSString) -> Void)
  func startTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  )
  func stopTunnel(withReply reply: @escaping (NSString) -> Void)
  func restartTunnel(
    corePath: NSString,
    configPath: NSString,
    workDirectoryPath: NSString,
    secret: NSString,
    withReply reply: @escaping (NSString) -> Void
  )
  func recentLogs(withReply reply: @escaping (NSString) -> Void)
}

enum ClashMaxHelperXPCInterface {
  static func make() -> NSXPCInterface {
    let interface = NSXPCInterface(with: ClashMaxHelperXPCProtocol.self)
    let stringClasses = allowedClassSet([NSString.self])
    let replySelectors = [
      #selector(ClashMaxHelperXPCProtocol.status(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.startTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.stopTunnel(withReply:)),
      #selector(ClashMaxHelperXPCProtocol.restartTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.recentLogs(withReply:))
    ]

    for selector in replySelectors {
      interface.setClasses(stringClasses, for: selector, argumentIndex: 0, ofReply: true)
    }

    let tunnelRequestSelectors = [
      #selector(ClashMaxHelperXPCProtocol.startTunnel(corePath:configPath:workDirectoryPath:secret:withReply:)),
      #selector(ClashMaxHelperXPCProtocol.restartTunnel(corePath:configPath:workDirectoryPath:secret:withReply:))
    ]
    for selector in tunnelRequestSelectors {
      for argumentIndex in 0..<4 {
        interface.setClasses(stringClasses, for: selector, argumentIndex: argumentIndex, ofReply: false)
      }
    }
    return interface
  }

  private static func allowedClassSet(_ classes: [AnyClass]) -> Set<AnyHashable> {
    NSSet(array: classes) as! Set<AnyHashable>
  }
}

enum HelperResponseKey {
  static let ok = "ok"
  static let running = "running"
  static let pid = "pid"
  static let message = "message"
}

enum HelperXPCPayload {
  static func response(ok: Bool, running: Bool = false, pid: Int = 0, message: String = "") -> NSString {
    jsonString([
      HelperResponseKey.ok: ok,
      HelperResponseKey.running: running,
      HelperResponseKey.pid: pid,
      HelperResponseKey.message: message
    ]) as NSString
  }

  static func responseDictionary(from payload: NSString) -> [String: Any] {
    guard let data = (payload as String).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return [:]
    }
    return object
  }

  static func logs(_ lines: [String]) -> NSString {
    jsonString(lines) as NSString
  }

  static func logLines(from payload: NSString) -> [String] {
    guard let data = (payload as String).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String]
    else {
      return []
    }
    return object
  }

  private static func jsonString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []),
          let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
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
