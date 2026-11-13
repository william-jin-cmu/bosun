import Foundation
import IOKit
import CBridge

// Temperature and fan sensors for the system monitor.
//
// Two sources, both opened once and reused across calls:
//   * AppleSMC user client: fans (FNum / F<n>Ac / F<n>Mn / F<n>Mx) and the per-core
//     CPU / GPU die temperature keys (Tp**, Tg**) plus battery (TB*T).
//   * IOHIDEventSystemClient thermal services (usage page 0xff00, usage 5): named
//     sensors such as "pACC MTR Temp Sensor*", "PMU tdie*", "gas gauge battery".
//     Used as a fallback when SMC has no usable CPU keys for this machine.
//
// Key tables and struct layouts follow the Stats app (github.com/exelban/stats, MIT).

struct SensorReading {
    /// °C. Mean of the CPU core die sensors that returned a plausible value
    /// (SMC `Tp**` core keys; falls back to the HID "pACC/eACC MTR Temp Sensor*"
    /// services, then to the HID "PMU tdie*" sensors). The mean is used rather
    /// than the max because single cores spike by 10-20 °C for a sample or two
    /// and make a menu bar readout jumpy; the max is exposed separately.
    /// Caveat for the last-resort fallback: "PMU tdie*" is the power-management IC
    /// die, which read ~15 °C below the SMC core sensors on an M1 Pro, so it is
    /// only an approximation of SoC temperature.
    var cpuTemperature: Double?
    /// One entry per fan reported by SMC `FNum`, actual RPM (`F<n>Ac`); empty if none.
    var fanRPMs: [Int] = []

    /// °C, hottest single CPU core die sensor from the same set as `cpuTemperature`.
    var cpuTemperatureMax: Double?
    /// °C, mean of the GPU die sensors (SMC `Tg**`), if any.
    var gpuTemperature: Double?
    /// °C, battery pack temperature (SMC `TB1T`/`TB2T`, else HID "gas gauge battery").
    var batteryTemperature: Double?
    /// Per-fan minimum / maximum RPM (`F<n>Mn` / `F<n>Mx`); same count as `fanRPMs`, 0 if unknown.
    var fanMinRPMs: [Int] = []
    var fanMaxRPMs: [Int] = []
}

enum Sensors {
    private static let lock = NSLock()
    private static var smc = SMCConnection()
    private static var hid = HIDThermalSensors()
    private static var cpuKeys: [String]?      // SMC keys that exist on this machine
    private static var gpuKeys: [String]?
    private static var batteryKeys: [String]?
    private static var fanLimits: [(min: Int, max: Int)] = []

    /// Thread-safe; serialised by an internal lock. Measured on an M1 Pro: ~20 ms for the
    /// first call (opens AppleSMC, probes the key tables), ~3.5 ms afterwards (about 18
    /// SMC round trips). The HID path costs ~60 ms per sweep, which is why it is only a
    /// fallback and never runs when SMC answers.
    static func read() -> SensorReading {
        lock.lock()
        defer { lock.unlock() }

        var reading = SensorReading()

        // Fans.
        if let count = fanCountLocked() {
            if fanLimits.count != count {
                fanLimits = (0..<count).map { i in
                    (min: Int(smc.value("F\(i)Mn") ?? 0), max: Int(smc.value("F\(i)Mx") ?? 0))
                }
            }
            for i in 0..<count {
                // A stopped fan reads 0 (or slightly negative noise on flt keys).
                let rpm = smc.value("F\(i)Ac") ?? 0
                reading.fanRPMs.append(max(0, Int(rpm.rounded())))
                reading.fanMinRPMs.append(fanLimits[i].min)
                reading.fanMaxRPMs.append(fanLimits[i].max)
            }
        }

        // Temperatures via SMC. Which keys exist is probed once and cached.
        if smc.isOpen {
            if cpuKeys == nil { cpuKeys = SMCKeyTable.cpuCores.filter { smc.value($0) != nil } }
            if gpuKeys == nil { gpuKeys = SMCKeyTable.gpu.filter { smc.value($0) != nil } }
            if batteryKeys == nil { batteryKeys = SMCKeyTable.battery.filter { smc.value($0) != nil } }
        }
        let cpu = plausible((cpuKeys ?? []).compactMap { smc.value($0) })
        let gpu = plausible((gpuKeys ?? []).compactMap { smc.value($0) })
        let battery = plausible((batteryKeys ?? []).compactMap { smc.value($0) })

        reading.cpuTemperature = mean(cpu)
        reading.cpuTemperatureMax = cpu.max()
        reading.gpuTemperature = mean(gpu)
        reading.batteryTemperature = mean(battery)

        // HID fallback, only consulted when SMC left something missing.
        if reading.cpuTemperature == nil || reading.batteryTemperature == nil {
            let named = hid.read()
            if reading.cpuTemperature == nil {
                var cores = plausible(named.filter {
                    $0.name.hasPrefix("pACC MTR Temp") || $0.name.hasPrefix("eACC MTR Temp")
                }.map(\.value))
                if cores.isEmpty {
                    cores = plausible(named.filter { $0.name.hasPrefix("PMU tdie") }.map(\.value))
                }
                reading.cpuTemperature = mean(cores)
                reading.cpuTemperatureMax = cores.max()
            }
            if reading.batteryTemperature == nil {
                reading.batteryTemperature = mean(plausible(
                    named.filter { $0.name == "gas gauge battery" }.map(\.value)))
            }
        }
        return reading
    }

