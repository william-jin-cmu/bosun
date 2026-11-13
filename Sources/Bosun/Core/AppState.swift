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
            for module in modules where isEnabled(module) { module.start() }
            started = true
            if panelVisible { panelVisibilityChanged(true) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

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
