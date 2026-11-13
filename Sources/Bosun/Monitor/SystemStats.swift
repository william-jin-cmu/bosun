import Foundation
import Darwin
import IOKit

// Raw CPU / memory / load readers. Sources follow the Stats app
// (github.com/exelban/stats, MIT): host_processor_info for per-core ticks,
// host_statistics64 for the VM counters, sysctl for swap / pressure / load.

struct CPULoad {
    var total: Double = 0          // 0...1 across all cores
    var user: Double = 0           // 0...1, user + nice
    var system: Double = 0         // 0...1
    var cores: [Double] = []       // 0...1 per logical CPU, in kernel order
    var idle: Double { max(0, 1 - user - system) }
}

/// Keeps the previous tick counters so `sample()` returns usage since the last call.
final class CPUSampler {
    private var previous: [(user: UInt32, system: UInt32, idle: UInt32)] = []

    func sample() -> CPULoad {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return CPULoad() }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var current: [(user: UInt32, system: UInt32, idle: UInt32)] = []
        current.reserveCapacity(Int(count))
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]) &+ UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)])
            current.append((user, UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                            UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)])))
        }
        defer { previous = current }
        guard previous.count == current.count else {
            return CPULoad(cores: Array(repeating: 0, count: current.count))
        }
        var load = CPULoad()
        var userSum: UInt64 = 0, systemSum: UInt64 = 0, totalSum: UInt64 = 0
        for (now, before) in zip(current, previous) {
            // Tick counters are 32-bit and wrap; wrapping subtraction keeps deltas right.
            let user = UInt64(now.user &- before.user)
            let system = UInt64(now.system &- before.system)
            let total = user + system + UInt64(now.idle &- before.idle)
            load.cores.append(total == 0 ? 0 : min(1, Double(user + system) / Double(total)))
            userSum += user
            systemSum += system
            totalSum += total
        }
        if totalSum > 0 {
            load.user = Double(userSum) / Double(totalSum)
            load.system = Double(systemSum) / Double(totalSum)
            load.total = min(1, load.user + load.system)
        }
        return load
    }
}

/// Which logical CPUs are efficiency cores and which are performance cores.
struct CPUTopology {
    struct Cluster: Equatable {
        var name: String         // "Efficiency", "Performance", or "Cores"
        var prefix: String       // "E", "P", or ""
        var indices: [Int]       // logical CPU numbers, matching CPULoad.cores
    }
    var clusters: [Cluster]

    func labels() -> [String] {
        var out: [Int: String] = [:]
        for cluster in clusters {
            for (n, index) in cluster.indices.enumerated() { out[index] = "\(cluster.prefix)\(n + 1)" }
        }
        return out.keys.sorted().map { out[$0]! }
    }

