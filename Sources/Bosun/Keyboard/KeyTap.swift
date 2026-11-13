import Carbon
import CBridge
import CoreGraphics
import Foundation
import os

/// The event tap that runs `KeyEngine` on real events. It sits at the HID
/// level, ahead of the window server's own shortcuts (Mission Control, Spaces,
/// Spotlight), so a rewritten key can trigger them; if macOS refuses that it
/// falls back to the session level. It runs on its own thread so a busy main
/// thread never delays typing.
final class KeyTap: @unchecked Sendable {
    enum Location: String { case hid = "HID", session = "session" }

    /// Marks events this tap posted itself, so they are not processed twice.
    static let marker: Int64 = 0x426F73756E   // "Bosun"

    private struct Shared {
        var config = KeyEngine.Config()
        var state = KeyEngine.State()
        var app: String?
        var paused = false
        /// Whether the real keyboard state reports a held trigger key as down
        /// (learned at its key-down); only then can a lost key-up be noticed.
        var verifiable: [UInt16: Bool] = [:]
        var handled = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let portLock = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?
    private(set) var location: Location?
    private let eventSource = CGEventSource(stateID: .hidSystemState)

    // Side effects, replaceable so the event plumbing can be checked headlessly.
    var keyIsDown: (UInt16) -> Bool = { CGEventSource.keyState(.hidSystemState, key: $0) }
    var onLaunch: (String) -> Void = { _ in }
    var onCapsLock: (_ long: Bool) -> Void = { _ in }

    var isRunning: Bool { portLock.withLockUnchecked { $0 != nil } }
    var handledCount: Int { shared.withLock { $0.handled } }

    /// New rules take effect at once; whatever was half-pressed is forgotten.
    func update(_ config: KeyEngine.Config) {
        shared.withLock {
            guard $0.config != config else { return }
            $0.config = config
            $0.state = .init()
            $0.verifiable = [:]
        }
    }

    func setFrontApp(_ bundleID: String?) { shared.withLock { $0.app = bundleID } }

    /// While paused every event passes untouched (used by the key recorder).
    func setPaused(_ paused: Bool) {
        shared.withLock {
            $0.paused = paused
            $0.state = .init()
        }
    }

