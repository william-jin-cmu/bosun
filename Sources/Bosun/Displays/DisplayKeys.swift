import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Session event tap for the brightness and volume keys. Independent of the
/// Keyboard module's remapping tap.
///
/// The tap runs on its own thread and decides there, from an immutable policy
/// snapshot, whether a key is ours. It never waits for the main thread, so a
/// busy UI cannot stall typing. Accepted keys are handed to `onKey`.
final class DisplayKeyTap: @unchecked Sendable {
    struct Policy {
        var config = DisplayKeyRouting.Config()
        var displays: [DisplayKeyRouting.Display] = []
        var output: DisplayAudioOutput?
    }

    /// Undocumented but stable CGEvent fields of "system defined" events
    /// (the values NSEvent exposes as `subtype` and `data1`). A self-check
    /// verifies them against NSEvent on every `--selftest`.
    static let subtypeField = CGEventField(rawValue: 83)!
    static let data1Field = CGEventField(rawValue: 149)!
    static let systemDefinedType = CGEventType(rawValue: 14)!

    /// Called on the tap thread for key-down events we accepted.
    var onKey: (@Sendable (_ action: DisplayKeyAction, _ fine: Bool, _ targets: [CGDirectDisplayID], _ isRepeat: Bool) -> Void)?

    private let lock = NSLock()
    private var policy = Policy()
    private var port: CFMachPort?
    private var runLoop: CFRunLoop?

    var isRunning: Bool { port != nil }

    func update(_ policy: Policy) {
        lock.lock()
        self.policy = policy
        lock.unlock()
    }

    /// False when the tap cannot be created (no Accessibility permission).
    func start() -> Bool {
        guard port == nil else { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue | CGEventMask(1) << Self.systemDefinedType.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<DisplayKeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: callback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(runLoop, source, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "bosun.displays.keys"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.port = nil
        runLoop = nil
    }

    /// True when the event should be swallowed.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        lock.lock()
        let policy = self.policy
        lock.unlock()

        guard let key = Self.decode(type: type, event: event, alternateBrightnessKeys: policy.config.alternateBrightnessKeys) else {
            return false
        }
        var env = DisplayKeyRouting.Environment(displays: policy.displays, output: policy.output)
        env.pointerDisplay = Self.display(at: event.location)
        if key.key.isBrightness, policy.config.brightnessTarget == .focus { env.focusDisplay = Self.focusedDisplay() }

        let decision = DisplayKeyRouting.decide(key: key.key, modifiers: DisplayKeyModifiers(cgFlags: event.flags),
                                         config: policy.config, env: env)
        guard case let .handle(action, fine, targets, swallow) = decision else { return false }
        // Key-up is swallowed along with its key-down but triggers nothing.
        if key.isDown { onKey?(action, fine, targets, key.isRepeat) }
        return swallow
    }

    /// Recognises a brightness or volume key in a tapped event.
    static func decode(type: CGEventType, event: CGEvent, alternateBrightnessKeys: Bool) -> (key: DisplayMediaKey, isDown: Bool, isRepeat: Bool)? {
        if type == .keyDown {
            let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
            guard let key = DisplayKeyDecode.mediaKey(keyCode: keyCode, alternateBrightnessKeys: alternateBrightnessKeys) else { return nil }
            return (key, true, event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        }
        guard type == systemDefinedType else { return nil }
        return DisplayKeyDecode.mediaKey(subtype: Int(event.getIntegerValueField(subtypeField)),
                                  data1: Int(event.getIntegerValueField(data1Field)))
    }

    /// `point` is in global display coordinates (origin top-left).
    static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id = CGDirectDisplayID()
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    /// The display holding the frontmost application's front window. Uses the
    /// window server's list, which is safe to query off the main thread.
    static func focusedDisplay() -> CGDirectDisplayID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                  (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary), bounds.width > 40, bounds.height > 40 else { continue }
            return display(at: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        return nil
    }
}

/// Global hot keys for the user-recorded shortcuts. Carbon hot keys need no
/// Accessibility permission, so these work even when the event tap cannot.
@MainActor
final class DisplayHotKeys {
    var onAction: ((_ action: DisplayKeyAction, _ isRepeat: Bool) -> Void)?

    private var registered: [UInt32: (action: DisplayKeyAction, ref: EventHotKeyRef)] = [:]
    private var handler: EventHandlerRef?
    private var repeatTimer: Timer?
    private static let signature: OSType = 0x4273_6E44      // 'BsnD'

    /// Replaces all registrations. Returns the actions whose shortcut the
    /// system refused (usually because another app owns it).
    @discardableResult
    func register(_ shortcuts: [DisplayKeyAction: DisplayShortcut]) -> Set<DisplayKeyAction> {
        unregisterAll()
        guard !shortcuts.isEmpty else { return [] }
        installHandler()
        var failed = Set<DisplayKeyAction>()
        var nextID: UInt32 = 1
        for (action, shortcut) in shortcuts.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: nextID)
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[nextID] = (action, ref)
            } else {
                failed.insert(action)
            }
            nextID += 1
        }
        return failed
    }

    func unregisterAll() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
        registered = [:]
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    nonisolated static func carbonModifiers(_ modifiers: DisplayKeyModifiers) -> UInt32 {
        var value = 0
        if modifiers.contains(.command) { value |= cmdKey }
        if modifiers.contains(.shift) { value |= shiftKey }
        if modifiers.contains(.option) { value |= optionKey }
        if modifiers.contains(.control) { value |= controlKey }
        return UInt32(value)
    }

    private func installHandler() {
        guard handler == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let center = Unmanaged<DisplayHotKeys>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hot keys on the main thread's event loop.
            MainActor.assumeIsolated { center.hotKey(id.id, pressed: pressed) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, specs.count, &specs,
                            Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    private func hotKey(_ id: UInt32, pressed: Bool) {
        repeatTimer?.invalidate()
        repeatTimer = nil
        guard pressed, let action = registered[id]?.action else { return }
        onAction?(action, false)
        guard action != .muteToggle else { return }
        // Hot keys do not auto-repeat; do it ourselves while the key is held.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.onAction?(action, true) }
                }
            }
        }
    }
}

/// Names for keys that have no printable character.
enum DisplayKeyNames {
    static func label(keyCode: Int, characters: String?) -> String {
        if let special = special[keyCode] { return special }
        let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return text.isEmpty ? "Key \(keyCode)" : text
    }

    private static let special: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Home: "Home", kVK_End: "End",
        kVK_PageUp: "Page Up", kVK_PageDown: "Page Down", kVK_ForwardDelete: "⌦",
        kVK_ANSI_KeypadPlus: "Keypad +", kVK_ANSI_KeypadMinus: "Keypad −",
    ]
}
