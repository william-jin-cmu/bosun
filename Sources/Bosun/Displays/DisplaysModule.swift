import AppKit
import SwiftUI

/// One connected display as shown in the panel.
struct DisplayState: Identifiable, Equatable {
    enum Control: Equatable {
        /// Apple panel driven through DisplayServices.
        case native
        /// External display driven over DDC/CI.
        case ddc
        /// Nothing answered.
        case none
    }

    let id: CGDirectDisplayID
    var name: String
    var isBuiltIn: Bool
    var control: Control = .none
    /// 0...1.
    var brightness: Double = 0
    /// 0...1, nil when the display has no DDC volume control.
    var volume: Double?
    /// Nil when the display has no DDC mute control.
    var muted: Bool?

    fileprivate var brightnessMax: UInt16 = 100
    fileprivate var volumeMax: UInt16 = 100
}

/// Serial worker for all I2C traffic. Slider writes are coalesced per
/// display and control: while one write is queued or running, newer values
/// just replace the pending one.
private final class DDCWorker: @unchecked Sendable {
    struct Key: Hashable {
        let display: CGDirectDisplayID
        let vcp: UInt8
    }

    let queue = DispatchQueue(label: "bosun.displays.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var pending: [Key: UInt16] = [:]

    func write(_ service: DDC.Service, display: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        let key = Key(display: display, vcp: vcp)
        lock.lock()
        let alreadyQueued = pending[key] != nil
        pending[key] = value
        lock.unlock()
        guard !alreadyQueued else { return }
        queue.async { [self] in
            lock.lock()
            let latest = pending.removeValue(forKey: key)
            lock.unlock()
            guard let latest else { return }
            if !DDC.write(service, vcp: vcp, value: latest) {
                Log.info("write of VCP 0x\(String(vcp, radix: 16)) to display \(display) failed", "displays")
            }
        }
    }
}

@MainActor
final class DisplaysModule: ObservableObject, BosunModule {
    let id = "displays"
    let title = "Displays"
    let symbol = "display"

    @Published private(set) var displays: [DisplayState] = []

    private let worker = DDCWorker()
    private var services: [CGDirectDisplayID: DDC.Service] = [:]
    private var lastEdit: [CGDirectDisplayID: Date] = [:]
    /// Displays that report a mute state but ignore writes to it.
    private var muteIgnored: Set<CGDirectDisplayID> = []
    private var refreshGeneration = 0
    private var running = false
    private var screenObserver: NSObjectProtocol?
    private var nativePoll: Timer?

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    func stop() {
        running = false
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        nativePoll?.invalidate()
        nativePoll = nil
        refreshGeneration += 1      // drop any refresh still in flight
        services = [:]
        muteIgnored = []
        displays = []
    }

