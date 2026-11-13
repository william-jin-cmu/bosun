import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, system, tint, displays, sound, keyboard
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .system: "System"
        case .tint: "Color Temperature"
        case .displays: "Displays"
        case .sound: "Sound"
        case .keyboard: "Keyboard"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .system: "cpu"
        case .tint: "sun.max"
        case .displays: "display"
        case .sound: "speaker.wave.2"
        case .keyboard: "keyboard"
        }
    }
}

/// The one settings window. Everything that does not fit the compact menu bar
/// panel lives here, one tab per module.
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let selection = SettingsSelection()

    static func show(_ tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Bosun Settings"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 700, height: 460)
            window.contentView = NSHostingView(rootView: SettingsView(state: AppState.shared, selection: selection))
            window.center()
            window.setFrameAutosaveName("BosunSettings")
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: Binding(get: { selection.tab }, set: { selection.tab = $0 ?? .general })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let module = module(for: selection.tab) {
                        Toggle("Enable \(module.title)", isOn: Binding(
                            get: { state.isEnabled(module) }, set: { state.setEnabled(module, $0) }))
                            .toggleStyle(.switch).controlSize(.mini)
                            .font(.headline)
                        Divider()
                    }
                    switch selection.tab {
                    case .general: GeneralSettings(state: state)
                    case .system: MonitorSettings(module: state.monitor)
                    case .tint: TintSettings(module: state.tint)
                    case .displays: DisplaysSettings(module: state.displays)
                    case .sound: AudioSettings(module: state.audio)
                    case .keyboard: KeyboardSettings(module: state.keyboard)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Compact controls throughout: the default-size switches and
                // buttons look heavy in a dense settings page.
                .controlSize(.small)
            }
            .navigationTitle(selection.tab.title)
        }
    }

    private func module(for tab: SettingsTab) -> (any BosunModule)? {
        switch tab {
        case .general: nil
        case .system: state.monitor
        case .tint: state.tint
        case .displays: state.displays
        case .sound: state.audio
        case .keyboard: state.keyboard
        }
    }
}

/// Shared Accessibility-permission helper (event taps need it).
enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt the first time; afterwards it only opens nothing, so pair with `openSettings()`.
    static func prompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}
