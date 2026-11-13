import AppKit
import Darwin

private func threadCPUSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9
}

enum MonitorChecks {
    static let all: [SelfTest.Check] = readers + logic

    // MARK: Live readers (this machine)

    private static let readers: [SelfTest.Check] = [
        ("monitor: cpu usage is a sane fraction, user + system = total", {
            let sampler = CPUSampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 0.5)
            let result = sampler.sample()
            guard result.cores.count == ProcessInfo.processInfo.processorCount else {
                return "got \(result.cores.count) cores, expected \(ProcessInfo.processInfo.processorCount)"
            }
            guard result.total > 0, result.total <= 1 else { return "total \(result.total)" }
            guard abs(result.user + result.system - result.total) < 0.001 else { return "user \(result.user) + system \(result.system) != \(result.total)" }
            return nil
        }),
        ("monitor: core topology covers every core once", {
            let topology = CPUTopology.current
            let indices = topology.clusters.flatMap(\.indices).sorted()
            guard indices == Array(0..<ProcessInfo.processInfo.processorCount) else { return "\(topology.clusters)" }
            let efficiency = sysctlInt("hw.perflevel1.logicalcpu")
            if sysctlInt("hw.nperflevels") == 2, topology.clusters.first?.indices.count != efficiency {
                return "efficiency cluster \(topology.clusters.first?.indices ?? []) but sysctl says \(efficiency) cores"
            }
            return nil
        }),
        ("monitor: memory breakdown adds up to physical memory", {
            let memory = MemoryUsage.read()
            guard memory.used > 1 << 30, memory.used <= memory.total else { return "used \(memory.used) of \(memory.total)" }
            let sum = memory.app + memory.wired + memory.compressed + memory.cached + memory.free
            guard Double(sum) > Double(memory.total) * 0.75, Double(sum) < Double(memory.total) * 1.05 else {
                return "app+wired+compressed+cached+free = \(sum) of \(memory.total)"
            }
            guard memory.swapUsed <= memory.swapTotal else { return "swap \(memory.swapUsed) of \(memory.swapTotal)" }
            return nil
        }),
        ("monitor: load average and boot time read", {
            let load = SystemLoad.read()
            guard load.one > 0, load.one < 1000, let boot = load.bootTime, boot < Date(), boot > Date(timeIntervalSince1970: 1_500_000_000)
            else { return "\(load)" }
            return nil
        }),
        ("monitor: network counters are non-zero and monotonic, interfaces carry addresses", {
            let first = NetworkSampler.totals()
            let sampler = NetworkSampler()
            _ = sampler.sample(withDetails: true)
            Thread.sleep(forTimeInterval: 0.3)
            let second = NetworkSampler.totals()
            guard first.rx > 0, second.rx >= first.rx, second.tx >= first.tx else { return "\(first) then \(second)" }
            let reading = sampler.sample(withDetails: true)
            guard reading.down >= 0, reading.up >= 0, reading.down < 1e10 else { return "rates \(reading.down) / \(reading.up)" }
            guard let primary = reading.interfaces.first(where: { !$0.address.isEmpty }) else {
                return "no interface with an address in \(reading.interfaces.map(\.name))"
            }
            guard primary.address.contains(".") || primary.address.contains(":") else { return "address \(primary.address)" }
            guard !reading.interfaces.contains(where: { $0.name.hasPrefix("lo") }) else { return "loopback listed" }
            return nil
        }),
        ("monitor: volumes include the startup disk, disk I/O counters read", {
            let volumes = DiskVolumes.read()
            guard let boot = volumes.first, boot.isBoot, boot.path == "/" else { return "first volume \(volumes.first.map { "\($0)" } ?? "none")" }
            guard boot.total > 0, boot.available > 0, boot.available < boot.total else { return "\(boot)" }
            guard let io = DiskIOSampler.counters(), io.read > 0, io.written > 0 else { return "no block storage statistics" }
            return nil
        }),
        ("monitor: GPU utilisation reads", {
            let sampler = GPUSampler()
            guard let gpu = sampler.sample() else { return "no IOAccelerator performance statistics" }
            guard (0...1).contains(gpu.utilization), !gpu.model.isEmpty else { return "\(gpu)" }
            return nil
        }),
        ("monitor: battery reads on this laptop", {
            guard let battery = BatteryInfo.read() else { return "no battery found" }
            guard (0...100).contains(battery.percent), battery.cycleCount > 0 else { return "\(battery)" }
            guard let health = battery.health, (0.3...1.2).contains(health) else { return "health \(String(describing: battery.health))" }
            guard let temperature = battery.temperature, (0...70).contains(temperature) else { return "temperature \(String(describing: battery.temperature))" }
            if let limit = battery.chargeLimit, !(50..<100).contains(limit) { return "charge limit \(limit)" }
            return nil
        }),
        ("monitor: process list covers own and system processes without waiting on ps every sweep", {
            let sampler = ProcessSampler()
            guard sampler.sample(limit: 5) == nil else { return "first sweep should only set the baseline" }
            // Burn a little CPU so this process must show up with a non-zero share.
            let until = Date().addingTimeInterval(0.4)
            var x = 0.0
            while Date() < until { x += sin(x + 1) }
            let started = threadCPUSeconds()
            guard let top = sampler.sample(limit: 4000) else { return "second sweep returned nothing" }
            let cost = threadCPUSeconds() - started
            let me = ProcessInfo.processInfo.processIdentifier
            guard let own = top.byCPU.first(where: { $0.pid == me }) else { return "own process missing" }
            guard own.cpu > 30, own.cpu < 400 else { return "own CPU \(own.cpu)% after a busy loop" }
            guard own.memory > 1 << 20, !own.name.isEmpty else { return "own row \(own)" }
            guard top.byMemory.contains(where: { $0.pid == 1 && $0.memory > 0 }) else { return "launchd (another user's process) missing" }
            guard top.byMemory.first!.memory >= top.byMemory.last!.memory else { return "memory list not sorted" }
            guard top.byCPU.contains(where: { $0.icon != nil }) else { return "no process got an app icon" }
            // 4000 rows also resolves every name, so this is far above a real sweep.
            guard cost < 0.5 else { return String(format: "sweep took %.0f ms of CPU", cost * 1000) }
            return nil
        }),
        ("monitor: a closed-panel sample costs under 0.5 ms of CPU", {
            let sampler = MonitorSampler()
            let needs = MonitorNeeds.make(prefs: MonitorPrefs(), panelVisible: false, settingsVisible: false)
            _ = sampler.sample(needs, thresholds: { _ in 0 }, fahrenheit: false)
            let rounds = 200
            let started = threadCPUSeconds()
            let prefs = MonitorPrefs()
            for _ in 0..<rounds {
                // Exactly what a tick does with the panel closed: the counters, then deciding
                // that the menu bar item has not changed. (Calling sample() itself in a loop
                // would skip the counters, which are not re-read within half a second.)
                sampler.sampleCounters(needs)
                guard StatusComposer.pieces(prefs: prefs, snapshot: sampler.snapshot) == [.icon] else { return "default item is not the icon" }
            }
            let each = (threadCPUSeconds() - started) / Double(rounds)
            Log.info(String(format: "closed-panel sample: %.0f µs of CPU each", each * 1e6), "monitor")
            // For the record: one full round with the compact panel open, and with every block detailed.
            var open = MonitorPrefs()
            for (label, detailed) in [("compact", Set<PanelBlock>()), ("detailed", Set(PanelBlock.allCases))] {
                open.detailedBlocks = detailed
                let visible = MonitorNeeds.make(prefs: open, panelVisible: true, settingsVisible: false)
                _ = sampler.sample(visible, thresholds: { _ in 0 }, fahrenheit: false)
                var costs: [Double] = []
                for _ in 0..<3 {
                    Thread.sleep(forTimeInterval: 0.5)
                    let before = threadCPUSeconds()
                    _ = sampler.sample(visible, thresholds: { _ in 0 }, fahrenheit: false)
                    costs.append(threadCPUSeconds() - before)
                }
                Log.info(String(format: "open-panel sample (%@): %.1f ms of CPU (excluding the ps child every 6 s)", label, costs.sorted()[1] * 1000), "monitor")
            }
            return each < 0.0005 ? nil : String(format: "%.0f µs per sample", each * 1e6)
        }),
    ]

    // MARK: Pure logic

    private static let logic: [SelfTest.Check] = [
        ("monitor: cluster labels", {
            let topology = CPUTopology.make(types: ["E", "E", "P", "P", "P"])
            guard topology.labels() == ["E1", "E2", "P1", "P2", "P3"] else { return "\(topology.labels())" }
            guard topology.clusters.map(\.name) == ["Efficiency", "Performance"] else { return "\(topology.clusters)" }
            guard abs(CPUTopology.mean([0.2, 0.4, 1, 1, 1], topology.clusters[0]) - 0.3) < 1e-9 else { return "mean" }
            // Unknown layout: one plain cluster, nothing dropped.
            let plain = CPUTopology.make(types: ["?", "?", "?"])
            return plain.clusters.count == 1 && plain.clusters[0].indices == [0, 1, 2] ? nil : "\(plain.clusters)"
        }),
        ("monitor: memory breakdown from VM counters", {
            var stats = vm_statistics64()
            stats.internal_page_count = 1000
            stats.purgeable_count = 100
            stats.wire_count = 300
            stats.compressor_page_count = 200
            stats.external_page_count = 400
            stats.free_count = 150
            stats.speculative_count = 50
            let memory = MemoryUsage.make(stats, pageSize: 1000, total: 2_000_000)
            let got = [memory.app, memory.wired, memory.compressed, memory.cached, memory.free, memory.used]
            return got == [900_000, 300_000, 200_000, 500_000, 100_000, 1_400_000] ? nil : "\(got)"
        }),
        ("monitor: formatting of rates, temperatures and durations", {
            let rates = [Format.rate(0), Format.rate(12_300), Format.rate(3_500_000), Format.rate(250_000_000), Format.rate(3e9), Format.rate(-5)]
            guard rates == ["0 K", "12 K", "3.3 M", "238 M", "2.8 G", "0 K"] else { return "\(rates)" }
            let temperatures = [Format.temperature(48.4, fahrenheit: false), Format.temperature(100, fahrenheit: true),
                                Format.degrees(48.6, fahrenheit: false), Format.degrees(0, fahrenheit: true)]
            guard temperatures == ["48 °C", "212 °F", "49°", "32°"] else { return "\(temperatures)" }
            let durations = [Format.duration(45), Format.duration(12 * 60), Format.duration(3 * 3600 + 5 * 60), Format.duration(16 * 86400 + 4 * 3600)]
            return durations == ["45 s", "12 min", "3 h 05 min", "16 d 4 h"] ? nil : "\(durations)"
        }),
        ("monitor: interface filtering and counting", {
            guard NetworkSampler.isCounted("en0", selection: ""), !NetworkSampler.isCounted("utun4", selection: ""),
                  NetworkSampler.isCounted("utun4", selection: "utun4"), !NetworkSampler.isCounted("en0", selection: "utun4")
            else { return "isCounted" }
            let listed = NetworkSampler.listed([
                InterfaceReading(name: "lo0", address: "127.0.0.1", isUp: true),
                InterfaceReading(name: "utun4", address: "198.18.0.1", isUp: true),
                InterfaceReading(name: "en5", address: "", totalDown: 10, isUp: true),
                InterfaceReading(name: "en0", address: "192.168.1.5", isUp: true),
                InterfaceReading(name: "en1", address: "10.0.0.2", isUp: false),
                InterfaceReading(name: "awdl0", address: "", totalDown: 99, isUp: true),
                InterfaceReading(name: "en9", address: "", isUp: true),
            ]).map(\.name)
            return listed == ["en0", "en5", "utun4"] ? nil : "\(listed)"
        }),
        ("monitor: volume ordering", {
            func volume(_ name: String, boot: Bool = false, isInternal: Bool = true, network: Bool = false) -> VolumeInfo {
                VolumeInfo(path: "/Volumes/\(name)", name: name, total: 100, available: 25, isBoot: boot, isInternal: isInternal, isNetwork: network)
            }
            let sorted = DiskVolumes.sorted([volume("NAS", isInternal: false, network: true), volume("USB", isInternal: false),
                                             volume("Data"), volume("Macintosh HD", boot: true)])
            guard sorted.map(\.name) == ["Macintosh HD", "Data", "USB", "NAS"] else { return "\(sorted.map(\.name))" }
            return abs(sorted[0].usedFraction - 0.75) < 1e-9 ? nil : "used \(sorted[0].usedFraction)"
        }),
        ("monitor: GPU statistics parse", {
            let gpu = GPUInfo.parse(["Device Utilization %": 40, "Renderer Utilization %": 39, "Tiler Utilization %": 140,
                                     "In use system memory": 981_745_664], model: "Apple M1 Pro")
            guard let gpu, gpu.utilization == 0.4, gpu.renderer == 0.39, gpu.tiler == 1, gpu.memoryInUse == 981_745_664 else { return "\(String(describing: gpu))" }
            return GPUInfo.parse(["recoveryCount": 0], model: "") == nil ? nil : "parsed a dictionary without utilisation"
        }),
        ("monitor: ps output and app bundle paths parse", {
            let parsed = ProcessSampler.parsePS("  501  12.5  20480 Google Chrome Helper (Renderer)\n    1   0.0   9000 launchd\nbogus line\n")
            guard parsed == [ProcessSampler.PSRow(pid: 501, cpu: 12.5, rssKB: 20480, name: "Google Chrome Helper (Renderer)"),
                             ProcessSampler.PSRow(pid: 1, cpu: 0, rssKB: 9000, name: "launchd")] else { return "\(parsed)" }
            let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"
            guard ProcessSampler.appBundlePath(helper) == "/Applications/Google Chrome.app" else { return "\(ProcessSampler.appBundlePath(helper) ?? "nil")" }
            guard ProcessSampler.displayName(path: helper) == "Google Chrome Helper (Renderer)" else { return "name" }
            return ProcessSampler.appBundlePath("/usr/libexec/mdworker") == nil ? nil : "daemon got a bundle"
        }),
        ("monitor: battery dictionary parses, charge-limit state", {
            let props: [String: Any] = [
                "CurrentCapacity": 95, "MaxCapacity": 100, "IsCharging": false, "ExternalConnected": true, "CycleCount": 260,
                "DesignCycleCount9C": 1000, "Voltage": 12410, "Amperage": NSNumber(value: UInt64(bitPattern: -1500)), "TimeRemaining": 65535,
                "AdapterDetails": ["Watts": 65, "Description": "pd charger"],
                "PowerTelemetryData": ["SystemPowerIn": 37925],
                "BatteryData": ["FullChargeCapacity": 6945, "NominalChargeCapacity": 7189, "DesignCapacity": 8694, "RemainingCapacity": 6529],
            ]
            guard var battery = BatteryInfo.parse(props) else { return "did not parse" }
            guard battery.percent == 95, battery.cycleCount == 260, battery.fullChargeCapacity == 6945, battery.nominalCapacity == 7189,
                  battery.designCapacity == 8694, battery.adapterWatts == 65, battery.adapterName == "pd charger",
                  battery.minutesRemaining == nil, battery.amperage == -1500, battery.remainingCapacity == 6529 else { return "\(battery)" }
            guard let health = battery.health, abs(health - 0.7988) < 0.001, let watts = battery.watts, abs(watts + 18.615) < 0.001,
                  battery.systemPowerIn == 37.925 else { return "health \(String(describing: battery.health)) watts \(String(describing: battery.watts))" }
            guard battery.stateText == "On power, not charging" else { return battery.stateText }
            battery.chargeLimit = 95
            guard battery.isHeldAtLimit, battery.stateText == "Holding at 95% limit" else { return battery.stateText }
            battery.percent = 60
            guard !battery.isHeldAtLimit else { return "held at 60%" }
            guard Sensors.parseChargeLimit([0x5f, 5, 5]) == 95, Sensors.parseChargeLimit([100, 5, 5]) == nil,
                  Sensors.parseChargeLimit([0]) == nil, Sensors.parseChargeLimit([]) == nil else { return "charge limit bytes" }
            return BatteryInfo.parse(["MaxCapacity": 0]) == nil ? nil : "parsed an empty battery"
        }),
        ("monitor: time-on-battery tracking", {
            let t0 = Date(timeIntervalSince1970: 1_000_000)
            var timeline = BatteryTimeline()
            // Started while already on battery: start unknown, so only a lower bound.
            timeline.update(onAC: false, percent: 80, now: t0)
            guard timeline.unpluggedAt == t0, !timeline.observed else { return "launch on battery: \(timeline)" }
            timeline.update(onAC: false, percent: 70, now: t0.addingTimeInterval(600))
            guard timeline.timeOnBattery(now: t0.addingTimeInterval(600)) == 600 else { return "elapsed" }
            timeline.update(onAC: true, percent: 71, now: t0.addingTimeInterval(700))
            guard timeline.unpluggedAt == nil else { return "plugging in should clear" }
            timeline.update(onAC: false, percent: 90, now: t0.addingTimeInterval(4000))
            guard timeline.observed, timeline.percentAtUnplug == 90, timeline.unpluggedAt == t0.addingTimeInterval(4000) else { return "observed unplug: \(timeline)" }
            // A restored start that the charge level contradicts is discarded.
            var restored = BatteryTimeline(unpluggedAt: t0, percentAtUnplug: 40, observed: true)
            restored.update(onAC: false, percent: 85, now: t0.addingTimeInterval(9000))
            guard restored.unpluggedAt == t0.addingTimeInterval(9000), !restored.observed else { return "stale restore kept: \(restored)" }
            var kept = BatteryTimeline(unpluggedAt: t0, percentAtUnplug: 90, observed: true)
            kept.update(onAC: false, percent: 60, now: t0.addingTimeInterval(9000))
            return kept.unpluggedAt == t0 && kept.observed ? nil : "valid restore dropped: \(kept)"
        }),
        ("monitor: preferences parse, reorder, persist and migrate", {
            let widgets: [StatusWidget] = MonitorPrefs.parseList("cpu, network,bogus,cpu,,battery")
            guard widgets == [.cpu, .network, .battery] else { return "\(widgets)" }
            guard MonitorPrefs.joinList(widgets) == "cpu,network,battery" else { return "join" }
            guard MonitorPrefs.completeOrder([PanelBlock.disk, .cpu], all: PanelBlock.allCases)
                    == [.disk, .cpu, .gpu, .memory, .network, .sensors, .battery, .processes] else { return "completeOrder" }
            guard MonitorPrefs.moved(2, by: -1, in: [1, 2, 3]) == [2, 1, 3], MonitorPrefs.moved(3, by: 1, in: [1, 2, 3]) == [1, 2, 3],
                  MonitorPrefs.moved(9, by: 1, in: [1, 2, 3]) == [1, 2, 3] else { return "moved" }
            guard MonitorPrefs.widgets(forLegacyStyle: "cpuMemory") == [.cpu, .memory], MonitorPrefs.widgets(forLegacyStyle: "icon").isEmpty
            else { return "legacy mapping" }

            let suite = "bosun.selftest.\(ProcessInfo.processInfo.processIdentifier)"
            guard let defaults = UserDefaults(suiteName: suite) else { return "no defaults suite" }
            defer { defaults.removePersistentDomain(forName: suite) }
            // Defaults: the plain icon, nothing else, no alerts.
            let fresh = MonitorPrefs.load(defaults)
            guard fresh == MonitorPrefs(), fresh.widgets.isEmpty, fresh.showIcon, fresh.alertsEnabled.isEmpty else { return "defaults \(fresh)" }
            // The old single-choice style migrates once and the old key goes away.
            defaults.set("network", forKey: "status.style")
            let migrated = MonitorPrefs.load(defaults)
            guard migrated.widgets == [.network], defaults.object(forKey: "status.style") == nil,
                  defaults.string(forKey: MonitorPrefs.Key.widgets) == "network" else { return "migration \(migrated.widgets)" }
            // Round trip.
            var edited = migrated
            edited.widgetOrder = [.battery] + edited.widgetOrder.filter { $0 != .battery }
            edited.widgets = edited.widgetOrder.filter { [.battery, .network, .cpuGraph].contains($0) }
            edited.showIcon = false
            edited.blockOrder = [.processes] + PanelBlock.allCases.filter { $0 != .processes }
            edited.hiddenBlocks = [.gpu]
            edited.detailedBlocks = [.cpu, .battery]
            edited.interval = 5
            edited.fahrenheit = true
            edited.processCount = 8
            edited.alertsEnabled = [.diskSpace]
            edited.alertThresholds[.diskSpace] = 25
            edited.save(changedFrom: migrated, to: defaults)
            let reloaded = MonitorPrefs.load(defaults)
            guard reloaded == edited else { return "round trip:\n\(reloaded)\nvs\n\(edited)" }
            guard reloaded.widgets == [.battery, .network, .cpuGraph] else { return "widget order \(reloaded.widgets)" }
            // Out-of-range stored values fall back.
            defaults.set(0.01, forKey: MonitorPrefs.Key.interval)
            defaults.set(9999.0, forKey: MonitorPrefs.Key.alertThreshold(.diskSpace))
            let clamped = MonitorPrefs.load(defaults)
            return clamped.interval == 2 && clamped.threshold(.diskSpace) == 500 ? nil : "clamping \(clamped.interval) \(clamped.threshold(.diskSpace))"
        }),
        ("monitor: only what is on screen is read", {
            var prefs = MonitorPrefs()
            let idle = MonitorNeeds.make(prefs: prefs, panelVisible: false, settingsVisible: false)
            guard idle == MonitorNeeds() else { return "closed panel with defaults wants \(idle)" }
            let open = MonitorNeeds.make(prefs: prefs, panelVisible: true, settingsVisible: false)
            guard open.visible, open.gpu, open.sensors == .summary, open.battery, open.volumes, open.processes,
                  open.processLimit == MonitorPrefs.compactProcessCount, !open.diskIO, !open.networkDetails else { return "open compact panel wants \(open)" }
            prefs.hiddenBlocks = [.processes, .gpu, .sensors]
            prefs.detailedBlocks = [.disk, .network, .sensors]
            let trimmed = MonitorNeeds.make(prefs: prefs, panelVisible: true, settingsVisible: false)
            guard !trimmed.processes, !trimmed.gpu, trimmed.sensors == nil, trimmed.diskIO, trimmed.networkDetails else { return "trimmed panel wants \(trimmed)" }
            prefs = MonitorPrefs()
            prefs.widgets = [.temperature, .cpu]
            prefs.alertsEnabled = [.batteryLow]
            let widget = MonitorNeeds.make(prefs: prefs, panelVisible: false, settingsVisible: false)
            guard !widget.visible, widget.sensors == .cpu, !widget.gpu, !widget.processes, !widget.battery, widget.alerts == [.batteryLow]
            else { return "temperature widget wants \(widget)" }
            prefs.detailedBlocks = [.sensors, .processes]
            prefs.processCount = 8
            let detailed = MonitorNeeds.make(prefs: prefs, panelVisible: true, settingsVisible: false)
            guard detailed.sensors == .named, detailed.processLimit == 8 else { return "detailed wants \(detailed)" }
            prefs.showAllSensors = true
            let settings = MonitorNeeds.make(prefs: prefs, panelVisible: false, settingsVisible: true)
            return settings.visible && settings.sensors == .all && !settings.processes ? nil : "settings want \(settings)"
        }),
        ("monitor: alert hysteresis cannot spam", {
            // Fires only after `sustain` breaching readings, once per excursion.
            let hot = AlertRule(threshold: 95, above: true, margin: 5, sustain: 3, cooldown: 900)
            var state = AlertRule.State()
            var fired: [Int] = []
            let readings: [Double?] = [96, 97, 80, 96, 96, 96, 99, 99, 94, 96, 93, 91, 96, nil, 89, 96, 96, 96, 96]
            for (index, value) in readings.enumerated() where hot.step(&state, value: value, now: Double(index) * 10) { fired.append(index) }
            // 0-1: streak broken at 2. 3-5: fires at 5. 8-13: hovering inside the 5 degree band stays quiet.
            // 14 recovers (89 < 90) and re-arms; 15-17 breach again but inside the cooldown, so no second banner.
            guard fired == [5] else { return "hot sequence fired at \(fired)" }
            guard state.active else { return "second excursion should be latched" }
            // After the cooldown a new excursion notifies again.
            _ = hot.step(&state, value: 60, now: 2000)
            var later: [Double] = []
            for (index, value) in [96.0, 96, 96, 96].enumerated() where hot.step(&state, value: value, now: 2000 + Double(index + 1) * 10) { later.append(value) }
            guard later.count == 1 else { return "after cooldown fired \(later.count) times" }

            // A falling value: battery at or below 15 %, re-arms above 20 %.
            let low = AlertRule.rule(for: .batteryLow, threshold: 15)
            var battery = AlertRule.State()
            var lowFired: [Double] = []
            var clock = 0.0
            for value in [30.0, 16, 15, 14, 13, 16, 15, 19, 21, 15, 14] {
                clock += 3600
                if low.step(&battery, value: value, now: clock) { lowFired.append(value) }
            }
            guard lowFired == [15, 15] else { return "low battery fired at \(lowFired)" }

            // Engine: values per kind, disabled kinds stay silent, plugging in counts as recovered.
            var engine = AlertEngine()
            var info = BatteryInfo.parse(["CurrentCapacity": 10, "MaxCapacity": 100, "ExternalConnected": false, "CycleCount": 1])!
            var events = engine.evaluate(AlertInputs(memoryPressure: .critical, bootFreeBytes: 5_000_000_000, battery: info),
                                         enabled: [.batteryLow, .diskSpace], thresholds: { $0.defaultThreshold }, fahrenheit: false, now: 100)
            guard events.map(\.kind) == [.diskSpace, .batteryLow] else { return "engine fired \(events.map(\.kind))" }
            events = engine.evaluate(AlertInputs(bootFreeBytes: 5_000_000_000, battery: info),
                                     enabled: [.batteryLow, .diskSpace], thresholds: { $0.defaultThreshold }, fahrenheit: false, now: 110)
            guard events.isEmpty else { return "engine repeated \(events.map(\.kind))" }
            info.onAC = true
            guard AlertEngine.value(.batteryLow, AlertInputs(battery: info)) == 100, AlertEngine.value(.batteryCharged, AlertInputs(battery: info)) == 10,
                  AlertEngine.value(.diskSpace, AlertInputs(bootFreeBytes: 12_000_000_000)) == 12, AlertEngine.value(.cpuTemperature, AlertInputs()) == nil
            else { return "engine values" }
            // The persisted cooldown survives a relaunch.
            var relaunched = AlertEngine(lastFired: [.diskSpace: 100])
            events = relaunched.evaluate(AlertInputs(bootFreeBytes: 5_000_000_000), enabled: [.diskSpace],
                                         thresholds: { $0.defaultThreshold }, fahrenheit: false, now: 200)
            return events.isEmpty ? nil : "relaunch bypassed the cooldown"
        }),
        ("monitor: menu bar item layout is stable and defaults to the plain icon", {
            var snapshot = MonitorSnapshot()
            var prefs = MonitorPrefs()
            guard StatusComposer.pieces(prefs: prefs, snapshot: snapshot) == [.icon] else { return "default is not the plain icon" }
            guard StatusRenderer.image([.icon]) === WheelGlyph.menuBarImage else { return "default image is not the wheel glyph" }
            prefs.showIcon = false
            guard StatusComposer.pieces(prefs: prefs, snapshot: snapshot) == [.icon] else { return "the item can become empty" }
            prefs.widgets = [.cpu, .cpuGraph, .cpuBars, .gpu, .memory, .network, .disk, .temperature, .battery]
            guard StatusComposer.pieces(prefs: prefs, snapshot: snapshot, enabled: false) == [.icon] else { return "disabled module shows widgets" }

            func fill(_ cpu: Double, _ rate: Double, _ percent: Int) {
                snapshot.cpu = CPULoad(total: cpu, cores: Array(repeating: cpu, count: 10))
                snapshot.cpuHistory = Array(repeating: cpu, count: 45)
                snapshot.gpu = GPUInfo(utilization: cpu)
                snapshot.memory.app = UInt64(Double(snapshot.memory.total) * cpu)
                snapshot.network.down = rate
                snapshot.network.up = rate / 7
                snapshot.disk.volumes = [VolumeInfo(path: "/", name: "Macintosh HD", total: 1000, available: Int64(1000 * (1 - cpu)), isBoot: true)]
                snapshot.sensors.cpuTemperature = 30 + cpu * 75
                snapshot.battery = BatteryInfo.parse(["CurrentCapacity": percent, "MaxCapacity": 100, "IsCharging": percent < 50])
            }
            var widths: Set<CGFloat> = []
            var all: [[StatusPiece]] = []
            for labels in [true, false] {
                prefs.widgetLabels = labels
                var perStyle: Set<CGFloat> = []
                for (cpu, rate, percent) in [(0.0, 0.0, 5), (0.07, 900.0, 47), (0.63, 123_456.0, 88), (1.0, 987_654_321.0, 100)] {
                    fill(cpu, rate, percent)
                    let pieces = StatusComposer.pieces(prefs: prefs, snapshot: snapshot)
                    guard pieces.count == 9 else { return "\(pieces.count) pieces for 9 widgets with the icon hidden" }
                    all.append(pieces)
                    perStyle.insert(StatusLayout.totalWidth(pieces))
                    for piece in pieces {
                        // The drawn text must fit the reserved width.
                        if case let .value(caption, text, _) = piece {
                            let font = caption == nil ? StatusLayout.valueFont : StatusLayout.smallValueFont
                            guard StatusLayout.textWidth(text, font) <= StatusLayout.width(piece) else { return "\(text) overflows" }
                        }
                        if case let .stack(top, bottom, _) = piece {
                            guard max(StatusLayout.textWidth(top, StatusLayout.stackFont), StatusLayout.textWidth(bottom, StatusLayout.stackFont))
                                    <= StatusLayout.width(piece) else { return "\(top) / \(bottom) overflows" }
                        }
                    }
                }
                guard perStyle.count == 1 else { return "width changes with the values: \(perStyle.sorted())" }
                widths.formUnion(perStyle)
            }
            guard let widest = widths.max(), widest < 420 else { return "all widgets together are \(widths) pt wide" }
            guard StatusLayout.level(0.5) == 8, StatusLayout.level(2) == 16, StatusLayout.level(-1) == 0 else { return "levels" }
            let image = StatusRenderer.image(all[2])
            guard image.isTemplate, image.size.height == StatusLayout.height, image.size.width == StatusLayout.totalWidth(all[2]) else { return "image \(image.size)" }
            guard StatusComposer.description(all[2]).contains("CPU 63%") else { return StatusComposer.description(all[2]) }

            // BOSUN_STATUS_PNG=/path/prefix writes light and dark previews of every sample for a visual check.
            if let prefix = ProcessInfo.processInfo.environment["BOSUN_STATUS_PNG"] {
                prefs.showIcon = true
                prefs.widgetLabels = true
                fill(0.42, 2_345_678, 95)
                var sets: [(String, [StatusPiece])] = all.enumerated().map { ("all\($0.offset)", $0.element) }
                prefs.widgets = [.cpu, .memory, .network]
                sets.append(("typical", StatusComposer.pieces(prefs: prefs, snapshot: snapshot)))
                prefs.widgets = [.cpuGraph, .temperature, .battery]
                sets.append(("graph", StatusComposer.pieces(prefs: prefs, snapshot: snapshot)))
                for (name, pieces) in sets {
                    for dark in [false, true] {
                        guard let png = StatusRenderer.preview(pieces, dark: dark, scale: 4)?.representation(using: .png, properties: [:]) else { return "preview failed" }
                        try? png.write(to: URL(fileURLWithPath: "\(prefix)-\(name)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
            return nil
        }),
    ]
}

enum SensorsChecks {
    static let all: [SelfTest.Check] = [
        (name: "sensors: CPU temperature present and 10-110 °C", run: {
            guard let t = Sensors.read().cpuTemperature else { return "no CPU temperature from SMC or HID" }
            return (10...110).contains(t) ? nil : String(format: "CPU temperature %.1f °C out of range", t)
        }),
        (name: "sensors: fan count matches SMC FNum, RPMs 0-10000, limits ordered", run: {
            guard let expected = Sensors.smcFanCount() else { return "SMC FNum unreadable" }
            let reading = Sensors.read()
            if reading.fanRPMs.count != expected {
                return "read() returned \(reading.fanRPMs.count) fans, SMC FNum says \(expected)"
            }
            if let bad = reading.fanRPMs.first(where: { !(0...10000).contains($0) }) {
                return "fan RPM \(bad) out of range (\(reading.fanRPMs))"
            }
            for fan in reading.fans where fan.max > 0 {
                guard fan.min < fan.max, let fraction = fan.fraction, (0...1).contains(fraction) else { return "fan limits \(fan)" }
            }
            return nil
        }),
        (name: "sensors: cheap level reads CPU only, named level lists every catalogued sensor", run: {
            let cheap = Sensors.read(.cpu)
            guard cheap.cpuTemperature != nil, cheap.fanRPMs.isEmpty, cheap.named.isEmpty, cheap.gpuTemperature == nil else { return "cpu level read \(cheap)" }
            let named = Sensors.read(.named)
            let cores = named.named.filter { $0.group == .cpu }
            guard cores.count >= 2 else { return "only \(cores.count) CPU sensors named" }
            guard let bad = named.named.first(where: { !(10...110).contains($0.celsius) }) else {
                guard Set(named.named.map(\.key)).count == named.named.count else { return "duplicate keys" }
                // The headline figure is the mean of exactly the listed cores.
                let mean = cores.map(\.celsius).reduce(0, +) / Double(cores.count)
                guard let cpu = named.cpuTemperature, abs(cpu - mean) < 0.01 else { return "CPU mean \(String(describing: named.cpuTemperature)) vs listed \(mean)" }
                let all = Sensors.read(.all)
                guard all.named.count >= named.named.count else { return "all (\(all.named.count)) < named (\(named.named.count))" }
                guard let power = named.systemPower, (1...400).contains(power) else { return "system power \(String(describing: named.systemPower))" }
                return nil
            }
            return "\(bad.name) (\(bad.key)) reads \(bad.celsius)"
        }),
        (name: "sensors: chip generation and catalogue", run: {
            let generations = ["Apple M1 Pro", "Apple M2", "Apple M3 Max", "Apple M4 Pro", "Apple M10", "Intel(R) Core(TM) i9"].map(SensorCatalog.generation(of:))
            guard generations == [.m1, .m2, .m3, .m4, .unknown, .unknown] else { return "\(generations)" }
            let m1 = SensorCatalog.entries(.m1)
            guard m1.first == SensorCatalog.Entry(key: "Tp09", name: "Efficiency core 1", group: .cpu),
                  m1.contains(SensorCatalog.Entry(key: "Tp0b", name: "Performance core 8", group: .cpu)),
                  m1.contains(SensorCatalog.Entry(key: "TH0x", name: "SSD (NAND)", group: .storage)) else { return "\(m1.prefix(3))" }
            // Tp09 is an efficiency core on M1 but a performance core on M2.
            guard SensorCatalog.entries(.m2).contains(SensorCatalog.Entry(key: "Tp09", name: "Performance core 3", group: .cpu)) else { return "m2 table" }
            guard Set(m1.map(\.key)).count == m1.count else { return "duplicate keys in the M1 table" }
            return nil
        }),
    ]
}
