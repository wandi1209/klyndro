import Foundation
import UserNotifications

/// Handles posting native macOS notifications forwarded from the Android peer.
///
/// Deduplicates notifications on their composite key `<package>:<id>:<postTime>`
/// for at least 5 minutes to avoid duplicates on reconnect (protocol §5.3).
public actor NotificationCenterForwarder {
    public static let shared = NotificationCenterForwarder()

    private var recentKeys: [String: Date] = [:]
    private let deduplicationWindow: TimeInterval

    public init(deduplicationWindow: TimeInterval = 300) {
        self.deduplicationWindow = deduplicationWindow
    }

    /// Requests user authorization for posting local notifications.
    public func requestAuthorization() async -> Bool {
        do {
            let center = UNUserNotificationCenter.current()
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// Posts a forwarded notification if it is not a recent duplicate.
    public func post(_ notification: NotificationPostBody) async {
        pruneExpiredKeys()

        if let seenAt = recentKeys[notification.key],
           Date().timeIntervalSince(seenAt) < deduplicationWindow {
            // Suppress duplicate notification
            return
        }

        recentKeys[notification.key] = Date()

        let content = UNMutableNotificationContent()
        content.title = notification.appName.isEmpty ? notification.title : "\(notification.appName): \(notification.title)"
        content.body = notification.text
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: notification.key,
            content: content,
            trigger: nil // Deliver immediately
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            NSLog("[Klyndro] Failed to post user notification: %@", error.localizedDescription)
        }
    }

    private func pruneExpiredKeys() {
        let now = Date()
        recentKeys = recentKeys.filter { now.timeIntervalSince($0.value) < deduplicationWindow }
    }
}
