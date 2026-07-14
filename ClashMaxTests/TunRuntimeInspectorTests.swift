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
    let runner = RecordingCommandRunner(outputs: [
      "/usr/bin/curl -fsS --max-time 2 -H Authorization: Bearer secret http://127.0.0.1:9097/version": #"{"version":"v1.19.24"}"#,
      "/sbin/ifconfig": "utun1024: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1500\n",
      "/sbin/route -n get 1.1.1.1": "route to: 1.1.1.1\ninterface: utun1024\n",
      "/usr/bin/dig +time=2 +tries=1 +short www.gstatic.com A": "198.18.0.42\n",
      "/usr/bin/curl -sS -o /dev/null -w %{http_code} --max-time 5 https://www.gstatic.com/generate_204": "503",
      "/usr/bin/dig @1.1.1.1 +time=2 +tries=1 +short example.com A": "93.184.216.34\n"
    ])
    let inspector = TunRuntimeInspector(commandRunner: runner)

    let snapshot = await inspector.inspect(configuration(routeExcludes: []))

    XCTAssertEqual(snapshot.check(id: "external-tcp")?.status, .fail)
    XCTAssertEqual(snapshot.check(id: "external-tcp")?.message, "External TCP probe returned HTTP 503.")
    XCTAssertTrue(runner.commands.contains("/usr/bin/curl -sS -o /dev/null -w %{http_code} --max-time 5 https://www.gstatic.com/generate_204"))
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

  private func configuration(
    helperPID: Int? = 123,
    routeExcludes: [String] = [],
    systemDNSState: SystemDNSOverrideState = .applied(serviceCount: 2),
    includeExternal: Bool = true
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
      includeExternal: includeExternal
    )
  }
}
