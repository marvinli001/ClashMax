import Foundation

struct ExternalControlHealthChecker: Sendable {
  private let session: URLSession
  private let timeout: TimeInterval

  init(session: URLSession = .shared, timeout: TimeInterval = 2.5) {
    self.session = session
    self.timeout = timeout
  }

  func checkController(settings: ExternalControllerSettings) async -> ExternalControlHealthResult {
    guard settings.enabled else {
      return ExternalControlHealthResult(
        status: .failed,
        message: String(localized: "External controller is disabled."),
        checkedAt: Date()
      )
    }
    do {
      let baseURL = try CoreAPIEndpoint(
        host: settings.normalizedHost,
        port: settings.normalizedPort,
        secret: settings.normalizedSecret
      ).baseURL
      let url = baseURL.appendingPathComponent("version")
      var request = URLRequest(url: url)
      request.httpMethod = "GET"
      request.timeoutInterval = timeout
      request.setValue("Bearer \(settings.normalizedSecret)", forHTTPHeaderField: "Authorization")
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return ExternalControlHealthResult(
          status: .failed,
          message: String(localized: "Controller returned an invalid response."),
          checkedAt: Date()
        )
      }
      let healthy = (200..<300).contains(http.statusCode)
      return ExternalControlHealthResult(
        status: healthy ? .healthy : .failed,
        message: healthy
          ? String(localized: "Controller is reachable.")
          : String(localized: "Controller health check failed."),
        checkedAt: Date(),
        httpStatus: http.statusCode
      )
    } catch {
      return ExternalControlHealthResult(
        status: .failed,
        message: UserFacingError.message(for: error),
        checkedAt: Date()
      )
    }
  }

  func checkDashboard(baseURL: URL) async -> ExternalControlHealthResult {
    let url = Self.dashboardHealthURL(from: baseURL)
    let head = await checkDashboard(url: url, method: "HEAD")
    if head.httpStatus == 405 || head.httpStatus == 501 {
      return await checkDashboard(url: url, method: "GET")
    }
    return head
  }

  static func dashboardHealthURL(from baseURL: URL) -> URL {
    guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
      return baseURL
    }
    components.queryItems = components.queryItems?.filter { item in
      !["hostname", "port", "secret"].contains { $0.caseInsensitiveCompare(item.name) == .orderedSame }
    }
    if components.queryItems?.isEmpty == true {
      components.queryItems = nil
    }
    return components.url ?? baseURL
  }

  private func checkDashboard(url: URL, method: String) async -> ExternalControlHealthResult {
    do {
      var request = URLRequest(url: url)
      request.httpMethod = method
      request.timeoutInterval = timeout
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return ExternalControlHealthResult(
          status: .failed,
          message: String(localized: "Dashboard returned an invalid response."),
          checkedAt: Date()
        )
      }
      let healthy = (200..<400).contains(http.statusCode)
      return ExternalControlHealthResult(
        status: healthy ? .healthy : .failed,
        message: healthy
          ? String(localized: "Dashboard is reachable.")
          : String(localized: "Dashboard health check failed."),
        checkedAt: Date(),
        httpStatus: http.statusCode
      )
    } catch {
      return ExternalControlHealthResult(
        status: .failed,
        message: UserFacingError.message(for: error),
        checkedAt: Date()
      )
    }
  }
}
