import Foundation

/// A user-recorded key combination.
struct DisplayShortcut: Codable, Hashable {
    var keyCode: Int
    var modifiers: DisplayKeyModifiers
    /// Key name captured when it was recorded ("F5", "B", "↑").
    var keyLabel: String

    var label: String { modifiers.symbols + keyLabel }
}

enum DisplayOSDStyle: String, Codable, CaseIterable, Identifiable {
    case system, compact, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: "macOS style"
        case .compact: "Compact bar"
        case .off: "Off"
        }
    }
}

/// Settings of one physical display, keyed by vendor, model and serial.
struct DisplayPrefs: Codable, Equatable {
    /// Empty: use the name the display reports.
    var friendlyName = ""
    /// Off: Bosun neither shows nor touches this display.
    var enabled = true
    var showBrightness = true
    var showContrast = false
    var showVolume = true
    var showInput = false
    /// Raw DDC clamps by control name; absent means the display's own range.
    var clampMin: [String: Int] = [:]
    var clampMax: [String: Int] = [:]
    /// Darken with an overlay window: below the backlight minimum on DDC
    /// displays, for the whole range on displays without DDC.
    var softwareDimming = false
    var followBuiltIn = true
    /// Added to the built-in brightness when following it, -0.5...0.5.
    var syncOffset = 0.0
    var muteSupport: DisplayMuteSupport = .unknown
    var softMute = DisplaySoftMute()
    /// Last values we set or read, 0...1 by control name.
    var last: [String: Double] = [:]

    func shows(_ control: DisplayControl) -> Bool {
        switch control {
        case .brightness: showBrightness
        case .contrast: showContrast
        case .volume: showVolume
        }
    }

    func range(_ control: DisplayControl, deviceMax: UInt16) -> DDCRange {
        DDCRange(deviceMax: deviceMax, clampMin: clampMin[control.rawValue], clampMax: clampMax[control.rawValue])
    }
}

struct DisplaysConfig: Codable, Equatable {
    // Keys. Both off by default: nothing is intercepted until asked for.
    var brightnessKeys = false
    var volumeKeys = false
    var alternateBrightnessKeys = true
    var brightnessTarget: DisplayKeyTarget = .pointer
    var brightnessChosen: String?
    var volumeTarget: DisplayVolumeTarget = .output
    var volumeChosen: String?
    var volumeAlways = false
    /// Size of one key press in percent. 6.25 is the 16 steps macOS uses.
    var stepPercent = 6.25
    var osd: DisplayOSDStyle = .system
    var smooth = false
    /// By `DisplayKeyAction` name.
    var shortcuts: [String: DisplayShortcut] = [:]

    var syncEnabled = false
    /// Write the last known values back on launch, wake and reconnect
    /// instead of adopting whatever the display reports.
    var restore = false

    var displays: [String: DisplayPrefs] = [:]

    func prefs(_ key: String) -> DisplayPrefs { displays[key] ?? DisplayPrefs() }

    var routing: DisplayKeyRouting.Config {
        DisplayKeyRouting.Config(brightnessKeys: brightnessKeys, volumeKeys: volumeKeys,
                          alternateBrightnessKeys: alternateBrightnessKeys,
                          brightnessTarget: brightnessTarget, brightnessChosen: brightnessChosen,
                          volumeTarget: volumeTarget, volumeChosen: volumeChosen, volumeAlways: volumeAlways)
    }

    // MARK: Storage

    static let defaultsKey = "displays.config"

    /// Decodes stored JSON on top of the defaults, so settings saved by an
    /// older build (with fewer fields) still load.
    static func decode(_ data: Data?) -> DisplaysConfig {
        guard let data, var stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return DisplaysConfig()
        }
        func object<T: Encodable>(_ value: T) -> [String: Any] {
            guard let data = try? JSONEncoder().encode(value) else { return [:] }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        let displayDefaults = object(DisplayPrefs())
        if let displays = stored["displays"] as? [String: [String: Any]] {
            stored["displays"] = displays.mapValues { displayDefaults.merging($0) { _, new in new } }
        }
        let merged = object(DisplaysConfig()).merging(stored) { _, new in new }
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? JSONDecoder().decode(DisplaysConfig.self, from: mergedData) else {
            return DisplaysConfig()
        }
        return config
    }

    func encoded() -> Data? { try? JSONEncoder().encode(self) }

    static func load(_ defaults: UserDefaults = .standard) -> DisplaysConfig {
        decode(defaults.data(forKey: defaultsKey))
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = encoded() { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
