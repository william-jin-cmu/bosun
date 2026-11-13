import CoreGraphics
import Foundation

// Decision logic of the Displays module, kept free of hardware, AppKit and
// global state so `DisplaysChecks` can exercise it headlessly.

/// A per-display control that maps a 0...1 value onto a DDC feature.
enum DisplayControl: String, Codable, CaseIterable {
    case brightness, contrast, volume

    var vcp: UInt8 {
        switch self {
        case .brightness: DDC.VCP.brightness
        case .contrast: DDC.VCP.contrast
        case .volume: DDC.VCP.volume
        }
    }

    var label: String {
        switch self {
        case .brightness: "Brightness"
        case .contrast: "Contrast"
        case .volume: "Volume"
        }
    }
}

/// What a key press asks for.
enum DisplayKeyAction: String, Codable, CaseIterable {
    case brightnessUp, brightnessDown, contrastUp, contrastDown, volumeUp, volumeDown, muteToggle

    var control: DisplayControl {
        switch self {
        case .brightnessUp, .brightnessDown: .brightness
        case .contrastUp, .contrastDown: .contrast
        case .volumeUp, .volumeDown, .muteToggle: .volume
        }
    }

    var isUp: Bool { self == .brightnessUp || self == .contrastUp || self == .volumeUp }

    var label: String {
        switch self {
        case .brightnessUp: "Brightness up"
        case .brightnessDown: "Brightness down"
        case .contrastUp: "Contrast up"
        case .contrastDown: "Contrast down"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .muteToggle: "Mute"
        }
    }
}

// MARK: - Steps

enum DisplayStepMath {
    /// Moves to the next grid line in the given direction, the way the macOS
    /// brightness keys do: a value sitting between two lines snaps to the line
    /// ahead, unless that line is less than a quarter step away, in which case
    /// it goes one further so every press is a visible change.
    static func next(_ current: Double, up: Bool, step: Double) -> Double {
        guard step > 0 else { return current }
        let position = Swift.min(Swift.max(current, 0), 1) / step
        let nearest = position.rounded()
        var line: Double
        if abs(position - nearest) < 1e-6 {
            line = nearest + (up ? 1 : -1)
        } else {
            let fraction = position - position.rounded(.down)
            line = up ? position.rounded(.up) : position.rounded(.down)
            if up, fraction > 0.75 { line += 1 }
            if !up, fraction < 0.25 { line -= 1 }
        }
        return Swift.min(1, Swift.max(0, line * step))
    }

    /// ⌥⇧ divides the step by four, like macOS.
    static func step(base: Double, fine: Bool) -> Double { fine ? base / 4 : base }
}

// MARK: - DDC value scaling

/// The raw DDC values a control may take: what the display reports, narrowed
/// by the user's optional min/max clamps.
struct DDCRange: Equatable {
    var min: UInt16
    var max: UInt16

    init(deviceMax: UInt16, clampMin: Int? = nil, clampMax: Int? = nil) {
        let top = Swift.max(1, Int(deviceMax))
        var high = Swift.min(top, Swift.max(1, clampMax ?? top))
        var low = Swift.min(Swift.max(0, clampMin ?? 0), top)
        if low >= high { low = 0; high = top }      // nonsense clamps are ignored
        min = UInt16(low)
        max = UInt16(high)
    }

    func raw(for fraction: Double) -> UInt16 {
        let clamped = Swift.min(Swift.max(fraction, 0), 1)
        return UInt16((Double(min) + clamped * Double(max - min)).rounded())
    }

    func fraction(for raw: UInt16) -> Double {
        let clamped = Swift.min(Swift.max(raw, min), max)
        return Double(clamped - min) / Double(max - min)
    }
}

// MARK: - Software dimming

