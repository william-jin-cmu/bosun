import SwiftUI

/// `Bosun --snapshot <file.png>` renders the panel off-screen with live data and
/// exits. Used to check the UI without clicking the menu bar item.
enum Snapshot {
    @MainActor
    static func run(path: String, settle: TimeInterval = 9) {
        let state = AppState.shared
        state.panelVisibilityChanged(true)
        let host = NSHostingView(rootView: PanelView(state: state, unboundedHeight: true)
            .frame(height: 1400, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 360, height: 1400),
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
