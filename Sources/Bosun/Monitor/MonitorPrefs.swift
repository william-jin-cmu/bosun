import Foundation

/// A compact reading that can sit next to the Bosun icon in the menu bar.
enum StatusWidget: String, CaseIterable, Identifiable {
    case cpu, cpuGraph, cpuBars, gpu, memory, network, disk, temperature, battery
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU usage"
        case .cpuGraph: "CPU history graph"
        case .cpuBars: "CPU core bars"
        case .gpu: "GPU usage"
        case .memory: "Memory usage"
        case .network: "Network speed"
        case .disk: "Disk usage"
        case .temperature: "CPU temperature"
        case .battery: "Battery"
        }
    }
    var detail: String {
        switch self {
        case .cpu: "Percent of all cores"
        case .cpuGraph: "Last two minutes or so, as a tiny graph"
        case .cpuBars: "One bar per core, efficiency cores first"
        case .gpu: "Percent of the GPU in use"
        case .memory: "Percent of memory in use"
        case .network: "Upload over download, two lines"
        case .disk: "Percent of the startup disk in use"
        case .temperature: "Average of the CPU core sensors"
        case .battery: "Charge level"
        }
    }
    /// Short caption drawn above the value when labels are on.
    var caption: String? {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "MEM"
        case .disk: "SSD"
        case .temperature: "TEMP"
        case .cpuGraph, .cpuBars, .network, .battery: nil
        }
    }
}

/// One block of the System section in the panel.
enum PanelBlock: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, disk, network, sensors, battery, processes
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .sensors: "Sensors"
        case .battery: "Battery"
        case .processes: "Processes"
        }
    }
    var detailSummary: String {
        switch self {
        case .cpu: "Per-core bars by cluster, user / system split, load average, uptime"
        case .gpu: "Renderer and tiler load, GPU memory, history"
        case .memory: "App / wired / compressed / cached, pressure, swap"
        case .disk: "Read / write speed and every mounted volume"
        case .network: "Each interface with its local address, totals since launch"
        case .sensors: "Every temperature sensor, fan speeds with their range, system power"
        case .battery: "Health, cycles, power, adapter, time on battery, charge limit"
        case .processes: "Longer list, switchable between CPU and memory"
        }
    }
}

enum AlertKind: String, CaseIterable, Identifiable {
    case cpuTemperature, memoryPressure, diskSpace, batteryLow, batteryCharged, batteryHealth
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cpuTemperature: "CPU temperature stays above"
        case .memoryPressure: "Memory pressure reaches"
        case .diskSpace: "Startup disk has less than"
        case .batteryLow: "Battery drops to"
        case .batteryCharged: "Battery charges to"
        case .batteryHealth: "Battery health falls below"
        }
    }
    var defaultThreshold: Double {
        switch self {
        case .cpuTemperature: 95       // °C
        case .memoryPressure: 4        // MemoryUsage.Pressure raw value: 2 warning, 4 critical
        case .diskSpace: 10            // GB free
        case .batteryLow: 15           // %
        case .batteryCharged: 80       // %
        case .batteryHealth: 80        // %
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .cpuTemperature: 60...110
        case .memoryPressure: 2...4
        case .diskSpace: 1...500
        case .batteryLow: 5...50
        case .batteryCharged: 50...100
        case .batteryHealth: 50...95
        }
    }
    var step: Double {
        switch self {
        case .cpuTemperature, .batteryLow, .batteryCharged, .batteryHealth: 5
        case .diskSpace: 1
        case .memoryPressure: 2
        }
    }
}

struct MonitorPrefs: Equatable {
    static let intervals: [Double] = [1, 2, 3, 5, 10]
    static let processCounts = [3, 5, 8, 10]
    static let compactProcessCount = 3

    // Menu bar
    var showIcon = true
    var widgets: [StatusWidget] = []          // enabled, in display order
    var widgetOrder: [StatusWidget] = StatusWidget.allCases   // all, in list order
    var widgetLabels = true
    // Panel
    var blockOrder: [PanelBlock] = PanelBlock.allCases
    var hiddenBlocks: Set<PanelBlock> = []
    var detailedBlocks: Set<PanelBlock> = []
    var processCount = 5
    var processesByMemory = false
    // Readings
    var interval: Double = 2
    var fahrenheit = false
    var networkInterface = ""                 // "" = all physical interfaces
    var showAllSensors = false
    // Alerts
    var alertsEnabled: Set<AlertKind> = []
    var alertThresholds: [AlertKind: Double] = [:]