/// How a display's brightness value is split between the backlight (DDC) and
/// a black overlay window on that screen.
enum DisplayDimMode: String, Codable, CaseIterable {
    /// Backlight only.
    case off
    /// The lowest part of the scale darkens the picture once the backlight is
    /// at its minimum.
    case belowMinimum
    /// No backlight control; the whole scale is the overlay.
    case softwareOnly
}

enum BrightnessSplit {
    /// The share of the scale handled by the overlay in `.belowMinimum`.
    static let softwareShare = 0.25
    /// The overlay never goes fully black, so the screen stays readable.
    static let maxShadeOpacity = 0.8

    /// `hardware` is the backlight level 0...1 (nil: leave it alone), `shade`
    /// the overlay opacity.
    static func split(_ value: Double, mode: DisplayDimMode) -> (hardware: Double?, shade: Double) {
        let value = Swift.min(Swift.max(value, 0), 1)
        switch mode {
        case .off:
            return (value, 0)
        case .belowMinimum:
            if value >= softwareShare { return ((value - softwareShare) / (1 - softwareShare), 0) }
            return (0, (1 - value / softwareShare) * maxShadeOpacity)
        case .softwareOnly:
            return (nil, (1 - value) * maxShadeOpacity)
        }
    }

    /// The inverse, used after reading the backlight level from the display.
    /// The overlay part cannot be read back, so `remembered` (the last value
    /// we set) supplies it while the backlight sits at its minimum.
    static func combine(hardware: Double?, remembered: Double?, mode: DisplayDimMode) -> Double {
        switch mode {
        case .off:
            return hardware ?? remembered ?? 1
        case .belowMinimum:
            guard let hardware else { return remembered ?? 1 }
            if hardware > 0.0001 { return softwareShare + hardware * (1 - softwareShare) }
            return Swift.min(remembered ?? softwareShare, softwareShare)
        case .softwareOnly:
            return remembered ?? 1
        }
    }
}

// MARK: - Sync

enum DisplaySyncMath {
    /// External brightness for a given built-in brightness.
    static func target(source: Double, offset: Double) -> Double {
        Swift.min(1, Swift.max(0, source + offset))
    }

    /// Ignore jitter below half a percent.
    static func changed(from last: Double?, to now: Double) -> Bool {
        guard let last else { return true }
        return abs(now - last) >= 0.005
    }
}

// MARK: - Mute

/// Whether a display's own mute feature (VCP 0x8D) can be used.
enum DisplayMuteSupport: String, Codable {
    /// Not tried yet.
    case unknown
    /// A write was read back changed.
    case hardware
    /// The display has no mute feature or ignores writes to it; mute by
    /// setting the volume to zero and restoring it afterwards.
    case fallback
}

/// State of the volume-zero mute fallback.
struct DisplaySoftMute: Codable, Equatable {
    var muted = false
    /// Volume (0...1) to return to on unmute.
    var savedVolume: Double = 0
}

enum DisplayMuteLogic {
    /// One audible step, used when unmuting would otherwise restore silence.
    static let minimumRestoredVolume = 1.0 / 16

    /// Toggles the fallback mute. Returns the new state and the volume to
    /// send to the display.
    static func toggle(_ state: DisplaySoftMute, volume: Double) -> (state: DisplaySoftMute, volume: Double) {
        if state.muted {
            let restored = state.savedVolume > 0 ? state.savedVolume : minimumRestoredVolume
            return (DisplaySoftMute(muted: false, savedVolume: 0), restored)
        }
        return (DisplaySoftMute(muted: true, savedVolume: volume), 0)
    }

    /// The user moved the volume while muted: any audible value unmutes.
    static func volumeSet(_ state: DisplaySoftMute, to volume: Double) -> DisplaySoftMute {
        state.muted && volume > 0 ? DisplaySoftMute() : state
    }

    /// The display reports a volume. If it is audible while we believe we
    /// muted it, something else (its own buttons, another app) unmuted it.
    static func reconcile(_ state: DisplaySoftMute, hardwareVolume: Double) -> DisplaySoftMute {
        state.muted && hardwareVolume > 0 ? DisplaySoftMute() : state
    }

