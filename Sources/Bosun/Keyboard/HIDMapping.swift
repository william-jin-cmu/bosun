import Foundation
import CBridge

/// The HID event system's `UserKeyMapping`: pure merge logic plus the two
/// system calls (read through IOHIDEventSystemClient, write through hidutil).
enum HIDMapping {
    struct Entry: Codable, Hashable {
        var src: UInt64
        var dst: UInt64
    }

    /// What Bosun last wrote, so exactly that can be taken back out later —
    /// including after a crash, since it is persisted.
    struct Applied: Codable, Equatable {
        var ours: [Entry] = []
        /// Foreign entries we overrode because they remapped the same key.
        var displaced: [Entry] = []
    }

    static let property = "UserKeyMapping"
    static let srcKey = "HIDKeyboardModifierMappingSrc"
    static let dstKey = "HIDKeyboardModifierMappingDst"

    // MARK: Pure logic

    /// Adds `ours` to `existing`. A foreign entry for a key we remap is set
    /// aside (one source key can only map once); everything else is kept.
    static func merge(existing: [Entry], ours: [Entry]) -> (merged: [Entry], applied: Applied) {
        var ownSources = Set<UInt64>()
        let own = ours.filter { ownSources.insert($0.src).inserted }
        var kept: [Entry] = [], displaced: [Entry] = []
        for entry in existing {
            if own.contains(entry) { continue }
            if ownSources.contains(entry.src) { displaced.append(entry) } else { kept.append(entry) }
        }
        return (kept + own, Applied(ours: own, displaced: displaced))
    }

    /// Takes a previous `merge` back out of whatever the mapping is now.
    static func unmerge(current: [Entry], applied: Applied) -> [Entry] {
        var result = current.filter { !applied.ours.contains($0) }
        for entry in applied.displaced where !result.contains(where: { $0.src == entry.src }) {
            result.append(entry)
        }
        return result
    }

    static func parse(_ value: Any?) -> [Entry] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let src = item[srcKey] as? NSNumber, let dst = item[dstKey] as? NSNumber else { return nil }
            return Entry(src: src.uint64Value, dst: dst.uint64Value)
        }
    }

    /// The argument for `hidutil property --set`.
    static func json(_ entries: [Entry]) -> String {
        let items = entries.map { "{\"\(srcKey)\":\($0.src),\"\(dstKey)\":\($0.dst)}" }
        return "{\"\(property)\":[\(items.joined(separator: ","))]}"
    }

    // MARK: System

    /// Current system-wide mapping (empty when none was ever set).
    static func read() -> [Entry] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return parse(IOHIDEventSystemClientCopyProperty(client, property as CFString))
    }

    /// Replaces the system-wide mapping. Returns nil on success, else why not.
    static func write(_ entries: [Entry]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--set", json(entries)]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        // Not waitUntilExit(): that spins the caller's run loop, which re-enters
        // main-thread work in the middle of start()/stop().
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return "hidutil did not start: \(error.localizedDescription)" }
        let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        done.wait()
        guard process.terminationStatus == 0 else {
            return "hidutil exited \(process.terminationStatus) \(detail.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        return nil
    }
}
