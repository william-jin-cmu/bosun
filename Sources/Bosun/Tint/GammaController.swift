import ColorSync
import CoreGraphics
import Foundation

/// The video-card gamma curve a display profile asks for (its `vcgt` tag).
/// This — not whatever the gamma table holds at the moment — is the untinted
/// state of a display, so it is what a tint is applied on top of.
enum VCGT: Equatable {
    case formula(gamma: [Double], min: [Double], max: [Double])     // per channel r, g, b
    case table(r: [Double], g: [Double], b: [Double])                // 0...1 samples

    /// Parses the raw tag (ICC `vcgt`, Apple's video card gamma type).
    init?(tag data: Data) {
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> Int? {
            offset + 2 <= bytes.count ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) : nil
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        guard bytes.count >= 18, bytes[0...3].elementsEqual(Array("vcgt".utf8)), let kind = u32(8) else { return nil }
        switch kind {
        case 0:
            guard let channels = u16(12), let count = u16(14), let size = u16(16),
                  channels == 1 || channels == 3, count >= 2, size == 1 || size == 2,
                  18 + channels * count * size <= bytes.count else { return nil }
            func channel(_ index: Int) -> [Double] {
                let base = 18 + index * count * size
                return (0..<count).map { i in
                    size == 1 ? Double(bytes[base + i]) / 255 : Double(u16(base + i * 2) ?? 0) / 65535
                }
            }
            let r = channel(0)
            self = channels == 3 ? .table(r: r, g: channel(1), b: channel(2)) : .table(r: r, g: r, b: r)
        case 1:
            guard bytes.count >= 12 + 36 else { return nil }
            func fixed(_ index: Int) -> Double { Double(Int32(bitPattern: u32(12 + index * 4) ?? 0)) / 65536 }
            let gamma = [fixed(0), fixed(3), fixed(6)], low = [fixed(1), fixed(4), fixed(7)], high = [fixed(2), fixed(5), fixed(8)]
            guard gamma.allSatisfy({ $0 > 0.05 && $0 < 20 }) else { return nil }
            self = .formula(gamma: gamma, min: low, max: high)
        default:
            return nil
        }
    }

    /// The curve sampled at `count` evenly spaced inputs.
    func sampled(count: Int) -> (r: [Double], g: [Double], b: [Double]) {
        let n = max(count, 2)
        func resample(_ source: [Double]) -> [Double] {
            (0..<n).map { i in
                let position = Double(i) / Double(n - 1) * Double(source.count - 1)
                let low = min(Int(position), source.count - 2)
                return TintMath.clamp01(TintMath.lerp(source[low], source[low + 1], position - Double(low)))
            }
        }
        switch self {
        case let .table(r, g, b):
            return (resample(r), resample(g), resample(b))
        case let .formula(gamma, low, high):
            func curve(_ c: Int) -> [Double] {
                (0..<n).map { i in
                    TintMath.clamp01(low[c] + (high[c] - low[c]) * pow(Double(i) / Double(n - 1), gamma[c]))
                }
            }
            return (curve(0), curve(1), curve(2))
        }
    }
}

/// Applies colour temperature by scaling each display's gamma table. The one
/// place in Bosun that writes gamma tables.
///
/// Facts this is built around (observed on macOS 27, Apple Silicon):
/// - Reading the table back returns exactly what was written, so "is it still
///   ours?" is a cheap, reliable comparison.
/// - The table belongs to whoever wrote last. When *any* process that wrote
///   one exits, the system resets every display to its profile.
/// - `CGDisplayRestoreColorSyncSettings()` does not undo another process's
///   table, so "restore, then read" is not a safe way to learn the untinted
///   state: it can return another app's tint, and tinting on top of that
///   compounds. The baseline therefore always comes from the display profile.
final class GammaController {
    struct Table: Equatable {
        var r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue]

        static func identity(count: Int) -> Table {
            let ramp = (0..<count).map { CGGammaValue($0) / CGGammaValue(max(count - 1, 1)) }
            return Table(r: ramp, g: ramp, b: ramp)
        }

