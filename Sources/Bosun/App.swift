import SwiftUI

@main
struct BosunApp: App {
    @StateObject private var state = AppState.shared

    init() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.runAndExit()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.async { Snapshot.run(path: path) }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(state: state)
        } label: {
            StatusLabel(monitor: state.monitor, monitorEnabled: state.isEnabled(state.monitor))
        }
        .menuBarExtraStyle(.window)
    }
}

enum StatusStyle: String, CaseIterable, Identifiable {
    case icon, cpu, cpuMemory, network
    var id: String { rawValue }
    var label: String {
        switch self {
        case .icon: "Icon only"
        case .cpu: "CPU"
        case .cpuMemory: "CPU and memory"
        case .network: "Network speed"
        }
    }
}

struct StatusLabel: View {
    @ObservedObject var monitor: MonitorModule
    let monitorEnabled: Bool
    @AppStorage("status.style") private var style: StatusStyle = .cpu

    var body: some View {
        let text = monitorEnabled ? monitor.statusText(style) : nil
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            if let text { Text(text).monospacedDigit() }
        }
    }
}
