import AppKit
import CoreAudio
import SwiftUI

/// Sound: output/input device pickers, master volume, and a volume slider per
/// app that is playing audio. No driver is installed; per-app volume uses Core
/// Audio process taps (see `AppTap`), which need the "System Audio Recording
/// Only" permission. Nothing that needs the permission happens until the user
/// first moves a per-app slider.
@MainActor
final class AudioModule: ObservableObject, BosunModule {
    let id = "audio"
    let title = "Sound"
    let symbol = "speaker.wave.2"

    @Published private(set) var outputDevices: [AudioDeviceInfo] = []
    @Published private(set) var inputDevices: [AudioDeviceInfo] = []
    @Published private(set) var defaultOutput = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var defaultInput = AudioDeviceID(kAudioObjectUnknown)
    @Published private(set) var volume: Float = 0
    @Published private(set) var isMuted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false
    /// Apps to show: playing now, played a moment ago, or with a custom volume.
    @Published private(set) var apps: [AudioApp] = []
    /// Slider positions (0…1) by app ID; absent means 100%.
    @Published private(set) var appVolumes: [String: Double] = [:]
    @Published private(set) var appErrors: [String: String] = [:]
    @Published private(set) var captureAccess: AudioCaptureAccess = .undetermined

    private enum Key {
        static let appVolumes = "audio.appVolumes"
        /// Set once the user has moved a per-app slider; before that no tap is ever created.
        static let armed = "audio.perAppArmed"
    }

    private struct Session {
        let tap: AppTap
        var processes: [AudioObjectID]
        let outputUID: String
    }

    /// How long an app's row stays after it stops playing.
    private static let rowLinger: TimeInterval = 20
    /// How long a tap is kept after its slider returns to 100%, so dragging
    /// across the top of the slider does not rebuild it repeatedly.
    private static let fullVolumeGrace: TimeInterval = 1.5

    private let defaults = UserDefaults.standard
    private var running = false
    private var armed = false
    private var requestingAccess = false
    private var systemListeners: [AudioListener] = []
    private var outputListeners: [AudioListener] = []
    private var processListeners: [AudioObjectID: AudioListener] = [:]
    private var processRefreshPending = false
    private var rowExpiry: DispatchWorkItem?
    private var allApps: [AudioApp] = []
    private var lastPlayed: [String: Date] = [:]
    private var lastEdit: [String: Date] = [:]
    private var icons: [String: NSImage] = [:]
    private var sessions: [String: Session] = [:]

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        armed = defaults.bool(forKey: Key.armed)
        let saved = defaults.dictionary(forKey: Key.appVolumes) as? [String: Double] ?? [:]
        appVolumes = saved.filter { $0.value >= 0 && $0.value < 1 }
        captureAccess = AudioCaptureAccess.current()

        func listen(_ selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor (AudioModule) -> Void) {
            let listener = AudioListener(CA.system, CA.address(selector)) { [weak self] in
                if let self, self.running { handler(self) }
            }
            if let listener { systemListeners.append(listener) }
        }
        listen(kAudioHardwarePropertyDevices) { $0.refreshDevices() }
        listen(kAudioHardwarePropertyDefaultInputDevice) { $0.refreshDevices() }
        listen(kAudioHardwarePropertyDefaultOutputDevice) { $0.outputDeviceChanged() }
        listen(kAudioHardwarePropertyProcessObjectList) { $0.scheduleProcessRefresh() }