    func panelVisibilityChanged(_ visible: Bool) {
        nativePoll?.invalidate()
        nativePoll = nil
        guard running, visible else { return }
        refresh()
        // The built-in panel also changes behind our back (keyboard keys,
        // ambient light); reading it is a cheap local call, unlike DDC.
        nativePoll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollNative() }
        }
    }

    // MARK: Reading

    /// Re-enumerates displays and reads every value, off the main thread.
    func refresh() {
        guard running else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        let started = Date()
        let names = Self.screenNames()
        worker.queue.async { [weak self] in
            let snapshot = DisplaysModule.readAll(names: names)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.apply(snapshot, generation: generation, started: started) }
            }
        }
    }

    private func apply(_ snapshot: Snapshot, generation: Int, started: Date) {
        guard running, generation == refreshGeneration else { return }
        services = snapshot.services
        var fresh = snapshot.displays
        for index in fresh.indices {
            if muteIgnored.contains(fresh[index].id) { fresh[index].muted = nil }
            // Keep what the user set while this read was in flight.
            guard let edited = lastEdit[fresh[index].id], edited > started,
                  let current = displays.first(where: { $0.id == fresh[index].id }),
                  current.control == fresh[index].control else { continue }
            fresh[index].brightness = current.brightness
            fresh[index].volume = current.volume
            fresh[index].muted = current.muted
        }
        if fresh != displays { displays = fresh }
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
        var displays: [DisplayState]
        var services: [CGDirectDisplayID: DDC.Service]
    }

    /// Blocking: ~90 ms per DDC value read, up to ~0.5 s for a display that
    /// does not answer.
    nonisolated static func readAll(names: [CGDirectDisplayID: String] = [:]) -> Snapshot {
        let ids = activeDisplayIDs()
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        let services = external.isEmpty ? [:] : DDC.match(displays: external, services: DDC.externalServices())

        var states: [DisplayState] = []
        for id in ids {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            var state = DisplayState(id: id, name: names[id] ?? fallbackName(id, builtIn: builtIn), isBuiltIn: builtIn)
            if builtIn, let value = NativeBrightness.get(id) {
                state.control = .native
                state.brightness = value
            } else if let service = services[id], let brightness = DDC.read(service, vcp: DDC.VCP.brightness), brightness.max > 0 {
                state.control = .ddc
                state.brightnessMax = brightness.max
                state.brightness = fraction(brightness.current, of: brightness.max)
                if let volume = DDC.read(service, vcp: DDC.VCP.volume), volume.max > 0 {
                    state.volumeMax = volume.max
                    state.volume = fraction(volume.current, of: volume.max)
                    if let mute = DDC.read(service, vcp: DDC.VCP.mute) {
                        state.muted = mute.current == DDC.Mute.on
                    }
                }
            } else if !builtIn, let value = NativeBrightness.get(id) {
                // Apple external displays answer DisplayServices, not DDC.
                state.control = .native
                state.brightness = value
            }
            states.append(state)
        }
        // Built-in first, then by display ID, so rows do not jump around.
        states.sort { ($0.isBuiltIn ? 0 : 1, $0.id) < ($1.isBuiltIn ? 0 : 1, $1.id) }
        return Snapshot(displays: states, services: services)
    }

    nonisolated static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        // A mirrored set shows up once, as its primary display.
        return Array(ids.prefix(Int(count)))
    }

    nonisolated static func fallbackName(_ id: CGDirectDisplayID, builtIn: Bool) -> String {
        if builtIn { return "Built-in Display" }
        let name = DDC.identity(of: id).name
        return name.isEmpty ? "Display \(id)" : name
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }

    private nonisolated static func fraction(_ value: UInt16, of max: UInt16) -> Double {
        Swift.min(1, Double(value) / Double(max))
    }

    // MARK: Writing

    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }) else { return }
        let value = Swift.min(Swift.max(value, 0), 1)
        displays[index].brightness = value
        lastEdit[displayID] = Date()
        switch displays[index].control {
        case .native:
            NativeBrightness.set(displayID, value)
        case .ddc:
            send(DDC.VCP.brightness, UInt16((value * Double(displays[index].brightnessMax)).rounded()), to: displayID)
        case .none:
            break
        }
    }

    func setVolume(_ value: Double, for displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }), displays[index].volume != nil else { return }
        let value = Swift.min(Swift.max(value, 0), 1)
        displays[index].volume = value
        lastEdit[displayID] = Date()
        send(DDC.VCP.volume, UInt16((value * Double(displays[index].volumeMax)).rounded()), to: displayID)
    }

    func setMuted(_ muted: Bool, for displayID: CGDirectDisplayID) {
        guard let index = displays.firstIndex(where: { $0.id == displayID }), displays[index].muted != nil else { return }
        displays[index].muted = muted
        lastEdit[displayID] = Date()
        guard let service = services[displayID] else { return }
        // Some displays answer reads of the mute feature but ignore writes.
        // Check that the toggle took; if not, stop offering it.
        let wanted = muted ? DDC.Mute.on : DDC.Mute.off
        worker.queue.async { [weak self] in
            DDC.write(service, vcp: DDC.VCP.mute, value: wanted)
            usleep(100_000)
            guard let seen = DDC.read(service, vcp: DDC.VCP.mute), seen.current != wanted else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.muteWasIgnored(by: displayID) }
            }
        }
    }

    private func muteWasIgnored(by displayID: CGDirectDisplayID) {
        guard running else { return }
        Log.info("display \(displayID) ignores DDC mute, hiding the control", "displays")
        muteIgnored.insert(displayID)
        if let index = displays.firstIndex(where: { $0.id == displayID }) { displays[index].muted = nil }
    }

    private func send(_ vcp: UInt8, _ value: UInt16, to displayID: CGDirectDisplayID) {
        guard let service = services[displayID] else { return }
        worker.write(service, display: displayID, vcp: vcp, value: value)
    }
}
