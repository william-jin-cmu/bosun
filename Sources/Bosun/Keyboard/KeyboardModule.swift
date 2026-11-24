import ApplicationServices
import SwiftUI

/// A driverless key remapper. Key → key remaps go through the HID event system
/// (`hidutil`); shortcuts, layers and tap/hold keys through an event tap, which
/// needs Accessibility permission. `KeyCompiler` turns the user's rules into
/// both halves.
@MainActor
final class KeyboardModule: ObservableObject, BosunModule {
    let id = "keyboard"
    let title = "Keyboard"
    let symbol = "keyboard"
    let enabledByDefault = false

    @Published private(set) var rules: [KeyRule]
    @Published private(set) var program: KeyProgram
    @Published private(set) var isRunning = false
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var tapRunning = false
    @Published private(set) var tapLocation: KeyTap.Location?
    /// nil while the key remaps are in place, else what went wrong.
    @Published private(set) var mappingError: String?
    @Published private(set) var karabinerRunning = false
    @Published private(set) var keyboards: [KeyboardDevice] = []
    @Published private(set) var builtInKeyboards: [KeyboardDevice] = []
    @Published private(set) var externalKeyboards: [KeyboardDevice] = []
    @Published var disableBuiltInWhenExternalConnected: Bool {
        didSet {
            guard disableBuiltInWhenExternalConnected != oldValue else { return }
            UserDefaults.standard.set(disableBuiltInWhenExternalConnected, forKey: Self.disableBuiltInKey)
            if isRunning { sync() }
        }
    }

    var builtInDisabled: Bool {
        isRunning && disableBuiltInWhenExternalConnected && !builtInKeyboards.isEmpty && !externalKeyboards.isEmpty
    }

    private static let appliedKey = "keyboard.appliedMapping"
    private static let disableBuiltInKey = "keyboard.disableBuiltInWhenExternalConnected"
    private let tap = KeyTap()
    private let watcher = KeyboardWatcher()
    private var builtInFnUsages: [UInt64] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var panelVisible = false
    private var recording: RecordingMode?

    init() {
        let rules = KeyRuleSet.load().rules
        self.rules = rules
        self.disableBuiltInWhenExternalConnected = UserDefaults.standard.bool(forKey: Self.disableBuiltInKey)
        program = KeyCompiler.compile(rules)
        tap.onLaunch = { bundleID in DispatchQueue.main.async { Self.open(bundleID) } }
        tap.onCapsLock = { CapsLock.pressed(long: $0) }
    }

    // MARK: BosunModule