        func isClose(to other: Table, tolerance: CGGammaValue = 0.0008) -> Bool {
            guard r.count == other.r.count, g.count == other.g.count, b.count == other.b.count else { return false }
            for i in r.indices where abs(r[i] - other.r[i]) > tolerance { return false }
            for i in g.indices where abs(g[i] - other.g[i]) > tolerance { return false }
            for i in b.indices where abs(b[i] - other.b[i]) > tolerance { return false }
            return true
        }
    }

    /// What the live gamma table of a display turned out to be.
    enum Finding: Equatable {
        case ours          // exactly what we last wrote
        case baseline      // the untinted profile state (never written, or the system reset it)
        case foreign       // something else: another app's tint
        case unreadable
    }

    private struct Slot {
        var baseline: Table
        var primaries: DisplayPrimaries
        var written: Table?
        var kelvin: Double?
    }

    private var slots: [CGDirectDisplayID: Slot] = [:]

    // MARK: Raw access

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func tableSize(_ display: CGDirectDisplayID) -> Int {
        let capacity = Int(CGDisplayGammaTableCapacity(display))
        return capacity >= 2 ? capacity : 256
    }

    static func readTable(_ display: CGDirectDisplayID) -> Table? {
        let capacity = UInt32(tableSize(display))
        var r = [CGGammaValue](repeating: 0, count: Int(capacity))
        var g = r, b = r
        var n: UInt32 = 0
        guard CGGetDisplayTransferByTable(display, capacity, &r, &g, &b, &n) == .success, n > 1 else { return nil }
        return Table(r: Array(r.prefix(Int(n))), g: Array(g.prefix(Int(n))), b: Array(b.prefix(Int(n))))
    }

    @discardableResult
    static func writeTable(_ display: CGDirectDisplayID, _ table: Table) -> Bool {
        CGSetDisplayTransferByTable(display, UInt32(table.r.count), table.r, table.g, table.b) == .success
    }

    static func scaled(_ table: Table, by m: (r: Double, g: Double, b: Double)) -> Table {
        Table(r: table.r.map { $0 * CGGammaValue(m.r) },
              g: table.g.map { $0 * CGGammaValue(m.g) },
              b: table.b.map { $0 * CGGammaValue(m.b) })
    }

    // MARK: Profile-derived state

    /// The untinted table for a profile's `vcgt` tag (identity when there is none).
    static func baseline(vcgt: VCGT?, count: Int) -> Table {
        guard let vcgt else { return .identity(count: count) }
        let curves = vcgt.sampled(count: count)
        return Table(r: curves.r.map { CGGammaValue($0) }, g: curves.g.map { CGGammaValue($0) }, b: curves.b.map { CGGammaValue($0) })
    }

    static func vcgt(of profile: ColorSyncProfile) -> VCGT? {
        guard let data = ColorSyncProfileCopyTag(profile, "vcgt" as CFString)?.takeRetainedValue() as Data? else { return nil }
        return VCGT(tag: data)
    }

    /// The untinted table the system would load for `display` right now.
    static func profileBaseline(_ display: CGDirectDisplayID) -> Table {
        let profile = ColorSyncProfileCreateWithDisplayID(display)?.takeRetainedValue()
        return baseline(vcgt: profile.flatMap(vcgt(of:)), count: tableSize(display))
    }

    static func primaries(_ display: CGDirectDisplayID) -> DisplayPrimaries {
        DisplayPrimaries(colorSpace: CGDisplayCopyColorSpace(display)) ?? .sRGB
    }

    // MARK: Ownership

    private func slot(_ display: CGDirectDisplayID) -> Slot {
        if let slot = slots[display] { return slot }
        let slot = Slot(baseline: Self.profileBaseline(display), primaries: Self.primaries(display))
        slots[display] = slot
        return slot
    }

    /// Re-reads the display's profile (after a reconfiguration or profile change).
    func refreshProfile(_ display: CGDirectDisplayID) {
        var slot = slot(display)
        slot.baseline = Self.profileBaseline(display)
        slot.primaries = Self.primaries(display)
        slots[display] = slot
    }

    func owns(_ display: CGDirectDisplayID) -> Bool { slots[display]?.written != nil }
    var ownedDisplays: [CGDirectDisplayID] { slots.filter { $0.value.written != nil }.map(\.key) }

    /// Classifies the live table. Re-reads the profile before calling something
    /// foreign, so a profile switch is not mistaken for another app.
    func inspect(_ display: CGDirectDisplayID) -> Finding {
        guard let live = Self.readTable(display) else { return .unreadable }
        if let written = slot(display).written, live.isClose(to: written) { return .ours }
        if live.isClose(to: slot(display).baseline) { return .baseline }
        refreshProfile(display)
        return live.isClose(to: slot(display).baseline) ? .baseline : .foreign
    }

    /// Tints `display` to `kelvin` on top of its profile baseline. Skips the
    /// write when nothing would change unless `force` is set.
    @discardableResult
    func apply(kelvin: Double, to display: CGDirectDisplayID, force: Bool = false) -> Bool {
        var slot = slot(display)
        if !force, slot.written != nil, let last = slot.kelvin, abs(last - kelvin) < 0.05 { return true }
        let table = Self.scaled(slot.baseline, by: ColorTemperature.multipliers(kelvin: kelvin, primaries: slot.primaries))
        guard Self.writeTable(display, table) else { return false }
        slot.written = table
        slot.kelvin = kelvin
        slots[display] = slot
        return true
    }

    /// The Kelvin last written to a display we own.
    func appliedKelvin(_ display: CGDirectDisplayID) -> Double? {
        guard let slot = slots[display], slot.written != nil else { return nil }
        return slot.kelvin
    }

    /// Writes the untinted table and gives the display up.
    func release(_ display: CGDirectDisplayID) {
        guard var slot = slots[display], slot.written != nil else { return }
        Self.writeTable(display, slot.baseline)
        slot.written = nil
        slot.kelvin = nil
        slots[display] = slot
    }

    /// Gives the display up without touching it (someone else is tinting it now).
    func abandon(_ display: CGDirectDisplayID) {
        slots[display]?.written = nil
        slots[display]?.kelvin = nil
    }

    /// Drops state for displays that are gone.
    func prune(keeping online: [CGDirectDisplayID]) {
        for id in slots.keys where !online.contains(id) { slots[id] = nil }
    }

    /// Untints everything we own. `CGDisplayRestoreColorSyncSettings` afterwards
    /// hands the tables back to the system (it is a no-op for other apps' tables).
    func restore() {
        let owned = ownedDisplays
        for display in owned { release(display) }
        if !owned.isEmpty { CGDisplayRestoreColorSyncSettings() }
        slots.removeAll()
    }
}
