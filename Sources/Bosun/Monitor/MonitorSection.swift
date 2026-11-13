import SwiftUI

/// The System section of the panel: one compact row per block, in the user's order;
/// a block's chevron opens its detailed view (remembered).
struct MonitorSection: View {
    @ObservedObject var module: MonitorModule

    var body: some View {
        let blocks = module.prefs.visibleBlocks
        VStack(alignment: .leading, spacing: 7) {
            if blocks.isEmpty {
                Text("Every block is hidden. Choose what to show in System settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(blocks) { block in
                if !(block == .battery && module.snapshot.battery == nil) {
                    BlockView(block: block, snapshot: module.snapshot, prefs: module.prefs,
                              detailed: module.prefs.detailedBlocks.contains(block),
                              toggle: { module.toggleDetail(block) },
                              setProcessSort: { module.prefs.processesByMemory = $0 })
                }
            }
        }
    }
}

private struct BlockView: View {
    let block: PanelBlock
    let snapshot: MonitorSnapshot
    let prefs: MonitorPrefs
    let detailed: Bool
    let toggle: () -> Void
    let setProcessSort: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if block == .processes {
                // The sort picker is a control of its own, so only the chevron toggles here.
                HStack(spacing: 8) {
                    Text(block.title).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                    summary.frame(maxWidth: .infinity, alignment: .trailing)
                    Button(action: toggle) { chevron.contentShape(Rectangle()) }
                        .buttonStyle(.plain)
                        .help(detailed ? "Show fewer processes" : "Show more processes")
                        .accessibilityLabel(detailed ? "Show fewer processes" : "Show more processes")
                }
                .font(.callout)
            } else {
                Button(action: toggle) {
                    HStack(spacing: 8) {
                        Text(block.title).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
                        summary.frame(maxWidth: .infinity, alignment: .trailing)
                        chevron
                    }
                    .font(.callout)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(detailed ? "Hide \(block.title) details" : "Show \(block.title) details")
                .accessibilityHint(detailed ? "Hides details" : "Shows details")
            }

            if block == .processes {
                ProcessList(snapshot: snapshot, byMemory: prefs.processesByMemory)
            }
            if detailed {
                detail
                    .font(.caption)
                    .padding(.leading, 8)
                    .padding(.bottom, 3)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 1).fill(.quaternary).frame(width: 2)
                    }
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            .rotationEffect(.degrees(detailed ? 90 : 0))
            .frame(width: 10)
    }

    // MARK: Compact rows

