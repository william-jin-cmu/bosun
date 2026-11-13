import SwiftUI

/// `Bosun --snapshot <file.png>` renders the panel off-screen with live data and
/// exits. Used to check the UI without clicking the menu bar item.
enum Snapshot {
    @MainActor
    static func run(path: String, settle: TimeInterval = 9) {
        let state = AppState.shared
        state.panelVisibilityChanged(true)
        // `--settings <tab>` renders that settings tab instead of the panel.
        var settingsTab: SettingsTab?
        if let index = CommandLine.arguments.firstIndex(of: "--settings"), CommandLine.arguments.count > index + 1 {
            settingsTab = SettingsTab(rawValue: CommandLine.arguments[index + 1])
        }
        var size = settingsTab == nil ? NSSize(width: 360, height: 1400) : NSSize(width: 760, height: 900)
        // `--height <points>` for tabs or panels taller than the default canvas.
        if let index = CommandLine.arguments.firstIndex(of: "--height"), CommandLine.arguments.count > index + 1,
           let height = Double(CommandLine.arguments[index + 1]) {
            size.height = height
        }
        let root: AnyView
        if let settingsTab {
            let selection = SettingsSelection()
            selection.tab = settingsTab
            root = AnyView(SettingsView(state: state, selection: selection)
                .frame(width: size.width, height: size.height)
                .background(Color(nsColor: .windowBackgroundColor)))
        } else {
            root = AnyView(PanelView(state: state, unboundedHeight: true)
                .frame(height: size.height, alignment: .top)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -5000, y: -5000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(1) }
            host.cacheDisplay(in: host.bounds, to: rep)
            let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil
            state.stopAll()
            exit(ok ? 0 : 1)
        }
    }
}
