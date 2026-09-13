import Foundation

/// The operating mode of the charge limiter.
public enum LimiterMode: String, Codable {
    /// In Alert Mode, BatteryGuard informs the user via local notifications to unplug when the limit is reached.
    case alertMode = "Alert Mode"
}

/// Evaluates battery state against user-defined charge limits and manages notification alerts.
public final class ChargeLimiter {
    
    // MARK: - Properties
    
    /// The user-configured charge limit percentage (e.g. 80%). Clamped between 50 and 100.
    public var chargeLimit: Int {
        didSet {
            let clamped = max(50, min(chargeLimit, 100))
            if chargeLimit != clamped {
                chargeLimit = clamped
            }
            // If user raised limit above current charge, reset alert state
            if let last = lastNotifiedPercentage, last < chargeLimit {
                isAlertActive = false
            }
        }
    }
    
    /// Always `.alertMode` in this phase to maintain honesty and transparency.
    public let mode: LimiterMode = .alertMode
    
    /// Whether an alert notification has already been triggered for the current session above the limit.
    public private(set) var isAlertActive: Bool = false
    
    /// The battery percentage recorded when the notification was last triggered.
    public private(set) var lastNotifiedPercentage: Int? = nil
    
    /// Delegate/notifier responsible for dispatching the actual user-facing notification.
    public weak var notifier: ChargeLimitNotifierProtocol?
    
    // MARK: - Initialization
    
    public init(chargeLimit: Int = 80, notifier: ChargeLimitNotifierProtocol? = nil) {
        self.chargeLimit = max(50, min(chargeLimit, 100))
        self.notifier = notifier
    }
    
    // MARK: - Evaluation Logic
    
    /// Evaluates the latest telemetry snapshot against the charge limit.
    ///
    /// - If AC is disconnected: clears the active alert state.
    /// - If AC is connected and charge >= limit: triggers a notification once per session.
    /// - If battery drops below (limit - 2%): resets the alert state via hysteresis.
    public func evaluate(snapshot: BatterySnapshot) {
        guard snapshot.isACPowerConnected else {
            // Reset when cable is disconnected
            if isAlertActive {
                print("[ChargeLimiter] AC disconnected. Resetting alert state.")
                isAlertActive = false
                lastNotifiedPercentage = nil
            }
            return
        }
        
        let percent = snapshot.currentChargePercentage
        
        if percent >= chargeLimit {
            if !isAlertActive {
                print("[ChargeLimiter] Charge limit (\(chargeLimit)%) reached at \(percent)%. Triggering alert.")
                isAlertActive = true
                lastNotifiedPercentage = percent
                notifier?.sendLimitReachedNotification(percentage: percent, limit: chargeLimit)
            }
        } else if isAlertActive && percent <= (chargeLimit - 2) {
            // Hysteresis reset: dropped at least 2% below limit while plugged in
            print("[ChargeLimiter] Battery dropped to \(percent)% (<= \(chargeLimit - 2)%). Resetting alert via hysteresis.")
            isAlertActive = false
            lastNotifiedPercentage = nil
        }
    }
}
