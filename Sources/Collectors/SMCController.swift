import Foundation
import IOKit

/// Diagnostic information about an SMC key on the current machine.
public struct SMCKeyInfo: Equatable, Codable {
    public let key: String
    public let exists: Bool
    public let dataType: String
    public let dataSize: Int
    
    public init(key: String, exists: Bool, dataType: String = "", dataSize: Int = 0) {
        self.key = key
        self.exists = exists
        self.dataType = dataType
        self.dataSize = dataSize
    }
}

/// Result for SMC write attempts.
public enum SMCWriteResult: Equatable {
    /// In this phase, writing to SMC is deliberately unsupported regardless of privileges.
    case unsupported
}

/// Read-only SMC controller for hardware capability detection.
///
/// SAFETY & INTEGRITY NOTE:
/// This class strictly performs READ-ONLY queries to AppleSMC to discover hardware
/// capabilities. In this phase, all write calls unconditionally return `.unsupported`
/// without dispatching any write requests to hardware or IOKit drivers.
public final class SMCController {
    
    // MARK: - Internal SMC Structures
    
    private struct SMCVersion {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
                        0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0,
                        0, 0, 0, 0, 0, 0, 0, 0
                    )
    }

    // MARK: - Public Properties
    
    /// Target keys known across Apple Silicon and Intel generations for charge management:
    /// - CHTE: Tahoe PMU charge inhibit (M3/M4 Apple Silicon)
    /// - CHIE: Adapter inhibit / force discharge (Apple Silicon)
    /// - CH0B: Charge inhibit (M1/M2 Apple Silicon)
    /// - CH0C: Cell inhibit (M1/M2 Apple Silicon)
    /// - BCLM: Battery Charge Limit Maximum (Intel Macs)
    public static let targetChargeKeys = ["CHTE", "CHIE", "CH0B", "CH0C", "BCLM"]
    
    public init() {}
    
    // MARK: - Hardware Detection (Read-Only)
    
    /// Scans the system's AppleSMC for known charge-related keys using unprivileged read queries.
    public func detectHardwareKeys() -> [String: SMCKeyInfo] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else {
            print("[SMCController] AppleSMC service not found.")
            return [:]
        }
        
        var conn: io_connect_t = 0
        let openRes = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        
        guard openRes == KERN_SUCCESS else {
            print("[SMCController] Failed to open AppleSMC connection: \(openRes)")
            return [:]
        }
        defer { IOServiceClose(conn) }
        
        var results: [String: SMCKeyInfo] = [:]
        for keyStr in Self.targetChargeKeys {
            results[keyStr] = queryKeyInfo(keyStr: keyStr, conn: conn)
        }
        return results
    }
    
    /// Returns true if this machine's SMC possesses at least one recognized charge control key.
    public func isHardwareInhibitKeyDetected() -> Bool {
        let keys = detectHardwareKeys()
        return (keys["CHTE"]?.exists == true) ||
               (keys["CH0B"]?.exists == true) ||
               (keys["CH0C"]?.exists == true) ||
               (keys["BCLM"]?.exists == true)
    }
    
    // MARK: - Write Stub (Unconditionally Unsupported)
    
    /// Unconditionally returns `.unsupported`.
    ///
    /// Per project specification, direct SMC writes are not implemented in this phase
    /// to avoid any risks associated with undocumented power-delivery hardware keys.
    public func write(key: String, bytes: [UInt8]) -> SMCWriteResult {
        // Deliberately no-op and unsupported across all execution modes and privilege levels.
        return .unsupported
    }
    
    // MARK: - Private Helpers
    
    private func queryKeyInfo(keyStr: String, conn: io_connect_t) -> SMCKeyInfo {
        let key = fourCharCode(keyStr)
        var input = SMCParamStruct()
        input.key = key
        input.data8 = 9 // kSMCGetKeyInfo
        
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.size
        
        let callRes = IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCParamStruct>.size, &output, &outSize)
        let exists = (callRes == KERN_SUCCESS && output.result == 0)
        let typeStr = exists ? codeToString(output.keyInfo.dataType) : ""
        let size = exists ? Int(output.keyInfo.dataSize) : 0
        
        return SMCKeyInfo(key: keyStr, exists: exists, dataType: typeStr, dataSize: size)
    }
    
    private func fourCharCode(_ str: String) -> UInt32 {
        var res: UInt32 = 0
        for char in str.utf8 {
            res = (res << 8) | UInt32(char)
        }
        return res
    }

    private func codeToString(_ code: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "????"
    }
}