        refreshDevices()
        bindOutputDevice()
        refreshProcesses()
    }

    func stop() {
        guard running else { return }
        running = false
        systemListeners = []
        outputListeners = []
        processListeners = [:]
        rowExpiry?.cancel()
        // Synchronous: every tap is gone, and every app back at its own
        // volume, before this returns (it also runs at app termination).
        let taps = sessions.values.map(\.tap)
        sessions = [:]
        AppTap.queue.sync { taps.forEach { $0.stop() } }
        allApps = []
        apps = []
        appErrors = [:]
        lastPlayed = [:]
    }

    func panelVisibilityChanged(_ visible: Bool) {
        guard running, visible else { return }
        // The user may have changed the permission in System Settings meanwhile.
        if !requestingAccess {
            let access = AudioCaptureAccess.current()
            if access != captureAccess {
                captureAccess = access
                appErrors = [:]
            }
        }
        refreshVolume()
        refreshProcesses()
    }

    // MARK: Devices and master volume

    func setDefaultOutput(_ device: AudioDeviceID) {
        guard device != defaultOutput else { return }
        AudioDevices.setDefault(device, .output)
    }

    func setDefaultInput(_ device: AudioDeviceID) {
        guard device != defaultInput else { return }
        AudioDevices.setDefault(device, .input)
    }

    func setVolume(_ value: Float) {
        guard canSetVolume else { return }
        let value = min(max(value, 0), 1)
        if AudioDevices.setVolume(defaultOutput, value) { volume = value }
        if isMuted, value > 0, canMute { setMuted(false) }
    }

    func setMuted(_ muted: Bool) {
        guard canMute else { return }
        if AudioDevices.setMuted(defaultOutput, muted) { isMuted = muted }
    }

    private func refreshDevices() {
        let outputs = AudioDevices.list(.output)
        let inputs = AudioDevices.list(.input)
        if outputs != outputDevices { outputDevices = outputs }
        if inputs != inputDevices { inputDevices = inputs }
        let input = AudioDevices.defaultDevice(.input) ?? AudioDeviceID(kAudioObjectUnknown)
        if input != defaultInput { defaultInput = input }
    }

    private func outputDeviceChanged() {
        bindOutputDevice()
        // Taps are tied to the output device: rebuild them all on the new one.
        appErrors = [:]
        reconcileTaps()
    }

    private func bindOutputDevice() {
        let device = AudioDevices.defaultDevice(.output) ?? AudioDeviceID(kAudioObjectUnknown)
        if device != defaultOutput { defaultOutput = device }
        outputListeners = []
        guard device != kAudioObjectUnknown else { return refreshVolume() }
        func listen(_ address: AudioObjectPropertyAddress, _ handler: @escaping @MainActor (AudioModule) -> Void) {
            let listener = AudioListener(device, address) { [weak self] in
                if let self, self.running, self.defaultOutput == device { handler(self) }
            }
            if let listener { outputListeners.append(listener) }
        }
        listen(AudioDevices.volumeSelector) { $0.refreshVolume() }
        listen(AudioDevices.muteSelector) { $0.refreshVolume() }
        listen(CA.address(kAudioDevicePropertyNominalSampleRate)) { $0.rebuildTaps() }
        refreshVolume()
    }

    private func refreshVolume() {
        let device = defaultOutput
        let settable = device != kAudioObjectUnknown && AudioDevices.canSetVolume(device)
        let level = device != kAudioObjectUnknown ? AudioDevices.volume(device) ?? 0 : 0
        let mutable = device != kAudioObjectUnknown && AudioDevices.canMute(device)
        let muted = device != kAudioObjectUnknown ? AudioDevices.isMuted(device) ?? false : false
        if settable != canSetVolume { canSetVolume = settable }
        if level != volume { volume = level }
        if mutable != canMute { canMute = mutable }
        if muted != isMuted { isMuted = muted }
    }

    // MARK: Apps

    func appVolume(_ appID: String) -> Double { appVolumes[appID] ?? 1 }

    func icon(for app: AudioApp) -> NSImage? {
        if let icon = icons[app.id] { return icon }
        let icon = AudioProcesses.icon(for: app)
        icons[app.id] = icon
        return icon
    }

    /// Whether per-app sliders can do anything.
    var perAppAvailable: Bool { captureAccess != .denied }

    func setAppVolume(_ appID: String, _ value: Double) {
        guard running, perAppAvailable else { return }
        let value = value >= 0.995 ? 1 : max(value, 0)
        guard value != appVolume(appID) else { return }
        if value < 1 { appVolumes[appID] = value } else { appVolumes[appID] = nil }
        defaults.set(appVolumes, forKey: Key.appVolumes)
        lastEdit[appID] = Date()
        appErrors[appID] = nil

        if value < 1 {
            if !armed {
                armed = true
                defaults.set(true, forKey: Key.armed)
            }
            if captureAccess == .undetermined, !requestingAccess {
                requestingAccess = true
                AudioCaptureAccess.request { [weak self] result in
                    guard let self else { return }
                    self.requestingAccess = false
                    self.captureAccess = result
                    self.reconcileTaps()
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fullVolumeGrace + 0.1) { [weak self] in
                self?.reconcileTaps()
            }
        }
        reconcileTaps()
    }

    func openCaptureSettings() {
        NSWorkspace.shared.open(AudioCaptureAccess.settingsURL)
    }

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
        guard running else { return }
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
        lastPlayed = lastPlayed.filter { now.timeIntervalSince($0.value) < Self.rowLinger }
        let visible = allApps.filter { $0.isPlaying || lastPlayed[$0.id] != nil || appVolume($0.id) < 1 }
        if visible != apps { apps = visible }
        let present = Set(allApps.map(\.id))
        icons = icons.filter { present.contains($0.key) }

        // One-shot timer to drop rows whose linger runs out; no polling.
        rowExpiry?.cancel()
        let playing = Set(allApps.filter(\.isPlaying).map(\.id))
        if let earliest = lastPlayed.filter({ !playing.contains($0.key) }).values.min() {
            let work = DispatchWorkItem { [weak self] in self?.refreshProcesses() }
            rowExpiry = work
            let delay = max(0.1, Self.rowLinger - now.timeIntervalSince(earliest) + 0.05)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
        reconcileTaps()
    }

    // MARK: Taps

    /// Brings the set of live taps in line with the current volumes, apps,
    /// output device and permission. Safe to call at any time.
    private func reconcileTaps() {
        var wanted: [String: AudioApp] = [:]
        // `.unknown` means TCC could not be asked; the system will prompt by itself.
        let permitted = captureAccess == .granted || captureAccess == .unknown
        let outputUID = defaultOutput != kAudioObjectUnknown ? AudioDevices.uid(defaultOutput) : nil
        if running, armed, permitted, outputUID != nil {
            let now = Date()
            for app in allApps where appErrors[app.id] == nil && !app.processObjects.isEmpty {
                let inGrace = sessions[app.id] != nil
                    && lastEdit[app.id].map { now.timeIntervalSince($0) < Self.fullVolumeGrace } == true
                if appVolume(app.id) < 1 || inGrace { wanted[app.id] = app }
            }
        }

        for (appID, session) in sessions where wanted[appID] == nil || session.outputUID != outputUID {
            sessions[appID] = nil
            let tap = session.tap
            AppTap.queue.async { tap.stop() }
        }

        guard let outputUID else { return }
        for (appID, app) in wanted {
            let gain = AudioMath.gain(forSlider: appVolume(appID))
            if var session = sessions[appID] {
                session.tap.setGain(gain)
                guard session.processes != app.processObjects else { continue }
                session.processes = app.processObjects
                sessions[appID] = session
                let tap = session.tap
                let processes = app.processObjects
                AppTap.queue.async { [weak self] in
                    guard tap.isRunning, !tap.update(processes: processes) else { return }
                    do { try tap.start(processes: processes, outputUID: outputUID) } catch {
                        DispatchQueue.main.async { self?.tapFailed(appID, tap, error) }
                    }
                }
            } else {
                guard let tap = AppTap(label: app.name, gain: gain) else { continue }
                sessions[appID] = Session(tap: tap, processes: app.processObjects, outputUID: outputUID)
                let processes = app.processObjects
                AppTap.queue.async { [weak self] in
                    do { try tap.start(processes: processes, outputUID: outputUID) } catch {
                        DispatchQueue.main.async { self?.tapFailed(appID, tap, error) }
                    }
                }
            }
        }
    }

    private func rebuildTaps() {
        let taps = sessions.values.map(\.tap)
        sessions = [:]
        AppTap.queue.async { taps.forEach { $0.stop() } }
        reconcileTaps()
    }

    private func tapFailed(_ appID: String, _ tap: AppTap, _ error: Error) {
        Log.info("per-app volume for \(appID): \(error)", "audio")
        guard sessions[appID]?.tap === tap else { return }
        sessions[appID] = nil
        appErrors[appID] = "Can't control this app on the current output"
    }

    /// For diagnostics and tests: app IDs with a live tap.
    var tappedAppIDs: [String] { sessions.keys.sorted() }
    func tapStats(_ appID: String) -> (cycles: UInt64, inputPeak: Float, outputPeak: Float)? {
        sessions[appID]?.tap.takeStats()
    }
}
