import AppKit
import SwiftUI

/// One connected display as shown in the panel and in Settings.
struct DisplayState: Identifiable, Equatable {
    enum Control: Equatable {
        /// Apple panel driven through DisplayServices.
        case native
        /// External display driven over DDC/CI.
        case ddc
        /// No DDC; dimmed with an overlay window because the user asked for it.
        case software
        /// Nothing we can or may control.
        case none
    }

    let id: CGDirectDisplayID
    /// Stable identity (vendor, model, serial) used to key settings.
    var key: String
    /// Name the display reports.
    var systemName: String
    /// Friendly name if the user set one.
    var name: String
    var isBuiltIn: Bool
    var control: Control = .none
    /// The display answered DDC (even if the user disabled control of it).
    var answersDDC = false
    /// 0...1. Includes the software-dimmed part of the scale.
    var brightness: Double = 1
    var contrast: Double?
    /// 0...1 as shown: zero while muted through the volume fallback.
    var volume: Double?
    var muted = false
    /// Active input (VCP 0x60, low byte).
    var input: UInt16?
    /// The display's own maximum per control, for the clamp fields.
    var deviceMax: [DisplayControl: UInt16] = [:]

    func value(_ control: DisplayControl) -> Double? {
        switch control {
        case .brightness: self.control == .none ? nil : brightness
        case .contrast: contrast
        case .volume: volume
        }
    }
}

/// What one refresh read from the hardware, before settings are applied.
struct RawDisplay: Sendable {
    struct Reading: Sendable, Equatable {
        var current: UInt16
        var max: UInt16
    }

    var id: CGDirectDisplayID
    var key: String
    var systemName: String
    var isBuiltIn: Bool
    var native: Double?
    var readings: [DisplayControl: Reading] = [:]
    var mute: UInt16?
    var input: UInt16?
}

/// Serial worker for all I2C traffic. Writes are coalesced per display and
/// feature: while one is queued or running, newer values replace the pending
/// one. A "smooth" write walks there in small steps instead of jumping.
final class DDCWorker: @unchecked Sendable {
    struct Key: Hashable {
        let display: CGDirectDisplayID
        let vcp: UInt8
    }

    let queue = DispatchQueue(label: "bosun.displays.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Key: (value: UInt16, smooth: Bool)] = [:]
    private var lastWritten: [Key: UInt16] = [:]

    /// Tells the worker what the display currently holds, as a starting point
    /// for smooth writes.
    func note(display: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        lock.lock()
        let key = Key(display: display, vcp: vcp)
        if pending[key] == nil { lastWritten[key] = value }
        lock.unlock()
    }

    func forget() {
        lock.lock()
        pending = [:]
        lastWritten = [:]
        lock.unlock()
    }

    func write(_ service: DDC.Service, display: CGDirectDisplayID, vcp: UInt8, value: UInt16, smooth: Bool = false) {
        let key = Key(display: display, vcp: vcp)
        lock.lock()
        let alreadyQueued = pending[key] != nil
        pending[key] = (value, smooth)
        lock.unlock()
        guard !alreadyQueued else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                guard let goal = pending[key] else { lock.unlock(); return }
                let from = lastWritten[key]
                lock.unlock()

                let next = Self.nextStep(from: from, to: goal.value, smooth: goal.smooth)
                if !DDC.write(service, vcp: vcp, value: next) {
                    Log.info("write of VCP 0x\(String(vcp, radix: 16)) to display \(display) failed", "displays")
                    lock.lock()
                    pending[key] = nil
                    lock.unlock()
                    return
                }
                lock.lock()
                lastWritten[key] = next
                let done = pending[key]?.value == next
                if done { pending[key] = nil }
                lock.unlock()
                if done { return }
            }
        }
    }

    /// A quarter of the remaining distance per write, at least one unit.
    static func nextStep(from: UInt16?, to: UInt16, smooth: Bool) -> UInt16 {
        guard smooth, let from, from != to else { return to }
        let distance = Int(to) - Int(from)
        let step = Swift.max(1, abs(distance) / 4)
        return UInt16(Int(from) + (distance > 0 ? step : -step))
    }
}

