import ApplicationServices
import SwiftUI

/// Replaces a small Karabiner-Elements config without a driver: key-to-key
/// remaps go through the HID event system (`hidutil`), and "while Caps Lock is
/// held" layers through an event tap that needs Accessibility permission.
@MainActor
final class KeyboardModule: ObservableObject, BosunModule {
    let id = "keyboard"
    let title = "Keyboard"
    let symbol = "keyboard"
    let enabledByDefault = false

    @Published private(set) var rules = KeyboardRules.load()
    @Published private(set) var plainArrows = UserDefaults.standard.bool(forKey: KeyboardRules.plainArrowsKey)
    @Published private(set) var isRunning = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var tapRunning = false
    /// nil while the key remaps are in place, else what went wrong.
    @Published private(set) var mappingError: String?
    @Published private(set) var karabinerRunning = false

    private static let appliedKey = "keyboard.appliedMapping"
    private let tap = KeyTap()
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var panelVisible = false

    // MARK: BosunModule

    func start() {
        guard !isRunning else { return }
        isRunning = true
        applyMapping()
        syncTap()
        refreshStatus()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // The mapping can be lost across sleep.
                self?.applyMapping()
                self?.syncTap()
            }
        }
        scheduleTimer()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        tap.stop()
        tapRunning = false
        removeMapping()
    }

    func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        guard isRunning else { return }
        if visible { tick() }
        scheduleTimer()
    }

    // MARK: Settings

    func setRemap(_ id: String, enabled: Bool) {
        guard let index = rules.remaps.firstIndex(where: { $0.id == id }) else { return }
        rules.remaps[index].enabled = enabled
        rulesChanged()
    }

    func setLayer(_ id: String, enabled: Bool) {
        guard let index = rules.layers.firstIndex(where: { $0.id == id }) else { return }
        rules.layers[index].enabled = enabled
        rulesChanged()
    }

    func setPlainArrows(_ on: Bool) {
        plainArrows = on
        UserDefaults.standard.set(on, forKey: KeyboardRules.plainArrowsKey)
        syncTap()
    }

    private func rulesChanged() {
        rules.save()
        guard isRunning else { return }
        applyMapping()
        syncTap()
    }

    // MARK: Accessibility

    var needsTap: Bool { !rules.activeLayers.isEmpty }

    /// Shows the system prompt (first time only) and opens the settings pane.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        scheduleTimer()
    }

    // MARK: Polling

    /// Permission can be granted or revoked while the panel is closed (opening
    /// System Settings closes it), so this runs whenever the module is on:
    /// quickly while waiting for permission, lazily once the tap is up.
    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return }
        let waiting = needsTap && !tapRunning
        guard waiting || panelVisible || tapRunning else { return }
        let interval: TimeInterval = waiting ? (panelVisible ? 1 : 2) : (panelVisible ? 3 : 15)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let wasRunning = tapRunning
        syncTap()
        refreshStatus()
        if wasRunning != tapRunning { scheduleTimer() }
    }

    private func refreshStatus() {
        if panelVisible { karabinerRunning = Self.detectKarabiner() }
    }

    // MARK: Event tap

    private func syncTap() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted { accessibilityGranted = trusted }
        tap.update(.init(layers: rules.activeLayers, plainArrows: plainArrows))
        let wanted = isRunning && needsTap && trusted
        if wanted, !tap.isRunning {
            if tap.start() { Log.info("event tap started", "keyboard") }
        } else if !wanted, tap.isRunning {
            // Also reached when permission is revoked: a tap left behind then
            // would swallow every keystroke.
            tap.stop()
            Log.info("event tap stopped", "keyboard")
        }
        if tapRunning != tap.isRunning { tapRunning = tap.isRunning }
    }

    // MARK: hidutil mapping

    private var storedApplied: HIDMapping.Applied? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.appliedKey) else { return nil }
            return try? JSONDecoder().decode(HIDMapping.Applied.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: Self.appliedKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.appliedKey)
            }
        }
    }

    /// Puts the enabled remaps into the system mapping, keeping foreign entries.
    /// Safe to repeat: whatever Bosun wrote before (even in a run that crashed)
    /// is taken out first.
    private func applyMapping() {
        let current = HIDMapping.read()
        let base = storedApplied.map { HIDMapping.unmerge(current: current, applied: $0) } ?? current
        let (merged, applied) = HIDMapping.merge(existing: base, ours: rules.activeRemaps)
        if merged != current, let failure = HIDMapping.write(merged) {
            mappingError = failure
            Log.info("apply failed: \(failure)", "keyboard")
            return
        }
        storedApplied = applied.ours.isEmpty && applied.displaced.isEmpty ? nil : applied
        let missing = applied.ours.filter { !HIDMapping.read().contains($0) }
        mappingError = missing.isEmpty ? nil : "The system did not keep the mapping"
        Log.info("mapping applied: \(applied.ours.count) ours, \(merged.count) total", "keyboard")
    }

    private func removeMapping() {
        guard let applied = storedApplied else { return }
        let current = HIDMapping.read()
        let restored = HIDMapping.unmerge(current: current, applied: applied)
        if restored != current, let failure = HIDMapping.write(restored) {
            Log.info("restore failed: \(failure)", "keyboard")
            return   // keep the record so the next start can still clean up
        }
        storedApplied = nil
        mappingError = nil
        Log.info("mapping restored: \(restored.count) entries left", "keyboard")
    }

    // MARK: Karabiner

    /// Karabiner-Elements grabs the keyboard itself; while it runs, both remap.
    nonisolated static func detectKarabiner() -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 3, &procs, &size, nil, 0) == 0 else { return false }
        // p_comm holds at most 16 characters, so compare prefixes.
        let names = ["karabiner_grabber", "Karabiner-Core-Service"].map { String($0.prefix(16)) }
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            let name = withUnsafeBytes(of: &procs[index].kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if names.contains(name) { return true }
        }
        return false
    }
}