    /// False when macOS refuses the tap, i.e. Accessibility is not granted.
    func start() -> Bool {
        if isRunning { return true }
        var mask: CGEventMask = 0
        for type in [CGEventType.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
                     .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp] {
            mask |= 1 << CGEventMask(type.rawValue)
        }
        var created: (CFMachPort, Location)?
        for (tap, location) in [(CGEventTapLocation.cghidEventTap, Location.hid), (.cgSessionEventTap, .session)] {
            if let port = CGEvent.tapCreate(tap: tap, place: .headInsertEventTap, options: .defaultTap,
                                            eventsOfInterest: mask, callback: keyTapCallback,
                                            userInfo: Unmanaged.passUnretained(self).toOpaque()) {
                created = (port, location)
                break
            }
        }
        guard let (port, location) = created else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        shared.withLock {
            $0.state = .init()
            $0.verifiable = [:]
        }
        portLock.withLockUnchecked { $0 = port }
        self.source = source
        self.location = location

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "bosun.keytap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        guard let port = portLock.withLockUnchecked({ port -> CFMachPort? in
            defer { port = nil }
            return port
        }) else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let runLoop {
            if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
            CFRunLoopStop(runLoop)
        }
        CFMachPortInvalidate(port)
        runLoop = nil
        source = nil
        location = nil
    }

    // MARK: Event handling

    /// Processes one event. Returns the event to let through (possibly edited
    /// in place) or nil to swallow it; anything else goes out through `post`.
    func handle(type: CGEventType, event: CGEvent, post: (CGEvent) -> Void) -> CGEvent? {
        let kind: KeyEngine.Input.Kind
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Key-ups may have been missed while disabled; start clean.
            shared.withLock {
                $0.state = .init()
                $0.verifiable = [:]
            }
            if let port = portLock.withLockUnchecked({ $0 }) { CGEvent.tapEnable(tap: port, enable: true) }
            return event
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        case .flagsChanged: kind = .flagsChanged
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: kind = .mouseDown
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: kind = .mouseUp
        default: return event
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker { return event }

        let isKey = kind == .keyDown || kind == .keyUp || kind == .flagsChanged
        let keycode = isKey ? UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)) : 0
        let flags = event.flags.rawValue
        let input = KeyEngine.Input(
            kind: kind, keycode: keycode, flags: flags,
            isRepeat: kind == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            timeMs: event.timestamp / 1_000_000, app: nil)

        let outputs: [KeyEngine.Output]? = shared.withLock { shared in
            guard !shared.paused, !(shared.config.isEmpty && shared.state.isIdle) else { return nil }
            // A hold key whose release never reached the tap (secure input,
            // tap timeout) must not keep its layer or modifiers stuck on.
            for trigger in KeyEngine.heldTriggers(config: shared.config, state: shared.state)
            where shared.verifiable[trigger] == true && !(isKey && keycode == trigger) && !keyIsDown(trigger) {
                KeyEngine.forget(trigger: trigger, config: shared.config, state: &shared.state)
            }
            var input = input
            input.app = shared.app
            let before = Set(KeyEngine.heldTriggers(config: shared.config, state: shared.state))
            let outputs = KeyEngine.process(input, config: shared.config, state: &shared.state)
            for trigger in KeyEngine.heldTriggers(config: shared.config, state: shared.state) where !before.contains(trigger) {
                shared.verifiable[trigger] = keyIsDown(trigger)
            }
            if outputs != [.original(flags: flags)] { shared.handled += 1 }
            return outputs
        }
        guard let outputs else { return event }

        // The common cases edit the event in place, which keeps everything
        // else about it (timestamp, keyboard type, repeat) genuine.
        if outputs.count == 1 {
            switch outputs[0] {
            case .original(let newFlags):
                if newFlags != flags { event.flags = CGEventFlags(rawValue: newFlags) }
                return event
            case .key(let down, let target, _, let newFlags) where (kind == .keyDown && down) || (kind == .keyUp && !down):
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(target))
                event.flags = CGEventFlags(rawValue: newFlags)
                return event
            default:
                break
            }
        }
        for output in outputs {
            switch output {
            case .original(let newFlags):
                guard let copy = event.copy() else { continue }
                copy.flags = CGEventFlags(rawValue: newFlags)
                copy.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                post(copy)
            case .key(let down, let target, let isRepeat, let newFlags):
                guard let made = CGEvent(keyboardEventSource: eventSource, virtualKey: target, keyDown: down) else { continue }
                made.flags = CGEventFlags(rawValue: newFlags)
                if isRepeat { made.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
                made.setIntegerValueField(.eventSourceUserData, value: Self.marker)
                post(made)
            case .launch(let bundleID):
                onLaunch(bundleID)
            case .capsLock(let long):
                onCapsLock(long)
            }
        }
        return nil
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
    return tap.handle(type: type, event: event) { $0.tapPostEvent(proxy) }.map { Unmanaged.passUnretained($0) }
}

/// What the Caps Lock key itself does, re-created for rules that had to take
/// the key away from the system: toggling the lock (state and keyboard light)
/// or, when macOS is set to "Use Caps Lock to switch to and from ABC",
/// switching input sources on a short press and locking on a long one.
enum CapsLock {
    static var isOn: Bool? {
        withConnection { connect in
            var state = false
            return IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS ? state : nil
        } ?? nil
    }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        withConnection { IOHIDSetModifierLockState($0, Int32(kIOHIDCapsLockState), on) == KERN_SUCCESS } ?? false
    }

    /// The system setting "Use the Caps Lock key to switch to and from ABC".
    static var switchesInputSource: Bool {
        (CFPreferencesCopyValue("TISRomanSwitchState" as CFString, kCFPreferencesAnyApplication,
                                kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? NSNumber)?.boolValue ?? false
    }

    /// The key was pressed alone; `long` if held past the rule's threshold.
    static func pressed(long: Bool) {
        if switchesInputSource {
            if long { toggle() } else { DispatchQueue.main.async { switchInputSource() } }
        } else if !long {
            toggle()
        }
    }

    static func toggle() {
        if let on = isOn { set(!on) }
    }

    private static func withConnection<T>(_ body: (io_connect_t) -> T) -> T? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return nil }
        defer { IOServiceClose(connect) }
        return body(connect)
    }

    // MARK: Input source

    nonisolated(unsafe) private static var lastOther: TISInputSource?

    private static func isLatin(_ source: TISInputSource) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }

    /// The other half of the pair {Latin layout, most recent other source}, or
    /// nil if only one kind is enabled.
    static func inputSourceToSwitchTo() -> TISInputSource? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        if isLatin(current) {
            if let lastOther { return lastOther }
            let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                          kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
            let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
            return list.first { !isLatin($0) }
        }
        lastOther = current
        return TISCopyCurrentASCIICapableKeyboardInputSource()?.takeRetainedValue()
    }

    static func switchInputSource() {
        if let target = inputSourceToSwitchTo() { TISSelectInputSource(target) }
    }
}