    /// Mean load of one cluster.
    static func mean(_ cores: [Double], _ cluster: Cluster) -> Double {
        let values = cluster.indices.compactMap { $0 < cores.count ? cores[$0] : nil }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    /// Builds clusters from one type letter per logical CPU ("E" / "P"); efficiency first.
    static func make(types: [Character]) -> CPUTopology {
        let efficiency = types.indices.filter { types[$0] == "E" }
        let performance = types.indices.filter { types[$0] == "P" }
        guard !efficiency.isEmpty, efficiency.count + performance.count == types.count else {
            return CPUTopology(clusters: [Cluster(name: "Cores", prefix: "", indices: Array(types.indices))])
        }
        var clusters = [Cluster(name: "Efficiency", prefix: "E", indices: efficiency)]
        if !performance.isEmpty { clusters.append(Cluster(name: "Performance", prefix: "P", indices: performance)) }
        return CPUTopology(clusters: clusters)
    }

    /// Read once: the `cluster-type` property of each IODeviceTree:/cpus child (what Stats
    /// uses); falls back to the hw.perflevel sysctls assuming efficiency cores come first.
    static let current: CPUTopology = {
        let count = ProcessInfo.processInfo.processorCount
        var types = [Character](repeating: "?", count: count)
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        if cpus != 0 {
            defer { IOObjectRelease(cpus) }
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(cpus, "IODeviceTree", &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                while case let child = IOIteratorNext(iterator), child != 0 {
                    defer { IOObjectRelease(child) }
                    func data(_ key: String) -> Data? {
                        IORegistryEntryCreateCFProperty(child, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
                    }
                    guard let type = data("cluster-type")?.first, let idData = data("logical-cpu-id") ?? data("cpu-id"),
                          let id = idData.first.map(Int.init), id < count else { continue }
                    types[id] = Character(UnicodeScalar(type))
                }
            }
        }
        if types.contains("?") {
            let performance = sysctlInt("hw.perflevel0.logicalcpu"), efficiency = sysctlInt("hw.perflevel1.logicalcpu")
            if sysctlInt("hw.nperflevels") == 2, performance + efficiency == count {
                types = Array(repeating: "E", count: efficiency) + Array(repeating: "P", count: performance)
            }
        }
        return make(types: types)
    }()

    static let chipName: String = sysctlString("machdep.cpu.brand_string")
}

func sysctlInt(_ name: String) -> Int {
    var value: Int64 = 0
    var size = MemoryLayout<Int64>.size
    return sysctlbyname(name, &value, &size, nil, 0) == 0 ? Int(value) : 0
}

func sysctlString(_ name: String) -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
    return String(cString: buffer)
}

struct MemoryUsage {
    enum Pressure: Int, Comparable {
        case normal = 1, warning = 2, critical = 4
        static func < (a: Pressure, b: Pressure) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .normal: "Normal"
            case .warning: "Warning"
            case .critical: "Critical"
            }
        }
    }

    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var app: UInt64 = 0          // anonymous memory minus purgeable
    var wired: UInt64 = 0
    var compressed: UInt64 = 0   // physical pages held by the compressor
    var cached: UInt64 = 0       // file-backed + purgeable ("Cached Files" in Activity Monitor)
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pressure: Pressure = .normal

    /// "Memory Used" as Activity Monitor shows it: app + wired + compressed.
    var used: UInt64 { min(total, app + wired + compressed) }
    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    static func read() -> MemoryUsage {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        var usage = result == KERN_SUCCESS ? make(stats, pageSize: UInt64(vm_kernel_page_size)) : MemoryUsage()
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            usage.swapUsed = swap.xsu_used
            usage.swapTotal = swap.xsu_total
        }
        var level: Int32 = 0
        var levelSize = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0) == 0 {
            usage.pressure = Pressure(rawValue: Int(level)) ?? .normal
        }
        return usage
    }

    static func make(_ stats: vm_statistics64, pageSize page: UInt64,
                     total: UInt64 = ProcessInfo.processInfo.physicalMemory) -> MemoryUsage {
        var usage = MemoryUsage(total: total)
        let purgeable = UInt64(stats.purgeable_count)
        let anonymous = UInt64(stats.internal_page_count)
        usage.app = (anonymous > purgeable ? anonymous - purgeable : 0) * page
        usage.wired = UInt64(stats.wire_count) * page
        usage.compressed = UInt64(stats.compressor_page_count) * page
        usage.cached = (UInt64(stats.external_page_count) + purgeable) * page
        let speculative = UInt64(stats.speculative_count), free = UInt64(stats.free_count)
        usage.free = (free > speculative ? free - speculative : 0) * page
        return usage
    }
}

struct SystemLoad {
    var one: Double = 0, five: Double = 0, fifteen: Double = 0
    var bootTime: Date?

    static func read() -> SystemLoad {
        var averages = [Double](repeating: 0, count: 3)
        var load = SystemLoad()
        if getloadavg(&averages, 3) == 3 { (load.one, load.five, load.fifteen) = (averages[0], averages[1], averages[2]) }
        load.bootTime = boot
        return load
    }

    static let boot: Date? = {
        var time = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1e6)
    }()
}

enum Format {
    static func bytes(_ value: Int64) -> String { byteCount(value, .memory) }
    static func bytes(_ value: UInt64) -> String { bytes(Int64(clamping: value)) }
    static func disk(_ value: Int64) -> String { byteCount(value, .file) }
    /// A formatter per call: ByteCountFormatter is not documented as thread-safe and this is
    /// used from both the main thread and the sampling queue. "0 KB" rather than "Zero KB".
    private static func byteCount(_ value: Int64, _ style: ByteCountFormatter.CountStyle) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: value)
    }
    /// Compact transfer rate without the unit suffix: "0 K", "12 K", "3.4 M", "1.2 G".
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = max(0, bytesPerSecond) / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) K" }
        let mb = kb / 1024
        if mb < 100 { return String(format: "%.1f M", mb) }
        if mb < 1000 { return "\(Int(mb.rounded())) M" }
        return String(format: "%.1f G", mb / 1024)
    }
    /// "12 KB/s"
    static func speed(_ bytesPerSecond: Double) -> String { rate(bytesPerSecond) + "B/s" }
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    /// "48 °C" / "118 °F".
    static func temperature(_ celsius: Double, fahrenheit: Bool, digits: Int = 0) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return String(format: "%.\(digits)f °%@", value, fahrenheit ? "F" : "C")
    }
    /// "48°" for the menu bar.
    static func degrees(_ celsius: Double, fahrenheit: Bool) -> String {
        "\(Int((fahrenheit ? celsius * 9 / 5 + 32 : celsius).rounded()))°"
    }

    /// "45 s", "12 min", "3 h 05 min", "16 d 4 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return String(format: "%d h %02d min", hours, minutes % 60) }
        return "\(hours / 24) d \(hours % 24) h"
    }
}
