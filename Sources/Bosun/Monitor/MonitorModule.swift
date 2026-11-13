import SwiftUI

@MainActor
final class MonitorModule: ObservableObject, BosunModule {
    let id = "monitor"
    let title = "System"
    let symbol = "cpu"

    @Published private(set) var cpu: Double = 0
    @Published private(set) var cores: [Double] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory = MemoryUsage()
    @Published private(set) var down: Double = 0
    @Published private(set) var up: Double = 0
    @Published private(set) var disk = DiskUsage()
    @Published private(set) var battery: BatteryInfo?
    @Published private(set) var sensors = SensorReading()
    @Published private(set) var topProcesses: [ProcessLoad] = []

    static let interval: TimeInterval = 2
    static let historyLength = 60

    private let queue = DispatchQueue(label: "bosun.monitor", qos: .utility)
    // Touched only on `queue`.
    nonisolated(unsafe) private let cpuSampler = CPUSampler()
    nonisolated(unsafe) private let networkSampler = NetworkSampler()
    private var timer: DispatchSourceTimer?

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.sampleOnQueue() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    func panelVisibilityChanged(_ visible: Bool) {
        queue.async { [weak self] in
            self?.detailWanted = visible
            if visible { self?.sampleOnQueue() }
        }
    }

    // Accessed only on `queue`.
    nonisolated(unsafe) private var detailWanted = false
    nonisolated(unsafe) private var slowTick = 0

    /// Runs on `queue`. Cheap counters every tick; the expensive readings
    /// (ps, sensors, battery registry) only while the panel is open.
    nonisolated private func sampleOnQueue() {
        let cpu = cpuSampler.sample()
        let memory = MemoryUsage.read()
        let net = networkSampler.sample()
        let detail = detailWanted
        slowTick += 1
        let slow = slowTick % 15 == 1
        let processes = detail ? ProcessLoad.top(5) : nil
        let sensors = detail ? Sensors.read() : nil
        let battery = (detail || slow) ? BatteryInfo.read() : nil
        let disk = (detail || slow) ? DiskUsage.read() : nil
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil else { return }
                self.cpu = cpu.total
                self.cores = cpu.cores
                self.cpuHistory = Array((self.cpuHistory + [cpu.total]).suffix(Self.historyLength))
                self.memory = memory
                self.down = net.down
                self.up = net.up
                if let processes { self.topProcesses = processes }
                if let sensors { self.sensors = sensors }
                if detail || slow { self.battery = battery }
                if let disk { self.disk = disk }
            }
        }
    }

    func statusText(_ style: StatusStyle) -> String? {
        switch style {
        case .icon: nil
        case .cpu: Format.percent(cpu)
        case .cpuMemory: "\(Format.percent(cpu)) · \(Format.percent(memory.fraction))"
        case .network: "↓\(Format.rate(down)) ↑\(Format.rate(up))"
        }
    }
}

enum MonitorChecks {
    static let all: [SelfTest.Check] = [
        ("monitor: cpu usage is a sane fraction", {
            let sampler = CPUSampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 0.5)
            let result = sampler.sample()
            guard result.cores.count == ProcessInfo.processInfo.processorCount else {
                return "got \(result.cores.count) cores, expected \(ProcessInfo.processInfo.processorCount)"
            }
            guard result.total > 0, result.total <= 1 else { return "total \(result.total)" }
            return nil
        }),
        ("monitor: memory used is within physical memory", {
            let memory = MemoryUsage.read()
            guard memory.used > 1 << 30, memory.used <= memory.total else { return "used \(memory.used) of \(memory.total)" }
            return nil
        }),
        ("monitor: network counters are non-zero and monotonic", {
            let first = NetworkSampler.totals()
            Thread.sleep(forTimeInterval: 0.3)
            let second = NetworkSampler.totals()
            guard first.rx > 0, second.rx >= first.rx, second.tx >= first.tx else { return "\(first) then \(second)" }
            return nil
        }),
        ("monitor: disk capacity reads", {
            let disk = DiskUsage.read()
            guard disk.total > 0, disk.available > 0, disk.available < disk.total else { return "\(disk)" }
            return nil
        }),
        ("monitor: battery reads on this laptop", {
            guard let battery = BatteryInfo.read() else { return "no battery found" }
            guard (0...100).contains(battery.percent), battery.cycleCount > 0 else { return "\(battery)" }
            guard let health = battery.health, (0.3...1.2).contains(health) else { return "health \(String(describing: battery.health))" }
            return nil
        }),
        ("monitor: ps output parses", {
            let parsed = ProcessLoad.parse("  501  12.5 Google Chrome Helper\n    1   0.0 launchd\n", limit: 5)
            guard parsed.count == 2, parsed[0].name == "Google Chrome Helper", parsed[0].cpu == 12.5 else { return "\(parsed)" }
            guard !ProcessLoad.top(3).isEmpty else { return "live ps returned nothing" }
            return nil
        }),
        ("monitor: rate formatting", {
            let got = [Format.rate(0), Format.rate(12_300), Format.rate(3_500_000), Format.rate(250_000_000)]
            return got == ["0 K", "12 K", "3.3 M", "238 M"] ? nil : "\(got)"
        }),
    ]
}
