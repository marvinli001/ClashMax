import XCTest
@testable import ClashMax

final class TunRuntimeInspectorTests: XCTestCase {
  func testInspectorReportsPassingDataPlaneChecks() async {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: utun1024\n",
      "/usr/sbin/netstat -rn": "Destination Gateway Flags Netif\n10/8 link#1 UCS en0\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n",
      "/usr/bin/curl -sS -o /dev/null -w %{http_code} --max-time 5 https://www.gstatic.com/generate_204": "204",
      "/usr/bin/dig @1.1.1.1 +time=2 +tries=1 +short example.com A": "93.184.216.34\n"
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)
    let snapshot = await inspector.inspect(configuration(routeExcludes: ["10.0.0.0/8"]))

    XCTAssertEqual(snapshot.check(id: "controller")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "helper-pid")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "interface")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "default-route")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "route-exclude")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "system-dns")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "dns-hijack")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "external-tcp")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "external-udp")?.status, .pass)
    XCTAssertEqual(snapshot.overallStatus, .pass)
  }

  func testInspectorWarnsAndFailsWhenDataPlaneEvidenceIsMissing() async {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "en0: flags=8863<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: en0\n",
      "/usr/sbin/netstat -rn": "Destination Gateway Flags Netif\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "142.250.191.68\n",
      "/usr/bin/curl -sS -o /dev/null -w %{http_code} --max-time 5 https://www.gstatic.com/generate_204": "000",
      "/usr/bin/dig @1.1.1.1 +time=2 +tries=1 +short example.com A": ""
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)
    let snapshot = await inspector.inspect(configuration(
      helperPID: nil,
      routeExcludes: ["10.0.0.0/8"],
      systemDNSState: .applyFailed("networksetup failed")
    ))

    XCTAssertEqual(snapshot.check(id: "helper-pid")?.status, .fail)
    XCTAssertEqual(snapshot.check(id: "interface")?.status, .fail)
    XCTAssertEqual(snapshot.check(id: "default-route")?.status, .warn)
    XCTAssertEqual(snapshot.check(id: "route-exclude")?.status, .warn)
    XCTAssertEqual(snapshot.check(id: "system-dns")?.status, .fail)
    XCTAssertEqual(snapshot.check(id: "dns-hijack")?.status, .warn)
    XCTAssertEqual(snapshot.check(id: "external-tcp")?.status, .fail)
    XCTAssertEqual(snapshot.check(id: "external-udp")?.status, .fail)
    XCTAssertEqual(snapshot.overallStatus, .fail)
  }

  func testInspectorSkipsExternalProbesWhenDisabled() async {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: utun1024\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n"
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)
    let snapshot = await inspector.inspect(configuration(includeExternal: false))

    XCTAssertEqual(snapshot.check(id: "external-tcp")?.status, .skipped)
    XCTAssertEqual(snapshot.check(id: "external-udp")?.status, .skipped)
    XCTAssertFalse(runner.commands.contains { $0.contains("https://www.gstatic.com/generate_204") })
    XCTAssertFalse(runner.commands.contains { $0.contains("@1.1.1.1") })
  }

  func testExternalTCPReportsHTTPStatusInsteadOfCommandFailure() async {
    for status in [503, 504] {
      let runner = RecordingCommandRunner(outputs: [
        "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
        "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
        "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: utun1024\n",
        "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n",
        "/usr/bin/curl -sS -o /dev/null -w %{http_code} --max-time 5 https://www.gstatic.com/generate_204": "\(status)",
        "/usr/bin/dig @1.1.1.1 +time=2 +tries=1 +short example.com A": "93.184.216.34\n"
      ])
      let inspector = TunRuntimeInspector(commandRunner: runner)

      let snapshot = await inspector.inspect(configuration(routeExcludes: []))

      XCTAssertEqual(snapshot.check(id: "external-tcp")?.status, .fail)
      XCTAssertEqual(snapshot.check(id: "external-tcp")?.message, "External TCP probe returned HTTP \(status).")
      XCTAssertEqual(snapshot.check(id: "external-udp")?.status, .pass)
      XCTAssertEqual(snapshot.check(id: "controller")?.status, .pass)
      XCTAssertEqual(snapshot.check(id: "default-route")?.status, .pass)
      XCTAssertEqual(snapshot.check(id: "dns-hijack")?.status, .pass)
      XCTAssertTrue(runner.commands.contains("/usr/bin/curl -sS -o /dev/null -w %{http_code} --max-time 5 https://www.gstatic.com/generate_204"))
    }
  }

  func testControllerProbeUsesBearerAuthAndFailsWhenControllerResponseIsMissing() async {
    let runner = RecordingCommandRunner(outputs: [
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: utun1024\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n"
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)

    let snapshot = await inspector.inspect(configuration(includeExternal: false))

    XCTAssertEqual(snapshot.check(id: "controller")?.status, .fail)
    XCTAssertTrue(runner.commands.contains("/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version"))
  }

  func testControllerProbeKeepsTheSecretOutOfItsDisplayDescription() async {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)

    _ = await inspector.inspect(configuration(includeExternal: false))

    XCTAssertTrue(
      runner.displayCommands.contains(
        "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer <redacted> http://127.0.0.1:9097/version"
      ),
      runner.displayCommands.joined(separator: "\n")
    )
    XCTAssertFalse(
      runner.displayCommands.contains { $0.contains("Bearer secret") },
      "the controller probe's display description still carries the API secret"
    )
  }

  func testRouteExcludeOnlyMatchesDestinationColumnAndPrefix() async {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: utun1024\n",
      "/usr/sbin/netstat -rn": """
      Destination        Gateway            Flags        Netif
      default            10.0.0.1           UGScg        utun1024
      192.168.0/24       link#10            UCS          en0
      """,
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n"
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)

    let snapshot = await inspector.inspect(configuration(routeExcludes: ["10.0.0.0/8"], includeExternal: false))

    XCTAssertEqual(snapshot.check(id: "route-exclude")?.status, .warn)
  }

  func testRouteProbeWarnsWhenTrafficUsesADifferentUtunDevice() async {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: utun999\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n"
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)

    let snapshot = await inspector.inspect(configuration(includeExternal: false))

    XCTAssertEqual(snapshot.check(id: "default-route")?.status, .warn)
    XCTAssertEqual(snapshot.check(id: "default-route")?.title, "TUN Route")
    XCTAssertEqual(
      snapshot.check(id: "default-route")?.message,
      "Route to 1.1.1.1 is not using the configured TUN device."
    )
  }

  func testRouteProbeSkipsAddressesCoveredByRouteExcludes() async {
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/usr/sbin/netstat -rn": "Destination Gateway Flags Netif\n0/0 link#1 UCS en0\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n"
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)

    let snapshot = await inspector.inspect(configuration(
      routeExcludes: ["0.0.0.0/0"],
      includeExternal: false
    ))

    XCTAssertEqual(snapshot.check(id: "default-route")?.status, .skipped)
    XCTAssertFalse(runner.commands.contains { $0.hasPrefix("/sbin/route -n get ") })
  }

  func testSystemProxyWarnsWhenMacOSStillPointsAtAPortTheRuntimeDoesNotServe() async {
    let inspector = TunRuntimeInspector(commandRunner: splitRouteRunner(routeInterface: "utun1024"))

    let snapshot = await inspector.inspect(configuration(
      includeExternal: false,
      systemProxyState: .entries([
        LocalSystemProxyEntry(service: "Wi-Fi", kind: "HTTP", host: "127.0.0.1", port: 17_890),
        LocalSystemProxyEntry(service: "Wi-Fi", kind: "HTTPS", host: "127.0.0.1", port: 17_890)
      ]),
      servedLocalProxyPorts: [7890]
    ))

    let check = snapshot.check(id: "system-proxy")
    XCTAssertEqual(check?.status, .warn)
    XCTAssertEqual(check?.title, "System Proxy")
    XCTAssertEqual(
      check?.message,
      "System Proxy still sends apps to 127.0.0.1:17890, which no ClashMax runtime is listening on."
    )
    XCTAssertEqual(check?.detail, "Wi-Fi HTTP → 127.0.0.1:17890, Wi-Fi HTTPS → 127.0.0.1:17890")
    XCTAssertEqual(snapshot.primaryIssue?.id, "system-proxy")
  }

  func testSystemProxyPassesWhenTheEnabledProxyIsTheRunningMixedPort() async {
    let inspector = TunRuntimeInspector(commandRunner: splitRouteRunner(routeInterface: "utun1024"))

    let snapshot = await inspector.inspect(configuration(
      includeExternal: false,
      systemProxyState: .entries([
        LocalSystemProxyEntry(service: "Wi-Fi", kind: "HTTP", host: "127.0.0.1", port: 7890)
      ]),
      servedLocalProxyPorts: [7890]
    ))

    XCTAssertEqual(snapshot.check(id: "system-proxy")?.status, .pass)
    XCTAssertEqual(snapshot.check(id: "system-proxy")?.detail, "Wi-Fi HTTP → 127.0.0.1:7890")
  }

  func testSystemProxyPassesWhenNoLocalProxyIsSet() async {
    let inspector = TunRuntimeInspector(commandRunner: splitRouteRunner(routeInterface: "utun1024"))

    let snapshot = await inspector.inspect(configuration(
      includeExternal: false,
      systemProxyState: .entries([]),
      servedLocalProxyPorts: [7890]
    ))

    XCTAssertEqual(snapshot.check(id: "system-proxy")?.status, .pass)
    XCTAssertEqual(
      snapshot.check(id: "system-proxy")?.message,
      "No local System Proxy is set while TUN handles routing."
    )
  }

  func testSystemProxyStaysOutOfTheFaultCountsWhenTheLiveStateIsUnknown() async {
    let inspector = TunRuntimeInspector(commandRunner: splitRouteRunner(routeInterface: "utun1024"))

    let unsampled = await inspector.inspect(configuration(includeExternal: false))
    XCTAssertEqual(unsampled.check(id: "system-proxy")?.status, .skipped)
    XCTAssertEqual(unsampled.warnCount, 0)

    let unreadable = await inspector.inspect(configuration(
      includeExternal: false,
      systemProxyState: .unavailable("networksetup timed out")
    ))
    XCTAssertEqual(unreadable.check(id: "system-proxy")?.status, .skipped)
    XCTAssertEqual(unreadable.check(id: "system-proxy")?.detail, "networksetup timed out")
    XCTAssertEqual(unreadable.warnCount, 0)
    XCTAssertNil(unreadable.primaryIssue)
  }

  func testRouteWarningDowngradesToInfoWhenLiveProbesStillReachTheNetwork() async {
    // The split-route shape from issue #19: TUN is up and carrying traffic, but the route to a
    // public address still resolves through the physical interface.
    let inspector = TunRuntimeInspector(commandRunner: splitRouteRunner(routeInterface: "en0"))

    let snapshot = await inspector.inspect(configuration())

    let route = snapshot.check(id: "default-route")
    XCTAssertEqual(route?.status, .info)
    XCTAssertEqual(
      route?.message,
      "Route to 1.1.1.1 is not using the configured TUN device. Live TCP and UDP probes still reached the network, so traffic is flowing."
    )
    // The original evidence survives the downgrade — the reader still sees which interface
    // the route landed on.
    XCTAssertEqual(route?.detail, "interface: en0 · external TCP and UDP probes passed")
    XCTAssertNil(snapshot.primaryIssue)
    XCTAssertEqual(snapshot.overallStatus, .pass)
    XCTAssertEqual(snapshot.infoCount, 1)
    XCTAssertTrue(snapshot.summaryLabel.hasSuffix("0 warn / 0 fail / 1 info"), snapshot.summaryLabel)
  }

  func testRouteWarningStaysAWarningWhenALiveProbeFails() async {
    let runner = splitRouteRunner(
      routeInterface: "en0",
      externalUDPOutput: ""
    )
    let inspector = TunRuntimeInspector(commandRunner: runner)

    let snapshot = await inspector.inspect(configuration())

    // Nothing confirmed the data plane, so the route warning keeps its weight and the failing
    // probe is what the user is told about first.
    XCTAssertEqual(snapshot.check(id: "default-route")?.status, .warn)
    XCTAssertEqual(snapshot.infoCount, 0)
    XCTAssertEqual(snapshot.check(id: "external-udp")?.status, .fail)
    XCTAssertEqual(snapshot.primaryIssue?.id, "external-udp")
  }

  func testRouteWarningIsNotDowngradedWhenExternalProbesAreSkipped() async {
    let inspector = TunRuntimeInspector(commandRunner: splitRouteRunner(routeInterface: "en0"))

    let snapshot = await inspector.inspect(configuration(includeExternal: false))

    XCTAssertEqual(snapshot.check(id: "default-route")?.status, .warn)
  }

  /// A runtime whose TUN device is up while the route to a public address resolves through
  /// `routeInterface`. Every other probe reports a healthy runtime.
  private func splitRouteRunner(
    routeInterface: String,
    externalTCPOutput: String = "204",
    externalUDPOutput: String = "93.184.216.34\n"
  ) -> RecordingCommandRunner {
    RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: \(routeInterface)\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n",
      "/usr/bin/curl -sS -o /dev/null -w %{http_code} --max-time 5 https://www.gstatic.com/generate_204": externalTCPOutput,
      "/usr/bin/dig @1.1.1.1 +time=2 +tries=1 +short example.com A": externalUDPOutput
    ])
  }

  private func configuration(
    helperPID: Int? = 123,
    routeExcludes: [String] = [],
    systemDNSState: SystemDNSOverrideState = .applied(serviceCount: 2),
    includeExternal: Bool = true,
    systemProxyState: LocalSystemProxyObservation = .notSampled,
    servedLocalProxyPorts: Set<Int> = []
  ) -> TunRuntimeInspectionConfiguration {
    TunRuntimeInspectionConfiguration(
      api: CoreAPIEndpoint(host: "127.0.0.1", port: 9097, secret: "secret"),
      tunSettings: TunSettings(
        stack: .mixed,
        device: "utun1024",
        autoRoute: true,
        strictRoute: false,
        autoDetectInterface: true,
        dnsHijack: ["any:53"],
        mtu: 1500,
        routeExcludeAddresses: routeExcludes,
        dnsFakeIPEnabled: true,
        fakeIPRange: "198.18.0.1/16",
        systemDNSOverrideEnabled: true,
        systemDNSServers: ["114.114.114.114"]
      ),
      helperPID: helperPID,
      systemDNSState: systemDNSState,
      systemProxyState: systemProxyState,
      servedLocalProxyPorts: servedLocalProxyPorts,
      includeExternal: includeExternal
    )
  }
}
