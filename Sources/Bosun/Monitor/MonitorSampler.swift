import Foundation

/// Everything the UI shows, as of one sample. Parts that were not due this round keep
/// their last value.
struct MonitorSnapshot {
    var at = Date()
    var cpu = CPULoad()
    var load = SystemLoad()
    var gpu: GPUInfo?
    var memory = MemoryUsage()
    var network = NetworkReading()
    var disk = DiskReading()
    var sensors = SensorReading()
    var battery: BatteryInfo?
    var topCPU: [ProcessLoad] = []
    var topMemory: [ProcessLoad] = []
    // Oldest first, at most `MonitorSampler.historyLength` entries.
    var cpuHistory: [Double] = []
    var gpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var downHistory: [Double] = []
    var upHistory: [Double] = []
}

/// What has to be read, derived from what is on screen. Anything not asked for is not read.
struct MonitorNeeds: Equatable {
    var visible = false                    // panel or settings open: publish every sample
    var gpu = false
    var sensors: Sensors.Detail?           // nil = none
    var battery = false
    var volumes = false
    var diskIO = false
    var networkDetails = false
    var processes = false
    var processLimit = 5
    var countedInterface = ""
    var widgets: [StatusWidget] = []
    var alerts: Set<AlertKind> = []

    /// Pure: which readers the current screen state requires.
    static func make(prefs: MonitorPrefs, panelVisible: Bool, settingsVisible: Bool) -> MonitorNeeds {
        var needs = MonitorNeeds()
        needs.visible = panelVisible || settingsVisible
        needs.countedInterface = prefs.networkInterface
        needs.widgets = prefs.widgets
        needs.alerts = prefs.alertsEnabled
        func raise(_ detail: Sensors.Detail) { needs.sensors = max(needs.sensors ?? detail, detail) }

        if panelVisible {
            for block in prefs.visibleBlocks {
                let detailed = prefs.detailedBlocks.contains(block)
                switch block {
                case .cpu, .memory: break
                case .gpu: needs.gpu = true
                case .disk:
                    needs.volumes = true
                    needs.diskIO = detailed
                case .network: needs.networkDetails = detailed
                case .sensors: raise(detailed ? .named : .summary)
                case .battery: needs.battery = true
                case .processes:
                    needs.processes = true
                    needs.processLimit = detailed ? prefs.processCount : MonitorPrefs.compactProcessCount
                }
            }
        }
        if settingsVisible {
            // The settings tab previews the menu bar item and lists the sensors and interfaces.
            needs.gpu = true
            needs.battery = true
            needs.volumes = true
            needs.networkDetails = true
            raise(prefs.showAllSensors ? .all : .named)
        }
        for widget in prefs.widgets {
            switch widget {
            case .gpu: needs.gpu = true
            case .temperature: raise(.cpu)
            case .battery: needs.battery = true
            case .disk: needs.volumes = true
            case .cpu, .cpuGraph, .cpuBars, .memory, .network: break
            }
        }
        return needs
    }
}

/// Owns every reader and its previous counters. Lives on the monitor queue; nothing in
/// here may be touched from another thread.
final class MonitorSampler {
    static let historyLength = 60
    /// How often the slow-moving readings are refreshed.
    static let batteryPeriod: (visible: TimeInterval, hidden: TimeInterval) = (10, 60)
    static let volumesPeriod: (visible: TimeInterval, hidden: TimeInterval) = (10, 60)
    static let hiddenSensorPeriod: TimeInterval = 5
    static let alertPeriod: TimeInterval = 10

    private let cpuSampler = CPUSampler()
    private let networkSampler = NetworkSampler()
    private let gpuSampler = GPUSampler()
    private let diskIO = DiskIOSampler()
    private let processes = ProcessSampler()
    private var timeline = BatteryTimeline.load()
    private var alertEngine: AlertEngine
    private(set) var snapshot = MonitorSnapshot()

    private var batteryAt: TimeInterval = -.infinity
    private var volumesAt: TimeInterval = -.infinity
    private var sensorsAt: TimeInterval = -.infinity
    private var alertsAt: TimeInterval = -.infinity
    private var cheapAt: TimeInterval = -.infinity
    private var lastNeeds = MonitorNeeds()

    init() {
        var lastFired: [AlertKind: TimeInterval] = [:]
        for kind in AlertKind.allCases {
            let time = UserDefaults.standard.double(forKey: MonitorPrefs.Key.alertLastFired(kind))
            if time > 0 { lastFired[kind] = time }
        }
        alertEngine = AlertEngine(lastFired: lastFired)
    }

