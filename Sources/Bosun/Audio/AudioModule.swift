import AVFoundation
import AppKit
import CoreAudio
import SwiftUI

/// Level of the default input device, published separately so that meter
/// updates do not redraw everything that observes the module.
@MainActor
final class InputMeterModel: ObservableObject {
    /// 0…1 on a −60…0 dB scale.
    @Published fileprivate(set) var level: Double = 0
    @Published fileprivate(set) var isRunning = false
}

/// Sound: devices, master volume, and per-app volume / mute / boost / output
/// routing. No driver is installed; the per-app features use Core Audio process
/// taps (see `AppTap`), which need the "System Audio Recording Only"
/// permission. Nothing that needs the permission happens until the user first
/// changes something for an app.
@MainActor
final class AudioModule: ObservableObject, BosunModule {
    let id = "audio"
    let title = "Sound"
    let symbol = "speaker.wave.2"

    @Published private(set) var isRunning = false
    @Published private(set) var outputs: [AudioDeviceState] = []
    @Published private(set) var inputs: [AudioDeviceState] = []
    @Published private(set) var defaultOutput = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var defaultInput = AudioDeviceID(kAudioObjectUnknown)
    /// App rows for the panel (playing, recent, pinned, or customised and running).
    @Published private(set) var rows: [AudioAppRow] = []
    /// Every app with saved settings, for the settings window.
    @Published private(set) var savedRows: [AudioAppRow] = []
    @Published private(set) var settings: [String: AudioAppSettings] = [:]
    @Published private(set) var appErrors: [String: String] = [:]
    @Published private(set) var captureAccess: AudioCaptureAccess = .undetermined
    @Published private(set) var micStatus: AVAuthorizationStatus = .notDetermined
    /// Top of the per-app sliders: 1, 1.5 or 2.
    @Published private(set) var boostLimit = AudioMath.defaultBoostLimit
    /// How long an app stays listed after it stops playing.
    @Published private(set) var recentWindow = AudioMath.defaultRecent
    let inputMeter = InputMeterModel()

    private enum Key {
        static let apps = "audio.apps"
        static let legacyVolumes = "audio.appVolumes"
        /// Set once the user has changed something for an app; before that no tap is ever created.
        static let armed = "audio.perAppArmed"
        static let boostLimit = "audio.boostLimit"
        static let recent = "audio.recentSeconds"
    }

    private struct Session {
        let tap: AppTap
        var processes: [AudioObjectID]
        let plan: TapPlan
        var watch = TapWatchdog.Track()
    }

    /// How long a tap is kept after an app returns to its defaults, so dragging
    /// across 100% does not rebuild it repeatedly.
    private static let defaultsGrace: TimeInterval = 1.5

    private let defaults = UserDefaults.standard
    private var armed = false
    private var requestingAccess = false
    private var panelVisible = false
    private var settingsVisible = false
    private var systemListeners: [AudioListener] = []
    private var deviceListeners: [AudioDeviceID: [AudioListener]] = [:]
    private var processListeners: [AudioObjectID: AudioListener] = [:]
    private var processRefreshPending = false
    private var deviceRefreshPending = false
    private var rowExpiry: DispatchWorkItem?
    private var watchdog: Timer?
    private var meterTimer: Timer?
    private var meterTap: InputLevelTap?
    private var allApps: [AudioApp] = []
    private var lastPlayed: [String: Date] = [:]
    private var lastEdit: [String: Date] = [:]
    private var icons: [String: NSImage] = [:]
    private var sessions: [String: Session] = [:]
    /// Consecutive failed attempts to build a tap, per app.
    private var failures: [String: Int] = [:]

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        armed = defaults.bool(forKey: Key.armed)
        settings = AudioStore.decode(defaults.dictionary(forKey: Key.apps))
        if let legacy = defaults.object(forKey: Key.legacyVolumes) {
            for (id, migrated) in AudioStore.migrate(legacyVolumes: legacy) where settings[id] == nil {
                settings[id] = migrated
            }
            defaults.removeObject(forKey: Key.legacyVolumes)
            persistSettings()
        }
        boostLimit = AudioMath.validBoostLimit(defaults.object(forKey: Key.boostLimit) as? Double ?? AudioMath.defaultBoostLimit)
        recentWindow = AudioMath.validRecent(defaults.object(forKey: Key.recent) as? Double ?? AudioMath.defaultRecent)
        captureAccess = AudioCaptureAccess.current()
        micStatus = AudioMicAccess.status

