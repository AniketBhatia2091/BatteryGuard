import Foundation
#if canImport(Darwin)
import Darwin
#endif

print("======================================================")
print(" BatteryGuard - CLI Battery Telemetry Monitor")
print(" SQLite Session Tracker Active (5s polling)")
print("======================================================\n")

let collector = BatteryCollector()
let store = SQLiteMetricsStore()
let tracker = ChargeSessionTracker(store: store, chargeLimit: 80) // 80% limit for testing overcharge timers

// Initialize recovery on startup
let initialSnapshot = collector.readBatterySnapshot()
Task {
    await tracker.initializeRecovery(currentSnapshot: initialSnapshot)
}

print("Charge Limit Setting: 80%")
print("Tip: Compare with: system_profiler SPPowerDataType\n")
fflush(stdout)

func formatTime(_ seconds: Double) -> String {
    let s = Int(seconds)
    let m = s / 60
    let remS = s % 60
    if m > 0 {
        return "\(m)m \(remS)s"
    } else {
        return "\(remS)s"
    }
}

while true {
    let snapshot = collector.readBatterySnapshot()
    let timestamp = DateFormatter.localizedString(from: snapshot.timestamp, dateStyle: .none, timeStyle: .medium)

    // Process tick through session tracker
    let sema = DispatchSemaphore(value: 0)
    var activeSessionCopy: StoredChargeSession?
    var todayOvercharge: Double = 0.0
    var weekOvercharge: Double = 0.0

    Task {
        await tracker.handleTick(snapshot: snapshot)
        activeSessionCopy = await tracker.activeSession
        todayOvercharge = await tracker.getTodayOverchargeSeconds()
        weekOvercharge = await tracker.getWeekOverchargeSeconds()
        sema.signal()
    }
    sema.wait()

    print("[\(timestamp)] Battery & Session Snapshot:")
    print("  • Current Charge:      \(snapshot.currentChargePercentage)%")
    print("  • Charging State:      \(snapshot.chargingState.rawValue)")
    print("  • AC Power Connected:  \(snapshot.isACPowerConnected ? "Yes" : "No")")

    if let cycles = snapshot.cycleCount {
        print("  • Cycle Count:         \(cycles)")
    } else {
        print("  • Cycle Count:         N/A")
    }

    if let health = snapshot.healthPercentage,
       let currentMax = snapshot.currentMaxCapacity,
       let design = snapshot.designCapacity {
        print(String(format: "  • Estimated Health:    %.1f%% (%d mAh / %d mAh)", health, currentMax, design))
        print("    [Info: Calculated from raw battery data; may differ from macOS Battery Health]")
    } else {
        print("  • Estimated Health:    N/A")
    }

    if let temp = snapshot.temperatureCelsius {
        print(String(format: "  • Temperature:         %.1f°C", temp))
    }

    // Session Information
    if let session = activeSessionCopy {
        let duration = Date().timeIntervalSince(session.startTime)
        print("  • Active Session:      \(session.sessionId.prefix(8))... (Plugged in: \(formatTime(duration)))")
        print("    - Max % Reached:     \(session.maxPercentReached)%")
        print("    - Overcharge (>=80%): \(formatTime(session.secondsSpentAtOrAboveLimit))")
        print("    - Time at 100%:      \(formatTime(session.secondsSpentAt100Percent))")
    } else {
        print("  • Active Session:      None (On Battery)")
    }

    // Aggregate stats
    print("  • Overcharge Today:    \(formatTime(todayOvercharge))")
    print("  • Overcharge This Week: \(formatTime(weekOvercharge))")
    print("------------------------------------------------------")
    fflush(stdout)

    Thread.sleep(forTimeInterval: 5.0)
}
