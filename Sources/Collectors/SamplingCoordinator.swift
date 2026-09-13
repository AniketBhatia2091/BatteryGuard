import Foundation
import Combine
import AppKit

/// Orchestrates background sampling across all registered MetricCollectors,
/// manages charge session tracking with SQLite persistence, and responds to sleep/wake notifications.
@MainActor
public final class SamplingCoordinator: ObservableObject {
    @Published public private(set) var latestBatterySnapshot: BatterySnapshot?
    @Published public private(set) var recentSamples: [MetricSample] = []
    @Published public private(set) var isSampling: Bool = false
    @Published public private(set) var sampleCount: Int = 0

    // Charge session and overcharge state
    @Published public private(set) var activeSession: StoredChargeSession?
    @Published public private(set) var todayOverchargeSeconds: Double = 0.0
    @Published public private(set) var weekOverchargeSeconds: Double = 0.0
    @Published public private(set) var dailyHistory: [DailyOverchargeSummary] = []

    // Charge limiter and hardware detection
    @Published public var chargeLimit: Int = 80 {
        didSet {
            limiter.chargeLimit = chargeLimit
            Task {
                await sessionTracker.setChargeLimit(chargeLimit)
            }
        }
    }
    public let limiter: ChargeLimiter
    public let smcController: SMCController

    private var collectors: [any MetricCollector] = []
    private let volatileStorage: any MetricsStorageProtocol
    public let persistentStore: any PersistentStorageProtocol
    public let sessionTracker: ChargeSessionTracker
    private let batteryCollector: BatteryCollector

    private var samplingTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    public var samplingInterval: TimeInterval = 5.0

    public init(
        volatileStorage: any MetricsStorageProtocol = InMemoryMetricsStorage(),
        persistentStore: any PersistentStorageProtocol = SQLiteMetricsStore(),
        notifier: ChargeLimitNotifierProtocol = ChargeLimitNotificationManager.shared
    ) {
        self.volatileStorage = volatileStorage
        self.persistentStore = persistentStore
        self.sessionTracker = ChargeSessionTracker(store: persistentStore, chargeLimit: 80)
        self.limiter = ChargeLimiter(chargeLimit: 80, notifier: notifier)
        self.smcController = SMCController()

        let battery = BatteryCollector()
        self.batteryCollector = battery
        self.collectors = [battery]

        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.sessionTracker.handleSystemWillSleep(latestSnapshot: self.latestBatterySnapshot)
            }
        }

        wsCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                let current = self.batteryCollector.readBatterySnapshot()
                self.latestBatterySnapshot = current
                await self.sessionTracker.handleSystemDidWake(currentSnapshot: current)
                await self.refreshSessionStats()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                await self.sessionTracker.flushAndClose()
            }
        }
    }

    /// Register additional hardware/system collectors (e.g. ThermalCollector, CPUCollector)
    public func register(collector: any MetricCollector) {
        guard !collectors.contains(where: { $0.id == collector.id }) else { return }
        collectors.append(collector)
    }

    /// Starts the background sampling loop and initializes session crash recovery
    public func start() {
        guard samplingTask == nil else { return }
        isSampling = true

        // Read immediate snapshot
        let snapshot = batteryCollector.readBatterySnapshot()
        self.latestBatterySnapshot = snapshot

        // Initialize session recovery (crash recovery or ongoing session restore)
        Task {
            self.limiter.notifier?.requestAuthorization()
            await sessionTracker.initializeRecovery(currentSnapshot: snapshot)
            await refreshSessionStats()
        }

        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.samplingInterval ?? 5.0) * 1_000_000_000))
                guard let self = self, !Task.isCancelled else { break }
                await self.sampleAll()
            }
        }
    }

    /// Stops the sampling loop
    public func stop() {
        samplingTask?.cancel()
        samplingTask = nil
        isSampling = false
    }

    /// Takes an immediate snapshot, samples all collectors, and updates session state
    public func refreshImmediate() {
        let snapshot = batteryCollector.readBatterySnapshot()
        self.latestBatterySnapshot = snapshot

        Task {
            await sampleAll()
        }
    }

    private func sampleAll() async {
        let currentCollectors = collectors

        for collector in currentCollectors where collector.isEnabled {
            do {
                let sample = try await collector.collectSample()
                await volatileStorage.append(sample: sample)

                if collector.id == batteryCollector.id {
                    let snapshot = batteryCollector.readBatterySnapshot()
                    self.latestBatterySnapshot = snapshot

                    // Evaluate charge limit notifications
                    self.limiter.evaluate(snapshot: snapshot)

                    // Feed snapshot to charge session state machine
                    await sessionTracker.handleTick(snapshot: snapshot)
                }
            } catch {
                print("[SamplingCoordinator] Collector \(collector.id) error: \(error)")
            }
        }

        let updated = await volatileStorage.getRecentSamples(limit: 30)
        self.recentSamples = updated
        self.sampleCount += 1

        await refreshSessionStats()
    }

    private func refreshSessionStats() async {
        self.activeSession = await sessionTracker.activeSession
        self.todayOverchargeSeconds = await sessionTracker.getTodayOverchargeSeconds()
        self.weekOverchargeSeconds = await sessionTracker.getWeekOverchargeSeconds()
        let history = (try? await persistentStore.getDailyOverchargeHistory(days: 14)) ?? []
        self.dailyHistory = history
    }

    deinit {
        samplingTask?.cancel()
    }
}