@MainActor
final class DisplaysModule: ObservableObject, BosunModule {
    enum KeyStatus: Equatable {
        /// Key control is switched off.
        case off
        /// Switched on, but no connected display has anything the keys could drive.
        case nothingToControl
        /// The event tap is running.
        case active
        /// Switched on, but Accessibility permission is missing.
        case needsAccessibility
    }

    enum ChangeSource { case slider, key, sync, restore }

    let id = "displays"
    let title = "Displays"
    let symbol = "display"

    @Published private(set) var displays: [DisplayState] = []
    @Published private(set) var config = DisplaysConfig.load()
    @Published private(set) var keyStatus: KeyStatus = .off
    @Published private(set) var soundOutput: DisplayAudioOutput?
    /// Custom shortcuts the system refused to register.
    @Published private(set) var shortcutFailures: Set<DisplayKeyAction> = []
    @Published private(set) var isRunning = false

    private let worker = DDCWorker()
    private let keyTap = DisplayKeyTap()
    private let hotKeys = DisplayHotKeys()
    private let osd = DisplayOSD()
    private let shades = DisplayShades()
    private let soundWatcher = SoundOutputWatcher()

    private var services: [CGDirectDisplayID: DDC.Service] = [:]
    private var lastEdit: [CGDirectDisplayID: Date] = [:]
    private var refreshGeneration = 0
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var nativePoll: Timer?
    private var syncTimer: Timer?
    private var lastSyncSource: Double?
    private var saveWork: DispatchWorkItem?
    private var registeredShortcuts: [DisplayKeyAction: DisplayShortcut] = [:]
    private var asleep = false
    /// Display keys whose saved values should be written back at the next read.
    private var restoreAll = false
    private var seenKeys: Set<String> = []
    private var wakeRetries = 0

