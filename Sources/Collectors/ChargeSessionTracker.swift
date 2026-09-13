import Foundation
import AppKit

/// Manages the charge session lifecycle and overcharge tracking.
///
/// Handles:
/// - Session start when plugged into AC power.
/// - Overcharge timer accumulation (at/above limit, and at 100%).
/// - Sleep/wake accounting (NSWorkspace.willSleepNotification / didWakeNotification).
/// - Rapid plug/unplug debouncing (12s grace period by default, configurable).
/// - Delta-time capping (min(delta, samplingInterval * 2)).
/// - Crash/restart recovery of orphaned sessions.
///
/// NOTE (Documented MVP Boundary):
/// Charge sessions are tracked while BatteryGuard is running. Unplug/replug events
/// that occur while the app is completely closed are not observable until the app launches.
public actor ChargeSessionTracker {
    public private(set) var activeSession: StoredChargeSession?
    public private(set) var isDebouncingDisconnect: Bool = false
    public var chargeLimit: Int = 100
    public var samplingInterval: Double = 5.0
    public var debounceDuration: TimeInterval = 12.0

    private let store: PersistentStorageProtocol
    private var lastTickTimestamp: Date?
    private var lastSleepTimestamp: Date?
    private var preSleepSnapshot: BatterySnapshot?
    private var disconnectTask: Task<Void, Never>?
    private var disconnectStartTime: Date?

    public init(
        store: PersistentStorageProtocol,
        chargeLimit: Int = 100,
        debounceDuration: TimeInterval = 12.0
    ) {
        self.store = store
        self.chargeLimit = chargeLimit
        self.debounceDuration = debounceDuration
    }

    // MARK: - Crash / Restart Recovery

    /// Called on app startup to inspect SQLite for ongoing sessions from previous runs or crashes.
    public func initializeRecovery(currentSnapshot: BatterySnapshot) async {
        do {
            if let ongoing = try await store.getOngoingSession() {
                if currentSnapshot.isACPowerConnected {
                    // Resuming ongoing session from previous run
                    var resumed = ongoing
                    resumed.maxPercentReached = max(resumed.maxPercentReached, currentSnapshot.currentChargePercentage)
                    resumed.lastUpdated = Date()
                    self.activeSession = resumed
                    self.lastTickTimestamp = Date()
                    try? await store.updateOngoingSession(session: resumed)
                    print("[ChargeSessionTracker] Resumed ongoing session \(resumed.sessionId) from prior run.")
                } else {
                    // Closed orphaned session because app reopened on battery
                    let estimatedEnd = ongoing.lastUpdated
                    try? await store.closeChargeSession(
                        sessionId: ongoing.sessionId,
                        endTime: estimatedEnd,
                        maxPercentReached: ongoing.maxPercentReached,
                        secondsSpentAtOrAboveLimit: ongoing.secondsSpentAtOrAboveLimit,
                        secondsSpentAt100Percent: ongoing.secondsSpentAt100Percent
                    )
                    print("[ChargeSessionTracker] Closed orphaned session \(ongoing.sessionId) at \(estimatedEnd).")
                    self.activeSession = nil
                }
            } else if currentSnapshot.isACPowerConnected {
                // Initial session if app launched already connected to AC
                await startNewSession(snapshot: currentSnapshot)
            }
        } catch {
            print("[ChargeSessionTracker] Recovery error: \(error)")
        }
    }

    // MARK: - Sampling Loop Tick Handling

    /// Called on every background sampling loop tick.
    public func handleTick(snapshot: BatterySnapshot, at timestamp: Date = Date()) async {
        let now = timestamp

        if snapshot.isACPowerConnected {
            // Cancel debounce if reconnected within grace period
            if isDebouncingDisconnect {
                disconnectTask?.cancel()
                disconnectTask = nil
                isDebouncingDisconnect = false
                disconnectStartTime = nil
                lastTickTimestamp = now
                print("[ChargeSessionTracker] AC reconnected within debounce grace period. Resuming session.")
            }

            if activeSession == nil {
                // Rule: New session starts when AC connects while below the limit
                // (or if limit is 100% or connecting for the first time)
                if snapshot.currentChargePercentage < chargeLimit || chargeLimit == 100 {
                    await startNewSession(snapshot: snapshot, at: now)
                } else {
                    // If connecting while already at/above limit, start session tracking immediately
                    await startNewSession(snapshot: snapshot, at: now)
                }
            } else if var session = activeSession {
                let lastTick = lastTickTimestamp ?? now
                let actualDelta = now.timeIntervalSince(lastTick)

                // Delta-time capping: prevent runaway accumulation on system hiccups
                let cappedDelta = max(0.0, min(actualDelta, samplingInterval * 2.0))

                session.maxPercentReached = max(session.maxPercentReached, snapshot.currentChargePercentage)

                let limit = session.chargeLimitSettingAtTime ?? chargeLimit
                if snapshot.currentChargePercentage >= limit {
                    session.secondsSpentAtOrAboveLimit += cappedDelta
                }
                if snapshot.currentChargePercentage >= 100 {
                    session.secondsSpentAt100Percent += cappedDelta
                }

                session.lastUpdated = now
                self.activeSession = session
                self.lastTickTimestamp = now

                try? await store.updateOngoingSession(session: session)
            }
        } else {
            // AC Disconnected
            if activeSession != nil && !isDebouncingDisconnect {
                triggerDisconnectDebounce(disconnectTime: now)
            }
        }
    }

    private func startNewSession(snapshot: BatterySnapshot, at timestamp: Date = Date()) async {
        let now = timestamp
        let session = StoredChargeSession(
            sessionId: UUID().uuidString,
            startTime: now,
            endTime: nil,
            lastUpdated: now,
            maxPercentReached: snapshot.currentChargePercentage,
            chargeLimitSettingAtTime: chargeLimit,
            secondsSpentAtOrAboveLimit: 0,
            secondsSpentAt100Percent: 0
        )

        do {
            try await store.startChargeSession(session: session)
            self.activeSession = session
            self.lastTickTimestamp = now
            print("[ChargeSessionTracker] Started charge session: \(session.sessionId)")
        } catch {
            print("[ChargeSessionTracker] Failed to start session: \(error)")
        }
    }

    // MARK: - Rapid Plug / Unplug Debounce

    private func triggerDisconnectDebounce(disconnectTime: Date) {
        isDebouncingDisconnect = true
        disconnectStartTime = disconnectTime

        let graceNanos = UInt64(max(0.1, debounceDuration) * 1_000_000_000)
        disconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: graceNanos)
            guard !Task.isCancelled else { return }
            await self?.finalizeDisconnect()
        }
    }

    public func finalizeDisconnect() async {
        guard isDebouncingDisconnect, var session = activeSession else { return }
        let end = disconnectStartTime ?? Date()
        session.endTime = end

        do {
            try await store.closeChargeSession(
                sessionId: session.sessionId,
                endTime: end,
                maxPercentReached: session.maxPercentReached,
                secondsSpentAtOrAboveLimit: session.secondsSpentAtOrAboveLimit,
                secondsSpentAt100Percent: session.secondsSpentAt100Percent
            )
            print("[ChargeSessionTracker] Completed session \(session.sessionId) (Overcharge: \(Int(session.secondsSpentAtOrAboveLimit))s).")
        } catch {
            print("[ChargeSessionTracker] Failed to close session: \(error)")
        }

        self.activeSession = nil
        self.isDebouncingDisconnect = false
        self.disconnectStartTime = nil
        self.disconnectTask = nil
        self.lastTickTimestamp = nil
    }

    // MARK: - Sleep & Wake Duration Accounting

    public func handleSystemWillSleep(at timestamp: Date = Date(), latestSnapshot: BatterySnapshot?) async {
        self.lastSleepTimestamp = timestamp
        self.preSleepSnapshot = latestSnapshot

        // Flush latest session state to disk before sleep
        if let session = activeSession {
            try? await store.updateOngoingSession(session: session)
        }
        print("[ChargeSessionTracker] System will sleep recorded at \(timestamp).")
    }

    public func handleSystemDidWake(at timestamp: Date = Date(), currentSnapshot: BatterySnapshot) async {
        guard let sleepTime = lastSleepTimestamp,
              var session = activeSession else {
            self.lastTickTimestamp = timestamp
            return
        }

        let sleepDuration = max(0.0, timestamp.timeIntervalSince(sleepTime))
        let preSleepPercent = preSleepSnapshot?.currentChargePercentage ?? currentSnapshot.currentChargePercentage
        let limit = session.chargeLimitSettingAtTime ?? chargeLimit

        // If battery was at/above limit before sleep and is still plugged in on wake:
        // Credit the elapsed sleep duration to the overcharge counter
        if currentSnapshot.isACPowerConnected && preSleepPercent >= limit {
            session.secondsSpentAtOrAboveLimit += sleepDuration
            if preSleepPercent >= 100 {
                session.secondsSpentAt100Percent += sleepDuration
            }
            session.maxPercentReached = max(session.maxPercentReached, currentSnapshot.currentChargePercentage)
            session.lastUpdated = timestamp
            self.activeSession = session
            try? await store.updateOngoingSession(session: session)
            print(String(format: "[ChargeSessionTracker] Credited sleep overcharge: %.1fs to session.", sleepDuration))
        }

        self.lastSleepTimestamp = nil
        self.preSleepSnapshot = nil
        self.lastTickTimestamp = timestamp
    }

    // MARK: - Clean Shutdown

    public func flushAndClose() async {
        disconnectTask?.cancel()
        disconnectTask = nil

        if var session = activeSession {
            let now = Date()
            session.lastUpdated = now
            // Update ongoing session with latest timestamps
            try? await store.updateOngoingSession(session: session)
        }
        await store.closeDatabase()
    }

    // MARK: - Aggregate Queries

    /// Total overcharge time accumulated today (00:00 to now).
    /// MVP boundary: Aggregated by session start_time.
    public func getTodayOverchargeSeconds() async -> Double {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? Date()

        var total = (try? await store.getTotalOvercharge(from: startOfDay, to: nextDay)) ?? 0.0

        // If currently ongoing session started today, ensure live progress is reflected
        if let current = activeSession, current.startTime >= startOfDay {
            let inDb = (try? await store.getTotalOvercharge(from: startOfDay, to: nextDay)) ?? 0.0
            total = max(inDb, total)
        }
        return total
    }

    /// Total overcharge time accumulated this week (Monday to now).
    /// MVP boundary: Aggregated by session start_time.
    public func getWeekOverchargeSeconds() async -> Double {
        var calendar = Calendar.current
        calendar.firstWeekday = 2 // Monday
        let now = Date()
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let startOfWeek = calendar.date(from: components) ?? calendar.startOfDay(for: now)
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: startOfWeek) ?? now

        let total = (try? await store.getTotalOvercharge(from: startOfWeek, to: nextWeek)) ?? 0.0
        return total
    }
}
