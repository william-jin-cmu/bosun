import Foundation
import IOKit
import CBridge

// Temperature, fan and power sensors for the system monitor.
//
// Two sources, both opened once and reused across calls:
//   * AppleSMC user client: fans (FNum / F<n>Ac / F<n>Mn / F<n>Mx), the per-core
//     CPU / GPU die temperature keys (Tp**, Tg**), battery (TB*T), system power (PSTR)
//     and the charge limit (CHLT).
//   * IOHIDEventSystemClient thermal services (usage page 0xff00, usage 5): named
//     sensors such as "pACC MTR Temp Sensor*", "PMU tdie*", "gas gauge battery".
//     Used as a fallback when SMC has no usable CPU keys for this machine.
//
// Key tables and struct layouts follow the Stats app (github.com/exelban/stats, MIT).

struct NamedSensor: Identifiable, Equatable {
    enum Group: String, CaseIterable {
        case cpu = "CPU", gpu = "GPU", memory = "Memory", storage = "Storage", battery = "Battery"
        case airflow = "Airflow", system = "System", unnamed = "Other SMC sensors"
    }
    var key: String        // SMC four-character key
    var name: String
    var group: Group
    var celsius: Double
    var id: String { key }
}

struct FanReading: Equatable {
    var rpm: Int
    var min: Int           // 0 if unknown
    var max: Int           // 0 if unknown
    /// Position between the fan's minimum and maximum speed, 0...1; nil if the limits are unknown.
    var fraction: Double? {
        guard max > min, min >= 0 else { return nil }
        return Swift.min(1, Swift.max(0, Double(rpm - min) / Double(max - min)))
    }
}

struct SensorReading {
    /// °C. Mean of the CPU core die sensors that returned a plausible value
    /// (SMC `Tp**` core keys for this chip generation; falls back to the HID
    /// "pACC/eACC MTR Temp Sensor*" services, then to the HID "PMU tdie*" sensors).
    /// The mean is used rather than the max because single cores spike by 10-20 °C
    /// for a sample or two and make a menu bar readout jumpy; the max is exposed separately.
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
    /// Watts drawn by the whole system (SMC `PSTR`), if the key exists.
    var systemPower: Double?
    /// Every sensor in the catalogue that exists on this Mac (`.named`), plus the
    /// uncatalogued SMC temperature keys (`.all`). Empty for the cheaper levels.
    var named: [NamedSensor] = []

    var fans: [FanReading] {
        fanRPMs.indices.map { i in
            FanReading(rpm: fanRPMs[i], min: i < fanMinRPMs.count ? fanMinRPMs[i] : 0,
                       max: i < fanMaxRPMs.count ? fanMaxRPMs[i] : 0)
        }
    }
}

enum Sensors {
    /// How much to read. Each level includes the ones before it.
    enum Detail: Int, Comparable {
        case cpu          // CPU core temperatures only (menu bar widget, temperature alert)
        case summary      // + GPU, battery, fans, system power
        case named        // + the catalogued sensor list
        case all          // + every other SMC temperature key, labelled by its key
        static func < (a: Detail, b: Detail) -> Bool { a.rawValue < b.rawValue }
    }

    private static let lock = NSLock()
    private static var smc = SMCConnection()
    private static var hid = HIDThermalSensors()
    private static var cpuKeys: [String]?      // SMC keys that exist on this machine
    private static var gpuKeys: [String]?
    private static var batteryKeys: [String]?
    private static var catalogue: [SensorCatalog.Entry]?
    private static var unnamedKeys: [String]?
    private static var fanLimits: [(min: Int, max: Int)] = []

