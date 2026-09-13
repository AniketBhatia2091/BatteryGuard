import Foundation

final class MockChargeLimitNotifier: ChargeLimitNotifierProtocol {
    var authRequested = false
    var notificationsSent: [(percentage: Int, limit: Int)] = []

    func requestAuthorization() {
        authRequested = true
    }

    func sendLimitReachedNotification(percentage: Int, limit: Int) {
        notificationsSent.append((percentage: percentage, limit: limit))
    }
}

public enum ChargeLimiterTests {
    public static func runAll() {
        print("\n======================================================")
        print(" Running BatteryGuard Charge Limiter & SMC Test Suite")
        print("======================================================")

        testSMCControllerReadAndWriteStub()
        testLimiterClampingAndDefault()
        testLimiterNotificationOnLimitReached()
        testLimiterDebouncePerSession()
        testLimiterACDisconnectReset()
        testLimiterHysteresisReset()

        print("======================================================")
        print(" 🎉 ALL CHARGE LIMITER & SMC TESTS PASSED!")
        print("======================================================\n")
    }

    private static func testSMCControllerReadAndWriteStub() {
        print("\n• Test A1: Testing SMCController Hardware Detection & Write Stub...")
        let smc = SMCController()
        let keys = smc.detectHardwareKeys()
        print("  -> Detected SMC Keys: \(keys.keys.sorted().joined(separator: ", "))")
        for (k, info) in keys.sorted(by: { $0.key < $1.key }) {
            print("     [\(k)]: exists=\(info.exists), type=\(info.dataType), size=\(info.dataSize)")
        }
        
        let writeResult = smc.write(key: "CHTE", bytes: [1, 0, 0, 0])
        assert(writeResult == .unsupported, "SMC write must unconditionally return .unsupported in this phase")
        print("  -> SMC write returned: \(writeResult) (strictly unsupported stub)")
        print("  ✅ Passed: SMC read-only detection and write stub verified.")
    }

    private static func testLimiterClampingAndDefault() {
        print("\n• Test A2: Testing ChargeLimiter Clamping & Mode...")
        let limiter = ChargeLimiter(chargeLimit: 80)
        assert(limiter.mode == .alertMode, "Mode must always be .alertMode")
        assert(limiter.chargeLimit == 80)

        limiter.chargeLimit = 120
        assert(limiter.chargeLimit == 100, "Should clamp to 100")

        limiter.chargeLimit = 30
        assert(limiter.chargeLimit == 50, "Should clamp to 50")
        print("  ✅ Passed: Limiter boundary clamping verified.")
    }

    private static func testLimiterNotificationOnLimitReached() {
        print("\n• Test A3: Testing Notification on Limit Reached...")
        let mock = MockChargeLimitNotifier()
        let limiter = ChargeLimiter(chargeLimit: 80, notifier: mock)

        // Case 1: On AC, below limit
        let snap75 = BatterySnapshot(currentChargePercentage: 75, chargingState: .charging, isACPowerConnected: true)
        limiter.evaluate(snapshot: snap75)
        assert(mock.notificationsSent.isEmpty, "No alert below limit")
        assert(!limiter.isAlertActive)

        // Case 2: On AC, reaches limit (80%)
        let snap80 = BatterySnapshot(currentChargePercentage: 80, chargingState: .charging, isACPowerConnected: true)
        limiter.evaluate(snapshot: snap80)
        assert(mock.notificationsSent.count == 1, "Alert must be sent when limit reached")
        assert(mock.notificationsSent.first?.percentage == 80)
        assert(mock.notificationsSent.first?.limit == 80)
        assert(limiter.isAlertActive)
        assert(limiter.lastNotifiedPercentage == 80)
        print("  ✅ Passed: Notification fired promptly when crossing limit.")
    }

    private static func testLimiterDebouncePerSession() {
        print("\n• Test A4: Testing Notification Debounce While Above Limit...")
        let mock = MockChargeLimitNotifier()
        let limiter = ChargeLimiter(chargeLimit: 80, notifier: mock)

        // Reach 80% -> alert 1
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 80, chargingState: .charging, isACPowerConnected: true))
        assert(mock.notificationsSent.count == 1)

        // Next tick: still at 80% -> no duplicate alert
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 80, chargingState: .charging, isACPowerConnected: true))
        assert(mock.notificationsSent.count == 1, "Should not duplicate alert on next tick")

        // Next tick: rises to 82% -> no duplicate alert
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 82, chargingState: .charging, isACPowerConnected: true))
        assert(mock.notificationsSent.count == 1, "Should not duplicate alert while continuously above limit")
        print("  ✅ Passed: Debounce verified (only one alert dispatched per session).")
    }

    private static func testLimiterACDisconnectReset() {
        print("\n• Test A5: Testing Alert Reset on AC Disconnect...")
        let mock = MockChargeLimitNotifier()
        let limiter = ChargeLimiter(chargeLimit: 80, notifier: mock)

        // Trigger alert at 85%
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 85, chargingState: .charging, isACPowerConnected: true))
        assert(limiter.isAlertActive)
        assert(mock.notificationsSent.count == 1)

        // Unplug charger (user complied with alert!)
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 85, chargingState: .discharging, isACPowerConnected: false))
        assert(!limiter.isAlertActive, "Alert state must reset when AC is disconnected")
        assert(limiter.lastNotifiedPercentage == nil)

        // Reconnect charger while still at 85% -> new session, should alert again!
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 85, chargingState: .charging, isACPowerConnected: true))
        assert(limiter.isAlertActive)
        assert(mock.notificationsSent.count == 2, "Must alert for new plugged-in session")
        print("  ✅ Passed: Alert resets cleanly on disconnect and re-arms on reconnect.")
    }

    private static func testLimiterHysteresisReset() {
        print("\n• Test A6: Testing 2% Hysteresis Reset While Plugged In...")
        let mock = MockChargeLimitNotifier()
        let limiter = ChargeLimiter(chargeLimit: 80, notifier: mock)

        // Trigger at 80%
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 80, chargingState: .charging, isACPowerConnected: true))
        assert(limiter.isAlertActive)
        assert(mock.notificationsSent.count == 1)

        // Dips to 79% (only 1% below limit) -> hysteresis prevents reset
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 79, chargingState: .charging, isACPowerConnected: true))
        assert(limiter.isAlertActive, "Should remain active at 79% due to 2% hysteresis")

        // Dips to 78% (limit - 2%) -> resets alert
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 78, chargingState: .charging, isACPowerConnected: true))
        assert(!limiter.isAlertActive, "Should reset at <= (limit - 2%)")

        // Climbs back to 80% -> should fire new notification!
        limiter.evaluate(snapshot: BatterySnapshot(currentChargePercentage: 80, chargingState: .charging, isACPowerConnected: true))
        assert(mock.notificationsSent.count == 2, "Fires again after hysteresis reset")
        print("  ✅ Passed: 2% hysteresis reset verified.")
    }
}
