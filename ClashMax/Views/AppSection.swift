import Foundation

enum AppSection: String, CaseIterable, Identifiable {
  case home
  case profiles
  case proxies
  case connections
  case rules
  case logs
  case settings

  var id: String { rawValue }

  var title: String {
    rawValue.capitalized
  }

  var symbolName: String {
    switch self {
    case .home: "gauge.with.dots.needle.67percent"
    case .profiles: "doc.text"
    case .proxies: "point.3.connected.trianglepath.dotted"
    case .connections: "network"
    case .rules: "list.bullet.rectangle"
    case .logs: "terminal"
    case .settings: "gearshape"
    }
  }
}
