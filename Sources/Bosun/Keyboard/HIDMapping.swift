import Foundation
import CBridge
import IOKit.hid

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
    /// HID Keyboard/Keypad Page NoEvent usage: remapping a key to this suppresses it.
    static let noEvent: UInt64 = 0x7_0000_0000

    /// Entries that silence every typing, modifier, fn, and media/function key on
    /// a built-in keyboard without touching power / Touch ID.
    static let disableEntries: [Entry] = buildDisableEntries(extra: [])

    /// Power / sleep usages that must never be suppressed.
    private static let protectedUsages: Set<UInt64> = [
        0xC_0000_0030,  // Consumer Power
        0x1_0000_0081,  // System Power Down
        0x1_0000_0082,  // System Sleep
        0x1_0000_0083,  // System Wake Up
    ]

    static func buildDisableEntries(extra: [UInt64]) -> [Entry] {
        let extraUsages: [UInt64] = [
            // ISO / JIS extra keys
            0x7_0000_0032,  // Non-US # / ~
            0x7_0000_0085,  // Keypad Comma
            0x7_0000_0087,  // International1 (JIS _)
            0x7_0000_0088,  // International2
            0x7_0000_0089,  // International3 (JIS ¥)
            0x7_0000_008A,  // International4
            0x7_0000_008B,  // International5
            0x7_0000_0090,  // LANG1 (Kana)
            0x7_0000_0091,  // LANG2 (Eisu)
            // Apple built-in keyboard F1–F12 default function usages (FnFunctionUsageMap)
            0xFF_0000_0004,    // Brightness Up (F2 on Apple built-in keyboards)
            0xFF_0000_0005,    // Brightness Down (F1 on Apple built-in keyboards)
            0xFF01_0000_0002,  // Dashboard
            0xFF01_0000_0020,  // Keyboard Brightness Down (legacy)
            0xFF01_0000_0021,  // Keyboard Brightness Up (legacy)
            0xC_0000_00B3,     // Fast Forward (F9 on Apple built-in keyboards)
            0xC_0000_00B4,     // Rewind (F7 on Apple built-in keyboards)
            0xC_0000_0221,     // AC Search / Spotlight (F4 on Apple built-in keyboards)
            0x1_0000_009B,     // System Do Not Disturb / Focus (F6 on Apple built-in keyboards)
        ]
        var seen = Set<UInt64>()
        let usages = (KeyCatalog.all.map(\.usage) + extraUsages + extra)
            .filter { !protectedUsages.contains($0) && seen.insert($0).inserted }
        return usages.map { Entry(src: $0, dst: noEvent) }
    }

    /// Parses IOKit's `FnFunctionUsageMap` string (`0xPPPPUUUU,0xPPPPUUUU,…`) into
    /// 64-bit `hidutil` usages (`usagePage << 32 | usage`), returning all target usages.
    static func parseFnUsageMap(_ raw: String) -> [UInt64] {
        let tokens = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var result: [UInt64] = []
        // Pairs of (src, dst); take every dst (odd index) so dynamic Mac function keys are covered.
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            let hex = token.hasPrefix("0x") || token.hasPrefix("0X") ? String(token.dropFirst(2)) : token
            if let packed = UInt32(hex, radix: 16) {
                let page = UInt64(packed >> 16)
                let usage = UInt64(packed & 0xFFFF)
                let combined = (page << 32) | usage
                if !protectedUsages.contains(combined) { result.append(combined) }
            }
            index += 2
        }
        return result
    }

    /// Minimal metadata for one HID service, used to distinguish built-in keyboards,
    /// real external keyboards, and mice that expose a secondary keyboard interface.
    struct ServiceInfo: Equatable {
        var device: KeyboardDevice
        var builtIn: Bool
        var isKeyboard: Bool
        var primaryUsagePage: Int
        var primaryUsage: Int
        var transport: String?
    }

    struct ClassifiedKeyboards: Equatable {
        var builtIn: [KeyboardDevice] = []
        var external: [KeyboardDevice] = []
        /// Extra target usages reported by the built-in keyboard's `FnFunctionUsageMap`.
        var builtInFnUsages: [UInt64] = []
    }

    /// Splits HID services into built-in keyboards and external keyboards.
    /// Gaming mice often expose a secondary keyboard interface for macro buttons;
    /// any non-built-in device that also has a primary mouse interface (1, 2) is
    /// excluded so plugging in a mouse never disables the laptop keyboard.
    static func classify(_ services: [ServiceInfo]) -> ClassifiedKeyboards {
        let mouseDevices = Set(services.filter {
            !$0.builtIn && $0.primaryUsagePage == 1 && $0.primaryUsage == 2
        }.map(\.device))
        var seenBuiltIn = Set<KeyboardDevice>()
        var seenExternal = Set<KeyboardDevice>()
        var builtIn: [KeyboardDevice] = []
        var external: [KeyboardDevice] = []
        for service in services where service.isKeyboard {
            if service.builtIn {
                if seenBuiltIn.insert(service.device).inserted { builtIn.append(service.device) }
            } else if !mouseDevices.contains(service.device), service.transport != "Virtual" {
                if seenExternal.insert(service.device).inserted { external.append(service.device) }
            }
        }
        let byName: (KeyboardDevice, KeyboardDevice) -> Bool = {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return ClassifiedKeyboards(builtIn: builtIn.sorted(by: byName), external: external.sorted(by: byName))
    }

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

    /// Attached keyboards split into built-in vs. external (excluding mice with
    /// macro keyboard interfaces and virtual keyboards).
    static func classifiedKeyboards() -> ClassifiedKeyboards {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let services = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] else { return .init() }
        var fnUsages: [UInt64] = []
        let infos: [ServiceInfo] = services.compactMap { service in
            let isKeyboard = IOHIDServiceClientConformsTo(service, 1, 6) != 0
            func number(_ key: String) -> Int? { (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue }
            let primaryPage = number("PrimaryUsagePage") ?? 0
            let primaryUsage = number("PrimaryUsage") ?? 0
            let isPrimaryMouse = primaryPage == 1 && primaryUsage == 2
            guard isKeyboard || isPrimaryMouse else { return nil }
            guard let vendor = number("VendorID"), let product = number("ProductID") else { return nil }
            let name = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
            let builtIn = (IOHIDServiceClientCopyProperty(service, "Built-In" as CFString) as? NSNumber)?.boolValue ?? false
            let transport = IOHIDServiceClientCopyProperty(service, "Transport" as CFString) as? String
            if builtIn, isKeyboard, let rawMap = IOHIDServiceClientCopyProperty(service, "FnFunctionUsageMap" as CFString) as? String {
                fnUsages.append(contentsOf: parseFnUsageMap(rawMap))
            }
            let device = KeyboardDevice(vendorID: vendor, productID: product, name: name ?? "Keyboard \(vendor):\(product)")
            return ServiceInfo(device: device, builtIn: builtIn, isKeyboard: isKeyboard,
                               primaryUsagePage: primaryPage, primaryUsage: primaryUsage, transport: transport)
        }
        var result = classify(infos)
        result.builtInFnUsages = fnUsages
        return result
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

/// Watches for keyboard attach / detach events via IOHIDManager (no extra
/// permission required since it never reads input events) and invokes `onChange`
/// on the main actor after a short debounce.
@MainActor
final class KeyboardWatcher {
    private var manager: IOHIDManager?
    private var debounce: DispatchWorkItem?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        guard manager == nil else { return }
        self.onChange = onChange
        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey as String: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey as String: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOHIDDeviceCallback = { context, _, _, _ in
            guard let context else { return }
            let watcher = Unmanaged<KeyboardWatcher>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { watcher.scheduleChange() }
        }
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, callback, context)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, callback, context)
        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            self.onChange = nil
            return
        }
        manager = mgr
    }

    func stop() {
        debounce?.cancel()
        debounce = nil
        onChange = nil
        guard let mgr = manager else { return }
        manager = nil
        IOHIDManagerRegisterDeviceMatchingCallback(mgr, nil, nil)
        IOHIDManagerRegisterDeviceRemovalCallback(mgr, nil, nil)
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private func scheduleChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onChange?()
        }
        debounce = work
        // Composite USB keyboards fire multiple callbacks on attach/detach and
        // IOHIDEventSystemClient needs a moment to publish the new services.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}
