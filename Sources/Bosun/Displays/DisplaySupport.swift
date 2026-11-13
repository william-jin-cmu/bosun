import AppKit
import CoreAudio
import SwiftUI

// MARK: - On-screen display

/// The private protocol of `com.apple.OSDUIHelper`, the agent that draws the
/// system's brightness/volume bezel. Checked working on macOS 27.0.
@objc private protocol OSDUIHelperProtocol {
    @objc(showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:)
    func showImage(_ image: Int64, onDisplayID: UInt32, priority: UInt32, msecUntilFade: UInt32,
                   filledChiclets: UInt32, totalChiclets: UInt32, locked: Bool)
}

/// Feedback shown on the affected screen when a key changes a value.
@MainActor
final class DisplayOSD {
    enum Kind: Equatable {
        case brightness, contrast, volume, muted

        /// Image numbers understood by OSDUIHelper.
        var systemImage: Int64 {
            switch self {
            case .brightness: 1
            case .volume: 3
            case .muted: 4
            case .contrast: 0
            }
        }

        var symbol: String {
            switch self {
            case .brightness: "sun.max.fill"
            case .contrast: "circle.lefthalf.filled"
            case .volume: "speaker.wave.2.fill"
            case .muted: "speaker.slash.fill"
            }
        }
    }

    private var connection: NSXPCConnection?
    /// Set once the system helper turned out to be unreachable.
    private(set) var systemUnavailable = false
    private var hud: NSPanel?
    private var hudModel = HUDModel()
    private var hideWork: DispatchWorkItem?

    /// `value` is 0...1. `steps` is how many segments the scale has.
    func show(_ kind: Kind, value: Double, on displayID: CGDirectDisplayID, style: DisplayOSDStyle, steps: Int = 64) {
        switch style {
        case .off:
            return
        case .compact:
            showCompact(kind, value: value, on: displayID)
        case .system:
            if systemUnavailable || !showSystem(kind, value: value, on: displayID, steps: steps) {
                showCompact(kind, value: value, on: displayID)
            }
        }
    }

    func close() {
        hideWork?.cancel()
        hud?.orderOut(nil)
        hud = nil
        connection?.invalidate()
        connection = nil
    }

    private func showSystem(_ kind: Kind, value: Double, on displayID: CGDirectDisplayID, steps: Int) -> Bool {
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: "com.apple.OSDUIHelper", options: [])
            connection.remoteObjectInterface = NSXPCInterface(with: OSDUIHelperProtocol.self)
            connection.invalidationHandler = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.connection = nil } }
            }
            connection.resume()
            self.connection = connection
        }
        let proxy = connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            // No helper on this system: use our own bar from now on, and
            // show it for the request that just failed.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Log.info("system OSD unavailable (\(error.localizedDescription)), using the compact bar", "displays")
                    self.systemUnavailable = true
                    self.showCompact(kind, value: value, on: displayID)
                }
            }
        }
        guard let helper = proxy as? OSDUIHelperProtocol else { return false }
        let filled = kind == .muted ? 0 : UInt32((Swift.min(Swift.max(value, 0), 1) * Double(steps)).rounded())
        helper.showImage(kind.systemImage, onDisplayID: displayID, priority: 0x1F4, msecUntilFade: 1000,
                         filledChiclets: filled, totalChiclets: UInt32(steps), locked: false)
        return true
    }

    private func showCompact(_ kind: Kind, value: Double, on displayID: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) ?? NSScreen.main else { return }
        hudModel.kind = kind
        hudModel.value = kind == .muted ? 0 : value
        let size = NSSize(width: 240, height: 44)
        if hud == nil {
            let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .screenSaver
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: HUDView(model: hudModel))
            hud = panel
        }
        guard let hud else { return }
        let frame = screen.frame
        hud.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.12,
                            width: size.width, height: size.height), display: true)
        hud.alphaValue = 1
        hud.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let hud = self?.hud else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    hud.animator().alphaValue = 0
                }, completionHandler: { hud.orderOut(nil) })
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }
}

