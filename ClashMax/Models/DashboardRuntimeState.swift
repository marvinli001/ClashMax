import Foundation

enum DashboardRuntimeState: Equatable {
  case blocked(reason: String)
  case stopped
  case starting
  case running
  case crashed(message: String)

  static func resolve(
    startInFlight: Bool,
    tunnelCoreRunning: Bool,
    coreStatus: CoreStatus,
    readinessIssue: String?
  ) -> DashboardRuntimeState {
    if startInFlight {
      return .starting
    }

    switch coreStatus {
    case .starting, .restarting:
      return .starting
    default:
      break
    }

    switch coreStatus {
    case let .crashed(message):
      return .crashed(message: message)
    case .running:
      return .running
    default:
      break
    }

    if tunnelCoreRunning {
      return .running
    }

    if let readinessIssue {
      return .blocked(reason: readinessIssue)
    }

    return .stopped
  }

  var isStarting: Bool {
    if case .starting = self { return true }
    return false
  }

  var isRunning: Bool {
    if case .running = self { return true }
    return false
  }

  var isVisualActive: Bool {
    isStarting || isRunning
  }

  var usesOperationalLayout: Bool {
    isStarting || isRunning
  }

  var displayTitle: String {
    switch self {
    case .blocked:
      return "Ready Needs Setup"
    case .stopped:
      return "Ready"
    case .starting:
      return "Starting"
    case .running:
      return "Running"
    case .crashed:
      return "Crashed"
    }
  }

  var launchTitle: String {
    switch self {
    case .blocked:
      return "ClashMax Needs Setup"
    case .crashed:
      return "Core Needs Attention"
    default:
      return "Ready"
    }
  }

  var detailMessage: String? {
    switch self {
    case let .blocked(reason):
      return reason
    case let .crashed(message):
      return message
    default:
      return nil
    }
  }
}
