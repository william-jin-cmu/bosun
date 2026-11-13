import CoreGraphics
import Foundation
import os

/// Session-level event tap that applies `KeyRewriter` to key events. It runs
/// on its own thread so a busy main thread never delays typing.
final class KeyTap: @unchecked Sendable {
    private struct Shared {
        var config = KeyRewriter.Config()
        var state = KeyRewriter.State()
        var rewritten = 0
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let portLock = OSAllocatedUnfairLock<CFMachPort?>(uncheckedState: nil)
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?

    var isRunning: Bool { portLock.withLockUnchecked { $0 != nil } }
    var rewrittenCount: Int { shared.withLock { $0.rewritten } }

    func update(_ config: KeyRewriter.Config) {
        shared.withLock { $0.config = config }
    }

    /// False when macOS refuses the tap, i.e. Accessibility is not granted.
    func start() -> Bool {
        if isRunning { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }
        shared.withLock { $0.state = .init() }
        portLock.withLockUnchecked { $0 = port }
        self.source = source

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
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Key-ups may have been missed while disabled; start clean.
            shared.withLock { $0.state = .init() }
            if let port = portLock.withLockUnchecked({ $0 }) { CGEvent.tapEnable(tap: port, enable: true) }
            return
        case .keyDown, .keyUp:
            break
        default:
            return
        }
        let keycode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let out = shared.withLock { shared -> KeyRewriter.Output in
            let out = KeyRewriter.rewrite(
                kind: type == .keyDown ? .keyDown : .keyUp, keycode: keycode, flags: flags,
                isRepeat: isRepeat, config: shared.config, state: &shared.state)
            if out.keycode != keycode { shared.rewritten += 1 }
            return out
        }
        if out.keycode != keycode { event.setIntegerValueField(.keyboardEventKeycode, value: Int64(out.keycode)) }
        if out.flags != flags { event.flags = CGEventFlags(rawValue: out.flags) }
    }
}

private func keyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                            refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if let refcon {
        Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
    }
    return Unmanaged.passUnretained(event)
}