        // Before any tap of our own exists: remove what a crashed run left behind.
        AppTap.queue.async {
            let removed = AppTap.sweepOrphans()
            if removed > 0 { Log.info("removed \(removed) leftover tap objects from a previous run", "audio") }
        }

        func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor (AudioModule) -> Void) {
            let listener = AudioListener(CA.system, CA.address(selector)) { [weak self] in
                if let self, self.isRunning { handler(self) }
            }
            if let listener { systemListeners.append(listener) }
        }
        listen(kAudioHardwarePropertyDevices) { $0.scheduleDeviceRefresh() }
        listen(kAudioHardwarePropertyDefaultInputDevice) { $0.scheduleDeviceRefresh() }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { $0.scheduleDeviceRefresh() }
        listen(kAudioHardwarePropertyProcessObjectList) { $0.scheduleProcessRefresh() }

        refreshDevices()
        refreshProcesses()
        updateMeter()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        systemListeners = []
        deviceListeners = [:]
        processListeners = [:]
        rowExpiry?.cancel()
        watchdog?.invalidate()
        watchdog = nil
        // Synchronous: every tap is gone, and every app back on its own
        // output, before this returns (it also runs at app termination).
        let taps = sessions.values.map(\.tap)
        sessions = [:]
        let meter = meterTap
        meterTap = nil
        AppTap.queue.sync {
            taps.forEach { $0.stop() }
            meter?.stop()
        }
        meterTimer?.invalidate()
        meterTimer = nil
        inputMeter.isRunning = false
        inputMeter.level = 0
        allApps = []
        rows = []
        appErrors = [:]
        failures = [:]
        lastPlayed = [:]
    }

    func panelVisibilityChanged(_ visible: Bool) {
        panelVisible = visible
        if visible { refreshOnShow() }
    }

    /// Called by the settings tab when it appears and disappears.
    func settingsVisibilityChanged(_ visible: Bool) {
        settingsVisible = visible
        if visible { refreshOnShow() }
        updateMeter()
    }

    private func refreshOnShow() {
        guard isRunning else { return }
        // The user may have changed permissions in System Settings meanwhile.
        if !requestingAccess {
            let access = AudioCaptureAccess.current()
            if access != captureAccess {
                captureAccess = access
                appErrors = [:]
            }
        }
        micStatus = AudioMicAccess.status
        refreshDevices()
        refreshProcesses()
    }

    // MARK: Devices

    var defaultOutputState: AudioDeviceState? { outputs.first { $0.id == defaultOutput } }
    var defaultInputState: AudioDeviceState? { inputs.first { $0.id == defaultInput } }

    func setDefaultOutput(_ device: AudioDeviceID) {
        guard device != defaultOutput else { return }
        AudioDevices.setDefault(device, .output)
        scheduleDeviceRefresh()
    }

    func setDefaultInput(_ device: AudioDeviceID) {
        guard device != defaultInput else { return }
        AudioDevices.setDefault(device, .input)
        scheduleDeviceRefresh()
    }

    func setVolume(_ value: Float, device: AudioDeviceID, _ direction: AudioDevices.Direction = .output) {
        let value = min(max(value, 0), 1)
        guard AudioDevices.setVolume(device, value, direction) else { return }
        // Like the volume keys: turning the volume up unmutes.
        if value > 0, AudioDevices.isMuted(device, direction) == true { AudioDevices.setMuted(device, false, direction) }
        update(device, direction) { $0.volume = value; if value > 0 { $0.isMuted = false } }
    }

    func setMuted(_ muted: Bool, device: AudioDeviceID, _ direction: AudioDevices.Direction = .output) {
        guard AudioDevices.setMuted(device, muted, direction) else { return }
        update(device, direction) { $0.isMuted = muted }
    }

    func setBalance(_ balance: Float, device: AudioDeviceID) {
        // Snap to centre so it can be found again.
        let value: Float = abs(balance - 0.5) < 0.03 ? 0.5 : min(max(balance, 0), 1)
        guard AudioDevices.setBalance(device, value) else { return }
        update(device, .output) { $0.balance = value }
    }

    func setSampleRate(_ rate: Double, device: AudioDeviceID) {
        guard AudioDevices.sampleRate(device) != rate else { return }
        AudioDevices.setSampleRate(device, rate)
        scheduleDeviceRefresh()
    }

    /// Reflects a change the user just made without waiting for the listener.
    private func update(_ device: AudioDeviceID, _ direction: AudioDevices.Direction, _ change: (inout AudioDeviceState) -> Void) {
        if direction == .output, let index = outputs.firstIndex(where: { $0.id == device }) { change(&outputs[index]) }
        if direction == .input, let index = inputs.firstIndex(where: { $0.id == device }) { change(&inputs[index]) }
    }

    private func scheduleDeviceRefresh() {
        guard !deviceRefreshPending else { return }
        deviceRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.deviceRefreshPending = false
            self.refreshDevices()
        }
    }

    private func refreshDevices() {
        guard isRunning else { return }
        let newOutputs = AudioDevices.list(.output)
        let newInputs = AudioDevices.list(.input)
        let newDefaultOutput = AudioDevices.defaultDevice(.output) ?? AudioDeviceID(kAudioObjectUnknown)
        let newDefaultInput = AudioDevices.defaultDevice(.input) ?? AudioDeviceID(kAudioObjectUnknown)

        // A tap is built for one device at one sample rate: note which
        // devices changed rate so their taps are rebuilt below.
        let oldRates = Dictionary(outputs.map { ($0.uid, $0.sampleRate) }, uniquingKeysWith: { a, _ in a })
        let rateChanged = Set(newOutputs.filter { oldRates[$0.uid].map { $0 != 0 } == true && oldRates[$0.uid] != $0.sampleRate }.map(\.uid))
        let outputChanged = newDefaultOutput != defaultOutput
        let devicesChanged = Set(newOutputs.map(\.uid)) != Set(outputs.map(\.uid))

        if newOutputs != outputs { outputs = newOutputs }
        if newInputs != inputs { inputs = newInputs }
        if outputChanged { defaultOutput = newDefaultOutput }
        if newDefaultInput != defaultInput { defaultInput = newDefaultInput }

        // Listeners: one set per device, rebuilt only for devices that came or went.
        let ids = Set(newOutputs.map(\.id)).union(newInputs.map(\.id))
        deviceListeners = deviceListeners.filter { ids.contains($0.key) }
        for device in ids where deviceListeners[device] == nil {
            var listeners: [AudioListener] = []
            var addresses = [
                AudioDevices.volumeAddress(.output), AudioDevices.muteAddress(.output),
                AudioDevices.volumeAddress(.input), AudioDevices.muteAddress(.input),
                CA.address(kAudioDevicePropertyNominalSampleRate),
                CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput),
            ]
            if let balance = AudioDevices.balanceAddress(device) { addresses.append(balance) }
            for address in addresses where CA.has(device, address) {
                if let listener = AudioListener(device, address, handler: { [weak self] in self?.scheduleDeviceRefresh() }) {
                    listeners.append(listener)
                }
            }
            deviceListeners[device] = listeners
        }

        if !rateChanged.isEmpty {
            for (appID, session) in sessions
            where rateChanged.contains(session.plan.outputUID) || session.plan.captureUID.map(rateChanged.contains) == true {
                dropSession(appID)
            }
        }
        if outputChanged || devicesChanged {
            // A different set of devices: whatever failed before may work now.
            appErrors = [:]
            failures = [:]
        }
        reconcileTaps()
        updateMeter()
    }

    // MARK: App settings

    func appSettings(_ appID: String) -> AudioAppSettings { settings[appID] ?? AudioAppSettings() }

    /// Whether per-app controls can do anything.
    var perAppAvailable: Bool { captureAccess != .denied }

    func setAppVolume(_ appID: String, _ value: Double) {
        let value = AudioMath.snap(value, limit: boostLimit)
        mutate(appID) { $0.volume = value }
    }

    func setAppMuted(_ appID: String, _ muted: Bool) {
        mutate(appID) { $0.muted = muted }
    }

    /// `uid` nil follows the system default output.
    func setAppOutput(_ appID: String, _ uid: String?) {
        mutate(appID) { $0.outputUID = uid }
    }

    func setPinned(_ appID: String, _ pinned: Bool) {
        mutate(appID) { $0.pinned = pinned }
    }

    /// Pins an app chosen from disk or from the running apps list.
    func pin(bundleID: String, name: String, path: String?) {
        mutate(bundleID) {
            $0.pinned = true
            $0.name = name
            if let path { $0.path = path }
        }
    }

    /// Back to untouched audio; a pinned app stays pinned.
    func resetApp(_ appID: String) {
        mutate(appID) {
            $0.volume = 1
            $0.muted = false
            $0.outputUID = nil
        }
    }

    /// Removes everything saved for the app, including its pin.
    func forgetApp(_ appID: String) {
        guard settings[appID] != nil else { return }
        settings[appID] = nil
        appErrors[appID] = nil
        lastEdit[appID] = nil
        persistSettings()
        rebuildRows()
        reconcileTaps()
    }

    func setBoostLimit(_ limit: Double) {
        let limit = AudioMath.validBoostLimit(limit)
        guard limit != boostLimit else { return }
        boostLimit = limit
        defaults.set(limit, forKey: Key.boostLimit)
        // Saved values above the new limit are clamped when applied, not rewritten.
        reconcileTaps()
    }

    func setRecentWindow(_ seconds: TimeInterval) {
        let seconds = AudioMath.validRecent(seconds)
        guard seconds != recentWindow else { return }
        recentWindow = seconds
        defaults.set(seconds, forKey: Key.recent)
        refreshProcesses()
    }

    /// Tears down every tap and forgets every per-app setting and preference.
    func resetAll() {
        settings = [:]
        appErrors = [:]
        failures = [:]
        lastEdit = [:]
        armed = false
        boostLimit = AudioMath.defaultBoostLimit
        recentWindow = AudioMath.defaultRecent
        for key in [Key.apps, Key.legacyVolumes, Key.armed, Key.boostLimit, Key.recent] {
            defaults.removeObject(forKey: key)
        }
        rebuildRows()
        reconcileTaps()
    }

    /// The app's chosen output device, when it is connected and not the default.
    func chosenOverride(_ appID: String) -> AudioDeviceState? {
        guard let uid = AudioRouting.override(appSettings(appID), defaultUID: defaultOutputUID, outputs: outputFacts)
        else { return nil }
        return outputs.first { $0.uid == uid }
    }

    /// Whether the app's audio is being sent to its chosen device right now.
    func isRouted(_ appID: String) -> Bool {
        guard let plan = sessions[appID]?.plan else { return false }
        return plan.outputUID != defaultOutputUID
    }

    /// True when the app has an output chosen that is not connected.
    func overrideUnavailable(_ appID: String) -> Bool {
        guard let uid = appSettings(appID).outputUID else { return false }
        return !outputs.contains { $0.uid == uid }
    }

    /// Running apps that could be pinned.
    func pinCandidates() -> [(id: String, name: String, path: String?)] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .filter { settings[$0.bundleIdentifier!]?.pinned != true }
            .map { (id: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!, path: $0.bundleURL?.path) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    func icon(for row: AudioAppRow) -> NSImage? {
        if let icon = icons[row.id] { return icon }
        var icon: NSImage?
        if let pid = row.ownerPID { icon = NSRunningApplication(processIdentifier: pid)?.icon }
        if icon == nil, let path = settings[row.id]?.path, FileManager.default.fileExists(atPath: path) {
            icon = NSWorkspace.shared.icon(forFile: path)
        }
        if icon == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: row.id) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        }
        icons[row.id] = icon
        return icon
    }

    private func mutate(_ appID: String, _ change: (inout AudioAppSettings) -> Void) {
        guard isRunning else { return }
        var updated = appSettings(appID)
        let before = updated
        change(&updated)
        guard updated != before else { return }
        // New per-app audio settings need the permission; pins and resets do not.
        if !pinOnlyChange(before, updated), !updated.isAudioDefault, !perAppAvailable { return }

        // Remember what the app is called so it can be listed while not running.
        if updated.name == nil || updated.path == nil, let app = allApps.first(where: { $0.id == appID }) {
            if updated.name == nil { updated.name = app.name }
            if updated.path == nil { updated.path = NSRunningApplication(processIdentifier: app.ownerPID)?.bundleURL?.path }
        }
        if updated.isEmpty { settings[appID] = nil } else { settings[appID] = updated }
        persistSettings()
        lastEdit[appID] = Date()
        appErrors[appID] = nil
        failures[appID] = nil

        if !updated.isAudioDefault {
            if !armed {
                armed = true
                defaults.set(true, forKey: Key.armed)
            }
            if captureAccess == .undetermined { requestCaptureAccess() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.defaultsGrace + 0.1) { [weak self] in
                self?.reconcileTaps()
            }
        }
        rebuildRows()
        reconcileTaps()
    }

    private func pinOnlyChange(_ before: AudioAppSettings, _ after: AudioAppSettings) -> Bool {
        var a = before, b = after
        a.pinned = false; b.pinned = false
        a.name = nil; b.name = nil
        a.path = nil; b.path = nil
        return a == b
    }

    private func persistSettings() {
        defaults.set(AudioStore.encode(settings), forKey: Key.apps)
    }

    // MARK: Permissions

    func requestCaptureAccess() {
        guard !requestingAccess else { return }
        requestingAccess = true
        AudioCaptureAccess.request { [weak self] result in
            guard let self else { return }
            self.requestingAccess = false
            self.captureAccess = result
            self.reconcileTaps()
        }
    }

    func openCaptureSettings() { NSWorkspace.shared.open(AudioCaptureAccess.settingsURL) }

    func requestMicAccess() {
        AudioMicAccess.request { [weak self] _ in
            guard let self else { return }
            self.micStatus = AudioMicAccess.status
            self.updateMeter()
        }
    }

    func openMicSettings() { NSWorkspace.shared.open(AudioMicAccess.settingsURL) }

    // MARK: Processes and rows

    private func scheduleProcessRefresh() {
        // isRunningOutput flaps while an app starts or stops; coalesce.
        guard !processRefreshPending else { return }
        processRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.processRefreshPending = false
            self.refreshProcesses()
        }
    }

    private func refreshProcesses() {
        guard isRunning else { return }
        let processes = AudioProcesses.list()
        let live = Set(processes.map(\.objectID))
        processListeners = processListeners.filter { live.contains($0.key) }
        for object in live where processListeners[object] == nil {
            processListeners[object] = AudioListener(object, CA.address(kAudioProcessPropertyIsRunningOutput)) {
                [weak self] in self?.scheduleProcessRefresh()
            }
        }

        allApps = AudioProcesses.group(processes)
        let now = Date()
        for app in allApps where app.isPlaying { lastPlayed[app.id] = now }
        lastPlayed = lastPlayed.filter { now.timeIntervalSince($0.value) < recentWindow }
        let present = Set(allApps.map(\.id)).union(settings.keys)
        icons = icons.filter { present.contains($0.key) }
        rebuildRows()

        // One-shot timer to drop rows whose "recent" time runs out; no polling.
        rowExpiry?.cancel()
        if let expiry = AudioAppList.nextExpiry(live: allApps, lastPlayed: lastPlayed, now: now, recentWindow: recentWindow) {
            let work = DispatchWorkItem { [weak self] in self?.refreshProcesses() }
            rowExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0.1, expiry.timeIntervalSince(now) + 0.05), execute: work)
        }
        reconcileTaps()
    }

    private func rebuildRows() {
        let panel = AudioAppList.panelRows(
            live: allApps, settings: settings, lastPlayed: lastPlayed, now: Date(), recentWindow: recentWindow)
        if panel != rows { rows = panel }
        let saved = AudioAppList.savedRows(live: allApps, settings: settings)
        if saved != savedRows { savedRows = saved }
    }

    // MARK: Taps

    private var defaultOutputUID: String? { defaultOutputState?.uid }

    private var outputFacts: [String: AudioOutputFacts] {
        Dictionary(outputs.map {
            ($0.uid, AudioOutputFacts(
                streamCount: $0.streamCount, isMultiOutput: $0.isMultiOutput,
                stereoLeft: $0.stereoLeft, stereoRight: $0.stereoRight))
        }, uniquingKeysWith: { a, _ in a })
    }

    /// Brings the set of live taps in line with the current settings, apps,
    /// devices and permission. Safe to call at any time.
    private func reconcileTaps() {
        var wanted: [String: (app: AudioApp, plan: TapPlan)] = [:]
        // `.unknown` means TCC could not be asked; the system will prompt by itself.
        let permitted = captureAccess == .granted || captureAccess == .unknown
        if isRunning, armed, permitted {
            let facts = outputFacts
            let defaultUID = defaultOutputUID
            let now = Date()
            for app in allApps where appErrors[app.id] == nil && !app.processObjects.isEmpty {
                if let plan = AudioRouting.plan(appSettings(app.id), defaultUID: defaultUID, outputs: facts) {
                    wanted[app.id] = (app, plan)
                } else if let session = sessions[app.id], facts[session.plan.outputUID] != nil,
                          session.plan.outputUID == defaultUID,
                          lastEdit[app.id].map({ now.timeIntervalSince($0) < Self.defaultsGrace }) == true {
                    // Just returned to defaults: keep the tap at unity for a moment.
                    wanted[app.id] = (app, session.plan)
                }
            }
        }

        for (appID, session) in sessions where wanted[appID]?.plan != session.plan { dropSession(appID) }

        for (appID, want) in wanted {
            let gain = AudioMath.effectiveGain(appSettings(appID), boostLimit: boostLimit)
            let processes = want.app.processObjects
            let plan = want.plan
            if var session = sessions[appID] {
                session.tap.setGain(gain)
                guard session.processes != processes else { continue }
                session.processes = processes
                sessions[appID] = session
                let tap = session.tap
                AppTap.queue.async { [weak self] in
                    guard tap.isRunning, !tap.update(processes: processes) else { return }
                    do { try tap.start(processes: processes, plan: plan) } catch {
                        DispatchQueue.main.async { self?.tapFailed(appID, tap, error) }
                    }
                }
            } else {
                guard let tap = AppTap(label: want.app.name, gain: gain) else { continue }
                sessions[appID] = Session(tap: tap, processes: processes, plan: plan)
                AppTap.queue.async { [weak self] in
                    do { try tap.start(processes: processes, plan: plan) } catch {
                        DispatchQueue.main.async { self?.tapFailed(appID, tap, error) }
                    }
                }
            }
        }
        updateWatchdog()
    }

    private func dropSession(_ appID: String) {
        guard let session = sessions.removeValue(forKey: appID) else { return }
        let tap = session.tap
        AppTap.queue.async { tap.stop() }
    }

    private func tapFailed(_ appID: String, _ tap: AppTap, _ error: Error) {
        Log.info("per-app audio for \(appID): \(error)", "audio")
        guard sessions[appID]?.tap === tap else { return }
        sessions[appID] = nil
        updateWatchdog()
        // The app is untouched from here on (its own audio, full volume).
        // Failures are often a race with a device or process going away, so
        // try again shortly, a couple of times, before reporting it.
        let count = (failures[appID] ?? 0) + 1
        failures[appID] = count
        if count <= 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.reconcileTaps() }
        } else {
            appErrors[appID] = "Can't control this app on the current output"
        }
    }

    // MARK: Watchdog

    private func updateWatchdog() {
        if sessions.isEmpty {
            watchdog?.invalidate()
            watchdog = nil
        } else if watchdog == nil {
            let timer = Timer(timeInterval: TapWatchdog.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.watchdogTick() }
            }
            timer.tolerance = 0.3
            RunLoop.main.add(timer, forMode: .common)
            watchdog = timer
        }
    }

    /// Whether the app is sending audio that this tap should be passing on.
    private func expectsIO(_ session: Session) -> Bool {
        let captureDevice = session.plan.captureUID.flatMap { uid in outputs.first { $0.uid == uid }?.id }
        if session.plan.captureUID != nil, captureDevice == nil { return false }
        return session.processes.contains { object in
            guard CA.value(object, CA.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)) ?? 0 != 0 else {
                return false
            }
            guard let captureDevice else { return true }
            return AudioDevices.outputDevices(ofProcess: object).contains(captureDevice)
        }
    }

    private func watchdogTick() {
        for (appID, session) in sessions {
            var track = session.watch
            let action = TapWatchdog.step(&track, cycles: session.tap.cycles, expectingIO: expectsIO(session))
            sessions[appID]?.watch = track
            switch action {
            case .none:
                if session.tap.cycles > 0 { failures[appID] = nil }
            case .restart:
                Log.info("tap for \(appID) stalled; rebuilding", "audio")
                let tap = session.tap
                let processes = session.processes
                let plan = session.plan
                AppTap.queue.async { [weak self] in
                    do { try tap.start(processes: processes, plan: plan) } catch {
                        DispatchQueue.main.async { self?.tapFailed(appID, tap, error) }
                    }
                }
            case .giveUp:
                Log.info("tap for \(appID) keeps stalling; releasing the app", "audio")
                dropSession(appID)
                appErrors[appID] = "Audio stalled, so Bosun let go of this app. Change its volume to try again."
            }
        }
        updateWatchdog()
    }

    // MARK: Input level meter

    private func updateMeter() {
        let device = defaultInput
        let wanted = isRunning && settingsVisible && micStatus == .authorized && device != kAudioObjectUnknown
        if !wanted {
            guard meterTap != nil else { return }
            let tap = meterTap
            meterTap = nil
            AppTap.queue.async { tap?.stop() }
            meterTimer?.invalidate()
            meterTimer = nil
            inputMeter.isRunning = false
            inputMeter.level = 0
            return
        }
        if meterTap == nil { meterTap = InputLevelTap() }
        guard let tap = meterTap else { return }
        AppTap.queue.async {
            if tap.runningDevice != device { _ = tap.start(device: device) }
        }
        inputMeter.isRunning = true
        if meterTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let tap = self.meterTap else { return }
                    let level = AudioMath.meterFraction(peak: tap.takePeak())
                    // Fast up, slow down, like a peak meter.
                    let shown = max(level, self.inputMeter.level - 0.04)
                    if abs(shown - self.inputMeter.level) > 0.002 { self.inputMeter.level = shown }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            meterTimer = timer
        }
    }

    // MARK: Diagnostics (used by tests)

    var tappedAppIDs: [String] { sessions.keys.sorted() }
    func tapStats(_ appID: String) -> AppTap.Stats? { sessions[appID]?.tap.takeStats() }
    func tapPlan(_ appID: String) -> TapPlan? { sessions[appID]?.plan }
    var liveApps: [AudioApp] { allApps }
    var meterCycles: UInt64 { meterTap?.cycles ?? 0 }
    var watchdogRestarts: Int { sessions.values.map(\.watch.restarts).max() ?? 0 }
    #if DEBUG
    /// Stops a tap's IO behind the module's back, to exercise the watchdog.
    func debugStallTap(_ appID: String) {
        guard let tap = sessions[appID]?.tap else { return }
        AppTap.queue.sync { tap.stop() }
    }
    #endif
}
