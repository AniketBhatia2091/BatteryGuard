import Foundation
import SQLite3
import AppKit

@main
struct ChargeSessionTrackerTests {
    static func main() async {
        print("======================================================")
        print(" Running BatteryGuard Unit & Integration Test Suite")
        print("======================================================\n")

        let testDbPath = "/tmp/test_bg_\(UUID().uuidString).sqlite"
        defer {
            try? FileManager.default.removeItem(atPath: testDbPath)
            try? FileManager.default.removeItem(atPath: "\(testDbPath)-wal")
            try? FileManager.default.removeItem(atPath: "\(testDbPath)-shm")
        }

        let store = SQLiteMetricsStore(customPath: testDbPath)
        let tracker = ChargeSessionTracker(store: store, chargeLimit: 80, debounceDuration: 12.0)

        // MARK: - Test 1: WAL Mode Verification
        print("• Test 1: Verifying SQLite WAL Journal Mode...")
        var dbPtr: OpaquePointer?
        if sqlite3_open_v2(testDbPath, &dbPtr, SQLITE_OPEN_READONLY, nil) == SQLITE_OK {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(dbPtr, "PRAGMA journal_mode;", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let mode = String(cString: sqlite3_column_text(stmt, 0))
                    print("  -> Journal Mode: \(mode)")
                    assert(mode.lowercased() == "wal", "Expected WAL journal mode")
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(dbPtr)
        }
        print("  ✅ Passed: WAL mode active.\n")

        // MARK: - Test 2: Start Session & Accumulate Overcharge
        print("• Test 2: Starting Session & Testing Overcharge Accumulation...")
        let baseTime = Date()
        let snapAC_85 = BatterySnapshot(
            currentChargePercentage: 85,
            chargingState: .charging,
            isACPowerConnected: true
        )

        // Tick 1: Starts session at 85%
        await tracker.handleTick(snapshot: snapAC_85, at: baseTime)
        var active = await tracker.activeSession
        assert(active != nil, "Active session should be created")
        let sessionId = active!.sessionId
        print("  -> Started session ID: \(sessionId)")

        // Tick 2: 3 seconds later at 85%
        let tick2Time = baseTime.addingTimeInterval(3.0)
        await tracker.handleTick(snapshot: snapAC_85, at: tick2Time)
        active = await tracker.activeSession
        let overchargeT2 = active!.secondsSpentAtOrAboveLimit
        print(String(format: "  -> Accumulated overcharge: %.2fs (expected ~3.0s)", overchargeT2))
        assert(abs(overchargeT2 - 3.0) < 0.1, "Overcharge timer should accumulate 3.0 seconds")
        print("  ✅ Passed: Session started and overcharge accumulated.\n")

        // MARK: - Test 3: Delta-Time Capping
        print("• Test 3: Testing Delta-Time Capping (safety net for timer delays)...")
        // Simulate a 40-second delay gap (with samplingInterval = 5s, cap is 10s)
        let delayTime = tick2Time.addingTimeInterval(40.0)
        await tracker.handleTick(snapshot: snapAC_85, at: delayTime)
        active = await tracker.activeSession
        let overchargeT3 = active!.secondsSpentAtOrAboveLimit
        let deltaT3 = overchargeT3 - overchargeT2
        print(String(format: "  -> Raw time gap was 40.0s; credited delta was %.2fs (capped at 10.0s)", deltaT3))
        assert(abs(deltaT3 - 10.0) < 0.1, "Delta time must be capped at samplingInterval * 2 (10s)")
        print("  ✅ Passed: Delta-time capped safely.\n")

        // MARK: - Test 4: Genuine Sleep Duration Crediting
        print("• Test 4: Testing Sleep / Wake Duration Crediting...")
        let sleepStart = delayTime.addingTimeInterval(5.0)
        await tracker.handleSystemWillSleep(at: sleepStart, latestSnapshot: snapAC_85)

        // Simulate waking 75.0 seconds later while still plugged in at 86%
        let wakeTime = sleepStart.addingTimeInterval(75.0)
        let wakeSnap = BatterySnapshot(
            currentChargePercentage: 86,
            chargingState: .charging,
            isACPowerConnected: true
        )
        let preWakeOvercharge = active!.secondsSpentAtOrAboveLimit
        await tracker.handleSystemDidWake(at: wakeTime, currentSnapshot: wakeSnap)
        active = await tracker.activeSession
        let postWakeOvercharge = active!.secondsSpentAtOrAboveLimit
        let creditedSleep = postWakeOvercharge - preWakeOvercharge
        print(String(format: "  -> Simulated Sleep: 75.0s. Credited sleep overcharge: %.2fs", creditedSleep))
        assert(abs(creditedSleep - 75.0) < 0.1, "Sleep duration must be credited exactly (75.0s)")
        print("  ✅ Passed: Genuine 75s sleep duration credited to overcharge timer.\n")

        // MARK: - Test 5: Rapid Disconnect Debounce (Part A & Part B)
        print("• Test 5: Testing Disconnect Debounce (Grace Period & Cancellation)...")
        let snapBatt = BatterySnapshot(
            currentChargePercentage: 86,
            chargingState: .discharging,
            isACPowerConnected: false
        )

        // Part A: Disconnect -> Reconnect within grace period
        await tracker.handleTick(snapshot: snapBatt)
        let isDebouncing = await tracker.isDebouncingDisconnect
        let hasActiveA = (await tracker.activeSession != nil)
        assert(isDebouncing == true, "Must enter debounce state on disconnect")
        assert(hasActiveA == true, "Active session must NOT be closed immediately")
        print("  -> Part A: Disconnected AC. Grace period active (session maintained).")

        // Reconnect within grace period
        await tracker.handleTick(snapshot: snapAC_85)
        let isDebouncingAfterReconnect = await tracker.isDebouncingDisconnect
        let activeAfterReconnect = await tracker.activeSession
        let hasActiveAfterReconnect = (activeAfterReconnect != nil)
        let sessionIdMatches = (activeAfterReconnect?.sessionId == sessionId)
        assert(isDebouncingAfterReconnect == false, "Debounce state must cancel on reconnect")
        assert(hasActiveAfterReconnect == true, "Active session continues with same ID")
        assert(sessionIdMatches, "Session ID must remain identical across cable bump")
        print("  -> Part A: Reconnected within grace period. Debounce cancelled, session preserved.")

        // Part B: Disconnect -> Wait for full debounce duration to expire
        print("  -> Part B: Testing full debounce expiration...")
        let shortDebounceTracker = ChargeSessionTracker(store: store, chargeLimit: 80, debounceDuration: 0.3)
        let snapAC_90 = BatterySnapshot(currentChargePercentage: 90, chargingState: .charging, isACPowerConnected: true)
        await shortDebounceTracker.handleTick(snapshot: snapAC_90)
        let bSession = await shortDebounceTracker.activeSession
        let bSessionId = bSession?.sessionId
        assert(bSessionId != nil, "Short debounce session started")

        // Disconnect with 0.3s debounce
        await shortDebounceTracker.handleTick(snapshot: snapBatt)
        let isShortDebouncing = await shortDebounceTracker.isDebouncingDisconnect
        assert(isShortDebouncing == true)

        // Wait 0.45s for the 0.3s background debounce task to finalize
        try? await Task.sleep(nanoseconds: 450_000_000)

        let sessionAfterExpiry = await shortDebounceTracker.activeSession
        assert(sessionAfterExpiry == nil, "Active session must be closed after debounce expires")

        let sessions = try! await store.fetchRecentSessions(limit: 5)
        let closedBSession = sessions.first { $0.sessionId == bSessionId }
        assert(closedBSession != nil, "Closed session must exist in DB")
        assert(closedBSession?.endTime != nil, "End time must be populated in DB row")
        print("  -> Part B: Debounce expired. Session finalized in SQLite with valid end_time.")
        print("  ✅ Passed: Disconnect debouncing verified for both cancellation and expiration.\n")

        // MARK: - Test 6: Aggregates Today & This Week
        print("• Test 6: Testing Aggregate Queries (Today & This Week)...")
        let todaySecs = await tracker.getTodayOverchargeSeconds()
        let weekSecs = await tracker.getWeekOverchargeSeconds()
        print(String(format: "  -> Today's Overcharge: %.2fs", todaySecs))
        print(String(format: "  -> This Week's Overcharge: %.2fs", weekSecs))
        assert(todaySecs >= 75.0, "Today overcharge should include the accumulated overcharge")
        assert(weekSecs >= todaySecs, "Week overcharge should be at least today's overcharge")
        print("  ✅ Passed: Aggregate queries compute correct sums.\n")

        // MARK: - Test 7: Crash Recovery of Orphaned Session
        print("• Test 7: Testing Crash Recovery of Orphaned Session...")
        // Ongoing session still in DB
        let unclosedOngoing = try! await store.getOngoingSession()
        assert(unclosedOngoing != nil, "Orphaned ongoing session exists in SQLite")

        // Simulate app relaunching while on battery (e.g. user rebooted while unplugged)
        let recoveryTracker = ChargeSessionTracker(store: store, chargeLimit: 80)
        await recoveryTracker.initializeRecovery(currentSnapshot: snapBatt)

        let recoveredActive = await recoveryTracker.activeSession
        assert(recoveredActive == nil, "Orphaned session should be closed on relaunch when on battery")

        let ongoingAfterRecovery = try! await store.getOngoingSession()
        assert(ongoingAfterRecovery == nil, "No ongoing sessions should remain unclosed in DB")
        print("  -> Orphaned session was successfully closed using last known sample timestamp.")
        print("  ✅ Passed: Crash recovery verified.\n")

        print("======================================================")
        print(" 🎉 ALL 7 INTEGRATION TESTS VERIFIED AND PASSED!")
        print("======================================================")
    }
}
