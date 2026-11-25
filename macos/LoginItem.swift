import Foundation
import ServiceManagement

enum LoginItemState {
  case off, on, requiresApproval, unavailable
}

enum LoginItemError: Error {
  case registrationFailed
}

@MainActor
struct LoginItem {
  let status: () -> LoginItemState
  let write: (Bool) throws -> Void

  static let unavailable = LoginItem(
    status: { .unavailable }, write: { _ in throw LoginItemError.registrationFailed })

  func setEnabled(_ enabled: Bool) throws {
    switch (status(), enabled) {
    case (.on, true), (.off, false):
      return
    case (.off, true), (.on, false), (.requiresApproval, false):
      try write(enabled)
    default:
      throw LoginItemError.registrationFailed
    }
  }

  static func system(bundle: Bundle = .main) -> LoginItem {
    guard bundle.bundleURL.pathExtension == "app",
      bundle.bundleIdentifier == "com.suebwj.sue-paper"
    else { return .unavailable }
    let url = bundle.bundleURL as CFURL
    let legacy = LoginItem(
      status: {
        switch matte_login_item_status(url) {
        case 0: .off
        case 1: .on
        default: .unavailable
        }
      },
      write: { enabled in
        guard matte_login_item_set_enabled(url, enabled) else {
          throw LoginItemError.registrationFailed
        }
      })
    guard #available(macOS 13, *) else { return legacy }
    let service = SMAppService.mainApp
    return LoginItem(
      status: {
        switch service.status {
        case .notRegistered: legacy.status() == .on ? .on : .off
        case .enabled: .on
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
      },
      write: { enabled in
        if enabled {
          try service.register()
        } else {
          if service.status != .notRegistered { try service.unregister() }
          // A login item created on macOS 12 can survive an OS upgrade.
          if legacy.status() == .on { try legacy.write(false) }
        }
      })
  }
}
