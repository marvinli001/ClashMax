@testable import ClashMax
import Foundation
import Testing
import Yams

struct NEProcessRoutingTests {
  private static let overrides = RuntimeOverrides.defaultForLaunch(secret: "fixture")
  private static let source = #"""
  proxies: [{name: Node, type: direct}]
  listeners: [{name: clashmax-ne-1, type: socks, listen: 127.0.0.1, port: 13333}]
  sub-rules:
    apps: ['PROCESS-NAME,Helper,DIRECT']
  rules:
    - 'AND,((NETWORK,TCP),(NOT,((PROCESS-NAME,Helper)))),Node'
    - 'PROCESS-PATH-REGEX,^/Applications/Example\.app/,Node'
    - 'SUB-RULE,(NETWORK,UDP),apps'
    - 'PROCESS-NAME,Helper,DIRECT'
    - 'MATCH,DIRECT'
  """#

  @Test func mergedRuleSnapshotAndCorePreflight() async throws {
    let options = RuntimeConfigOptions(networkExtensionRoutingSettings: .default, blocksInheritedExposedListeners: true)
    let result = try ConfigNormalizer().generateRuntimeConfig(from: Self.source, overrides: Self.overrides, options: options)
    let root = try #require(try Yams.load(yaml: result.yaml) as? [String: Any])
    #expect(root["rules"] as? [String] == [
      "AND,((NETWORK,TCP),(NOT,((OR,((PROCESS-NAME,Helper),(IN-NAME,clashmax-ne-2)))))),Node",
      #"OR,((PROCESS-PATH-REGEX,^/Applications/Example\.app/),(IN-NAME,clashmax-ne-3)),Node"#,
      "SUB-RULE,(NETWORK,UDP),apps",
      "OR,((PROCESS-NAME,Helper),(IN-NAME,clashmax-ne-2)),DIRECT", "MATCH,DIRECT",
    ])
    #expect((root["sub-rules"] as? [String: [String]])?["apps"]?.first == "OR,((PROCESS-NAME,Helper),(IN-NAME,clashmax-ne-2)),DIRECT")
    let routes = result.processRoutePlan.routes
    #expect(routes.count == 2 && Set(routes.map(\.port)).count == 2)
    #expect(routes.map(\.conditional) == [true, false])
    #expect(routes.last?.attributedApp == "Example")
    let listeners = try #require(root["listeners"] as? [[String: Any]])
    #expect(listeners.suffix(2).allSatisfy { $0["listen"] as? String == "127.0.0.1" && $0["udp"] as? Bool == true })
    #expect(ListenerRuntimeFacts.facts(from: root).exposedListeners.isEmpty)
    let audit = SubscriptionAuditBuilder.build(sourceYAML: Self.source, runtimeYAML: result.yaml, listenerPolicy: nil, trigger: .imported, generatedAt: Date())
    #expect(!audit.needsListenerDecision)
    let config = NetworkExtensionRuntimeConfiguration.clashMax(overrides: Self.overrides, processRoutes: routes)
    let shipped = try #require(config.providerConfiguration["processRoutes"])
    #expect(try JSONDecoder().decode([NEProcessRoute].self, from: JSONSerialization.data(withJSONObject: shipped)) == routes)
    var reload = options
    reload.existingNEProcessRoutes = routes
    let repeated = try ConfigNormalizer().generateRuntimeConfig(from: Self.source, overrides: Self.overrides, options: reload)
    #expect(repeated.processRoutePlan == result.processRoutePlan)

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("runtime.yaml")
    try result.yaml.write(to: url, atomically: true, encoding: .utf8)
    let core = try #require(try BundledCoreRequirement.coreURL())
    try await MihomoRuntimeConfigValidator().validate(coreURL: core, configURL: url, workDirectory: directory)
  }

  @Test func limitModeAndNoMatches() throws {
    let base = "proxies: [{name: Node, type: direct}]\nrules:\n"
    let many = (0..<65).map { "  - PROCESS-NAME,App\($0),Node" }.joined(separator: "\n")
    let options = RuntimeConfigOptions(networkExtensionRoutingSettings: .default)
    let result = try ConfigNormalizer().generateRuntimeConfig(from: base + many, overrides: Self.overrides, options: options)
    #expect(result.processRoutePlan.routes.count == 64 && result.processRoutePlan.overLimit == 1)
    #expect(result.yaml.contains("PROCESS-NAME,App64,Node"))
    #expect(!result.yaml.contains("clashmax-ne-65"))
    for (source, options) in [(base + "  - MATCH,DIRECT", options), (base + many, .default)] {
      let result = try ConfigNormalizer().generateRuntimeConfig(from: source, overrides: Self.overrides, options: options)
      #expect(result.processRoutePlan.routes.isEmpty && !result.yaml.contains("listeners:"))
    }
  }

  @Test func matchingOrderingAndUnavailableIdentity() throws {
    let first = NEProcessRoute(predicate: .init(kind: .nameRegex, value: "(?<=H)ELP"), inbound: "first", port: 50001, conditional: true)
    let second = NEProcessRoute(predicate: .init(kind: .pathRegex, value: #"^/Applications/Example\.app/"#), inbound: "second", port: 50002, conditional: false)
    let path = "/Applications/Example.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
    let matcher = try NEProcessMatcher(routes: [first, second])
    #expect(matcher.select(path: path, signingIdentifier: "") == .init(route: first, uncertain: true))
    #expect(try NEProcessMatcher(routes: [second, first]).select(path: path, signingIdentifier: "") == .init(route: second))
    #expect(matcher.select(path: nil, signingIdentifier: "org.example.Tool").route == nil)
    #expect(matcher.select(path: nil, signingIdentifier: "org.example.Helper").route == first)
    var sensitive = first
    sensitive.predicate.value = "(?-i)ELP"
    #expect(try NEProcessMatcher(routes: [sensitive]).select(path: path, signingIdentifier: "").route == nil)
    var byName = first
    byName.predicate = .init(kind: .name, value: "HELPER")
    #expect(try NEProcessMatcher(routes: [byName]).select(path: path, signingIdentifier: "").route == byName)
  }

  @Test func regexp2CaseAndUnsupportedExpressions() throws {
    func matches(_ pattern: String, _ name: String) throws -> Bool {
      let route = NEProcessRoute(predicate: .init(kind: .nameRegex, value: pattern), inbound: "test", port: 50001, conditional: false)
      return try NEProcessMatcher(routes: [route]).select(path: "/" + name, signingIdentifier: "").route != nil
    }
    #expect(try !matches("^strasse$", "Straße"))
    #expect(try matches("^straße$", "Straße"))
    #expect(try matches("^i$", "İ"))
    #expect(try !matches("^S$", "ſ"))
    var root: [String: Any] = ["rules": ["PROCESS-NAME-REGEX,(?(?=H)Hel|xyz),DIRECT", "PROCESS-NAME,Helper,DIRECT"]]
    var rewriter = NEProcessRuleRewriter()
    let plan = try rewriter.apply(to: &root, reservedPorts: [])
    #expect(plan.unsupported == 1 && plan.routes.count == 1)
    #expect((root["rules"] as? [String])?.first == "PROCESS-NAME-REGEX,(?(?=H)Hel|xyz),DIRECT")
    #expect(plan.omissionSummary(appliedAt: Date()) != nil)
  }

  @Test @MainActor func closedConnectionKeepsItsOriginalAttribution() throws {
    let route = NEProcessRoute(predicate: .init(kind: .name, value: "Helper"), inbound: "clashmax-ne-1", port: 53001, conditional: false)
    let store = RuntimeDataStore()
    store.setProcessRoutePlan(.init(routes: [route]))
    let row = ConnectionSnapshot(id: "one", network: "udp", host: "", inboundPort: route.port, inboundName: route.inbound, upload: 0, download: 0, chain: [], rule: nil)
    store.replaceConnections([row])
    store.replaceConnections([])
    store.setProcessRoutePlan(.init())
    let history = try #require(store.connectionRecords.first?.snapshot)
    #expect(history.neAttributedAt != nil && history.neAttributedApp == "Helper")
  }
}
