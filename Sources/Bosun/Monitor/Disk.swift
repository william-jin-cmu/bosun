import Foundation
import IOKit

struct VolumeInfo: Identifiable, Equatable {
    var path: String
    var name: String
    var total: Int64
    var available: Int64      // what Finder calls "available" (includes purgeable space) where the system reports it
    var isBoot = false
    var isInternal = true
    var isNetwork = false
    var isEjectable = false
    var id: String { path }
    var usedFraction: Double { total > 0 ? min(1, max(0, 1 - Double(available) / Double(total))) : 0 }
    var kind: String { isNetwork ? "Network" : isBoot ? "Startup disk" : isInternal ? "Internal" : "External" }
}

struct DiskReading {
    var volumes: [VolumeInfo] = []
    var readRate: Double?     // bytes per second across all block devices; nil until two samples exist
    var writeRate: Double?
    var boot: VolumeInfo? { volumes.first(where: \.isBoot) ?? volumes.first }
}

enum DiskVolumes {
    private static let keys: Set<URLResourceKey> = [
        .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeIsInternalKey, .volumeIsLocalKey,
        .volumeIsEjectableKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
    ]

    /// Every user-visible mounted volume, startup disk first. Does not touch the disks
    /// themselves (statfs-level information), so it will not spin up a sleeping drive.
    static func read() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        var volumes: [VolumeInfo] = []
        for url in urls {
            // mountedVolumeURLs hands back fresh URLs, so the resource values are not stale.
            guard let values = try? url.resourceValues(forKeys: keys),
                  let total = values.volumeTotalCapacity, total > 0 else { continue }
            let important = values.volumeAvailableCapacityForImportantUsage ?? 0
            volumes.append(VolumeInfo(
                path: url.path,
                name: values.volumeName ?? url.lastPathComponent,
                total: Int64(total),
                // "Important usage" is 0 on file systems that have no purgeable accounting (exFAT, SMB).
                available: important > 0 ? important : Int64(values.volumeAvailableCapacity ?? 0),
                isBoot: values.volumeIsRootFileSystem ?? (url.path == "/"),
                isInternal: values.volumeIsInternal ?? false,
                isNetwork: !(values.volumeIsLocal ?? true),
                isEjectable: values.volumeIsEjectable ?? false))
        }
        return sorted(volumes)
    }

    static func sorted(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        volumes.sorted { a, b in
            if a.isBoot != b.isBoot { return a.isBoot }
            if a.isInternal != b.isInternal { return a.isInternal }
            if a.isNetwork != b.isNetwork { return !a.isNetwork }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}

/// Read / write throughput summed over every IOBlockStorageDriver (the source Stats uses).
final class DiskIOSampler {
    private var previous: (read: UInt64, written: UInt64, at: TimeInterval)?

    func sample() -> (read: Double, write: Double)? {
        guard let now = Self.counters() else { return nil }
        let at = ProcessInfo.processInfo.systemUptime
        defer { previous = (now.read, now.written, at) }
        // After a gap (panel was closed) the first delta would average over the whole gap.
        guard let previous, at > previous.at, at - previous.at < 30,
              now.read >= previous.read, now.written >= previous.written else { return nil }
        let dt = at - previous.at
        return (Double(now.read - previous.read) / dt, Double(now.written - previous.written) / dt)
    }

    func reset() { previous = nil }

    static func counters() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0, found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            found = true
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? (read, written) : nil
    }
}