    /// Snapshot runs share the machine with the installed app: they read and
    /// render, but never intercept keys or write to displays on their own.
    private var sideEffectsAllowed: Bool { !AppState.snapshotMode }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        asleep = false
        restoreAll = config.restore
        seenKeys = []

        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.asleep = true }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.woke() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.woke() }
        // Posted when the Accessibility list in System Settings changes.
        observe(DistributedNotificationCenter.default(), Notification.Name("com.apple.accessibility.api")) { module in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { module.updateKeyHandling() }
            }
        }

        keyTap.onKey = { [weak self] action, fine, targets, isRepeat in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.perform(action, fine: fine, targets: targets, isRepeat: isRepeat) }
            }
        }
        hotKeys.onAction = { [weak self] action, isRepeat in self?.shortcutPressed(action, isRepeat: isRepeat) }
        soundWatcher.onChange = { [weak self] in self?.soundOutputChanged() }
        soundWatcher.start()
        soundOutput = SoundOutputWatcher.current()

        refresh()
        updateSyncTimer()
        updateKeyHandling()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers = []
        nativePoll?.invalidate()
        nativePoll = nil
        syncTimer?.invalidate()
        syncTimer = nil
        keyTap.stop()
        hotKeys.unregisterAll()
        registeredShortcuts = [:]
        shortcutFailures = []
        soundWatcher.stop()
        shades.removeAll()
        osd.close()
        keyStatus = .off
        refreshGeneration += 1      // drop any refresh still in flight
        services = [:]
        worker.forget()
        displays = []
        saveNow()
    }

    func panelVisibilityChanged(_ visible: Bool) {
        nativePoll?.invalidate()
        nativePoll = nil
        guard isRunning, visible else { return }
        refresh()
        // The built-in panel also changes behind our back (keyboard keys,
        // ambient light); reading it is a cheap local call, unlike DDC.
        nativePoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNative() }
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (DisplaysModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    private func screensChanged() {
        shades.screensChanged()
        refresh()
    }

    private func woke() {
        // Displays need a moment after wake before they answer DDC again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else { return }
                self.asleep = false
                self.restoreAll = self.config.restore
                self.wakeRetries = 4
                self.lastSyncSource = nil
                self.refresh()
            }
        }
    }

    // MARK: Settings

    /// Changes settings from the UI.
    func update(_ mutate: (inout DisplaysConfig) -> Void) {
        var changed = config
        mutate(&changed)
        guard changed != config else { return }
        let old = config
        config = changed
        scheduleSave()
        guard isRunning else { return }

        renameDisplays()
        if Self.hardwareRelevant(old) != Self.hardwareRelevant(changed) { refresh() }
        if old.syncEnabled != changed.syncEnabled || old.displays.mapValues(\.syncOffset) != changed.displays.mapValues(\.syncOffset)
            || old.displays.mapValues(\.followBuiltIn) != changed.displays.mapValues(\.followBuiltIn) {
            lastSyncSource = nil
            updateSyncTimer()
        }
        updateKeyHandling()
    }

    func updatePrefs(_ key: String, _ mutate: (inout DisplayPrefs) -> Void) {
        update { config in
            var prefs = config.prefs(key)
            mutate(&prefs)
            config.displays[key] = prefs
        }
    }

    /// The per-display settings that change how hardware values are read or
    /// mapped, i.e. everything except what we merely remember.
    private static func hardwareRelevant(_ config: DisplaysConfig) -> [String: DisplayPrefs] {
        config.displays.mapValues { prefs in
            var copy = prefs
            copy.last = [:]
            copy.softMute = DisplaySoftMute()
            copy.friendlyName = ""
            copy.syncOffset = 0
            copy.followBuiltIn = true
            copy.showBrightness = true
            copy.showContrast = true
            copy.showVolume = true
            copy.showInput = true
            return copy
        }
    }

    /// Internal bookkeeping (last values, mute state): saved, but does not
    /// re-run the settings machinery.
    private func remember(_ key: String, _ mutate: (inout DisplayPrefs) -> Void) {
        var prefs = config.prefs(key)
        mutate(&prefs)
        guard prefs != config.displays[key] else { return }
        config.displays[key] = prefs
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveNow() } }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        config.save()
    }

    private func renameDisplays() {
        for index in displays.indices {
            let friendly = config.prefs(displays[index].key).friendlyName.trimmingCharacters(in: .whitespaces)
            let name = friendly.isEmpty ? displays[index].systemName : friendly
            if displays[index].name != name { displays[index].name = name }
        }
    }

    // MARK: Reading

    /// Re-enumerates displays and reads every value, off the main thread.
    func refresh() {
        guard isRunning else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let started = Date()
        let names = Self.screenNames()
        let untouched = Set(config.displays.filter { !$0.value.enabled }.keys)
        let noMute = Set(config.displays.filter { $0.value.muteSupport == .fallback }.keys)
        worker.queue.async { [weak self] in
            let snapshot = DisplaysModule.readAll(names: names, untouched: untouched, skipMute: noMute)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot, generation: generation, started: started) }
            }
        }
    }

    private func apply(_ snapshot: Snapshot, generation: Int, started: Date) {
        guard isRunning, generation == refreshGeneration else { return }
        services = snapshot.services
        var fresh: [DisplayState] = []
        var toRestore: [(id: CGDirectDisplayID, control: DisplayControl, value: Double)] = []
        var unanswered = false

        for raw in snapshot.displays {
            let prefs = config.prefs(raw.key)
            var state = Self.state(from: raw, prefs: prefs)
            if prefs.enabled, !raw.isBuiltIn, snapshot.services[raw.id] != nil, !state.answersDDC { unanswered = true }

            if state.control == .ddc {
                for (control, reading) in raw.readings {
                    worker.note(display: raw.id, vcp: control.vcp, value: reading.current)
                }
                // A display without a mute feature can only be muted by volume.
                if state.volume != nil, raw.mute == nil, prefs.muteSupport == .unknown {
                    remember(raw.key) { $0.muteSupport = .fallback }
                }
                let reconciled = DisplayMuteLogic.reconcile(prefs.softMute, hardwareVolume: state.volume ?? 0)
                if reconciled != prefs.softMute {
                    remember(raw.key) { $0.softMute = reconciled }
                    state.muted = false
                }

                let isNew = !seenKeys.contains(raw.key)
                if sideEffectsAllowed, config.restore, restoreAll || (isNew && !seenKeys.isEmpty) {
                    for control in [DisplayControl.brightness, .contrast] {
                        guard let saved = prefs.last[control.rawValue], let current = state.value(control),
                              abs(saved - current) > 0.004 else { continue }
                        toRestore.append((raw.id, control, saved))
                    }
                }
            }

            // Keep what the user set while this read was in flight.
            if let edited = lastEdit[raw.id], edited > started,
               let current = displays.first(where: { $0.id == raw.id }), current.control == state.control {
                state.brightness = current.brightness
                state.contrast = current.contrast
                state.volume = current.volume
                state.muted = current.muted
                state.input = current.input
            }
            fresh.append(state)
        }

        if fresh != displays { displays = fresh }
        for state in fresh where state.control != .none {
            seenKeys.insert(state.key)
            // Remember what the display holds, for restore and for the
            // software part of the brightness scale.
            remember(state.key) { prefs in
                for control in DisplayControl.allCases {
                    if let value = state.value(control), !(control == .volume && state.muted) {
                        prefs.last[control.rawValue] = value
                    }
                }
            }
        }
        applyShades()
        restoreAll = false
        for item in toRestore { setValue(item.control, item.value, for: item.id, source: .restore) }

        // After wake a display may not answer yet; try again a few times.
        if unanswered, wakeRetries > 0 {
            wakeRetries -= 1
            restoreAll = config.restore
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        } else {
            wakeRetries = 0
        }
        updateKeyHandling()
    }

    /// Turns raw readings into what the UI shows, according to the display's
    /// settings. Pure.
    nonisolated static func state(from raw: RawDisplay, prefs: DisplayPrefs) -> DisplayState {
        let friendly = prefs.friendlyName.trimmingCharacters(in: .whitespaces)
        var state = DisplayState(id: raw.id, key: raw.key, systemName: raw.systemName,
                                 name: friendly.isEmpty ? raw.systemName : friendly, isBuiltIn: raw.isBuiltIn)
        state.answersDDC = raw.readings[.brightness] != nil
        guard prefs.enabled else { return state }

        if let native = raw.native {
            state.control = .native
            state.brightness = native
        } else if let brightness = raw.readings[.brightness] {
            state.control = .ddc
            for (control, reading) in raw.readings { state.deviceMax[control] = reading.max }
            let hardware = prefs.range(.brightness, deviceMax: brightness.max).fraction(for: brightness.current)
            state.brightness = BrightnessSplit.combine(hardware: hardware, remembered: prefs.last[DisplayControl.brightness.rawValue],
                                                       mode: prefs.softwareDimming ? .belowMinimum : .off)
            if let contrast = raw.readings[.contrast] {
                state.contrast = prefs.range(.contrast, deviceMax: contrast.max).fraction(for: contrast.current)
            }
            if let volume = raw.readings[.volume] {
                let level = prefs.range(.volume, deviceMax: volume.max).fraction(for: volume.current)
                switch prefs.muteSupport {
                case .hardware:
                    state.muted = raw.mute == DDC.Mute.on
                    state.volume = level
                case .fallback, .unknown:
                    // Mute here means "we set the volume to zero".
                    state.muted = DisplayMuteLogic.reconcile(prefs.softMute, hardwareVolume: level).muted
                    state.volume = state.muted ? 0 : level
                }
            }
            state.input = raw.input.map(DisplayInputSource.value(fromRaw:))
        } else if prefs.softwareDimming {
            state.control = .software
            state.brightness = BrightnessSplit.combine(hardware: nil, remembered: prefs.last[DisplayControl.brightness.rawValue],
                                                       mode: .softwareOnly)
        }
        return state
    }

    private func pollNative() {
        for index in displays.indices where displays[index].control == .native {
            let display = displays[index]
            if let edited = lastEdit[display.id], Date().timeIntervalSince(edited) < 1 { continue }
            if let value = NativeBrightness.get(display.id), abs(value - display.brightness) > 0.001 {
                displays[index].brightness = value
            }
        }
    }

    struct Snapshot: @unchecked Sendable {
        var displays: [RawDisplay]
        var services: [CGDirectDisplayID: DDC.Service]
    }

    /// Blocking: ~90 ms per DDC value read, up to ~0.5 s for a display that
    /// does not answer. Displays in `untouched` are listed but not queried.
    nonisolated static func readAll(names: [CGDirectDisplayID: String] = [:], untouched: Set<String> = [],
                                    skipMute: Set<String> = []) -> Snapshot {
        let ids = activeDisplayIDs()
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        let services = external.isEmpty ? [:] : DDC.match(displays: external, services: DDC.externalServices())
        let keys = stableKeys(ids)

        var result: [RawDisplay] = []
        for id in ids {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let key = keys[id] ?? "display-\(id)"
            var raw = RawDisplay(id: id, key: key, systemName: names[id] ?? fallbackName(id, builtIn: builtIn), isBuiltIn: builtIn)
            defer { result.append(raw) }
            guard !untouched.contains(key) else { continue }

            if builtIn, let value = NativeBrightness.get(id) {
                raw.native = value
            } else if let service = services[id], let brightness = DDC.read(service, vcp: DDC.VCP.brightness), brightness.max > 0 {
                raw.readings[.brightness] = .init(current: brightness.current, max: brightness.max)
                if let contrast = DDC.read(service, vcp: DDC.VCP.contrast), contrast.max > 0 {
                    raw.readings[.contrast] = .init(current: contrast.current, max: contrast.max)
                }
                if let volume = DDC.read(service, vcp: DDC.VCP.volume), volume.max > 0 {
                    raw.readings[.volume] = .init(current: volume.current, max: volume.max)
                    if !skipMute.contains(key) { raw.mute = DDC.read(service, vcp: DDC.VCP.mute)?.current }
                }
                raw.input = DDC.read(service, vcp: DDC.VCP.inputSource)?.current
            } else if !builtIn, let value = NativeBrightness.get(id) {
                // Apple external displays answer DisplayServices, not DDC.
                raw.native = value
            }
        }
        // Built-in first, then by display ID, so rows do not jump around.
        result.sort { ($0.isBuiltIn ? 0 : 1, $0.id) < ($1.isBuiltIn ? 0 : 1, $1.id) }
        return Snapshot(displays: result, services: services)
    }

    nonisolated static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        // A mirrored set shows up once, as its primary display.
        return Array(ids.prefix(Int(count)))
    }

    /// Settings follow the physical display, not the port or display ID. Two
    /// identical displays without serial numbers are told apart by order.
    nonisolated static func stableKeys(_ ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: String] {
        var result: [CGDirectDisplayID: String] = [:]
        var seen: [String: Int] = [:]
        for id in ids.sorted() {
            let base = CGDisplayIsBuiltin(id) != 0
                ? "builtin"
                : "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
            let count = seen[base, default: 0] + 1
            seen[base] = count
            result[id] = count == 1 ? base : "\(base)#\(count)"
        }
        return result
    }

    nonisolated static func fallbackName(_ id: CGDirectDisplayID, builtIn: Bool) -> String {
        if builtIn { return "Built-in Display" }
        let name = DDC.identity(of: id).name
        return name.isEmpty ? "Display \(id)" : name
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let id = screen.displayID { names[id] = screen.localizedName }
        }
        return names
    }

    // MARK: Writing

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) { setValue(.brightness, value, for: displayID) }
    func setContrast(_ value: Double, for displayID: CGDirectDisplayID) { setValue(.contrast, value, for: displayID) }
    func setVolume(_ value: Double, for displayID: CGDirectDisplayID) { setValue(.volume, value, for: displayID) }

    func setValue(_ control: DisplayControl, _ value: Double, for displayID: CGDirectDisplayID, source: ChangeSource = .slider) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        let display = displays[index]
        let prefs = config.prefs(display.key)
        let value = Swift.min(Swift.max(value, 0), 1)
        let smooth = source == .key && config.smooth

        switch control {
        case .brightness:
            switch display.control {
            case .native:
                NativeBrightness.set(displayID, value)
            case .ddc:
                let split = BrightnessSplit.split(value, mode: prefs.softwareDimming ? .belowMinimum : .off)
                let range = prefs.range(.brightness, deviceMax: display.deviceMax[.brightness] ?? 100)
                send(DDC.VCP.brightness, range.raw(for: split.hardware ?? 0), to: displayID, smooth: smooth)
                if sideEffectsAllowed { shades.setOpacity(split.shade, for: displayID) }
            case .software:
                if sideEffectsAllowed {
                    shades.setOpacity(BrightnessSplit.split(value, mode: .softwareOnly).shade, for: displayID)
                }
            case .none:
                return
            }
            displays[index].brightness = value
            // Moving a display by hand while it follows the built-in display
            // changes its offset rather than fighting the sync.
            if source == .slider || source == .key, config.syncEnabled, !display.isBuiltIn, prefs.followBuiltIn,
               let builtIn = displays.first(where: { $0.isBuiltIn && $0.control == .native }) {
                remember(display.key) { $0.syncOffset = ((value - builtIn.brightness) * 100).rounded() / 100 }
            }

        case .contrast:
            guard display.control == .ddc, display.contrast != nil else { return }
            let range = prefs.range(.contrast, deviceMax: display.deviceMax[.contrast] ?? 100)
            send(DDC.VCP.contrast, range.raw(for: value), to: displayID)
            displays[index].contrast = value

        case .volume:
            guard display.control == .ddc, display.volume != nil else { return }
            if display.muted, value > 0 {
                // Raising the volume unmutes, as on any Mac.
                if prefs.muteSupport == .hardware { send(DDC.VCP.mute, DDC.Mute.off, to: displayID) }
                remember(display.key) { $0.softMute = DisplayMuteLogic.volumeSet($0.softMute, to: value) }
                displays[index].muted = false
            }
            let range = prefs.range(.volume, deviceMax: display.deviceMax[.volume] ?? 100)
            var raw = range.raw(for: value)
            // Never let an audible setting round down to silence.
            if value > 0 { raw = Swift.max(1, raw) }
            send(DDC.VCP.volume, raw, to: displayID)
            displays[index].volume = value
        }

        lastEdit[displayID] = Date()
        if !(control == .volume && displays[index].muted) {
            remember(display.key) { $0.last[control.rawValue] = value }
        }
    }

    func toggleMute(for displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }),
              displays[index].control == .ddc, displays[index].volume != nil else { return }
        let display = displays[index]
        lastEdit[displayID] = Date()
        switch config.prefs(display.key).muteSupport {
        case .hardware:
            displays[index].muted = !display.muted
            send(DDC.VCP.mute, display.muted ? DDC.Mute.off : DDC.Mute.on, to: displayID)
        case .fallback:
            applySoftMuteToggle(displayID)
        case .unknown:
            // First use on this display: find out whether its mute feature
            // really works, then mute one way or the other.
            guard let service = services[displayID] else { return }
            let wantMuted = !display.muted
            displays[index].muted = wantMuted
            let key = display.key
            worker.queue.async { [weak self] in
                let support = DisplaysModule.probeMute(service, wantMuted: wantMuted)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.muteProbed(displayID, key: key, support: support, wantMuted: wantMuted) }
                }
            }
        }
    }

    /// Blocking. Leaves the display in the wanted state if its mute works.
    nonisolated static func probeMute(_ service: DDC.Service, wantMuted: Bool) -> DisplayMuteSupport {
        let want = wantMuted ? DDC.Mute.on : DDC.Mute.off
        let other = wantMuted ? DDC.Mute.off : DDC.Mute.on
        guard let before = DDC.read(service, vcp: DDC.VCP.mute)?.current else { return .fallback }
        // Write a value that differs from what the display reports and see
        // whether it sticks.
        let trial = before == want ? other : want
        DDC.write(service, vcp: DDC.VCP.mute, value: trial)
        usleep(100_000)
        let support = DisplayMuteLogic.probe(before: before, wrote: trial, after: DDC.read(service, vcp: DDC.VCP.mute)?.current)
        if support == .hardware, trial != want { DDC.write(service, vcp: DDC.VCP.mute, value: want) }
        return support
    }

    private func muteProbed(_ displayID: CGDirectDisplayID, key: String, support: DisplayMuteSupport, wantMuted: Bool) {
        guard isRunning else { return }
        remember(key) { $0.muteSupport = support }
        guard support == .fallback, let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        Log.info("display \(displayID) ignores DDC mute; muting through volume instead", "displays")
        displays[index].muted = !wantMuted
        applySoftMuteToggle(displayID)
    }

    private func applySoftMuteToggle(_ displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        let display = displays[index]
        let prefs = config.prefs(display.key)
        var state = prefs.softMute
        state.muted = display.muted
        let result = DisplayMuteLogic.toggle(state, volume: display.volume ?? 0)
        let range = prefs.range(.volume, deviceMax: display.deviceMax[.volume] ?? 100)
        // Mute writes a literal zero, whatever the configured minimum is.
        send(DDC.VCP.volume, result.state.muted ? 0 : Swift.max(1, range.raw(for: result.volume)), to: displayID)
        displays[index].muted = result.state.muted
        displays[index].volume = result.volume
        lastEdit[displayID] = Date()
        remember(display.key) { prefs in
            prefs.softMute = result.state
            if !result.state.muted { prefs.last[DisplayControl.volume.rawValue] = result.volume }
        }
    }

    /// Forget what we learned about a display's mute feature and test again
    /// at the next toggle.
    func resetMuteSupport(_ key: String) {
        remember(key) { $0.muteSupport = .unknown; $0.softMute = DisplaySoftMute() }
        refresh()
    }

    func setInput(_ value: UInt16, for displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }), displays[index].control == .ddc,
              displays[index].input != nil, displays[index].input != value else { return }
        displays[index].input = value
        lastEdit[displayID] = Date()
        send(DDC.VCP.inputSource, value, to: displayID)
    }

    private func send(_ vcp: UInt8, _ value: UInt16, to displayID: CGDirectDisplayID, smooth: Bool = false) {
        guard let service = services[displayID] else { return }
        worker.write(service, display: displayID, vcp: vcp, value: value, smooth: smooth)
    }

    private func applyShades() {
        guard sideEffectsAllowed else { return }
        var wanted: [CGDirectDisplayID: Double] = [:]
        for display in displays {
            let prefs = config.prefs(display.key)
            switch display.control {
            case .ddc where prefs.softwareDimming:
                wanted[display.id] = BrightnessSplit.split(display.brightness, mode: .belowMinimum).shade
            case .software:
                wanted[display.id] = BrightnessSplit.split(display.brightness, mode: .softwareOnly).shade
            default:
                break
            }
        }
        for displayID in shades.dimmedDisplays where wanted[displayID] == nil { shades.remove(displayID) }
        for (displayID, opacity) in wanted { shades.setOpacity(opacity, for: displayID) }
    }

    // MARK: Keys

    /// The connected displays as the key router sees them.
    var routingDisplays: [DisplayKeyRouting.Display] {
        displays.compactMap { display in
            guard config.prefs(display.key).enabled else { return nil }
            var controls = Set<DisplayControl>()
            if display.control != .none { controls.insert(.brightness) }
            if display.contrast != nil { controls.insert(.contrast) }
            if display.volume != nil { controls.insert(.volume) }
            return DisplayKeyRouting.Display(id: display.id, key: display.key, name: display.systemName,
                                      isBuiltIn: display.isBuiltIn, controls: controls)
        }
    }

    /// The displays the volume keys would drive right now (for the settings
    /// tab's status line).
    var volumeKeyTargets: [String] {
        var env = DisplayKeyRouting.Environment(displays: routingDisplays, output: soundOutput)
        env.pointerDisplay = DisplayKeyTap.display(at: CGEvent(source: nil)?.location ?? .zero)
        let ids = DisplayKeyRouting.volumeTargets(config.routing, env).map(\.id)
        return displays.filter { ids.contains($0.id) }.map(\.name)
    }

    private func soundOutputChanged() {
        soundOutput = SoundOutputWatcher.current()
        updateKeyHandling()
    }

    /// Starts, stops or re-briefs the event tap and the hot keys so they
    /// match the settings, the connected displays and the permission state.
    func updateKeyHandling() {
        guard isRunning else {
            keyTap.stop()
            if keyStatus != .off { keyStatus = .off }
            return
        }
        let routing = config.routing
        let policy = DisplayKeyTap.Policy(config: routing, displays: routingDisplays, output: soundOutput)
        let status: KeyStatus
        if !(config.brightnessKeys || config.volumeKeys) {
            keyTap.stop()
            status = .off
        } else if !Accessibility.isTrusted {
            keyTap.stop()
            status = .needsAccessibility
        } else if !DisplayKeyRouting.needsTap(routing, DisplayKeyRouting.Environment(displays: policy.displays, output: policy.output)) {
            keyTap.stop()
            status = .nothingToControl
        } else if !sideEffectsAllowed {
            status = .active        // snapshot run: show what would happen, intercept nothing
        } else {
            keyTap.update(policy)
            status = keyTap.start() ? .active : .needsAccessibility
        }
        if status != keyStatus { keyStatus = status }

        var shortcuts: [DisplayKeyAction: DisplayShortcut] = [:]
        for (name, shortcut) in config.shortcuts {
            if let action = DisplayKeyAction(rawValue: name) { shortcuts[action] = shortcut }
        }
        if sideEffectsAllowed, shortcuts != registeredShortcuts {
            registeredShortcuts = shortcuts
            shortcutFailures = hotKeys.register(shortcuts)
        }
    }

    private func shortcutPressed(_ action: DisplayKeyAction, isRepeat: Bool) {
        var env = DisplayKeyRouting.Environment(displays: routingDisplays, output: soundOutput)
        env.pointerDisplay = DisplayKeyTap.display(at: CGEvent(source: nil)?.location ?? .zero)
        env.focusDisplay = DisplayKeyTap.focusedDisplay()
        perform(action, fine: false, targets: DisplayKeyRouting.shortcutTargets(action, config: config.routing, env: env), isRepeat: isRepeat)
    }

    /// Applies a key press to the given displays and shows the result.
    func perform(_ action: DisplayKeyAction, fine: Bool, targets: [CGDirectDisplayID], isRepeat: Bool) {
        guard isRunning, !asleep else { return }
        let step = DisplayStepMath.step(base: config.stepPercent / 100, fine: fine)
        let segments = config.stepPercent == 6.25 ? 64 : 100
        for displayID in targets {
            guard let display = displays.first(where: { $0.id == displayID }) else { continue }
            if action == .muteToggle {
                guard !isRepeat, display.volume != nil else { continue }
                toggleMute(for: displayID)
                let after = displays.first { $0.id == displayID }
                osd.show(after?.muted == true ? .muted : .volume, value: after?.volume ?? 0, on: displayID,
                         style: config.osd, steps: segments)
                continue
            }
            guard var current = display.value(action.control) else { continue }
            // Like macOS, a volume key pressed while muted continues from the
            // volume there was before the mute.
            if action.control == .volume, display.muted {
                let saved = config.prefs(display.key).softMute.savedVolume
                if saved > 0 { current = saved }
            }
            let next = DisplayStepMath.next(current, up: action.isUp, step: step)
            setValue(action.control, next, for: displayID, source: .key)
            let kind: DisplayOSD.Kind = switch action.control {
            case .brightness: .brightness
            case .contrast: .contrast
            case .volume: next > 0 ? .volume : .muted
            }
            osd.show(kind, value: next, on: displayID, style: config.osd, steps: segments)
        }
    }

    // MARK: Sync

    private func updateSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = nil
        guard isRunning, sideEffectsAllowed, config.syncEnabled else { return }
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncTick() }
        }
    }

    private func syncTick() {
        guard !asleep, let builtIn = displays.first(where: { $0.isBuiltIn && $0.control == .native }),
              let source = NativeBrightness.get(builtIn.id), DisplaySyncMath.changed(from: lastSyncSource, to: source) else { return }
        lastSyncSource = source
        if let index = displays.firstIndex(where: { $0.id == builtIn.id }) { displays[index].brightness = source }
        for display in displays where !display.isBuiltIn && (display.control == .ddc || display.control == .software) {
            let prefs = config.prefs(display.key)
            guard prefs.followBuiltIn else { continue }
            let target = DisplaySyncMath.target(source: source, offset: prefs.syncOffset)
            if abs(target - display.brightness) > 0.004 { setValue(.brightness, target, for: display.id, source: .sync) }
        }
    }
}
