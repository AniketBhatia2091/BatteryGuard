import Foundation
import Combine

/// Orchestrates background sampling across all registered MetricCollectors.
/// Future collectors (Thermal, CPU, etc.) register here and share the same sampling loop.
@MainActor
public final class SamplingCoordinator: ObservableObject {
    @Published public private(set) var latestBatterySnapshot: BatterySnapshot?
    @Published public private(set) var recentSamples: [MetricSample] = []
    @Published public private(set) var isSampling: Bool = false
    @Published public private(set) var sampleCount: Int = 0

    private var collectors: [any MetricCollector] = []
    private let storage: any MetricsStorageProtocol
    private let batteryCollector: BatteryCollector

    private var samplingTask: Task<Void, Never>?
    public var samplingInterval: TimeInterval = 5.0

    public init(storage: any MetricsStorageProtocol = InMemoryMetricsStorage()) {
        self.storage = storage
        let battery = BatteryCollector()
        self.batteryCollector = battery
        self.collectors = [battery]
    }

    /// Register additional hardware/system collectors (e.g. ThermalCollector, CPUCollector)
    public func register(collector: any MetricCollector) {
        guard !collectors.contains(where: { $0.id == collector.id }) else { return }
        collectors.append(collector)
    }

    /// Starts the background sampling loop
    public func start() {
        guard samplingTask == nil else { return }
        isSampling = true

        // Read an immediate snapshot on start
        refreshImmediate()

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

    /// Takes an immediate snapshot and updates published state
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
                await storage.append(sample: sample)

                if collector.id == batteryCollector.id {
                    let snapshot = batteryCollector.readBatterySnapshot()
                    self.latestBatterySnapshot = snapshot
                }
            } catch {
                print("[SamplingCoordinator] Collector \(collector.id) error: \(error)")
            }
        }

        let updated = await storage.getRecentSamples(limit: 30)
        self.recentSamples = updated
        self.sampleCount += 1
    }

    deinit {
        samplingTask?.cancel()
    }
}