    @ViewBuilder private var summary: some View {
        switch block {
        case .cpu:
            HStack(spacing: 8) {
                Sparkline(values: snapshot.cpuHistory, capacity: MonitorSampler.historyLength)
                    .frame(height: 20).accessibilityLabel("CPU history")
                Text(Format.percent(snapshot.cpu.total)).fontWeight(.medium).monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }
        case .gpu:
            if let gpu = snapshot.gpu {
                BarValue(fraction: gpu.utilization, text: Format.percent(gpu.utilization), label: "GPU usage")
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        case .memory:
            BarValue(fraction: snapshot.memory.fraction,
                     text: "\(Format.bytes(snapshot.memory.used)) of \(Format.bytes(snapshot.memory.total))",
                     label: "Memory used",
                     tint: snapshot.memory.pressure == .critical ? .red : snapshot.memory.pressure == .warning ? .orange : nil)
        case .disk:
            if let boot = snapshot.disk.boot {
                BarValue(fraction: boot.usedFraction, text: "\(Format.disk(boot.available)) free", label: "Disk used")
            } else {
                Text("–").foregroundStyle(.secondary)
            }
        case .network:
            HStack(spacing: 10) {
                Text("↓ \(Format.speed(snapshot.network.down))")
                Text("↑ \(Format.speed(snapshot.network.up))")
            }
            .monospacedDigit()
        case .sensors:
            Text(sensorSummary).monospacedDigit().lineLimit(1)
        case .battery:
            if let battery = snapshot.battery {
                HStack(spacing: 5) {
                    Text([battery.stateText, battery.remainingText].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: battery.symbol)
                    Text("\(battery.percent)%").fontWeight(.medium).monospacedDigit()
                }
            }
        case .processes:
            Picker("Sort processes by", selection: Binding(get: { prefs.processesByMemory }, set: setProcessSort)) {
                Text("CPU").tag(false)
                Text("Memory").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().controlSize(.mini).fixedSize()
        }
    }

    private var sensorSummary: String {
        var parts: [String] = []
        if let temperature = snapshot.sensors.cpuTemperature {
            parts.append("CPU \(Format.temperature(temperature, fahrenheit: prefs.fahrenheit))")
        }
        let fans = snapshot.sensors.fanRPMs
        if !fans.isEmpty {
            parts.append(fans.allSatisfy { $0 == 0 } ? "Fans off" : "Fan \(fans.max() ?? 0) rpm")
        }
        return parts.isEmpty ? "–" : parts.joined(separator: " · ")
    }

    // MARK: Detailed views

    @ViewBuilder private var detail: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch block {
            case .cpu: cpuDetail
            case .gpu: gpuDetail
            case .memory: memoryDetail
            case .disk: diskDetail
            case .network: networkDetail
            case .sensors: sensorsDetail
            case .battery: if let battery = snapshot.battery { BatteryDetail(battery: battery, now: snapshot.at, fahrenheit: prefs.fahrenheit) }
            case .processes:
                Text("Other users' processes (system daemons) report resident memory; yours report the footprint Activity Monitor shows.")
                    .foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var cpuDetail: some View {
        ClusterBars(cores: snapshot.cpu.cores, topology: CPUTopology.current)
        DetailRow("User", Format.percent(snapshot.cpu.user))
        DetailRow("System", Format.percent(snapshot.cpu.system))
        DetailRow("Idle", Format.percent(snapshot.cpu.idle))
        DetailRow("Load average", String(format: "%.2f  %.2f  %.2f", snapshot.load.one, snapshot.load.five, snapshot.load.fifteen))
        if let boot = snapshot.load.bootTime {
            DetailRow("Uptime", Format.duration(snapshot.at.timeIntervalSince(boot)))
        }
        if !CPUTopology.chipName.isEmpty { DetailRow("Chip", CPUTopology.chipName) }
    }

    @ViewBuilder private var gpuDetail: some View {
        if let gpu = snapshot.gpu {
            Sparkline(values: snapshot.gpuHistory, capacity: MonitorSampler.historyLength)
                .frame(height: 22).accessibilityLabel("GPU history")
            if let renderer = gpu.renderer { DetailRow("Renderer", Format.percent(renderer)) }
            if let tiler = gpu.tiler { DetailRow("Tiler", Format.percent(tiler)) }
            if let memory = gpu.memoryInUse { DetailRow("Memory in use", Format.bytes(memory)) }
            if let temperature = snapshot.sensors.gpuTemperature {
                DetailRow("Temperature", Format.temperature(temperature, fahrenheit: prefs.fahrenheit))
            }
            if !gpu.model.isEmpty { DetailRow("Model", gpu.model) }
        } else {
            Text("No GPU statistics available.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var memoryDetail: some View {
        let memory = snapshot.memory
        SegmentBar(segments: [
            (Double(memory.app), Color.accentColor), (Double(memory.wired), Color.orange),
            (Double(memory.compressed), Color.purple), (Double(memory.cached), Color.secondary.opacity(0.45)),
        ], total: Double(memory.total))
        .frame(height: 6).accessibilityLabel("Memory breakdown")
        LegendRow(color: .accentColor, label: "App memory", value: Format.bytes(memory.app))
        LegendRow(color: .orange, label: "Wired", value: Format.bytes(memory.wired))
        LegendRow(color: .purple, label: "Compressed", value: Format.bytes(memory.compressed))
        LegendRow(color: .secondary.opacity(0.45), label: "Cached files", value: Format.bytes(memory.cached))
        LegendRow(color: .clear, label: "Free", value: Format.bytes(memory.free))
        DetailRow("Pressure", memory.pressure.label,
                  valueColor: memory.pressure == .critical ? .red : memory.pressure == .warning ? .orange : nil)
        DetailRow("Swap used", memory.swapTotal > 0
                  ? "\(Format.bytes(memory.swapUsed)) of \(Format.bytes(memory.swapTotal))" : "None")
    }

    @ViewBuilder private var diskDetail: some View {
        DetailRow("Read", snapshot.disk.readRate.map(Format.speed) ?? "–")
        DetailRow("Write", snapshot.disk.writeRate.map(Format.speed) ?? "–")
        ForEach(snapshot.disk.volumes) { volume in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(volume.name).lineLimit(1).truncationMode(.middle)
                    Text(volume.kind).foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(Format.disk(volume.available)) free of \(Format.disk(volume.total))").monospacedDigit()
                }
                MiniBar(fraction: volume.usedFraction).accessibilityLabel("\(volume.name) used")
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private var networkDetail: some View {
        let interfaces = snapshot.network.interfaces
        if interfaces.isEmpty { Text("No active interfaces.").foregroundStyle(.secondary) }
        ForEach(interfaces) { interface in
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text(interface.title).lineLimit(1)
                    Spacer()
                    Text("↓ \(Format.speed(interface.down))  ↑ \(Format.speed(interface.up))").monospacedDigit()
                }
                HStack {
                    Text(interface.address.isEmpty ? "No address" : interface.address)
                        .textSelection(.enabled)
                    Spacer()
                    Text("↓ \(Format.bytes(interface.totalDown))  ↑ \(Format.bytes(interface.totalUp))").monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
        DetailRow("Since Bosun started", "↓ \(Format.bytes(snapshot.network.totalDown))  ↑ \(Format.bytes(snapshot.network.totalUp))")
            .padding(.top, 2)
    }

    @ViewBuilder private var sensorsDetail: some View {
        let sensors = snapshot.sensors
        if let hottest = sensors.cpuTemperatureMax {
            DetailRow("Hottest CPU core", Format.temperature(hottest, fahrenheit: prefs.fahrenheit))
        }
        if let power = sensors.systemPower { DetailRow("System power", String(format: "%.1f W", power)) }
        ForEach(Array(sensors.fans.enumerated()), id: \.offset) { index, fan in
            VStack(spacing: 2) {
                DetailRow(sensors.fans.count > 1 ? "Fan \(index + 1)" : "Fan",
                          fan.rpm == 0 ? "Off" : fan.max > 0 ? "\(fan.rpm) rpm  (\(fan.min)–\(fan.max))" : "\(fan.rpm) rpm")
                if let fraction = fan.fraction { MiniBar(fraction: fraction, thresholds: false).accessibilityLabel("Fan \(index + 1) speed") }
            }
        }
        SensorGrid(sensors: sensors.named.filter { $0.group != .unnamed }, fahrenheit: prefs.fahrenheit)
    }
}

// MARK: - Pieces

/// Sensors grouped under small headings, two per line.
struct SensorGrid: View {
    let sensors: [NamedSensor]
    let fahrenheit: Bool
    var columns = 2

    var body: some View {
        let groups = NamedSensor.Group.allCases.compactMap { group -> (NamedSensor.Group, [NamedSensor])? in
            let members = sensors.filter { $0.group == group }
            return members.isEmpty ? nil : (group, members)
        }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(groups, id: \.0) { group, members in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: columns), spacing: 2) {
                        ForEach(members) { sensor in
                            HStack(spacing: 4) {
                                Text(sensor.name).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 2)
                                Text(Format.temperature(sensor.celsius, fahrenheit: fahrenheit))
                                    .monospacedDigit()
                                    .foregroundStyle(sensor.celsius >= 95 ? Color.red : sensor.celsius >= 80 ? Color.orange : Color.primary)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ProcessList: View {
    let snapshot: MonitorSnapshot
    let byMemory: Bool

    var body: some View {
        let list = byMemory ? snapshot.topMemory : snapshot.topCPU
        VStack(spacing: 3) {
            if list.isEmpty {
                Text("Measuring…").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(list) { process in
                HStack(spacing: 6) {
                    Group {
                        if let icon = process.icon {
                            Image(nsImage: icon).resizable().interpolation(.high)
                        } else {
                            Image(systemName: "gearshape").resizable().scaledToFit().padding(2).foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 14, height: 14)
                    .accessibilityHidden(true)
                    Text(process.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(byMemory ? Format.bytes(process.memory) : String(format: "%.1f%%", process.cpu))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }
}

private struct BatteryDetail: View {
    let battery: BatteryInfo
    let now: Date
    let fahrenheit: Bool

    var body: some View {
        if let health = battery.health {
            DetailRow("Health", capacityText(health))
        }
        if let nominal = battery.nominalCapacity, nominal != battery.fullChargeCapacity {
            DetailRow("Nominal capacity", "\(nominal) mAh")
        }
        DetailRow("Cycles", battery.designCycleCount.map { "\(battery.cycleCount) of \($0)" } ?? "\(battery.cycleCount)")
        if let remaining = battery.remainingCapacity, remaining > 0 { DetailRow("Charge", "\(remaining) mAh") }
        if let limit = battery.chargeLimit { DetailRow("Charge limit", "\(limit)%") }
        if let seconds = battery.timeline.timeOnBattery(now: now), !battery.onAC {
            let dropped = battery.timeline.percentAtUnplug.map { $0 - battery.percent } ?? 0
            DetailRow("Time on battery", (battery.timeline.observed ? "" : "at least ") + Format.duration(seconds)
                      + (dropped > 0 ? "  (−\(dropped)%)" : ""))
        }
        if let watts = battery.watts, abs(watts) >= 0.05 {
            DetailRow(watts > 0 ? "Charging at" : "Drawing", String(format: "%.1f W", abs(watts)))
        }
        if let voltage = battery.voltage {
            DetailRow("Voltage", String(format: "%.2f V", voltage) + (battery.amperage.map { "  ·  \($0) mA" } ?? ""))
        }
        if battery.onAC {
            if let adapter = battery.adapterWatts {
                DetailRow("Power adapter", "\(adapter) W" + (battery.adapterName.map { "  ·  \($0)" } ?? ""))
            }
            if let input = battery.systemPowerIn, input > 0 { DetailRow("Power in", String(format: "%.1f W", input)) }
        }
        if let temperature = battery.temperature {
            DetailRow("Temperature", Format.temperature(temperature, fahrenheit: fahrenheit, digits: 1))
        }
    }

    private func capacityText(_ health: Double) -> String {
        guard let full = battery.fullChargeCapacity, let design = battery.designCapacity else { return Format.percent(health) }
        return "\(Format.percent(health))  (\(full) of \(design) mAh)"
    }
}

/// Label on the left, value on the right, at the surrounding font size.
struct DetailRow: View {
    let label: String
    let value: String
    var valueColor: Color?

    init(_ label: String, _ value: String, valueColor: Color? = nil) {
        self.label = label
        self.value = value
        self.valueColor = valueColor
    }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(valueColor ?? .primary).lineLimit(1)
        }
    }
}

private struct LegendRow: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).monospacedDigit()
        }
    }
}

/// A thin bar followed by its value.
private struct BarValue: View {
    let fraction: Double
    let text: String
    let label: String
    var tint: Color?

    var body: some View {
        HStack(spacing: 8) {
            MiniBar(fraction: fraction, tint: tint).frame(minWidth: 40).accessibilityLabel(label)
            Text(text).monospacedDigit().lineLimit(1).fixedSize()
        }
    }
}

struct MiniBar: View {
    let fraction: Double
    var tint: Color?
    /// Turn orange / red as the bar fills up.
    var thresholds = true

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        let color = tint ?? (thresholds ? (clamped > 0.9 ? Color.red : clamped > 0.8 ? Color.orange : Color.accentColor) : Color.accentColor)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: max(clamped > 0 ? 3 : 0, geo.size.width * clamped))
            }
        }
        .frame(height: 5)
        .accessibilityValue(Format.percent(clamped))
    }
}

private struct SegmentBar: View {
    let segments: [(value: Double, color: Color)]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    Rectangle().fill(segment.color)
                        .frame(width: max(0, geo.size.width * (total > 0 ? segment.value / total : 0) - 1))
                }
                Spacer(minLength: 0)
            }
            .background(.quaternary)
            .clipShape(Capsule())
        }
    }
}

struct Sparkline: View {
    let values: [Double]   // 0...1, oldest first
    let capacity: Int

    var body: some View {
        GeometryReader { geo in
            let step = geo.size.width / CGFloat(max(capacity - 1, 1))
            let offset = CGFloat(capacity - values.count) * step
            let points = values.enumerated().map { index, value in
                CGPoint(x: offset + CGFloat(index) * step, y: geo.size.height * (1 - CGFloat(min(max(value, 0), 1))))
            }
            ZStack {
                if let first = points.first, let last = points.last, points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        points.forEach { path.addLine(to: $0) }
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(Color.accentColor.opacity(0.18))
                    Path { path in
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
            }
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Per-core bars grouped by cluster, each core labelled (E1, E2, P1 ...).
struct ClusterBars: View {
    let cores: [Double]
    let topology: CPUTopology

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(topology.clusters.enumerated()), id: \.offset) { _, cluster in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(cluster.name).foregroundStyle(.secondary)
                        Text(Format.percent(CPUTopology.mean(cores, cluster))).monospacedDigit()
                    }
                    .lineLimit(1).fixedSize()
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(Array(cluster.indices.enumerated()), id: \.offset) { position, index in
                            let load = index < cores.count ? cores[index] : 0
                            VStack(spacing: 2) {
                                GeometryReader { geo in
                                    ZStack(alignment: .bottom) {
                                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                                            .frame(height: max(1.5, geo.size.height * CGFloat(min(max(load, 0), 1))))
                                    }
                                }
                                .frame(height: 26)
                                Text("\(cluster.prefix)\(position + 1)")
                                    .font(.system(size: 8, weight: .medium)).foregroundStyle(.tertiary)
                                    .lineLimit(1).fixedSize()
                            }
                            .frame(minWidth: 14, maxWidth: 22)
                            .accessibilityElement()
                            .accessibilityLabel("\(cluster.name) core \(position + 1)")
                            .accessibilityValue(Format.percent(load))
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