    /// Interprets a probe: we wrote `wrote` (different from `before`) to the
    /// mute feature and then read `after`.
    static func probe(before: UInt16?, wrote: UInt16, after: UInt16?) -> DisplayMuteSupport {
        guard let before, let after, wrote != before else { return .fallback }
        return after == wrote ? .hardware : .fallback
    }
}

// MARK: - Keys

/// The hardware keys the module can take over.
enum DisplayMediaKey: Equatable {
    case brightnessUp, brightnessDown, volumeUp, volumeDown, mute

    var isBrightness: Bool { self == .brightnessUp || self == .brightnessDown }
}

struct DisplayKeyModifiers: OptionSet, Hashable, Codable {
    let rawValue: Int
    static let shift = DisplayKeyModifiers(rawValue: 1)
    static let control = DisplayKeyModifiers(rawValue: 2)
    static let option = DisplayKeyModifiers(rawValue: 4)
    static let command = DisplayKeyModifiers(rawValue: 8)

    init(rawValue: Int) { self.rawValue = rawValue }

    init(cgFlags: CGEventFlags) {
        var value: DisplayKeyModifiers = []
        if cgFlags.contains(.maskShift) { value.insert(.shift) }
        if cgFlags.contains(.maskControl) { value.insert(.control) }
        if cgFlags.contains(.maskAlternate) { value.insert(.option) }
        if cgFlags.contains(.maskCommand) { value.insert(.command) }
        self = value
    }

    var symbols: String {
        (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "")
            + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
    }
}

enum DisplayKeyDecode {
    /// Media keys arrive as "system defined" events of subtype 8 whose data1
    /// packs the key type, the up/down state and a repeat flag.
    static func mediaKey(subtype: Int, data1: Int) -> (key: DisplayMediaKey, isDown: Bool, isRepeat: Bool)? {
        guard subtype == 8 else { return nil }
        let keyType = (data1 & 0xFFFF_0000) >> 16
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8       // 0x0A down, 0x0B up
        guard state == 0x0A || state == 0x0B else { return nil }
        let key: DisplayMediaKey
        switch keyType {
        case 0: key = .volumeUp          // NX_KEYTYPE_SOUND_UP
        case 1: key = .volumeDown        // NX_KEYTYPE_SOUND_DOWN
        case 2: key = .brightnessUp      // NX_KEYTYPE_BRIGHTNESS_UP
        case 3: key = .brightnessDown    // NX_KEYTYPE_BRIGHTNESS_DOWN
        case 7: key = .mute              // NX_KEYTYPE_MUTE
        default: return nil
        }
        return (key, state == 0x0A, flags & 1 == 1)
    }

    /// Brightness keys that arrive as ordinary key-down events.
    static func mediaKey(keyCode: Int, alternateBrightnessKeys: Bool) -> DisplayMediaKey? {
        switch keyCode {
        case 144: .brightnessUp                                   // built-in keyboard brightness keys
        case 145: .brightnessDown
        case 113: alternateBrightnessKeys ? .brightnessUp : nil   // F15
        case 107: alternateBrightnessKeys ? .brightnessDown : nil // F14
        default: nil
        }
    }
}

/// Which display(s) the keys act on.
enum DisplayKeyTarget: String, Codable, CaseIterable, Identifiable {
    case pointer, focus, all, chosen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .pointer: "Display under the pointer"
        case .focus: "Display with the focused window"
        case .all: "All displays"
        case .chosen: "One display"
        }
    }
}

/// Which display(s) the volume keys act on.
enum DisplayVolumeTarget: String, Codable, CaseIterable, Identifiable {
    case output, pointer, all, chosen
    var id: String { rawValue }
    var label: String {
        switch self {
        case .output: "Display playing the sound"
        case .pointer: "Display under the pointer"
        case .all: "All displays"
        case .chosen: "One display"
        }
    }
}

