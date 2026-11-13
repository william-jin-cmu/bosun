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

// The menu bar label (`StatusLabel`) lives in Monitor/StatusLabel.swift.
