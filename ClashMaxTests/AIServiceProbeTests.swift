@testable import ClashMax
import Foundation
import Testing

struct AIServiceProbeTests {
  @Test func anonymousHTTPResponses() {
    // Minimal response fragments recorded from anonymous GETs, 2026-11-20.
    #expect(AIProbeClassifier.content(service: .openAI, api: true, status: 401,
                                      body: #"{"error":{"message":"Missing bearer authentication in header","type":"invalid_request_error"}}"#) == .normal)
    #expect(AIProbeClassifier.content(service: .anthropic, api: true, status: 401,
                                      body: #"{"error":{"type":"authentication_error","message":"x-api-key header is required"}}"#) == .normal)
    #expect(AIProbeClassifier.content(service: .anthropic, api: false, status: 403, body: "<title>Just a moment...</title>", challenge: true) == .serviceDenied)
    #expect(AIProbeClassifier.content(service: .gemini, api: true, status: 403,
                                      body: #"{"error":{"code":403,"message":"Permission denied on the service.","status":"PERMISSION_DENIED"}}"#) == .serviceDenied)
    #expect(AIProbeClassifier.content(service: .gemini, api: true, status: 200,
                                      body: #"{"kind":"discovery#restDescription","name":"generativelanguage"}"#) == .normal)
    #expect(AIProbeClassifier.content(service: .openAI, api: true, status: 403, body: #"{"error":{"code":"unsupported_country_region_territory"}}"#) == .region)
    #expect(AIProbeClassifier.content(service: .gemini, api: false, status: 200, body: "unknown captive portal") == .unavailable)
  }

  @Test func routeTransportAndRegion() {
    let start = Date()
    var connection = ConnectionSnapshot(id: "1", network: "tcp", host: "chatgpt.com", sourcePort: 50000, inboundPort: 7890,
                                        upload: 0, download: 0, chain: ["DIRECT", "Group"], rule: "Domain", startedAt: start)
    #expect(AIProbeClassifier.verdict(content: .normal, connection: connection, regionSupported: true) == .direct)
    #expect(AIProbeClassifier.content(service: .openAI, api: false, status: nil, body: "", error: .cannotConnectToHost) == .unreachable)
    #expect(AIProbeClassifier.content(service: .openAI, api: false, status: nil, body: "", error: .serverCertificateUntrusted) == .tls)
    #expect(AIService.traceRegion("h=chatgpt.com\nip=192.0.2.1\nloc=NZ\n", host: "chatgpt.com") == "NZ")
    #expect(AIService.traceRegion("loc=NZ", host: "chatgpt.com") == nil)
    #expect(AIService.openAI.supports(region: "NZ") == true && AIService.openAI.supports(region: "CN") == false)
    let window = start...start.addingTimeInterval(1)
    let first = connection
    connection.id = "other"
    connection.sourcePort = 50001
    let candidates = [first, connection]
    #expect(AIServiceProbe.connection(for: "chatgpt.com", port: 7890, window: window, localPort: nil, candidates: candidates) == nil)
    #expect(AIServiceProbe.connection(for: "chatgpt.com", port: 7890, window: window, localPort: 50000, candidates: candidates) == first)
    #expect(AIServiceProbe.connection(for: "chatgpt.com", port: 7890, window: Date.distantPast...Date.distantPast, localPort: 50000, candidates: candidates) == nil)
  }
}
