import Foundation
import IOKit.ps
import IOKit

/// Detailed charging state of the battery.
public enum ChargingState: String, Codable, Sendable {
    case charging = "charging"
    case discharging = "discharging"
    case full = "full"
    case notCharging = "not charging"
}

/// Battery telemetry snapshot data model containing on-demand hardware status.
public struct BatterySnapshot: Sendable {
    /// Current charge level (0 - 100)
    public let currentChargePercentage: Int

    /// Current charging state (charging / discharging / full / not charging)
    public let chargingState: ChargingState

    /// Whether an external AC power adapter is connected
    public let isACPowerConnected: Bool

    /// Battery hardware cycle count
    public let cycleCount: Int?

    /// Current maximum charge capacity in mAh (NominalChargeCapacity or AppleRawMaxCapacity)
    public let currentMaxCapacity: Int?

    /// Original factory design capacity in mAh
    public let designCapacity: Int?

    /// Calculated health percentage: (currentMaxCapacity / designCapacity) * 100
    public let healthPercentage: Double?

    /// Hardware health condition string (e.g. "Normal", "Good")
    public let condition: String?

    /// Battery temperature in degrees Celsius
    public let temperatureCelsius: Double?

    /// Real-time current in mA (negative when discharging, positive when charging)
    public let amperage: Int?

    /// Voltage in Volts
    public let voltage: Double?

    /// Snapshot capture timestamp
    public let timestamp: Date

    // MARK: - Compatibility accessors for UI and legacy callers
    public var percentage: Double { Double(currentChargePercentage) }
    public var isCharging: Bool { chargingState == .charging }
    public var isACPowered: Bool { isACPowerConnected }
    public var currentCapacity: Double { Double(currentChargePercentage) }
    public var maxCapacity: Double { Double(currentMaxCapacity ?? 100) }

    public init(
        currentChargePercentage: Int,
        chargingState: ChargingState,
        isACPowerConnected: Bool,
        cycleCount: Int? = nil,
        currentMaxCapacity: Int? = nil,
        designCapacity: Int? = nil,
        healthPercentage: Double? = nil,
        condition: String? = nil,
        temperatureCelsius: Double? = nil,
        amperage: Int? = nil,
        voltage: Double? = nil,
        timestamp: Date = Date()
    ) {
        self.currentChargePercentage = currentChargePercentage
        self.chargingState = chargingState
        self.isACPowerConnected = isACPowerConnected
        self.cycleCount = cycleCount
        self.currentMaxCapacity = currentMaxCapacity
        self.designCapacity = designCapacity
        self.healthPercentage = healthPercentage
        self.condition = condition
        self.temperatureCelsius = temperatureCelsius
        self.amperage = amperage
        self.voltage = voltage
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
            "currentChargePercentage": Double(snapshot.currentChargePercentage),
            "isCharging": snapshot.isCharging ? 1.0 : 0.0,
            "isACPowered": snapshot.isACPowerConnected ? 1.0 : 0.0
        ]

        if let currentMax = snapshot.currentMaxCapacity {
            sampleData["currentMaxCapacity"] = Double(currentMax)
        }
        if let design = snapshot.designCapacity {
            sampleData["designCapacity"] = Double(design)
        }
        if let cycle = snapshot.cycleCount {
            sampleData["cycleCount"] = Double(cycle)
        }
        if let health = snapshot.healthPercentage {
            sampleData["healthPercentage"] = health
        }
        if let temp = snapshot.temperatureCelsius {
            sampleData["temperatureCelsius"] = temp
        }
        if let amp = snapshot.amperage {
            sampleData["amperage"] = Double(amp)
        }
        if let volt = snapshot.voltage {
            sampleData["voltage"] = volt
        }

        var metadata: [String: String] = [
            "chargingState": snapshot.chargingState.rawValue,
            "isACPowerConnected": snapshot.isACPowerConnected ? "true" : "false"
        ]
        if let cycle = snapshot.cycleCount {
            metadata["cycleCount"] = "\(cycle)"
        }
        if let cond = snapshot.condition {
            metadata["condition"] = cond
        }

