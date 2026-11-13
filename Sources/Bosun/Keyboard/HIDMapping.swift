import Foundation
import CBridge

/// The HID event system's `UserKeyMapping`: pure planning logic plus the
/// system calls (read through IOHIDEventSystemClient, write through hidutil).
///
/// How the system behaves (checked on macOS 27): a mapping set without
/// `--matching` is copied onto every keyboard service, replacing whatever a
/// service had; a mapping set with `--matching` replaces the list of just the
/// matching services. So a per-keyboard remap means "that keyboard's list is
/// the global list plus its own entries", and it must be written again after
/// every global write.
enum HIDMapping {
    struct Entry: Codable, Hashable {
        var src: UInt64
        var dst: UInt64
    }

    /// What Bosun last wrote, so exactly that can be taken back out later —
    /// including after a crash, since it is persisted.
    struct Applied: Codable, Equatable {
        struct Device: Codable, Equatable {
            var device: KeyboardDevice
            var ours: [Entry] = []
            /// Entries someone else set on just this keyboard.
            var foreign: [Entry] = []
        }
        var ours: [Entry] = []
        /// Foreign entries we overrode because they remapped the same key.
        var displaced: [Entry] = []
        var devices: [Device] = []

        var isEmpty: Bool { ours.isEmpty && displaced.isEmpty && devices.isEmpty }

        init(ours: [Entry] = [], displaced: [Entry] = [], devices: [Device] = []) {
            self.ours = ours
            self.displaced = displaced
            self.devices = devices
        }

        // The round-one record had no `devices`.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ours = try c.decodeIfPresent([Entry].self, forKey: .ours) ?? []
            displaced = try c.decodeIfPresent([Entry].self, forKey: .displaced) ?? []
            devices = try c.decodeIfPresent([Device].self, forKey: .devices) ?? []
        }
    }

    /// The mapping as the system has it now.
    struct Snapshot: Equatable {
        var global: [Entry] = []
        /// Attached keyboards and the list on each.
        var devices: [KeyboardDevice: [Entry]] = [:]
    }

    struct Desired: Equatable {
        var global: [Entry] = []
        var devices: [KeyboardDevice: [Entry]] = [:]
    }

    /// Writes to perform, in order: the global list first (if any), then devices.
    struct Plan: Equatable {
        var global: [Entry]?
        var devices: [KeyboardDevice: [Entry]] = [:]
        var applied = Applied()
        var isNoop: Bool { global == nil && devices.isEmpty }
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

    /// Works out what to write so that the system ends up with everyone else's
    /// entries plus `desired`, given what Bosun wrote last time (`previous`).
    /// Planning from the resulting state with the resulting `applied` is a no-op,
    /// and planning with an empty `desired` restores what was there before.
    static func plan(current: Snapshot, previous: Applied?, desired: Desired) -> Plan {
        let previous = previous ?? Applied()
        let base = unmerge(current: current.global, applied: Applied(ours: previous.ours, displaced: previous.displaced))
        let (newGlobal, globalApplied) = merge(existing: base, ours: desired.global)
        var plan = Plan()
        plan.applied = globalApplied
        let writesGlobal = !sameMapping(newGlobal, current.global)
        if writesGlobal { plan.global = newGlobal }

        for (device, list) in current.devices.sorted(by: { $0.key.id < $1.key.id }) {
            let record = previous.devices.first { $0.device == device }
            let ourOld = previous.ours + (record?.ours ?? [])
            // Entries only this keyboard has and that are not ours.
            var foreign = list.filter { !current.global.contains($0) && !ourOld.contains($0) }
            for entry in record?.foreign ?? [] where !foreign.contains(where: { $0.src == entry.src }) {
                foreign.append(entry)
            }
            let ours = desired.devices[device] ?? []
            let target = merge(existing: merge(existing: newGlobal, ours: foreign).merged, ours: ours).merged
            // A global write resets this keyboard to the global list.
            let willHave = writesGlobal ? newGlobal : list
            if !sameMapping(target, willHave) { plan.devices[device] = target }
            if !ours.isEmpty || !foreign.isEmpty {
                plan.applied.devices.append(.init(device: device, ours: ours, foreign: foreign))
            }
        }
        // Rules for keyboards that are not attached wait for them to show up.
        for (device, ours) in desired.devices where current.devices[device] == nil && !ours.isEmpty {
            let foreign = previous.devices.first { $0.device == device }?.foreign ?? []
            plan.applied.devices.append(.init(device: device, ours: ours, foreign: foreign))
        }
        plan.applied.devices.sort { $0.device.id < $1.device.id }
        return plan
    }

    /// Order does not matter to the system.
    static func sameMapping(_ a: [Entry], _ b: [Entry]) -> Bool { Set(a) == Set(b) }

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

    /// The argument for `hidutil property --matching`.
    static func matching(_ device: KeyboardDevice) -> String {
        "{\"VendorID\":\(device.vendorID),\"ProductID\":\(device.productID)}"
    }

    // MARK: System

    /// Current system-wide mapping (empty when none was ever set).
    static func read() -> [Entry] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        return parse(IOHIDEventSystemClientCopyProperty(client, property as CFString))
    }

    /// System-wide mapping plus the list on each attached keyboard.
    static func snapshot() -> Snapshot {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        var snapshot = Snapshot(global: parse(IOHIDEventSystemClientCopyProperty(client, property as CFString)))
        for (device, service) in keyboardServices(client) where snapshot.devices[device] == nil {
            snapshot.devices[device] = parse(IOHIDServiceClientCopyProperty(service, property as CFString))
        }
        return snapshot
    }

    /// Attached keyboards (anything with a keyboard interface), by name.
    static func keyboards() -> [KeyboardDevice] {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        var seen = Set<KeyboardDevice>()
        return keyboardServices(client).map(\.0).filter { seen.insert($0).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func keyboardServices(_ client: IOHIDEventSystemClient) -> [(KeyboardDevice, IOHIDServiceClient)] {
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return [] }
        return services.compactMap { service in
            guard IOHIDServiceClientConformsTo(service, 1, 6) != 0 else { return nil }      // Generic Desktop / Keyboard
            func number(_ key: String) -> Int? { (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue }
            guard let vendor = number("VendorID"), let product = number("ProductID") else { return nil }
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
            return (KeyboardDevice(vendorID: vendor, productID: product, name: name ?? "Keyboard \(vendor):\(product)"), service)
        }
    }

    /// Replaces the mapping, system-wide or on one keyboard model. Returns nil
    /// on success, else why not.
    static func write(_ entries: [Entry], device: KeyboardDevice? = nil) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property"] + (device.map { ["--matching", matching($0)] } ?? []) + ["--set", json(entries)]
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

    /// Carries out a plan. Returns nil on success, else the first failure.
    static func execute(_ plan: Plan) -> String? {
        if let global = plan.global, let failure = write(global) { return failure }
        for (device, entries) in plan.devices.sorted(by: { $0.key.id < $1.key.id }) {
            if let failure = write(entries, device: device) { return failure }
        }
        return nil
    }

    /// Puts the system back to a snapshot taken earlier (used by the live checks).
    static func restore(_ snapshot: Snapshot) -> String? {
        let now = self.snapshot()
        var wroteGlobal = false
        if !sameMapping(now.global, snapshot.global) {
            if let failure = write(snapshot.global) { return failure }
            wroteGlobal = true
        }
        for (device, entries) in snapshot.devices {
            let has = wroteGlobal ? snapshot.global : (now.devices[device] ?? [])
            if !sameMapping(has, entries), let failure = write(entries, device: device) { return failure }
        }
        return nil
    }
}
