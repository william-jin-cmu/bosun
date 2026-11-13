import SwiftUI

struct MonitorSection: View {
    @ObservedObject var module: MonitorModule

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CPU").font(.caption).foregroundStyle(.secondary)
                    Text(Format.percent(module.cpu)).font(.title2.weight(.semibold)).monospacedDigit()
                }
                .frame(width: 58, alignment: .leading)
                Sparkline(values: module.cpuHistory, capacity: MonitorModule.historyLength)
                    .frame(height: 34)
                    .accessibilityLabel("CPU history")
            }
            CoreBars(cores: module.cores).frame(height: 14)

            Gauge(label: "Memory",
                  detail: "\(Format.bytes(Int64(module.memory.used))) of \(Format.bytes(Int64(module.memory.total)))",
                  fraction: module.memory.fraction)
            if module.memory.swapUsed > 0 {
                StatRow(label: "Swap used", value: Format.bytes(Int64(module.memory.swapUsed)))
            }
            if module.disk.total > 0 {
                Gauge(label: "Disk",
                      detail: "\(Format.disk(module.disk.available)) free",
                      fraction: 1 - Double(module.disk.available) / Double(module.disk.total))
            }
            StatRow(label: "Network", value: "↓ \(Format.rate(module.down))B/s   ↑ \(Format.rate(module.up))B/s")
            if let temperature = module.sensors.cpuTemperature {
                StatRow(label: "CPU temperature", value: String(format: "%.0f °C", temperature))
            }
            if !module.sensors.fanRPMs.isEmpty {
                StatRow(label: "Fans", value: module.sensors.fanRPMs.allSatisfy { $0 == 0 }
                        ? "Off" : module.sensors.fanRPMs.map { "\($0) rpm" }.joined(separator: " · "))
            }

            if !module.topProcesses.isEmpty {
                Divider()
                ForEach(module.topProcesses) { process in
                    HStack {
                        Text(process.name).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(String(format: "%.1f%%", process.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }

            if let battery = module.battery {
                Divider()
                BatteryBlock(battery: battery)
            }
        }
    }
}

struct BatteryBlock: View {
    let battery: BatteryInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("\(battery.percent)%", systemImage: battery.isCharging ? "battery.100.bolt" : "battery.75")
                    .font(.callout.weight(.medium)).monospacedDigit()
                Spacer()
                Text([battery.stateText, battery.remainingText].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let health = battery.health {
                StatRow(label: "Health", value: capacityText(health))
            }
            StatRow(label: "Cycles", value: "\(battery.cycleCount)")
            if let watts = battery.watts, abs(watts) >= 0.05 {
                StatRow(label: watts > 0 ? "Charging at" : "Drawing", value: String(format: "%.1f W", abs(watts)))
            }
            if let adapter = battery.adapterWatts, battery.onAC {
                StatRow(label: "Power adapter", value: "\(adapter) W")
            }
            if let temperature = battery.temperature {
                StatRow(label: "Battery temperature", value: String(format: "%.1f °C", temperature))
            }
        }
    }

    private func capacityText(_ health: Double) -> String {
        guard let full = battery.fullChargeCapacity, let design = battery.designCapacity else { return Format.percent(health) }
        return "\(Format.percent(health))  (\(full) of \(design) mAh)"
    }
}

struct Gauge: View {
    let label: String
    let detail: String
    let fraction: Double

    var body: some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).foregroundStyle(.secondary)
                Spacer()
                Text(detail).monospacedDigit()
            }
            .font(.callout)
            ProgressView(value: min(max(fraction, 0), 1))
                .tint(fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor)
                .accessibilityLabel(label)
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

struct CoreBars: View {
    let cores: [Double]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(Array(cores.enumerated()), id: \.offset) { _, load in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor)
                            .frame(height: max(1, geo.size.height * CGFloat(load)))
                    }
                }
            }
        }
        .accessibilityLabel("Per-core CPU load")
    }
}
