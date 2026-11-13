import SwiftUI
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let monitor = MonitorModule()
    let tint = TintModule()
    let displays = DisplaysModule()
    let keyboard = KeyboardModule()
    let audio = AudioModule()

    @Published private(set) var enabled: [String: Bool] = [:]
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled

    var modules: [any BosunModule] { [monitor, tint, displays, audio, keyboard] }

    private init() {
        let defaults = UserDefaults.standard
        for module in modules {
            // bool(forKey:) so command-line overrides (`-module.tint.enabled YES`) work too.
            let on = defaults.object(forKey: module.enabledKey) != nil
                ? defaults.bool(forKey: module.enabledKey) : module.enabledByDefault
            enabled[module.id] = on
        }
        // Start after init returns, so nothing a module does while starting can
        // reach back into a half-built AppState.shared.
        DispatchQueue.main.async { [self] in
            for module in modules where isEnabled(module) && Self.mayStart(module) { module.start() }
            started = true
            if panelVisible { panelVisibilityChanged(true) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    /// Snapshot runs (`--snapshot`) share the machine with the installed app, so
    /// by default they only start modules that just read state. `--start a,b,c`
    /// (module ids, or `none`) overrides the list.
    static let snapshotMode = CommandLine.arguments.contains("--snapshot")
    private static func mayStart(_ module: any BosunModule) -> Bool {
        guard snapshotMode else { return true }
        var allowed = ["monitor", "displays", "audio"]
        if let index = CommandLine.arguments.firstIndex(of: "--start"), CommandLine.arguments.count > index + 1 {
            allowed = CommandLine.arguments[index + 1].split(separator: ",").map(String.init)
        }
        return allowed.contains(module.id)
    }
    private var running: Set<String> = []

    func isEnabled(_ module: any BosunModule) -> Bool { enabled[module.id] ?? false }

    func setEnabled(_ module: any BosunModule, _ on: Bool) {
        guard isEnabled(module) != on else { return }
        enabled[module.id] = on
        UserDefaults.standard.set(on, forKey: module.enabledKey)
        guard started else { return }
        if on {
            module.start()
            if panelVisible { module.panelVisibilityChanged(true) }
        } else {
            module.stop()
        }
    }

    private var started = false
    private var panelVisible = false

    func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        guard started else { return }
        for module in modules where isEnabled(module) { module.panelVisibilityChanged(visible) }
    }

    func stopAll() {
        guard started else { return }
        for module in modules where isEnabled(module) { module.stop() }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("launch at login failed: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