    var visibleBlocks: [PanelBlock] { blockOrder.filter { !hiddenBlocks.contains($0) } }
    func threshold(_ kind: AlertKind) -> Double {
        let value = alertThresholds[kind] ?? kind.defaultThreshold
        return min(max(value, kind.range.lowerBound), kind.range.upperBound)
    }
    /// The menu bar item can never be empty: with nothing selected the icon comes back.
    var effectiveShowIcon: Bool { showIcon || widgets.isEmpty }

    // MARK: Pure list helpers

    /// "cpu,network,bogus,cpu" -> [.cpu, .network]
    static func parseList<T: RawRepresentable>(_ raw: String, as type: T.Type = T.self) -> [T] where T.RawValue == String, T: Hashable {
        var seen: Set<T> = []
        return raw.split(separator: ",").compactMap { T(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
            .filter { seen.insert($0).inserted }
    }
    static func joinList<T: RawRepresentable>(_ items: [T]) -> String where T.RawValue == String {
        items.map(\.rawValue).joined(separator: ",")
    }
    /// A stored order may predate newer cases: keep it and append whatever is missing.
    static func completeOrder<T: Hashable>(_ stored: [T], all: [T]) -> [T] {
        stored + all.filter { !stored.contains($0) }
    }
    /// Moves `item` one place up (-1) or down (+1); no-op at the ends.
    static func moved<T: Equatable>(_ item: T, by offset: Int, in list: [T]) -> [T] {
        guard let index = list.firstIndex(of: item) else { return list }
        let target = index + offset
        guard list.indices.contains(target) else { return list }
        var out = list
        out.swapAt(index, target)
        return out
    }
    /// The old single-choice `status.style` preference mapped onto widgets.
    static func widgets(forLegacyStyle style: String) -> [StatusWidget] {
        switch style {
        case "cpu": [.cpu]
        case "cpuMemory": [.cpu, .memory]
        case "network": [.network]
        default: []
        }
    }

    // MARK: Persistence (flat keys, so `defaults write` and `-key value` launch arguments work)

    enum Key {
        static let showIcon = "monitor.status.showIcon"
        static let widgets = "monitor.status.widgets"
        static let widgetOrder = "monitor.status.order"
        static let widgetLabels = "monitor.status.labels"
        static let blockOrder = "monitor.panel.order"
        static let hiddenBlocks = "monitor.panel.hidden"
        static let detailedBlocks = "monitor.panel.detailed"
        static let processCount = "monitor.processes.count"
        static let processesByMemory = "monitor.processes.byMemory"
        static let interval = "monitor.interval"
        static let fahrenheit = "monitor.fahrenheit"
        static let networkInterface = "monitor.network.interface"
        static let showAllSensors = "monitor.sensors.showAll"
        static let legacyStyle = "status.style"
        static func alertEnabled(_ kind: AlertKind) -> String { "monitor.alert.\(kind.rawValue).enabled" }
        static func alertThreshold(_ kind: AlertKind) -> String { "monitor.alert.\(kind.rawValue).threshold" }
        static func alertLastFired(_ kind: AlertKind) -> String { "monitor.alert.\(kind.rawValue).lastFired" }
    }

    static func load(_ defaults: UserDefaults = .standard) -> MonitorPrefs {
        var prefs = MonitorPrefs()
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        prefs.showIcon = bool(Key.showIcon, true)
        if let raw = defaults.string(forKey: Key.widgets) {
            prefs.widgets = parseList(raw)
        } else if let legacy = defaults.string(forKey: Key.legacyStyle) {
            // One-time migration of the old "Icon only / CPU / CPU and memory / Network speed" choice.
            prefs.widgets = widgets(forLegacyStyle: legacy)
            defaults.set(joinList(prefs.widgets), forKey: Key.widgets)
        }
        defaults.removeObject(forKey: Key.legacyStyle)
        let storedOrder: [StatusWidget] = parseList(defaults.string(forKey: Key.widgetOrder) ?? "")
        // Enabled widgets keep their saved order even if the order key is missing.
        prefs.widgetOrder = completeOrder(completeOrder(storedOrder, all: prefs.widgets), all: StatusWidget.allCases)
        prefs.widgets = prefs.widgetOrder.filter { prefs.widgets.contains($0) }
        prefs.widgetLabels = bool(Key.widgetLabels, true)
        prefs.blockOrder = completeOrder(parseList(defaults.string(forKey: Key.blockOrder) ?? ""), all: PanelBlock.allCases)
        prefs.hiddenBlocks = Set(parseList(defaults.string(forKey: Key.hiddenBlocks) ?? "") as [PanelBlock])
        prefs.detailedBlocks = Set(parseList(defaults.string(forKey: Key.detailedBlocks) ?? "") as [PanelBlock])
        let count = defaults.integer(forKey: Key.processCount)
        prefs.processCount = processCounts.contains(count) ? count : 5
        prefs.processesByMemory = bool(Key.processesByMemory, false)
        let interval = defaults.double(forKey: Key.interval)
        prefs.interval = intervals.contains(interval) ? interval : 2
        prefs.fahrenheit = bool(Key.fahrenheit, false)
        prefs.networkInterface = defaults.string(forKey: Key.networkInterface) ?? ""
        prefs.showAllSensors = bool(Key.showAllSensors, false)
        for kind in AlertKind.allCases {
            if bool(Key.alertEnabled(kind), false) { prefs.alertsEnabled.insert(kind) }
            if defaults.object(forKey: Key.alertThreshold(kind)) != nil {
                prefs.alertThresholds[kind] = defaults.double(forKey: Key.alertThreshold(kind))
            }
        }
        return prefs
    }

    /// Writes only what differs from `old`, so untouched keys stay unset (and overridable).
    func save(changedFrom old: MonitorPrefs, to defaults: UserDefaults = .standard) {
        if showIcon != old.showIcon { defaults.set(showIcon, forKey: Key.showIcon) }
        if widgets != old.widgets { defaults.set(Self.joinList(widgets), forKey: Key.widgets) }
        if widgetOrder != old.widgetOrder { defaults.set(Self.joinList(widgetOrder), forKey: Key.widgetOrder) }
        if widgetLabels != old.widgetLabels { defaults.set(widgetLabels, forKey: Key.widgetLabels) }
        if blockOrder != old.blockOrder { defaults.set(Self.joinList(blockOrder), forKey: Key.blockOrder) }
        if hiddenBlocks != old.hiddenBlocks {
            defaults.set(Self.joinList(PanelBlock.allCases.filter(hiddenBlocks.contains)), forKey: Key.hiddenBlocks)
        }
        if detailedBlocks != old.detailedBlocks {
            defaults.set(Self.joinList(PanelBlock.allCases.filter(detailedBlocks.contains)), forKey: Key.detailedBlocks)
        }
        if processCount != old.processCount { defaults.set(processCount, forKey: Key.processCount) }
        if processesByMemory != old.processesByMemory { defaults.set(processesByMemory, forKey: Key.processesByMemory) }
        if interval != old.interval { defaults.set(interval, forKey: Key.interval) }
        if fahrenheit != old.fahrenheit { defaults.set(fahrenheit, forKey: Key.fahrenheit) }
        if networkInterface != old.networkInterface { defaults.set(networkInterface, forKey: Key.networkInterface) }
        if showAllSensors != old.showAllSensors { defaults.set(showAllSensors, forKey: Key.showAllSensors) }
        for kind in AlertKind.allCases {
            if alertsEnabled.contains(kind) != old.alertsEnabled.contains(kind) {
                defaults.set(alertsEnabled.contains(kind), forKey: Key.alertEnabled(kind))
            }
            if alertThresholds[kind] != old.alertThresholds[kind], let value = alertThresholds[kind] {
                defaults.set(value, forKey: Key.alertThreshold(kind))
            }
        }
    }
}