/// The current default sound output, as far as key routing cares.
struct DisplayAudioOutput: Equatable {
    var name: String
    /// macOS can set this device's volume itself.
    var canSetVolume: Bool
    /// The device is reached over DisplayPort or HDMI.
    var isDisplayTransport: Bool
}

enum DisplayKeyRouting {
    struct Display: Equatable {
        var id: CGDirectDisplayID
        /// Stable identity used in settings.
        var key: String
        var name: String
        var isBuiltIn: Bool
        /// Controls we can drive on this display (for the built-in display,
        /// brightness through macOS).
        var controls: Set<DisplayControl>
    }

    struct Config: Equatable {
        var brightnessKeys = false
        var volumeKeys = false
        var alternateBrightnessKeys = true
        var brightnessTarget: DisplayKeyTarget = .pointer
        var brightnessChosen: String?
        var volumeTarget: DisplayVolumeTarget = .output
        var volumeChosen: String?
        /// Take the volume keys even when macOS could set the output volume.
        var volumeAlways = false
    }

    struct Environment: Equatable {
        var displays: [Display] = []
        var pointerDisplay: CGDirectDisplayID?
        var focusDisplay: CGDirectDisplayID?
        var output: DisplayAudioOutput?
    }

    enum Decision: Equatable {
        /// Not ours: macOS handles the key as usual.
        case passThrough
        /// Apply `action` to `targets`. With `swallow` false the event also
        /// continues to macOS, which then adjusts the built-in display itself.
        case handle(action: DisplayKeyAction, fine: Bool, targets: [CGDirectDisplayID], swallow: Bool)
    }

