import Foundation
import IOKit.ps
import IOKit

/// Battery telemetry snapshot data model.
public struct BatterySnapshot: Sendable {
    public let currentCapacity: Double
    public let maxCapacity: Double
    public let percentage: Double
    public let isCharging: Bool
    public let isACPowered: Bool
    public let cycleCount: Int?
    public let designCapacity: Int?
    public let healthPercentage: Double?
    public let temperatureCelsius: Double?
    public let timestamp: Date

    public init(
        currentCapacity: Double,
        maxCapacity: Double,
        percentage: Double,
        isCharging: Bool,
        isACPowered: Bool,
        cycleCount: Int? = nil,
        designCapacity: Int? = nil,
        healthPercentage: Double? = nil,
        temperatureCelsius: Double? = nil,
        timestamp: Date = Date()
    ) {
        self.currentCapacity = currentCapacity
        self.maxCapacity = maxCapacity
        self.percentage = percentage
        self.isCharging = isCharging
        self.isACPowered = isACPowered
        self.cycleCount = cycleCount
        self.designCapacity = designCapacity
        self.healthPercentage = healthPercentage
        self.temperatureCelsius = temperatureCelsius
        self.timestamp = timestamp
    }
}

/// Collector responsible for gathering battery telemetry via IOKit APIs:
/// - IOPSCopyPowerSourcesInfo / IOPSGetPowerSourceDescription for charge %, state, and power source.
/// - IORegistryEntry (AppleSmartBattery) for cycle count, design capacity, temperature, and health %.
///
/// NOTE: Standard user-space apps have permission to read these IOKit properties without
/// special entitlements or root privileges.
public final class BatteryCollector: MetricCollector, @unchecked Sendable {
    public let id: String = "com.batteryguard.collector.battery"
    public let displayName: String = "Battery Telemetry"
    public let metricType: MetricType = .battery
    public private(set) var isEnabled: Bool = true

    public init() {}

    public func startMonitoring() async {
        // Monitoring hooks (e.g. CFRunLoopSource / IOPSNotificationCreateRunLoopSource) can be attached here.
    }

    public func stopMonitoring() async {
        // Cleanup monitoring hooks.
    }

    /// Collects a generic MetricSample that can be stored and fed into the unified timeline.
    public func collectSample() async throws -> MetricSample {
        let snapshot = readBatterySnapshot()

        var sampleData: [String: Double] = [
            "percentage": snapshot.percentage,
            "currentCapacity": snapshot.currentCapacity,
            "maxCapacity": snapshot.maxCapacity,
            "isCharging": snapshot.isCharging ? 1.0 : 0.0,
            "isACPowered": snapshot.isACPowered ? 1.0 : 0.0
        ]

        if let cycle = snapshot.cycleCount {
            sampleData["cycleCount"] = Double(cycle)
        }
        if let health = snapshot.healthPercentage {
            sampleData["healthPercentage"] = health
        }
        if let temp = snapshot.temperatureCelsius {
            sampleData["temperatureCelsius"] = temp
        }

        var metadata: [String: String] = [
            "chargingState": snapshot.isCharging ? "Charging" : (snapshot.isACPowered ? "Plugged in (Not Charging)" : "On Battery")
        ]
        if let cycle = snapshot.cycleCount {
            metadata["cycleCount"] = "\(cycle)"
        }

        return MetricSample(
            collectorId: self.id,
            type: self.metricType,
            timestamp: snapshot.timestamp,
            data: sampleData,
            metadata: metadata
        )
    }

    /// Reads direct hardware snapshot using IOKit APIs.
    public func readBatterySnapshot() -> BatterySnapshot {
        // 1. Read IOPSCopyPowerSourcesInfo for Charge % & Charging State
        var currentCap: Double = 100.0
        var maxCap: Double = 100.0
        var percent: Double = 100.0
        var charging: Bool = false
        var acPower: Bool = true

        if let psBlob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let psList = IOPSCopyPowerSourcesList(psBlob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in psList {
                if let desc = IOPSGetPowerSourceDescription(psBlob, ps)?.takeUnretainedValue() as? [String: Any] {
                    if let cur = desc[kIOPSCurrentCapacityKey] as? Double {
                        currentCap = cur
                    }
                    if let max = desc[kIOPSMaxCapacityKey] as? Double, max > 0 {
                        maxCap = max
                        percent = (currentCap / maxCap) * 100.0
                    }
                    if let isCharging = desc[kIOPSIsChargingKey] as? Bool {
                        charging = isCharging
                    }
                    if let state = desc[kIOPSPowerSourceStateKey] as? String {
                        acPower = (state == (kIOPSACPowerValue as String))
                    }
                }
            }
        }

        // 2. Read IORegistryEntry for AppleSmartBattery (CycleCount, DesignCapacity, Health %, Temperature)
        var cycleCount: Int? = nil
        var designCapacity: Int? = nil
        var healthPercentage: Double? = nil
        var tempCelsius: Double? = nil

        let batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if batteryService != 0 {
            defer { IOObjectRelease(batteryService) }

            var propRef: Unmanaged<CFMutableDictionary>?
            let result = IORegistryEntryCreateCFProperties(
                batteryService,
                &propRef,
                kCFAllocatorDefault,
                0
            )

            if result == kIOReturnSuccess, let properties = propRef?.takeRetainedValue() as? [String: Any] {
                if let cycles = properties["CycleCount"] as? Int {
                    cycleCount = cycles
                }

                let regMaxCapacity = properties["MaxCapacity"] as? Int ?? Int(maxCap)
                if let designCap = properties["DesignCapacity"] as? Int, designCap > 0 {
                    designCapacity = designCap
                    healthPercentage = (Double(regMaxCapacity) / Double(designCap)) * 100.0
                }

                // AppleSmartBattery temperature is reported in hundredths of a Kelvin (0.01 K) or tenth of a degree
                if let rawTemp = properties["Temperature"] as? Double {
                    // Typically rawTemp ~ 3000 for ~27°C (Kelvin * 100)
                    if rawTemp > 2000 {
                        tempCelsius = (rawTemp / 100.0) - 273.15
                    } else if rawTemp > 200 {
                        tempCelsius = (rawTemp / 10.0) - 273.15
                    } else {
                        tempCelsius = rawTemp
                    }
                }
            }
        }

        return BatterySnapshot(
            currentCapacity: currentCap,
            maxCapacity: maxCap,
            percentage: percent,
            isCharging: charging,
            isACPowered: acPower,
            cycleCount: cycleCount,
            designCapacity: designCapacity,
            healthPercentage: healthPercentage,
            temperatureCelsius: tempCelsius,
            timestamp: Date()
        )
    }
}