    /// Thread-safe; serialised by an internal lock. Measured on an M1 Pro: ~20 ms for the
    /// first call (opens AppleSMC, probes the key tables), ~3.5 ms afterwards for `.summary`
    /// (about 18 SMC round trips). The HID path costs ~60 ms per sweep, which is why it is
    /// only a fallback and never runs when SMC answers.
    static func read(_ detail: Detail = .summary) -> SensorReading {
        lock.lock()
        defer { lock.unlock() }

        var reading = SensorReading()
        let generation = SensorCatalog.generation

        // Which keys exist is probed once and cached.
        if smc.isOpenOrOpens() {
            if cpuKeys == nil {
                let specific = SensorCatalog.cpuKeys(generation).filter { smc.value($0) != nil }
                cpuKeys = specific.isEmpty ? SensorCatalog.allCPUKeys.filter { smc.value($0) != nil } : specific
            }
        }
        var values: [String: Double] = [:]
        func value(_ key: String) -> Double? {
            if let cached = values[key] { return cached }
            let v = smc.value(key)
            if let v { values[key] = v }
            return v
        }
        let cpu = plausible((cpuKeys ?? []).compactMap { value($0) })
        reading.cpuTemperature = mean(cpu)
        reading.cpuTemperatureMax = cpu.max()

        if detail >= .summary {
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
            if smc.isOpen {
                if gpuKeys == nil {
                    let specific = SensorCatalog.gpuKeys(generation).filter { smc.value($0) != nil }
                    gpuKeys = specific.isEmpty ? SensorCatalog.allGPUKeys.filter { smc.value($0) != nil } : specific
                }
                if batteryKeys == nil { batteryKeys = SensorCatalog.batteryKeys.filter { smc.value($0) != nil } }
            }
            reading.gpuTemperature = mean(plausible((gpuKeys ?? []).compactMap { value($0) }))
            reading.batteryTemperature = mean(plausible((batteryKeys ?? []).compactMap { value($0) }))
            if let watts = smc.value("PSTR"), watts.isFinite, watts > 0, watts < 1000 { reading.systemPower = watts }
        }

        // HID fallback, only consulted when SMC left something missing.
        if reading.cpuTemperature == nil || (detail >= .summary && reading.batteryTemperature == nil) {
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
            if detail >= .summary, reading.batteryTemperature == nil {
                reading.batteryTemperature = mean(plausible(
                    named.filter { $0.name == "gas gauge battery" }.map(\.value)))
            }
        }

        if detail >= .named, smc.isOpen {
            if catalogue == nil {
                catalogue = SensorCatalog.entries(generation).filter { smc.value($0.key) != nil }
            }
            for entry in catalogue ?? [] {
                guard let v = value(entry.key), v.isFinite, v > 1, v < 130 else { continue }
                reading.named.append(NamedSensor(key: entry.key, name: entry.name, group: entry.group, celsius: v))
            }
        }
        if detail >= .all, smc.isOpen {
            if unnamedKeys == nil {
                let known = Set((catalogue ?? []).map(\.key))
                unnamedKeys = smc.allKeys().filter { $0.hasPrefix("T") && !known.contains($0) }
                    .filter { key in smc.value(key).map { $0.isFinite && $0 > 1 && $0 < 130 } ?? false }
                    .sorted()
            }
            for key in unnamedKeys ?? [] {
                guard let v = value(key), v.isFinite, v > 1, v < 130 else { continue }
                reading.named.append(NamedSensor(key: key, name: key, group: .unnamed, celsius: v))
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

    /// Raw bytes of a key whatever its type.
    static func smcBytes(_ key: String) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return smc.bytes(key)?.bytes
    }

    /// The battery charge limit set in System Settings > Battery > Charging, in percent,
    /// or nil when there is no limit (or the key is absent). SMC `CHLT`: first byte is the
    /// limit; it read 95 on an M1 Pro whose limit was set to 95 % (macOS 27).
    static func chargeLimit() -> Int? {
        guard let bytes = smcBytes("CHLT") else { return nil }
        return parseChargeLimit(bytes)
    }

    static func parseChargeLimit(_ bytes: [UInt8]) -> Int? {
        guard let first = bytes.first, (50..<100).contains(first) else { return nil }
        return Int(first)
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

// MARK: - Sensor catalogue

/// Which SMC key is which sensor. The same key means different things on different
/// chip generations (Tp09 is an efficiency core on M1 and a performance core on M2),
/// so the tables are per generation, as in Stats.
enum SensorCatalog {
    enum Generation: String { case m1, m2, m3, m4, m5, unknown }
    struct Entry: Equatable { var key: String; var name: String; var group: NamedSensor.Group }

    static let generation = generation(of: CPUTopology.chipName)

    static func generation(of brand: String) -> Generation {
        for candidate in [Generation.m1, .m2, .m3, .m4, .m5] {
            let tag = "Apple " + candidate.rawValue.uppercased()
            if brand == tag || brand.hasPrefix(tag + " ") { return candidate }
        }
        return .unknown
    }

    private static let efficiency: [Generation: [String]] = [
        .m1: ["Tp09", "Tp0T"],
        .m2: ["Tp1h", "Tp1t", "Tp1p", "Tp1l"],
        .m3: ["Te05", "Te0L", "Te0P", "Te0S"],
        .m4: ["Te05", "Te0S", "Te09", "Te0H"],
        .m5: ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K"],     // "super" cores
    ]
    private static let performance: [Generation: [String]] = [
        .m1: ["Tp01", "Tp05", "Tp0D", "Tp0H", "Tp0L", "Tp0P", "Tp0X", "Tp0b"],
        .m2: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0X", "Tp0b", "Tp0f", "Tp0j"],
        .m3: ["Tf04", "Tf09", "Tf0A", "Tf0B", "Tf0D", "Tf0E", "Tf44", "Tf49", "Tf4A", "Tf4B", "Tf4D", "Tf4E"],
        .m4: ["Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b", "Tp0e"],
        .m5: ["Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"],
    ]
    private static let gpu: [Generation: [String]] = [
        .m1: ["Tg05", "Tg0D", "Tg0L", "Tg0T"],
        .m2: ["Tg0f", "Tg0j"],
        .m3: ["Tf14", "Tf18", "Tf19", "Tf1A", "Tf24", "Tf28", "Tf29", "Tf2A"],
        .m4: ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"],
        .m5: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c", "Tg1g"],
    ]
    private static let memory: [Generation: [String]] = [
        .m1: ["Tm02", "Tm06", "Tm08", "Tm09"],
        .m4: ["Tm0p", "Tm1p", "Tm2p"],
    ]
    static let batteryKeys = ["TB1T", "TB2T"]

    static func cpuKeys(_ generation: Generation) -> [String] {
        (efficiency[generation] ?? []) + (performance[generation] ?? [])
    }
    static func gpuKeys(_ generation: Generation) -> [String] { gpu[generation] ?? [] }
    /// Union over every generation, for chips newer than the tables.
    static let allCPUKeys: [String] = unique([Generation.m1, .m2, .m3, .m4, .m5].flatMap { cpuKeys($0) })
    static let allGPUKeys: [String] = unique([Generation.m1, .m2, .m3, .m4, .m5].flatMap { gpuKeys($0) })

    private static func unique(_ keys: [String]) -> [String] {
        var seen: Set<String> = []
        return keys.filter { seen.insert($0).inserted }
    }

    /// Candidate sensors for a generation, in display order; the caller keeps those that exist.
    static func entries(_ generation: Generation) -> [Entry] {
        var out: [Entry] = []
        func add(_ keys: [String], _ label: String, _ group: NamedSensor.Group) {
            for (n, key) in keys.enumerated() {
                out.append(Entry(key: key, name: keys.count == 1 ? label : "\(label) \(n + 1)", group: group))
            }
        }
        if generation == .unknown {
            add(allCPUKeys, "CPU core sensor", .cpu)
            add(allGPUKeys, "GPU sensor", .gpu)
        } else {
            add(efficiency[generation] ?? [], generation == .m5 ? "Super core" : "Efficiency core", .cpu)
            add(performance[generation] ?? [], "Performance core", .cpu)
            add(gpu[generation] ?? [], "GPU", .gpu)
            add(memory[generation] ?? [], generation == .m4 ? "Memory proximity" : "Memory", .memory)
        }
        out.append(Entry(key: "TH0x", name: "SSD (NAND)", group: .storage))
        add(batteryKeys, "Battery", .battery)
        out.append(Entry(key: "TaLP", name: "Airflow left", group: .airflow))
        out.append(Entry(key: "TaRF", name: "Airflow right", group: .airflow))
        out.append(Entry(key: "TW0P", name: "Wi-Fi module", group: .system))
        return out
    }
}

// MARK: - AppleSMC connection

/// One long-lived AppleSMC user client. Not thread-safe on its own; `Sensors.lock` guards it.
private struct SMCConnection {
    private var conn: io_connect_t = 0
    private var lastOpenAttempt: TimeInterval = -.infinity
    private var keyInfo: [UInt32: BosunSMCKeyInfo] = [:]
    private var missing: Set<UInt32> = []

    var isOpen: Bool { conn != 0 }

    mutating func isOpenOrOpens() -> Bool { open() }

    /// Numeric value of a key, or nil if the key is absent / unreadable / of an unknown type.
    mutating func value(_ key: String) -> Double? {
        guard let raw = bytes(key) else { return nil }
        return decode(raw.bytes, type: raw.type)
    }

    /// Raw bytes and four-character type code of a key.
    mutating func bytes(_ key: String) -> (bytes: [UInt8], type: UInt32)? {
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

        return (withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.dataSize))) }, info.dataType)
    }

    /// Every key the SMC knows (`#KEY` count, then read-by-index). ~10 ms for ~2200 keys on an M1 Pro.
    mutating func allKeys() -> [String] {
        guard let count = value("#KEY"), count > 0, count < 20000 else { return [] }
        var keys: [String] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<UInt32(count) {
            var input = BosunSMCParamStruct()
            input.data8 = UInt8(kBosunSMCReadKeyAtIndex)
            input.data32 = index
            guard let output = call(&input), output.result == 0 else { continue }
            let code = output.key
            let scalars = [UInt8(code >> 24), UInt8(code >> 16 & 0xff), UInt8(code >> 8 & 0xff), UInt8(code & 0xff)]
            if let key = String(bytes: scalars, encoding: .ascii) { keys.append(key) }
        }
        return keys
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