    /// Fan count straight from SMC `FNum`, or nil if SMC is unavailable.
    static func smcFanCount() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return fanCountLocked()
    }

    /// Every named HID thermal sensor, for diagnostics.
    static func hidTemperatures() -> [(name: String, value: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return hid.read()
    }

    /// Raw SMC value for a four-character key, for diagnostics.
    static func smcValue(_ key: String) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        return smc.value(key)
    }

    private static func fanCountLocked() -> Int? {
        guard let n = smc.value("FNum"), n >= 0, n <= 16 else { return nil }
        return Int(n)
    }

    /// Drops unpopulated / glitching sensors (0, negative, or absurd readings).
    private static func plausible(_ values: [Double]) -> [Double] {
        values.filter { $0.isFinite && $0 > 1 && $0 < 130 }
    }

    private static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}

// MARK: - SMC key tables

/// Candidate keys; only those the SMC actually answers for are used. Union of the
/// Stats tables for the M1 through M4 generations, since the key set differs per SoC.
private enum SMCKeyTable {
    static let cpuCores: [String] = [
        // M1 / M1 Pro / M1 Max / M1 Ultra
        "Tp09", "Tp0T", "Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b",
        // M2 generation
        "Tp1h", "Tp1t", "Tp1p", "Tp1l", "Tp0f", "Tp0j",
        // M3 generation
        "Te05", "Te0L", "Te0P", "Te0S", "Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E",
        "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E",
        // M4 generation
        "Te09", "Te0H", "Tp0V", "Tp0Y", "Tp0e",
    ]
    static let gpu: [String] = [
        "Tg05", "Tg0D", "Tg0L", "Tg0T",          // M1 generation
        "Tg0f", "Tg0j",                          // M2 / M3
        "Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A",   // M3
        "Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0d", "Tg0e", "Tg0k",   // M4
    ]
    static let battery: [String] = ["TB1T", "TB2T"]
}

// MARK: - AppleSMC connection

/// One long-lived AppleSMC user client. Not thread-safe on its own; `Sensors.lock` guards it.
private struct SMCConnection {
    private var conn: io_connect_t = 0
    private var lastOpenAttempt: TimeInterval = -.infinity
    private var keyInfo: [UInt32: BosunSMCKeyInfo] = [:]
    private var missing: Set<UInt32> = []

    var isOpen: Bool { conn != 0 }