    func start() {
        guard !isRunning else { return }
        isRunning = true
        tap.setFrontApp(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // The mapping can be lost across sleep.
                MainActor.assumeIsolated { self?.sync() }
            },
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let bundleID = app?.bundleIdentifier
                MainActor.assumeIsolated { self?.tap.setFrontApp(bundleID) }
            },
        ]
        watcher.start { [weak self] in self?.sync() }
        sync()
        refreshStatus()
        scheduleTimer()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.invalidate()
        timer = nil
        watcher.stop()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers = []
        tap.stop()
        tapRunning = false
        tapLocation = nil
        applyMapping()
    }

    func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshClassifiedKeyboards() }
        guard isRunning else { return }
        if visible { tick() }
        scheduleTimer()
    }

    // MARK: Editing

    func rule(_ id: String) -> KeyRule? { rules.first { $0.id == id } }

    func setEnabled(_ id: String, _ enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[index].enabled = enabled
        rulesChanged()
    }

    /// Replaces the rule with the same id, or appends it.
    func save(_ rule: KeyRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) { rules[index] = rule } else { rules.append(rule) }
        rulesChanged()
    }

    func add(_ new: [KeyRule]) {
        guard !new.isEmpty else { return }
        rules.append(contentsOf: new)
        rulesChanged()
    }

    func delete(_ id: String) {
        rules.removeAll { $0.id == id }
        rulesChanged()
    }

    func duplicate(_ id: String) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        var copy = KeyPreset(id: "", title: "", detail: "", rules: [rules[index]]).instantiate()[0]
        if !copy.name.isEmpty { copy.name += " copy" }
        rules.insert(copy, at: index + 1)
        rulesChanged()
    }

    func move(_ id: String, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        rules.swapAt(index, target)
        rulesChanged()
    }

    func move(fromOffsets: IndexSet, toOffset: Int) {
        rules.move(fromOffsets: fromOffsets, toOffset: toOffset)
        rulesChanged()
    }

    func issues(_ id: String) -> [KeyProgram.Issue] { program.issues[id] ?? [] }

    private func rulesChanged() {
        KeyRuleSet(rules: rules).save()
        program = KeyCompiler.compile(rules)
        if isRunning { sync() }
    }

    // MARK: Key recorder support

    enum RecordingMode {
        /// The key as the keyboard sends it: all of Bosun's remaps are lifted.
        case physical
        /// The key as the event tap will see it: only the automatic Caps Lock
        /// carrier is lifted, so Caps Lock records as Caps Lock.
        case logical
    }

    /// The recorder must see the user's real keys, not what the rules make of them.
    func beginRecording(_ mode: RecordingMode) {
        recording = mode
        tap.setPaused(true)
        if isRunning { applyMapping() }
    }

    func endRecording() {
        guard recording != nil else { return }
        recording = nil
        tap.setPaused(false)
        if isRunning { applyMapping() }
    }

    func refreshKeyboards() {
        keyboards = HIDMapping.keyboards()
        refreshClassifiedKeyboards()
    }

    private func refreshClassifiedKeyboards() {
        let classified = HIDMapping.classifiedKeyboards()
        if builtInKeyboards != classified.builtIn { builtInKeyboards = classified.builtIn }
        if externalKeyboards != classified.external { externalKeyboards = classified.external }
        builtInFnUsages = classified.builtInFnUsages
    }

    // MARK: Accessibility

    var needsTap: Bool { program.needsTap }

    /// Shows the system prompt (first time only) and opens the settings pane.
    func requestAccessibility() {
        Accessibility.prompt()
        Accessibility.openSettings()
        scheduleTimer()
    }

    // MARK: Polling

    /// Permission can be granted or revoked while the panel is closed (opening
    /// System Settings closes it), keyboards come and go, and other tools may
    /// rewrite the mapping, so this runs whenever the module is on: quickly
    /// while waiting for permission, lazily otherwise.
    private func scheduleTimer() {
        timer?.invalidate()
        timer = nil
        guard isRunning else { return }
        let waiting = needsTap && !tapRunning
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
        sync(quiet: true)
        refreshStatus()
        if wasRunning != tapRunning { scheduleTimer() }
    }

    private func refreshStatus() {
        if panelVisible { karabinerRunning = Self.detectKarabiner() }
    }

    /// Brings the tap and the system mapping in line with the rules.
    private func sync(quiet: Bool = false) {
        refreshClassifiedKeyboards()
        syncTap()
        applyMapping(quiet: quiet)
    }

    // MARK: Event tap

    private func syncTap() {
        let trusted = AXIsProcessTrusted()
        if trusted != accessibilityGranted { accessibilityGranted = trusted }
        tap.update(program.tap)
        let wanted = isRunning && needsTap && trusted
        if wanted, !tap.isRunning {
            if tap.start() { Log.info("event tap started at the \(tap.location?.rawValue ?? "?") level", "keyboard") }
        } else if !wanted, tap.isRunning {
            // Also reached when permission is revoked: a tap left behind then
            // would swallow every keystroke.
            tap.stop()
            Log.info("event tap stopped", "keyboard")
        }
        if tapRunning != tap.isRunning { tapRunning = tap.isRunning }
        if tapLocation != tap.location { tapLocation = tap.location }
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

    /// What should be in the system mapping right now.
    private var desiredMapping: HIDMapping.Desired {
        guard isRunning, recording != .physical else { return .init() }
        // Without the tap to swallow it, a carried Caps Lock would be a dead key.
        let carriers = tap.isRunning && recording == nil ? [] : program.carriers
        var devices = program.devices
        if disableBuiltInWhenExternalConnected && !externalKeyboards.isEmpty {
            let disableEntries = HIDMapping.buildDisableEntries(extra: builtInFnUsages)
            for device in builtInKeyboards {
                devices[device] = disableEntries
            }
        }
        return .init(global: program.global.filter { !carriers.contains($0) }, devices: devices)
    }

    /// Makes the system mapping "everyone else's entries plus ours", per
    /// keyboard where a rule asks for it. Safe to repeat: whatever Bosun wrote
    /// before (even in a run that crashed) is taken out first, and nothing is
    /// written when the system already matches.
    private func applyMapping(quiet: Bool = false) {
        let plan = HIDMapping.plan(current: HIDMapping.snapshot(), previous: storedApplied, desired: desiredMapping)
        if plan.isNoop {
            storedApplied = plan.applied.isEmpty || !isRunning ? nil : plan.applied
            return
        }
        if let failure = HIDMapping.execute(plan) {
            mappingError = failure
            Log.info("mapping failed: \(failure)", "keyboard")
            return       // keep the old record so a later attempt can still clean up
        }
        storedApplied = plan.applied.isEmpty || !isRunning ? nil : plan.applied
        let after = HIDMapping.plan(current: HIDMapping.snapshot(), previous: storedApplied, desired: desiredMapping)
        mappingError = after.isNoop ? nil : "The system did not keep the mapping"
        Log.info("mapping written: \(plan.applied.ours.count) global, \(plan.applied.devices.reduce(0) { $0 + $1.ours.count }) per keyboard"
                 + (quiet ? " (had drifted)" : ""), "keyboard")
    }

    // MARK: Helpers

    private static func open(_ bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Log.info("no app with bundle id \(bundleID)", "keyboard")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

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
        // The root Core-Service daemon keeps running after "Quit Karabiner-Elements";
        // only the per-user server means Karabiner is actually remapping.
        let names = ["karabiner_console_user_server", "Karabiner-Console-User-Server"].map { String($0.prefix(16)) }
        for index in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            let name = withUnsafeBytes(of: &procs[index].kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            if names.contains(name) { return true }
        }
        return false
    }
}
