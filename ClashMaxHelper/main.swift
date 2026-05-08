import Foundation

let service = HelperService()
let delegate = HelperListenerDelegate(service: service)
let listener = NSXPCListener(machServiceName: clashMaxHelperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()

final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
  let service: HelperService
  private let connectionAuthorizer: any HelperConnectionAuthorizing

  init(
    service: HelperService,
    connectionAuthorizer: any HelperConnectionAuthorizing = CodeSignatureConnectionAuthorizer()
  ) {
    self.service = service
    self.connectionAuthorizer = connectionAuthorizer
  }

  func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
    guard connectionAuthorizer.isAuthorized(newConnection) else {
      return false
    }

    newConnection.exportedInterface = ClashMaxHelperXPCInterface.make()
    newConnection.exportedObject = service
    newConnection.resume()
    return true
  }
}

protocol HelperConnectionAuthorizing {
  func isAuthorized(_ connection: NSXPCConnection) -> Bool
}

final class CodeSignatureConnectionAuthorizer: HelperConnectionAuthorizing {
  private let policy: HelperCodeSignaturePolicy

  init(policy: HelperCodeSignaturePolicy = .live()) {
    self.policy = policy
  }

  func isAuthorized(_ connection: NSXPCConnection) -> Bool {
    do {
      let requirement = policy.clientCodeSigningRequirement
      if let requirement {
        connection.setCodeSigningRequirement(requirement)
      }

      let info = try HelperCodeSignatureReader.info(
        forProcessIdentifier: connection.processIdentifier,
        requirementString: requirement
      )
      guard policy.allowsClient(info) else {
        throw HelperCodeSignatureError.untrustedClientSignature(info.bundleIdentifier ?? "<unsigned>")
      }
      return true
    } catch {
      return false
    }
  }
}
