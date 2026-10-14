import Foundation
import ServiceManagement

/// Launch at login through `SMAppService.mainApp`.
///
/// With an ad-hoc signed, locally built app this may fail or need the user's approval in System
/// Settings > General > Login Items (SPEC risk R7). Every call can fail; callers show the message and
/// leave the checkbox reflecting the real state instead of crashing.
enum LoginItem {
    enum State: Equatable {
        case enabled
        case disabled
        /// Registered, but the user has to switch it on in System Settings.
        case requiresApproval
        /// The system does not know this bundle (for example it runs from a build folder).
        case unavailable
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .notRegistered: return .disabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    /// Registers or unregisters. Throws the underlying error so the UI can explain it.
    static func set(enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Plain-language explanation for a failed attempt.
    static func explain(_ error: Error) -> String {
        let nsError = error as NSError
        var text = "macOS refused to change the login item: \(nsError.localizedDescription)"
        if state == .unavailable {
            text += " FanPilot is probably not running from an app bundle in /Applications."
        } else if state == .requiresApproval {
            text += " Switch FanPilot on in System Settings > General > Login Items."
        }
        return text
    }
}