    /// Same normalisation MonitorControl uses to compare a display name with
    /// an audio device name ("DELL U2720Q (2)" vs "DELL U2720Q").
    static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { !"() 0123456789".contains($0) }
    }

    static func candidates(_ mode: DisplayKeyTarget, chosen: String?, _ env: Environment) -> [Display] {
        switch mode {
        case .all:
            return env.displays
        case .focus:
            return env.displays.filter { $0.id == env.focusDisplay }
        case .chosen:
            let match = env.displays.filter { $0.key == chosen }
            // The chosen display is not connected: behave like the default.
            return match.isEmpty ? env.displays.filter { $0.id == env.pointerDisplay } : match
        case .pointer:
            return env.displays.filter { $0.id == env.pointerDisplay }
        }
    }

    /// Displays the volume keys should drive, or none when they should be
    /// left to macOS.
    static func volumeTargets(_ config: Config, _ env: Environment) -> [Display] {
        let capable = env.displays.filter { $0.controls.contains(.volume) }
        guard !capable.isEmpty else { return [] }
        if !config.volumeAlways {
            // macOS cannot set the volume of a monitor's own audio device;
            // every other output keeps the normal volume keys.
            guard let output = env.output, !output.canSetVolume else { return [] }
        }
        switch config.volumeTarget {
        case .all:
            return capable
        case .pointer:
            return capable.filter { $0.id == env.pointerDisplay }
        case .chosen:
            let match = capable.filter { $0.key == config.volumeChosen }
            return match.isEmpty ? capable.filter { $0.id == env.pointerDisplay } : match
        case .output:
            guard let output = env.output else { return [] }
            let named = capable.filter { normalizedName($0.name) == normalizedName(output.name) }
            if !named.isEmpty { return named }
            // A display-audio device whose name matches no display.
            guard output.isDisplayTransport else { return [] }
            return capable.count == 1 ? capable : capable.filter { $0.id == env.pointerDisplay }
        }
    }

    /// What to do with a hardware brightness or volume key.
    static func decide(key: DisplayMediaKey, modifiers: DisplayKeyModifiers, config: Config, env: Environment) -> Decision {
        // ⌥ alone opens the matching System Settings pane; keep that.
        if modifiers == [.option] { return .passThrough }
        let fine = modifiers.isSuperset(of: [.option, .shift])

        if key.isBrightness {
            guard config.brightnessKeys else { return .passThrough }
            let up = key == .brightnessUp
            let contrast = modifiers.isSuperset(of: [.control, .option, .command])
            // ⌃ + brightness is how macOS addresses an Apple external display.
            if modifiers.contains(.control), !contrast { return .passThrough }
            let candidates = candidates(config.brightnessTarget, chosen: config.brightnessChosen, env)
            if contrast {
                let targets = candidates.filter { !$0.isBuiltIn && $0.controls.contains(.contrast) }
                guard !targets.isEmpty else { return .passThrough }
                return .handle(action: up ? .contrastUp : .contrastDown, fine: modifiers.contains(.shift),
                               targets: targets.map(\.id), swallow: true)
            }
            let externals = candidates.filter { !$0.isBuiltIn && $0.controls.contains(.brightness) }
            guard !externals.isEmpty else { return .passThrough }
            // The built-in display is always left to macOS: if it is among the
            // targets the event is let through as well.
            let builtInTargeted = candidates.contains { $0.isBuiltIn }
            return .handle(action: up ? .brightnessUp : .brightnessDown, fine: fine,
                           targets: externals.map(\.id), swallow: !builtInTargeted)
        }

        guard config.volumeKeys else { return .passThrough }
        let targets = volumeTargets(config, env)
        guard !targets.isEmpty else { return .passThrough }
        let action: DisplayKeyAction = key == .mute ? .muteToggle : key == .volumeUp ? .volumeUp : .volumeDown
        return .handle(action: action, fine: fine, targets: targets.map(\.id), swallow: true)
    }

    /// Targets of a user-recorded shortcut. Nothing else handles these keys,
    /// so here the built-in display is adjusted by us too.
    static func shortcutTargets(_ action: DisplayKeyAction, config: Config, env: Environment) -> [CGDirectDisplayID] {
        switch action.control {
        case .brightness, .contrast:
            return candidates(config.brightnessTarget, chosen: config.brightnessChosen, env)
                .filter { $0.controls.contains(action.control) }.map(\.id)
        case .volume:
            var always = config
            always.volumeAlways = true      // an explicit shortcut is an explicit request
            if always.volumeTarget == .output, env.output?.canSetVolume ?? true { always.volumeTarget = .pointer }
            let targets = volumeTargets(always, env)
            if !targets.isEmpty { return targets.map(\.id) }
            let capable = env.displays.filter { $0.controls.contains(.volume) }
            return capable.count == 1 ? capable.map(\.id) : []
        }
    }

    /// Whether an event tap is needed at all with this configuration.
    static func needsTap(_ config: Config, _ env: Environment) -> Bool {
        let externals = env.displays.filter { !$0.isBuiltIn }
        if config.brightnessKeys, externals.contains(where: { $0.controls.contains(.brightness) || $0.controls.contains(.contrast) }) {
            return true
        }
        return config.volumeKeys && externals.contains { $0.controls.contains(.volume) }
    }
}

// MARK: - Input sources

/// MCCS input source values (VCP 0x60). Displays report the active input in
/// the low byte; several (Dell among them) put vendor data in the high byte.
enum DisplayInputSource {
    static let known: [(value: UInt16, name: String)] = [
        (0x0F, "DisplayPort 1"), (0x10, "DisplayPort 2"),
        (0x11, "HDMI 1"), (0x12, "HDMI 2"),
        (0x1B, "USB-C"), (0x19, "USB-C 2"),
        (0x03, "DVI 1"), (0x04, "DVI 2"), (0x01, "VGA 1"),
    ]

    static func value(fromRaw raw: UInt16) -> UInt16 { raw & 0xFF }

    static func name(_ value: UInt16) -> String {
        known.first { $0.value == value }?.name ?? String(format: "Input 0x%02X", value)
    }
}
