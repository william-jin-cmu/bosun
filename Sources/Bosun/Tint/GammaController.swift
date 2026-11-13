import CoreGraphics

/// Applies a colour-temperature tint by scaling each display's gamma table.
/// The untinted table is captured per display so calibration (the ColorSync
/// profile's own curve) is preserved underneath the tint.
final class GammaController {
    struct Table {
        var r: [CGGammaValue], g: [CGGammaValue], b: [CGGammaValue]
    }

    private var baselines: [CGDirectDisplayID: Table] = [:]

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        return Array(ids.prefix(Int(count)))
    }

    static func readTable(_ display: CGDirectDisplayID) -> Table? {
        let capacity = max(CGDisplayGammaTableCapacity(display), 256)
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

    /// Drops every tint (ours or anyone's) and re-reads the untinted tables.
    func resetBaselines() {
        CGDisplayRestoreColorSyncSettings()
        baselines.removeAll()
        for display in Self.onlineDisplays() {
            baselines[display] = Self.readTable(display)
        }
    }

    func apply(kelvin: Double) {
        let multipliers = ColorTemperature.multipliers(kelvin: kelvin)
        for display in Self.onlineDisplays() {
            if baselines[display] == nil { baselines[display] = Self.readTable(display) }
            guard let baseline = baselines[display] else { continue }
            Self.writeTable(display, Self.scaled(baseline, by: multipliers))
        }
    }

    func restore() {
        CGDisplayRestoreColorSyncSettings()
        baselines.removeAll()
    }
}
