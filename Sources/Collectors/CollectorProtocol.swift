import Foundation

/// Defines the category or type of metric collected.
public enum MetricType: String, Codable, Sendable {
    case battery
    case thermal
    case cpu
    case custom
}

/// Represents an individual metric sample collected at a specific point in time.
public struct MetricSample: Identifiable, Sendable {
    public let id: UUID
    public let collectorId: String
    public let type: MetricType
    public let timestamp: Date
    public let data: [String: Double]
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        collectorId: String,
        type: MetricType,
        timestamp: Date = Date(),
        data: [String: Double] = [:],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.collectorId = collectorId
        self.type = type
        self.timestamp = timestamp
        self.data = data
        self.metadata = metadata
    }
}

/// Generic protocol for any hardware/system metric collector (Battery, Thermal, CPU, etc.).
/// All future collectors plug into the same background sampling loop via this interface.
public protocol MetricCollector: AnyObject, Sendable {
    /// Unique identifier for this collector (e.g. "com.batteryguard.collector.battery")
    var id: String { get }

    /// Human-readable display name (e.g. "Battery Telemetry")
    var displayName: String { get }

    /// Type of metric gathered by this collector
    var metricType: MetricType { get }

    /// Whether this collector is currently enabled
    var isEnabled: Bool { get }

    /// Starts any background subscriptions, notification observers, or runloop monitors
    func startMonitoring() async

    /// Stops background monitoring and cleans up resources
    func stopMonitoring() async

    /// Polls a snapshot sample from the hardware/system source
    func collectSample() async throws -> MetricSample
}
