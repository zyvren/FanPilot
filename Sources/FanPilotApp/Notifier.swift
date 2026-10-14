import AppKit
import FanPilotKit
import Foundation
import UserNotifications

/// Local notifications through the notification center.
///
/// A notification with a given key is not repeated within `repeatInterval` seconds (default:
/// ten minutes). The center only exists for real app bundles; when FanPilot runs as a bare
/// executable (`swift run`) every call is a no-op instead of a crash.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var lastSent: [String: Date] = [:]
    private var delegateInstalled = false

    /// False when the process is not inside an `.app` bundle.
    nonisolated static var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    private var center: UNUserNotificationCenter? {
        guard Self.isAvailable else { return nil }
        let center = UNUserNotificationCenter.current()
        if !delegateInstalled {
            center.delegate = self
            delegateInstalled = true
        }
        return center
    }

    func authorizationStatus() async -> UNAuthorizationStatus? {
        guard let center else { return nil }
        return await center.notificationSettings().authorizationStatus
    }

    /// Asks for permission (the system prompt shows once). Returns whether notifications are allowed.
    func requestAuthorization() async -> Bool {
        guard let center else { return false }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    /// Posts a notification unless the same `key` was posted less than `repeatInterval` seconds ago.
    /// Permission is asked for the first time a notification is actually due, not at launch. Returns
    /// whether the notification was accepted for delivery (it may still be blocked by the user's
    /// notification settings).
    @discardableResult
    func post(key: String, title: String, body: String, repeatInterval: TimeInterval,
              sound: String?, now: Date = Date()) -> Bool {
        guard let center else { return false }
        if let last = lastSent[key], now.timeIntervalSince(last) < repeatInterval { return false }
        lastSent[key] = now

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let sound {
            content.sound = sound.isEmpty ? .default : UNNotificationSound(named: UNNotificationSoundName(sound))
        }
        let request = UNNotificationRequest(identifier: "\(key)-\(Int(now.timeIntervalSince1970))",
                                            content: content, trigger: nil)
        Task { @MainActor [weak self] in
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined, let self {
                _ = await self.requestAuthorization()
                status = await center.notificationSettings().authorizationStatus
            }
            AppModel.shared.notificationsBlocked = (status == .denied)
            guard status == .authorized || status == .provisional else { return }
            try? await center.add(request)
        }
        return true
    }

    func clearHistory() { lastSent.removeAll() }

    // Show banners even while FanPilot is the active app (it usually is when a window is open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Names of the system alert sounds, for the popup in the Notifications pane.
    static func systemSoundNames() -> [String] {
        let folder = URL(fileURLWithPath: "/System/Library/Sounds")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }
}
