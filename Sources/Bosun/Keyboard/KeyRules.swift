import Foundation

/// A key-to-key remap done by the HID event system (`hidutil` UserKeyMapping).
/// `src`/`dst` are `usagePage << 32 | usage`.
struct KeyRemapRule: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var src: UInt64
    var dst: UInt64
    var enabled: Bool
}

/// "While a modifier is held, key → key", done by the event tap.
struct LayerRule: Codable, Identifiable, Equatable {
    struct Key: Codable, Equatable {
        var from: UInt16   // virtual keycodes
        var to: UInt16
    }
    var id: String
    var title: String
    var detail: String
    /// Remap rule that produces the hold key; the layer is inert without it.
    var requires: String?
    /// Device-dependent bit in the raw event flags that means "hold key is down".
    var holdFlag: UInt64
    /// Device-independent modifier the hold key contributes, and the device bit
    /// of its twin on the other side (the modifier is kept if the twin is down).
    var holdModifier: UInt64
    var holdTwinFlag: UInt64
    /// Flags the real target keys carry.
    var addFlags: UInt64
    var keys: [Key]
    var enabled: Bool
}

struct KeyboardRules: Codable, Equatable {
    var remaps: [KeyRemapRule]
    var layers: [LayerRule]

    var activeRemaps: [HIDMapping.Entry] {
        remaps.filter(\.enabled).map { HIDMapping.Entry(src: $0.src, dst: $0.dst) }
    }

    func isUsable(_ layer: LayerRule) -> Bool {
        guard let needed = layer.requires else { return true }
        return remaps.contains { $0.id == needed && $0.enabled }
    }

    var activeLayers: [LayerRule] { layers.filter { $0.enabled && isUsable($0) } }

    // MARK: Defaults (the user's former Karabiner config)

    static let capsRuleID = "caps-to-control"
    static let fnRuleID = "rctrl-to-fn"

    static let defaults = KeyboardRules(
        remaps: [
            // hidutil mappings do not chain: Caps Lock becomes a real Right
            // Control while the physical Right Control becomes fn, so "right
            // control is down" can only mean "Caps Lock is held".
            KeyRemapRule(id: capsRuleID, title: "Caps Lock → Control",
                         detail: "Acts as Right Control system-wide",
                         src: HIDUsage.capsLock, dst: HIDUsage.rightControl, enabled: true),
            KeyRemapRule(id: fnRuleID, title: "Right Control → fn",
                         detail: "Turn off if fn / Globe misbehaves",
                         src: HIDUsage.rightControl, dst: HIDUsage.appleFn, enabled: true),
        ],
        layers: [
            LayerRule(id: "caps-wasd", title: "Caps Lock + W A S D → arrows",
                      detail: "Sent as Control+Arrow, like Karabiner did",
                      requires: capsRuleID,
                      holdFlag: RawFlag.deviceRightControl,
                      holdModifier: RawFlag.control,
                      holdTwinFlag: RawFlag.deviceLeftControl,
                      addFlags: RawFlag.numericPad | RawFlag.secondaryFn,
                      keys: [.init(from: KeyCode.w, to: KeyCode.up),
                             .init(from: KeyCode.a, to: KeyCode.left),
                             .init(from: KeyCode.s, to: KeyCode.down),
                             .init(from: KeyCode.d, to: KeyCode.right)],
                      enabled: true),
        ])

    // MARK: Persistence

    static let rulesKey = "keyboard.rules"          // JSON string, so `defaults read` stays legible
    static let plainArrowsKey = "keyboard.plainArrows"

    static func load(from defaults: UserDefaults = .standard) -> KeyboardRules {
        guard let text = defaults.string(forKey: rulesKey),
              let rules = try? JSONDecoder().decode(KeyboardRules.self, from: Data(text.utf8))
        else { return .defaults }
        return rules
    }

    func save(to defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        defaults.set(String(decoding: data, as: UTF8.self), forKey: Self.rulesKey)
    }
}

enum HIDUsage {
    static let capsLock: UInt64 = 0x7_0000_0039
    static let rightControl: UInt64 = 0x7_0000_00E4
    static let appleFn: UInt64 = 0xFF_0000_0003      // AppleVendor top case, keyboard_fn
    static let f23: UInt64 = 0x7_0000_0072
    static let f24: UInt64 = 0x7_0000_0073
}

enum KeyCode {
    static let a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2, w: UInt16 = 13
    static let left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
}

/// Bits of the raw `CGEventFlags` value (IOLLEvent.h).
enum RawFlag {
    static let deviceLeftControl: UInt64 = 0x1       // NX_DEVICELCTLKEYMASK
    static let deviceRightControl: UInt64 = 0x2000   // NX_DEVICERCTLKEYMASK
    static let shift: UInt64 = 0x2_0000
    static let control: UInt64 = 0x4_0000
    static let option: UInt64 = 0x8_0000
    static let command: UInt64 = 0x10_0000
    static let numericPad: UInt64 = 0x20_0000
    static let secondaryFn: UInt64 = 0x80_0000
}