        return MetricSample(
            collectorId: self.id,
            type: self.metricType,
            timestamp: snapshot.timestamp,
            data: sampleData,
            metadata: metadata
        )
    }

    /// Reads direct hardware snapshot on demand using IOKit APIs:
    /// - Current charge percentage
    /// - Charging state (charging / discharging / full / not charging)
    /// - Cycle count
    /// - Battery health / max capacity percentage (design capacity vs current max capacity)
    /// - Is AC power connected
    public func readBatterySnapshot() -> BatterySnapshot {
        // 1. Read IOPSCopyPowerSourcesInfo for Power Sources
        var rawChargePercent: Int = 100
        var isChargingReported: Bool = false
        var isChargedReported: Bool = false
        var isACConnected: Bool = false
        var conditionString: String? = nil

        if let psBlob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let psList = IOPSCopyPowerSourcesList(psBlob)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in psList {
                if let desc = IOPSGetPowerSourceDescription(psBlob, ps)?.takeUnretainedValue() as? [String: Any] {
                    if let cur = desc[kIOPSCurrentCapacityKey] as? Int {
                        rawChargePercent = cur
                    } else if let curDbl = desc[kIOPSCurrentCapacityKey] as? Double {
                        rawChargePercent = Int(curDbl)
                    }

                    if let charging = desc[kIOPSIsChargingKey] as? Bool {
                        isChargingReported = charging
                    } else if let chargingInt = desc[kIOPSIsChargingKey] as? Int {
                        isChargingReported = (chargingInt != 0)
                    }

                    if let charged = desc[kIOPSIsChargedKey] as? Bool {
                        isChargedReported = charged
                    } else if let chargedInt = desc[kIOPSIsChargedKey] as? Int {
                        isChargedReported = (chargedInt != 0)
                    }

                    if let state = desc[kIOPSPowerSourceStateKey] as? String {
                        isACConnected = (state == (kIOPSACPowerValue as String))
                    }

                    if let cond = desc[kIOPSBatteryHealthConditionKey] as? String, !cond.isEmpty {
                        conditionString = cond
                    } else if let health = desc["BatteryHealth"] as? String, !health.isEmpty {
                        conditionString = health
                    }
                }
            }
        }

        // 2. Read IORegistryEntry for AppleSmartBattery
        var cycleCount: Int? = nil
        var currentMaxCapacity: Int? = nil
        var designCapacity: Int? = nil
        var healthPercentage: Double? = nil
        var tempCelsius: Double? = nil
        var amperage: Int? = nil
        var voltageVolts: Double? = nil
        var regFullyCharged: Bool = false
        var regIsCharging: Bool = false
        var regExternalConnected: Bool = false

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
                // Fallback charge percent if not read from IOPS
                if let regCurrentCap = properties["CurrentCapacity"] as? Int, rawChargePercent == 100 && !isACConnected {
                    rawChargePercent = regCurrentCap
                }

                if let cycles = properties["CycleCount"] as? Int {
                    cycleCount = cycles
                }

                // Prefer NominalChargeCapacity for current maximum capacity, fallback to AppleRawMaxCapacity
                if let nominal = properties["NominalChargeCapacity"] as? Int, nominal > 0 {
                    currentMaxCapacity = nominal
                } else if let rawMax = properties["AppleRawMaxCapacity"] as? Int, rawMax > 0 {
                    currentMaxCapacity = rawMax
                }

                if let design = properties["DesignCapacity"] as? Int, design > 0 {
                    designCapacity = design
                }

                if let curMax = currentMaxCapacity, let design = designCapacity, design > 0 {
                    healthPercentage = (Double(curMax) / Double(design)) * 100.0
                }

                if let full = properties["FullyCharged"] as? Bool {
                    regFullyCharged = full
                } else if let fullInt = properties["FullyCharged"] as? Int {
                    regFullyCharged = (fullInt != 0)
                }

                if let charging = properties["IsCharging"] as? Bool {
                    regIsCharging = charging
                } else if let chargingInt = properties["IsCharging"] as? Int {
                    regIsCharging = (chargingInt != 0)
                }

                if let ext = properties["ExternalConnected"] as? Bool {
                    regExternalConnected = ext
                } else if let extInt = properties["ExternalConnected"] as? Int {
                    regExternalConnected = (extInt != 0)
                }

                if let amp = properties["Amperage"] as? Int {
                    amperage = amp
                } else if let instAmp = properties["InstantAmperage"] as? Int {
                    amperage = instAmp
                }

                if let voltMv = properties["Voltage"] as? Double {
                    voltageVolts = voltMv / 1000.0
                } else if let voltInt = properties["Voltage"] as? Int {
                    voltageVolts = Double(voltInt) / 1000.0
                }

                // AppleSmartBattery temperature is reported in 0.01 °C on macOS (e.g. 3029 = 30.29 °C)
                let rawTemp: Double? = (properties["Temperature"] as? Double) ?? (properties["Temperature"] as? Int).map { Double($0) }
                if let rawTemp = rawTemp {
                    if rawTemp > 1000 {
                        tempCelsius = rawTemp / 100.0
                    } else if rawTemp > 100 {
                        tempCelsius = rawTemp / 10.0
                    } else {
                        tempCelsius = rawTemp
                    }
                }
            }
        }

        // Reconcile AC connection
        let acConnected = isACConnected || regExternalConnected

        // Reconcile charging state: charging / discharging / full / not charging
        let isCharging = isChargingReported || regIsCharging
        let isFull = isChargedReported || regFullyCharged || (acConnected && rawChargePercent >= 100)

        let resolvedState: ChargingState
        if isCharging {
            resolvedState = .charging
        } else if isFull {
            resolvedState = .full
        } else if acConnected {
            resolvedState = .notCharging
        } else {
            resolvedState = .discharging
        }

        return BatterySnapshot(
            currentChargePercentage: rawChargePercent,
            chargingState: resolvedState,
            isACPowerConnected: acConnected,
            cycleCount: cycleCount,
            currentMaxCapacity: currentMaxCapacity,
            designCapacity: designCapacity,
            healthPercentage: healthPercentage,
            condition: conditionString ?? "Normal",
            temperatureCelsius: tempCelsius,
            amperage: amperage,
            voltage: voltageVolts,
            timestamp: Date()
        )
    }
}