    /// One sampling round. Returns the alerts that fired.
    func sample(_ needs: MonitorNeeds, thresholds: (AlertKind) -> Double, fahrenheit: Bool) -> [AlertEvent] {
        let now = ProcessInfo.processInfo.systemUptime
        if needs != lastNeeds {
            // Something new came on screen: read it now instead of waiting out its period.
            if needs.battery && !lastNeeds.battery || needs.visible && !lastNeeds.visible { batteryAt = -.infinity }
            if needs.volumes && !lastNeeds.volumes || needs.visible && !lastNeeds.visible { volumesAt = -.infinity }
            if needs.sensors != lastNeeds.sensors { sensorsAt = -.infinity }
            if !needs.processes { processes.reset() }
            if !needs.diskIO {
                diskIO.reset()
                snapshot.disk.readRate = nil
                snapshot.disk.writeRate = nil
            }
            lastNeeds = needs
        }

        // Always: three cheap kernel calls (about 50 µs together), which keep the histories alive.
        // Skipped when the previous sample is under half a second old (an extra sample taken
        // because a setting changed): usage over so short a window is mostly noise.
        let advance = now - cheapAt >= 0.45
        snapshot.at = Date()
        if advance {
            cheapAt = now
            sampleCounters(needs)
        }
        if needs.visible { snapshot.load = SystemLoad.read() }

        if needs.gpu {
            if advance || snapshot.gpu == nil {
                snapshot.gpu = gpuSampler.sample()
                push(&snapshot.gpuHistory, snapshot.gpu?.utilization ?? 0)
            }
        } else if !snapshot.gpuHistory.isEmpty {
            snapshot.gpuHistory = []
            snapshot.gpu = nil
        }

        let alertsDue = !needs.alerts.isEmpty && now - alertsAt >= Self.alertPeriod
        var sensorDetail = needs.sensors
        if alertsDue, needs.alerts.contains(.cpuTemperature), sensorDetail == nil { sensorDetail = .cpu }
        if let sensorDetail, needs.visible || alertsDue || now - sensorsAt >= Self.hiddenSensorPeriod {
            sensorsAt = now
            snapshot.sensors = Sensors.read(sensorDetail)
        }

        let wantsBattery = needs.battery || !needs.alerts.isDisjoint(with: [.batteryLow, .batteryCharged, .batteryHealth])
        if wantsBattery, now - batteryAt >= (needs.visible && needs.battery ? Self.batteryPeriod.visible : Self.batteryPeriod.hidden) {
            batteryAt = now
            var battery = BatteryInfo.read()
            if battery != nil {
                let before = timeline
                timeline.update(onAC: battery!.onAC, percent: battery!.percent, now: snapshot.at)
                if timeline != before { timeline.save() }
                battery!.timeline = timeline
            }
            snapshot.battery = battery
        }

        let wantsVolumes = needs.volumes || needs.alerts.contains(.diskSpace)
        if wantsVolumes, now - volumesAt >= (needs.visible && needs.volumes ? Self.volumesPeriod.visible : Self.volumesPeriod.hidden) {
            volumesAt = now
            snapshot.disk.volumes = DiskVolumes.read()
        }
        if needs.diskIO, advance, let rates = diskIO.sample() {
            snapshot.disk.readRate = rates.read
            snapshot.disk.writeRate = rates.write
        }

        if needs.processes, advance || !processes.hasBaseline, let top = processes.sample(limit: needs.processLimit) {
            snapshot.topCPU = top.byCPU
            snapshot.topMemory = top.byMemory
        }

        guard alertsDue else { return [] }
        alertsAt = now
        let inputs = AlertInputs(
            cpuTemperature: needs.alerts.contains(.cpuTemperature) ? snapshot.sensors.cpuTemperature : nil,
            memoryPressure: snapshot.memory.pressure,
            bootFreeBytes: wantsVolumes ? snapshot.disk.boot?.available : nil,
            battery: wantsBattery ? snapshot.battery : nil)
        let wallClock = snapshot.at.timeIntervalSince1970
        let events = alertEngine.evaluate(inputs, enabled: needs.alerts, thresholds: thresholds,
                                          fahrenheit: fahrenheit, now: wallClock)
        for event in events {
            // Persisted so a relaunch cannot bypass the cooldown.
            UserDefaults.standard.set(wallClock, forKey: MonitorPrefs.Key.alertLastFired(event.kind))
        }
        return events
    }

    /// The part of a round that always runs: CPU ticks, VM statistics, interface counters.
    func sampleCounters(_ needs: MonitorNeeds) {
        snapshot.cpu = cpuSampler.sample()
        snapshot.memory = MemoryUsage.read()
        snapshot.network = networkSampler.sample(counted: needs.countedInterface, withDetails: needs.networkDetails)
        push(&snapshot.cpuHistory, snapshot.cpu.total)
        push(&snapshot.memoryHistory, snapshot.memory.fraction)
        push(&snapshot.downHistory, snapshot.network.down)
        push(&snapshot.upHistory, snapshot.network.up)
    }

    private func push(_ history: inout [Double], _ value: Double) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }
}
