import Foundation
import IOKit

struct GPUInfo: Equatable {
    var model: String = ""
    var utilization: Double = 0       // 0...1, "Device Utilization %"
    var renderer: Double?             // 0...1
    var tiler: Double?                // 0...1
    var memoryInUse: UInt64?          // bytes of system memory the GPU has in use

    /// `stats` is the IOAccelerator "PerformanceStatistics" dictionary.
    static func parse(_ stats: [String: Any], model: String) -> GPUInfo? {
        func percent(_ key: String) -> Double? {
            (stats[key] as? NSNumber).map { min(1, max(0, $0.doubleValue / 100)) }
        }
        guard let device = percent("Device Utilization %") ?? percent("GPU Activity(%)") else { return nil }
        return GPUInfo(model: model, utilization: device,
                       renderer: percent("Renderer Utilization %"), tiler: percent("Tiler Utilization %"),
                       memoryInUse: (stats["In use system memory"] as? NSNumber)?.uint64Value)
    }
}

/// Reads the busiest IOAccelerator's performance statistics (what Stats and Activity
/// Monitor's GPU history use). The matched services are kept, so a read is one registry
/// property fetch per GPU. Touch from one queue only.
final class GPUSampler {
    private var services: [(service: io_object_t, model: String)] = []
    private var discoveredAt: TimeInterval = -.infinity

    deinit { services.forEach { IOObjectRelease($0.service) } }

    func sample() -> GPUInfo? {
        let now = ProcessInfo.processInfo.systemUptime
        if services.isEmpty ? now - discoveredAt > 30 : now - discoveredAt > 300 { discover(now) }
        var best: GPUInfo?
        for (service, model) in services {
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any], let info = GPUInfo.parse(stats, model: model) else { continue }
            if best == nil || info.utilization > best!.utilization { best = info }
        }
        return best
    }

    private func discover(_ now: TimeInterval) {
        discoveredAt = now
        services.forEach { IOObjectRelease($0.service) }
        services = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            var name = model as? String ?? ""
            if name.isEmpty, let data = model as? Data { name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
            services.append((service, name))
        }
    }
}