    /// Numeric value of a key, or nil if the key is absent / unreadable / of an unknown type.
    mutating func value(_ key: String) -> Double? {
        guard let code = fourCC(key), !missing.contains(code), open() else { return nil }

        let info: BosunSMCKeyInfo
        if let cached = keyInfo[code] {
            info = cached
        } else {
            var input = BosunSMCParamStruct()
            input.key = code
            input.data8 = UInt8(kBosunSMCReadKeyInfo)
            guard let output = call(&input) else { return nil }
            if Int(output.result) == kBosunSMCResultKeyNotFound || output.keyInfo.dataSize == 0 {
                missing.insert(code)
                return nil
            }
            guard output.result == 0, output.keyInfo.dataSize <= 32 else { return nil }
            info = output.keyInfo
            keyInfo[code] = info
        }

        var input = BosunSMCParamStruct()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = UInt8(kBosunSMCReadBytes)
        guard let output = call(&input), output.result == 0 else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }
        return decode(bytes, type: info.dataType)
    }

    private mutating func open() -> Bool {
        if conn != 0 { return true }
        // Rate-limit retries so a missing service never costs a lookup per poll.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastOpenAttempt > 10 else { return false }
        lastOpenAttempt = now

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var c: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &c) == kIOReturnSuccess else { return false }
        conn = c
        return true
    }

    private mutating func call(_ input: inout BosunSMCParamStruct) -> BosunSMCParamStruct? {
        var output = BosunSMCParamStruct()
        var outputSize = MemoryLayout<BosunSMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, UInt32(kBosunSMCHandleYPCEvent),
                                           &input, MemoryLayout<BosunSMCParamStruct>.stride,
                                           &output, &outputSize)
        if kr == kIOReturnSuccess { return output }
        // Transport-level failures that mean the connection itself is dead: drop it
        // and reopen (rate-limited) on a later poll. Per-key errors keep the connection.
        if kr == MACH_SEND_INVALID_DEST || kr == kIOReturnNotOpen || kr == kIOReturnNoDevice
            || kr == kIOReturnNotAttached || kr == kIOReturnOffline {
            IOServiceClose(conn)
            conn = 0
            keyInfo.removeAll()
        }
        return nil
    }

    private func fourCC(_ s: String) -> UInt32? {
        let u = Array(s.utf8)
        guard u.count == 4 else { return nil }
        return u.reduce(0) { $0 << 8 | UInt32($1) }
    }

    private func decode(_ b: [UInt8], type: UInt32) -> Double? {
        func be(_ n: Int) -> UInt32 { b.prefix(n).reduce(0) { $0 << 8 | UInt32($1) } }
        switch type {
        case 0x666c7420 /* 'flt ' */ where b.count == 4:
            // Apple Silicon: native little-endian IEEE float.
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case 0x75693820 /* 'ui8 ' */ where b.count == 1: return Double(b[0])
        case 0x75693136 /* 'ui16' */ where b.count == 2: return Double(be(2))
        case 0x75693332 /* 'ui32' */ where b.count == 4: return Double(be(4))
        case 0x66706532 /* 'fpe2' */ where b.count == 2: return Double(be(2)) / 4       // Intel fans
        case 0x73703738 /* 'sp78' */ where b.count == 2:                                // Intel temps
            return Double(Int16(bitPattern: UInt16(be(2)))) / 256
        default: return nil
        }
    }
}

// MARK: - IOHIDEventSystem thermal sensors

/// One long-lived HID event system client matching the Apple vendor temperature
/// sensors. Not thread-safe on its own; `Sensors.lock` guards it.
private struct HIDThermalSensors {
    private var client: IOHIDEventSystemClient?
    private var services: [(name: String, service: IOHIDServiceClient)] = []
    private var lastDiscovery: TimeInterval = -.infinity

    mutating func read() -> [(name: String, value: Double)] {
        let now = ProcessInfo.processInfo.systemUptime
        if client == nil {
            guard let c = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }
            let matching: [String: Int] = [
                "PrimaryUsagePage": Int(kBosunHIDPageAppleVendor),
                "PrimaryUsage": Int(kBosunHIDUsageAppleVendorTemperature),
            ]
            _ = IOHIDEventSystemClientSetMatching(c, matching as CFDictionary)
            client = c
            lastDiscovery = -.infinity
        }
        // Re-enumerate occasionally (sleep/wake can replace services), sooner if empty.
        if now - lastDiscovery > (services.isEmpty ? 10 : 60), let client {
            lastDiscovery = now
            let list = (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
            services = list.compactMap { service in
                guard let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
                else { return nil }
                return (name, service)
            }
        }

        var out: [(name: String, value: Double)] = []
        out.reserveCapacity(services.count)
        for (name, service) in services {
            guard let event = IOHIDServiceClientCopyEvent(
                service, Int64(kBosunHIDEventTypeTemperature), 0, 0) else { continue }
            let value = IOHIDEventGetFloatValue(event, Int32(kBosunHIDEventFieldTemperatureLevel))
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(event)).release()
            out.append((name, value))
        }
        if out.isEmpty && !services.isEmpty {
            // Everything went stale (seen after wake): rebuild the client next time.
            services = []
            client = nil
        }
        return out
    }
}

// MARK: - Self-test

enum SensorsChecks {
    static let all: [SelfTest.Check] = [
        (name: "sensors: CPU temperature present and 10-110 °C", run: {
            guard let t = Sensors.read().cpuTemperature else { return "no CPU temperature from SMC or HID" }
            return (10...110).contains(t) ? nil : String(format: "CPU temperature %.1f °C out of range", t)
        }),
        (name: "sensors: fan count matches SMC FNum, RPMs 0-10000", run: {
            guard let expected = Sensors.smcFanCount() else { return "SMC FNum unreadable" }
            let reading = Sensors.read()
            if reading.fanRPMs.count != expected {
                return "read() returned \(reading.fanRPMs.count) fans, SMC FNum says \(expected)"
            }
            if let bad = reading.fanRPMs.first(where: { !(0...10000).contains($0) }) {
                return "fan RPM \(bad) out of range (\(reading.fanRPMs))"
            }
            return nil
        }),
    ]
}
