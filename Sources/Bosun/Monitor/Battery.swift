import Foundation
import IOKit

struct BatteryInfo: Equatable {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var cycleCount: Int
    var designCycleCount: Int?     // cycles the pack is rated for
    var health: Double?            // full-charge capacity / design capacity (coconutBattery's figure)
    var fullChargeCapacity: Int?   // mAh
    var nominalCapacity: Int?      // mAh; the smoothed figure System Settings bases "Maximum Capacity" on
    var designCapacity: Int?       // mAh
    var remainingCapacity: Int?    // mAh
    var temperature: Double?       // °C
    var voltage: Double?           // V
    var amperage: Int?             // mA, negative while discharging
    var watts: Double?             // negative while discharging
    var adapterWatts: Int?
    var adapterName: String?
    var systemPowerIn: Double?     // W coming in from the adapter
    var minutesRemaining: Int?     // to empty or to full; nil while the system is still estimating
    var chargeLimit: Int?          // percent, from SMC; nil = no limit
    var timeline = BatteryTimeline()

    /// nil on Macs without a battery. One registry read plus, with `withSMC`, two SMC keys.
    static func read(withSMC: Bool = true) -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any], var info = parse(props) else { return nil }
        if withSMC {
            info.chargeLimit = Sensors.chargeLimit()
            if info.temperature == nil {
                info.temperature = ["TB1T", "TB2T", "TB0T"].lazy.compactMap { Sensors.smcValue($0) }
                    .first { $0 > 1 && $0 < 100 }
            }
        }
        return info
    }

    static func parse(_ props: [String: Any]) -> BatteryInfo? {
        // Newer macOS releases moved the capacity figures into a nested "BatteryData" dictionary.
        let nested = props["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { ((props[key] ?? nested[key]) as? NSNumber)?.intValue }
        guard let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }
        let design = int("DesignCapacity")
        let full = int("AppleRawMaxCapacity") ?? int("FullChargeCapacity") ?? int("NominalChargeCapacity")
        var watts: Double?
        var amperage: Int?
        if let millivolts = int("Voltage"), let rawAmps = props["Amperage"] as? NSNumber {
            // Amperage is a signed value that some firmware reports as an unsigned 64-bit number.
            amperage = Int(rawAmps.int64Value)
            watts = Double(millivolts) / 1000 * Double(rawAmps.int64Value) / 1000
        }
        let remaining = int("TimeRemaining").flatMap { (1..<6000).contains($0) ? $0 : nil }
        let adapter = props["AdapterDetails"] as? [String: Any]
        let telemetry = props["PowerTelemetryData"] as? [String: Any]
        return BatteryInfo(
            percent: Int((Double(current) / Double(max) * 100).rounded()),
            isCharging: (props["IsCharging"] as? Bool) ?? false,
            onAC: (props["ExternalConnected"] as? Bool) ?? false,
            cycleCount: int("CycleCount") ?? 0,
            designCycleCount: int("DesignCycleCount9C"),
            health: (full != nil && design != nil && design! > 0) ? Double(full!) / Double(design!) : nil,
            fullChargeCapacity: full,
            nominalCapacity: int("NominalChargeCapacity"),
            designCapacity: design,
            remainingCapacity: (nested["RemainingCapacity"] as? NSNumber)?.intValue ?? int("AppleRawCurrentCapacity"),
            temperature: (int("Temperature") ?? int("VirtualTemperature")).map { Double($0) / 100 },
            voltage: int("Voltage").map { Double($0) / 1000 },
            amperage: amperage,
            watts: watts,
            adapterWatts: (adapter?["Watts"] as? NSNumber)?.intValue,
            adapterName: (adapter?["Name"] as? String) ?? (adapter?["Description"] as? String),
            systemPowerIn: (telemetry?["SystemPowerIn"] as? NSNumber).map { $0.doubleValue / 1000 },
            minutesRemaining: remaining)
    }

    /// On power, not charging, and sitting at the configured charge limit.
    var isHeldAtLimit: Bool {
        guard let chargeLimit, onAC, !isCharging else { return false }
        return percent >= chargeLimit - 2
    }

    var stateText: String {
        if isCharging { return "Charging" }
        if onAC {
            if isHeldAtLimit, let chargeLimit { return "Holding at \(chargeLimit)% limit" }
            return percent >= 100 ? "Full" : "On power, not charging"
        }
        return "On battery"
    }

    var remainingText: String? {
        guard let minutes = minutesRemaining, isCharging || !onAC else { return nil }
        let text = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return isCharging ? "\(text) to full" : "\(text) left"
    }

    /// SF Symbol matching the charge level.
    var symbol: String {
        if isCharging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// When the Mac last came off the charger. The system keeps no such figure (checked the
/// AppleSmartBattery registry entry and the IOPS power-source description on macOS 27), so
/// Bosun tracks the transitions itself. If Bosun started while already on battery the start
/// is unknown and `observed` is false: the figure is then a lower bound.
struct BatteryTimeline: Equatable {
    var unpluggedAt: Date?
    var percentAtUnplug: Int?
    var observed = false
    private var sawPower = false

    init(unpluggedAt: Date? = nil, percentAtUnplug: Int? = nil, observed: Bool = false) {
        self.unpluggedAt = unpluggedAt
        self.percentAtUnplug = percentAtUnplug
        self.observed = observed
    }

    mutating func update(onAC: Bool, percent: Int, now: Date) {
        if onAC {
            sawPower = true
            unpluggedAt = nil
            percentAtUnplug = nil
            observed = false
            return
        }
        // A restored start that the charge level contradicts (it went up since) is stale.
        let stale = (percentAtUnplug.map { percent > $0 + 2 } ?? false) || (unpluggedAt.map { $0 > now } ?? false)
        if unpluggedAt == nil || stale {
            unpluggedAt = now
            percentAtUnplug = percent
            observed = sawPower && !stale
        }
    }

    func timeOnBattery(now: Date) -> TimeInterval? { unpluggedAt.map { now.timeIntervalSince($0) } }

    // Survives relaunches, so quitting Bosun on battery does not lose the start.
    private static let atKey = "monitor.battery.unpluggedAt"
    private static let percentKey = "monitor.battery.unpluggedPercent"
    private static let observedKey = "monitor.battery.unpluggedObserved"

    static func load(_ defaults: UserDefaults = .standard) -> BatteryTimeline {
        let at = defaults.double(forKey: atKey)
        guard at > 0, defaults.object(forKey: percentKey) != nil else { return BatteryTimeline() }
        return BatteryTimeline(unpluggedAt: Date(timeIntervalSince1970: at),
                               percentAtUnplug: defaults.integer(forKey: percentKey),
                               observed: defaults.bool(forKey: observedKey))
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let unpluggedAt, let percentAtUnplug {
            defaults.set(unpluggedAt.timeIntervalSince1970, forKey: Self.atKey)
            defaults.set(percentAtUnplug, forKey: Self.percentKey)
            defaults.set(observed, forKey: Self.observedKey)
        } else {
            [Self.atKey, Self.percentKey, Self.observedKey].forEach(defaults.removeObject(forKey:))
        }
    }
}
