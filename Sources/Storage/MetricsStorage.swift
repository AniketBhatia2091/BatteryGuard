import Foundation

/// Base protocol for metric sample storage.
public protocol MetricsStorageProtocol: AnyObject, Sendable {
    func append(sample: MetricSample) async
    func getRecentSamples(limit: Int) async -> [MetricSample]
    func getSamples(for collectorId: String, limit: Int) async -> [MetricSample]
    func clear() async
}

/// Stub protocol for persistent storage (e.g. SQLite / CoreData / SwiftData)
/// Designed to store charge session history and long-term telemetry that survives app restarts.
public protocol PersistentStorageProtocol: MetricsStorageProtocol {
    /// Save a completed charge session event or metric batch to disk
    func saveChargeSession(startTime: Date, endTime: Date?, startPercentage: Double, endPercentage: Double?, cycleCount: Int?) async throws

    /// Retrieve historical sessions across app restarts
    func fetchHistoricalSessions(since date: Date) async throws -> [ChargeSessionRecord]

    /// Purge telemetry older than a specific retention window
    func purgeRecordsOlderThan(days: Int) async throws -> Int
}

/// Representation of a stored charging session for persistence.
public struct ChargeSessionRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public let startTime: Date
    public let endTime: Date?
    public let startPercentage: Double
    public let endPercentage: Double?
    public let cycleCount: Int?

    public init(
        id: UUID = UUID(),
        startTime: Date,
        endTime: Date? = nil,
        startPercentage: Double,
        endPercentage: Double? = nil,
        cycleCount: Int? = nil
    ) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
        self.startPercentage = startPercentage
        self.endPercentage = endPercentage
        self.cycleCount = cycleCount
    }
}

/// Thread-safe in-memory ring buffer storage for recent live samples.
public actor InMemoryMetricsStorage: MetricsStorageProtocol {
    private var samples: [MetricSample] = []
    private let capacity: Int

    public init(capacity: Int = 500) {
        self.capacity = capacity
    }

    public func append(sample: MetricSample) {
        samples.append(sample)
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public func getRecentSamples(limit: Int = 50) -> [MetricSample] {
        return Array(samples.suffix(limit))
    }

    public func getSamples(for collectorId: String, limit: Int = 50) -> [MetricSample] {
        return Array(samples.filter { $0.collectorId == collectorId }.suffix(limit))
    }

    public func clear() {
        samples.removeAll()
    }
}
