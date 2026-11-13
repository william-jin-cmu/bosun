import Foundation
import IOKit

struct BatteryInfo {
    var percent: Int
    var isCharging: Bool
    var onAC: Bool
    var cycleCount: Int
    var health: Double?            // full-charge capacity / design capacity
    var fullChargeCapacity: Int?   // mAh
    var designCapacity: Int?       // mAh
    var temperature: Double?       // °C
    var watts: Double?             // negative while discharging
    var adapterWatts: Int?
    var minutesRemaining: Int?     // to empty or to full; nil while the system is still estimating

    /// nil on Macs without a battery.
    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return parse(props)
    }

    static func parse(_ props: [String: Any]) -> BatteryInfo? {
        // Newer macOS releases moved the capacity figures into a nested "BatteryData" dictionary.
        let nested = props["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? { ((props[key] ?? nested[key]) as? NSNumber)?.intValue }
        guard let current = int("CurrentCapacity"), let max = int("MaxCapacity"), max > 0 else { return nil }
        let design = int("DesignCapacity")
        let full = int("AppleRawMaxCapacity") ?? int("FullChargeCapacity") ?? int("NominalChargeCapacity")
        var watts: Double?
        if let millivolts = int("Voltage"), let rawAmps = props["Amperage"] as? NSNumber {
            // Amperage is a signed value that some firmware reports as an unsigned 64-bit number.
            watts = Double(millivolts) / 1000 * Double(rawAmps.int64Value) / 1000
        }
        let remaining = int("TimeRemaining").flatMap { (1..<6000).contains($0) ? $0 : nil }
        return BatteryInfo(
            percent: Int((Double(current) / Double(max) * 100).rounded()),
            isCharging: (props["IsCharging"] as? Bool) ?? false,
            onAC: (props["ExternalConnected"] as? Bool) ?? false,
            cycleCount: int("CycleCount") ?? 0,
            health: (full != nil && design != nil && design! > 0) ? Double(full!) / Double(design!) : nil,
            fullChargeCapacity: full,
            designCapacity: design,
            temperature: (int("Temperature") ?? int("VirtualTemperature")).map { Double($0) / 100 },
            watts: watts,
            adapterWatts: (props["AdapterDetails"] as? [String: Any]).flatMap { ($0["Watts"] as? NSNumber)?.intValue },
            minutesRemaining: remaining)
    }

    var stateText: String {
        if isCharging { return "Charging" }
        if onAC { return percent >= 100 ? "Full" : "On power, not charging" }
        return "On battery"
    }

    var remainingText: String? {
        guard let minutes = minutesRemaining, isCharging || !onAC else { return nil }
        let text = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return isCharging ? "\(text) to full" : "\(text) left"
    }
}
