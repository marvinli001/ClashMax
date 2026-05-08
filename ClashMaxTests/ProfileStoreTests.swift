import Foundation
import Combine
import XCTest
@testable import ClashMax

@MainActor
final class ProfileStoreTests: XCTestCase {
  func testImportRenameDeleteAndPersistActiveProfile() throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())

    let profile = try store.importLocalConfig(from: fixture.configURL)
    try store.rename(profile, to: "Work")

    let renamed = try XCTUnwrap(store.profiles.first)
    XCTAssertEqual(renamed.name, "Work")
    XCTAssertEqual(store.activeProfileID, profile.id)

    let reloaded = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    XCTAssertEqual(reloaded.profiles.first?.name, "Work")
    XCTAssertEqual(reloaded.activeProfileID, profile.id)

    try store.delete(renamed)
    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.originalConfigPath))
  }

  func testSelectingAlreadyActiveProfileDoesNotPublishChanges() throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let profile = try store.importLocalConfig(from: fixture.configURL)
    var changeCount = 0
    let cancellable = store.objectWillChange.sink { changeCount += 1 }
    defer { cancellable.cancel() }

    try store.select(profile)

    XCTAssertEqual(changeCount, 0)
  }

  func testSubscriptionURLIsStoredOutsideManifestAndUpdateRefreshesConfig() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let recorder = URLProtocolRecorder(
      responseBody: "mixed-port: 9000\nproxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: [
        "subscription-userinfo": "upload=1; download=2; total=3; expire=1893456000",
        "profile-update-interval": "6",
        "profile-web-page-url": "https://example.com/dashboard"
      ]
    )
    let session = URLSession(configuration: recorder.configuration)

    let profile = try await store.addSubscription(
      name: "",
      url: URL(string: "https://example.com/sub.yaml")!,
      session: session
    )

    XCTAssertEqual(recorder.lastRequest?.value(forHTTPHeaderField: "User-Agent"), "clash.meta")
    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/sub.yaml")
    XCTAssertEqual(profile.subscriptionMetadata?.traffic?.download, 2)
    XCTAssertEqual(profile.subscriptionMetadata?.updateIntervalMinutes, 360)
    XCTAssertEqual(profile.subscriptionMetadata?.webPageURL, URL(string: "https://example.com/dashboard"))
    let manifest = try String(contentsOf: fixture.paths.manifestURL, encoding: .utf8)
    XCTAssertFalse(manifest.contains("https://example.com/sub.yaml"))

    let updateRecorder = URLProtocolRecorder(
      responseBody: "mixed-port: 9001\nproxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["subscription-userinfo": "upload=4; download=5; total=6"]
    )
    let updateSession = URLSession(configuration: updateRecorder.configuration)
    try await store.updateSubscription(profile, session: updateSession)
    XCTAssertEqual(updateRecorder.lastRequest?.value(forHTTPHeaderField: "User-Agent"), "clash.meta")
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), "mixed-port: 9001\nproxies:\n  - name: DIRECT\n    type: direct\n")
    XCTAssertEqual(store.profiles.first?.subscriptionMetadata?.traffic?.download, 5)
  }

  func testSubscriptionNameUsesRemoteNameThenYamlThenHostFallback() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let remoteSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxy-groups:\n  - name: YAML Group\n    type: select\n    proxies: [DIRECT]\nproxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename*=UTF-8''Elite.yaml"]
    ).configuration)

    let remoteProfile = try await store.addSubscription(
      url: URL(string: "https://example.com/sub")!,
      session: remoteSession
    )

    XCTAssertEqual(remoteProfile.name, "Elite")
    XCTAssertFalse(remoteProfile.nameIsUserCustomized)

    let yamlSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxy-groups:\n  - name: YAML Group\n    type: select\n    proxies: [DIRECT]\nproxies:\n  - name: DIRECT\n    type: direct\n"))
    let yamlProfile = try await store.addSubscription(
      url: URL(string: "https://yaml.example/sub")!,
      session: yamlSession
    )

    XCTAssertEqual(yamlProfile.name, "YAML Group")

    let hostSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let hostProfile = try await store.addSubscription(
      url: URL(string: "https://host.example/sub")!,
      session: hostSession
    )

    XCTAssertEqual(hostProfile.name, "host.example")
  }

  func testSubscriptionUpdateDoesNotOverwriteCustomizedName() async throws {
    let fixture = try TemporaryProfileFixture()
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())
    let initialSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename=Remote.yaml"]
    ).configuration)
    let profile = try await store.addSubscription(
      url: URL(string: "https://example.com/sub.yaml")!,
      session: initialSession
    )

    try store.rename(profile, to: "Custom")

    let updateSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename=Updated.yaml"]
    ).configuration)
    try await store.updateSubscription(profile, session: updateSession)

    XCTAssertEqual(store.profiles.first?.name, "Custom")
    XCTAssertEqual(store.profiles.first?.subscriptionMetadata?.remoteFileName, "Updated.yaml")
  }

  func testEditingSubscriptionSourceValidatesBeforeMutatingStoredURLAndConfig() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      url: URL(string: "https://example.com/old")!,
      session: initialSession
    )
    let originalConfig = try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8)

    let invalidSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("rules: []\n"))
    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscriptionSource(
        profile,
        url: URL(string: "https://example.com/bad")!,
        session: invalidSession
      )
    }

    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/old")
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), originalConfig)

    let validSession = URLSession(configuration: URLProtocolRecorder(
      responseBody: "proxies:\n  - name: DIRECT\n    type: direct\n",
      responseHeaders: ["content-disposition": "attachment; filename=New.yaml"]
    ).configuration)
    try await store.updateSubscriptionSource(
      profile,
      url: URL(string: "https://example.com/new")!,
      session: validSession
    )

    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/new")
    XCTAssertEqual(store.profiles.first?.name, "New")
  }

  func testSubscriptionAcceptsBase64URIProviderContentAndStoresRawSource() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let uriSubscription = """
    vless://00000000-0000-0000-0000-000000000000@example.com:443?security=tls&sni=example.com#VLESS%20Node
    hysteria2://password@example.net:8443?sni=example.net&insecure=1#Hysteria2%20Node
    """
    let encodedSubscription = Data(uriSubscription.utf8).base64EncodedString()
    let session = URLSession(configuration: URLProtocolRecorder.configurationReturning(encodedSubscription))

    let profile = try await store.addSubscription(
      name: "Xboard",
      url: URL(string: "https://example.com/api/v1/client/subscribe?token=test")!,
      session: session
    )

    XCTAssertEqual(profile.name, "Xboard")
    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), encodedSubscription)
    XCTAssertEqual(try secrets.load(account: "subscription.\(profile.id.uuidString)"), "https://example.com/api/v1/client/subscribe?token=test")
  }

  func testImportRejectsConfigWithoutProxyDefinitions() throws {
    let fixture = try TemporaryProfileFixture(config: "mixed-port: 7890\nrules: []\n")
    let store = ProfileStore(paths: fixture.paths, keychain: InMemorySecretStore())

    XCTAssertThrowsError(try store.importLocalConfig(from: fixture.configURL)) { error in
      XCTAssertTrue(
        String(describing: error)
          .contains(String(localized: "Profile must include at least one proxy or proxy provider."))
      )
    }

    XCTAssertTrue(store.profiles.isEmpty)
    XCTAssertNil(store.activeProfileID)
  }

  func testSubscriptionUpdateRejectsInvalidConfigAndKeepsExistingProfileConfig() async throws {
    let fixture = try TemporaryProfileFixture(config: "proxies:\n  - name: DIRECT\n    type: direct\n")
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub.yaml")!,
      session: initialSession
    )

    let updateSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("rules: []\n"))
    await XCTAssertThrowsErrorAsync {
      try await store.updateSubscription(profile, session: updateSession)
    }

    XCTAssertEqual(
      try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8),
      "proxies:\n  - name: DIRECT\n    type: direct\n"
    )
  }

  func testSubscriptionUpdateAcceptsURIProviderContent() async throws {
    let fixture = try TemporaryProfileFixture()
    let secrets = InMemorySecretStore()
    let store = ProfileStore(paths: fixture.paths, keychain: secrets)
    let initialSession = URLSession(configuration: URLProtocolRecorder.configurationReturning("proxies:\n  - name: DIRECT\n    type: direct\n"))
    let profile = try await store.addSubscription(
      name: "Remote",
      url: URL(string: "https://example.com/sub")!,
      session: initialSession
    )

    let updatedSubscription = "trojan://password@example.com:443?sni=example.com#Trojan%20Node\n"
    let updateSession = URLSession(configuration: URLProtocolRecorder.configurationReturning(updatedSubscription))
    try await store.updateSubscription(profile, session: updateSession)

    XCTAssertEqual(try String(contentsOfFile: profile.originalConfigPath, encoding: .utf8), updatedSubscription)
  }
}

private struct TemporaryProfileFixture {
  let root: URL
  let paths: RuntimePaths
  let configURL: URL

  init(config: String = "mixed-port: 7890\nproxies:\n  - name: DIRECT\n    type: direct\n") throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ClashMaxTests-\(UUID().uuidString)", isDirectory: true)
    self.root = root
    paths = RuntimePaths(
      appSupport: root,
      profiles: root.appendingPathComponent("Profiles", isDirectory: true),
      runtime: root.appendingPathComponent("Runtime", isDirectory: true),
      subscriptions: root.appendingPathComponent("Subscriptions", isDirectory: true),
      logs: root.appendingPathComponent("Logs", isDirectory: true)
    )
    for directory in [paths.appSupport, paths.profiles, paths.runtime, paths.subscriptions, paths.logs] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    configURL = root.appendingPathComponent("sample.yaml")
    try config.write(to: configURL, atomically: true, encoding: .utf8)
  }
}

final class InMemorySecretStore: SecretStoring {
  private var values: [String: String] = [:]

  func save(_ value: String, account: String) throws {
    values[account] = value
  }

  func load(account: String) throws -> String? {
    values[account]
  }

  func delete(account: String) throws {
    values.removeValue(forKey: account)
  }
}