@MainActor
private final class HUDModel: ObservableObject {
    @Published var kind: DisplayOSD.Kind = .brightness
    @Published var value = 0.0
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: model.kind.symbol).frame(width: 22)
            ProgressView(value: model.value).progressViewStyle(.linear).tint(.primary)
            Text("\(Int((model.value * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 14)
        .frame(width: 240, height: 44)
        .background(.regularMaterial, in: Capsule())
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

// MARK: - Software dimming

/// Black, click-through overlay windows, one per dimmed screen. Used instead
/// of gamma tables, which belong to the Color Temperature module.
@MainActor
final class DisplayShades {
    private var windows: [CGDirectDisplayID: NSWindow] = [:]

    var dimmedDisplays: Set<CGDirectDisplayID> { Set(windows.keys) }

    func opacity(of displayID: CGDirectDisplayID) -> Double {
        Double(windows[displayID]?.contentView?.alphaValue ?? 0)
    }

    /// 0 removes the overlay.
    func setOpacity(_ opacity: Double, for displayID: CGDirectDisplayID) {
        let opacity = Swift.min(Swift.max(opacity, 0), BrightnessSplit.maxShadeOpacity)
        guard opacity > 0.001, let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            remove(displayID)
            return
        }
        let window = windows[displayID] ?? makeWindow()
        windows[displayID] = window
        if window.frame != screen.frame { window.setFrame(screen.frame, display: true) }
        window.contentView?.alphaValue = opacity
        window.orderFrontRegardless()
    }

    /// Follow resolution and arrangement changes; drop overlays of displays
    /// that are gone.
    func screensChanged() {
        for (displayID, window) in windows {
            if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
                window.setFrame(screen.frame, display: true)
            } else {
                remove(displayID)
            }
        }
    }

    func remove(_ displayID: CGDirectDisplayID) {
        windows.removeValue(forKey: displayID)?.orderOut(nil)
    }

    func removeAll() {
        for window in windows.values { window.orderOut(nil) }
        windows = [:]
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.sharingType = .none      // screenshots and screen sharing show the real picture
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.alphaValue = 0
        window.contentView = view
        return window
    }
}

// MARK: - Sound output

/// Watches the default sound output device. The volume keys are only taken
/// over while that device is one macOS cannot set the volume of.
@MainActor
final class SoundOutputWatcher {
    var onChange: (() -> Void)?
    private var listening = false
    private var listener: AudioObjectPropertyListenerBlock?

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)

    func start() {
        guard !listening else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange?() } }
        }
        listener = block
        listening = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                        &Self.defaultOutputAddress, DispatchQueue.main, block) == noErr
    }

    func stop() {
        guard listening, let listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutputAddress,
                                               DispatchQueue.main, listener)
        listening = false
        self.listener = nil
    }

    nonisolated static func current() -> DisplayAudioOutput? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }

        var name: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioObjectPropertyName
        let hasName = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr

        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)

        // 'vmvc': kAudioHardwareServiceDeviceProperty_VirtualMainVolume, the
        // volume the system slider and keys drive. MonitorControl uses the
        // same test.
        var volume = AudioObjectPropertyAddress(mSelector: 0x766D_7663, mScope: kAudioDevicePropertyScopeOutput,
                                                mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        let canSet = AudioObjectHasProperty(device, &volume)
            && AudioObjectIsPropertySettable(device, &volume, &settable) == noErr && settable.boolValue

        return DisplayAudioOutput(name: hasName ? (name?.takeRetainedValue() as String? ?? "") : "",
                           canSetVolume: canSet,
                           isDisplayTransport: transport == kAudioDeviceTransportTypeDisplayPort
                               || transport == kAudioDeviceTransportTypeHDMI)
    }
}
