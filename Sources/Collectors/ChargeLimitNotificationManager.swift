import Foundation
import UserNotifications

/// Protocol allowing charge limit alerts to be tested without invoking live system notifications.
public protocol ChargeLimitNotifierProtocol: AnyObject {
    func requestAuthorization()
    func sendLimitReachedNotification(percentage: Int, limit: Int)
}

/// Dispatches prominent local macOS user notifications when the charge limit is reached.
public final class ChargeLimitNotificationManager: ChargeLimitNotifierProtocol {
    
    public static let shared = ChargeLimitNotificationManager()
    
    private var center: UNUserNotificationCenter? {
        if Bundle.main.bundleIdentifier != nil {
            return UNUserNotificationCenter.current()
        }
        return nil
    }
    private var isAuthorized = false

    public init() {}

    /// Requests notification permissions for alert banners and sound.
    public func requestAuthorization() {
        guard let center = center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error = error {
                print("[ChargeLimitNotificationManager] Notification auth error: \(error.localizedDescription)")
            }
            self?.isAuthorized = granted
            print("[ChargeLimitNotificationManager] Notification permissions granted: \(granted)")
        }
    }
    
    /// Dispatches a prominent notification prompting the user to unplug.
    public func sendLimitReachedNotification(percentage: Int, limit: Int) {
        let content = UNMutableNotificationContent()
        content.title = "⚠️ Charge Limit Reached (\(percentage)%)"
        content.body = "Battery has reached your configured \(limit)% limit. Please unplug your charger now to protect battery health."
        content.sound = UNNotificationSound.default
        content.interruptionLevel = .timeSensitive
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "com.batteryguard.limitReached.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        
        guard let center = center else {
            print("[ChargeLimitNotificationManager] Notification scheduled (CLI/test environment): \(percentage)% reached.")
            return
        }
        center.add(request) { error in
            if let error = error {
                print("[ChargeLimitNotificationManager] Failed to schedule notification: \(error)")
            } else {
                print("[ChargeLimitNotificationManager] Prominent alert posted for \(percentage)% (limit: \(limit)%).")
            }
        }
    }
}
