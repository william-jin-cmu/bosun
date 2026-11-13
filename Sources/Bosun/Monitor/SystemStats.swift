import Foundation
import Darwin

/// Raw samplers. Each keeps the previous counters so `sample()` returns a rate.
final class CPUSampler {
    private var previous: [(busy: UInt64, total: UInt64)] = []

    /// Returns overall usage 0...1 and per-core usage 0...1.
    func sample() -> (total: Double, cores: [Double]) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, []) }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var current: [(busy: UInt64, total: UInt64)] = []
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            let user = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            let nice = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
            let idle = UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            current.append((user + system + nice, user + system + nice + idle))
        }
        defer { previous = current }
        guard previous.count == current.count else { return (0, Array(repeating: 0, count: current.count)) }
        var cores: [Double] = []
        var busySum: UInt64 = 0, totalSum: UInt64 = 0
        for (now, before) in zip(current, previous) {
            // Tick counters are 32-bit and wrap; wrapping subtraction keeps deltas right.
            let busy = UInt64(UInt32(truncatingIfNeeded: now.busy) &- UInt32(truncatingIfNeeded: before.busy))
            let total = UInt64(UInt32(truncatingIfNeeded: now.total) &- UInt32(truncatingIfNeeded: before.total))
            cores.append(total == 0 ? 0 : min(1, Double(busy) / Double(total)))
            busySum += busy
            totalSum += total
        }
        return (totalSum == 0 ? 0 : min(1, Double(busySum) / Double(totalSum)), cores)
    }
}

struct MemoryUsage {
    var used: UInt64 = 0
    var total: UInt64 = ProcessInfo.processInfo.physicalMemory
    var compressed: UInt64 = 0
    var swapUsed: UInt64 = 0
    var fraction: Double { total == 0 ? 0 : Double(used) / Double(total) }

    /// "Used" follows Activity Monitor: app memory + wired + compressed.
    static func read() -> MemoryUsage {
        var usage = MemoryUsage()
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return usage }
        let page = UInt64(vm_kernel_page_size)
        let app = UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)
        usage.compressed = UInt64(stats.compressor_page_count) * page
        usage.used = min(usage.total, (app + UInt64(stats.wire_count)) * page + usage.compressed)
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.stride
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 { usage.swapUsed = swap.xsu_used }
        return usage
    }
}

final class NetworkSampler {
    private var previous: (rx: UInt64, tx: UInt64, at: TimeInterval)?

    /// Bytes per second across physical interfaces (en*), 0 on the first call.
    func sample() -> (down: Double, up: Double) {
        let (rx, tx) = Self.totals()
        let now = ProcessInfo.processInfo.systemUptime
        defer { previous = (rx, tx, now) }
        guard let previous, now > previous.at, rx >= previous.rx, tx >= previous.tx else { return (0, 0) }
        let dt = now - previous.at
        return (Double(rx - previous.rx) / dt, Double(tx - previous.tx) / dt)
    }

    /// 64-bit per-interface counters via the routing sysctl (getifaddrs only exposes 32-bit ones).
    static func totals() -> (rx: UInt64, tx: UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return (0, 0) }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return (0, 0) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(info.ifm_index), &name) != nil, String(cString: name).hasPrefix("en") {
                        rx += info.ifm_data.ifi_ibytes
                        tx += info.ifm_data.ifi_obytes
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        return (rx, tx)
    }
}

struct DiskUsage {
    var available: Int64 = 0
    var total: Int64 = 0
    static func read() -> DiskUsage {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        return DiskUsage(available: values?.volumeAvailableCapacityForImportantUsage ?? 0,
                         total: Int64(values?.volumeTotalCapacity ?? 0))
    }
}

struct ProcessLoad: Identifiable {
    let pid: Int32
    let name: String
    let cpu: Double      // percent of one core, as ps reports it
    var id: Int32 { pid }

    /// Top CPU consumers. Shells out to ps, so only call while the panel is open.
    static func top(_ limit: Int) -> [ProcessLoad] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-Aceo", "pid=,pcpu=,comm=", "-r"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self), limit: limit)
    }

    static func parse(_ output: String, limit: Int) -> [ProcessLoad] {
        var result: [ProcessLoad] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let cpu = Double(parts[1]) else { continue }
            result.append(ProcessLoad(pid: pid, name: String(parts[2]), cpu: cpu))
            if result.count == limit { break }
        }
        return result
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .memory)
    }
    static func disk(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    /// Compact transfer rate: "0 K", "12 K", "3.4 M".
    static func rate(_ bytesPerSecond: Double) -> String {
        let kb = bytesPerSecond / 1024
        if kb < 1000 { return "\(Int(kb.rounded())) K" }
        let mb = kb / 1024
        return mb < 100 ? String(format: "%.1f M", mb) : "\(Int(mb.rounded())) M"
    }
    static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}
