import Foundation

/// The four modifiers a tap-level rule can require or produce.
struct Mods: OptionSet, Hashable, Codable {
    let rawValue: UInt8
    static let control = Mods(rawValue: 1)
    static let option = Mods(rawValue: 2)
    static let shift = Mods(rawValue: 4)
    static let command = Mods(rawValue: 8)
    static let hyper: Mods = [.control, .option, .shift, .command]

    struct Info {
        let mod: Mods
        let name: String
        let symbol: String
        let flag: UInt64        // device-independent CGEventFlags bit
        let leftBit: UInt64     // device-dependent bits (IOLLEvent.h NX_DEVICE…KEYMASK)
        let rightBit: UInt64
    }

    /// In the order macOS writes them: ⌃⌥⇧⌘.
    static let all: [Info] = [
        Info(mod: .control, name: "control", symbol: "⌃", flag: 0x4_0000, leftBit: 0x1, rightBit: 0x2000),
        Info(mod: .option, name: "option", symbol: "⌥", flag: 0x8_0000, leftBit: 0x20, rightBit: 0x40),
        Info(mod: .shift, name: "shift", symbol: "⇧", flag: 0x2_0000, leftBit: 0x2, rightBit: 0x4),
        Info(mod: .command, name: "command", symbol: "⌘", flag: 0x10_0000, leftBit: 0x8, rightBit: 0x10),
    ]

    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// The modifiers present in raw event flags.
    init(flags: UInt64) {
        var mods: Mods = []
        for info in Mods.all where flags & info.flag != 0 { mods.insert(info.mod) }
        self = mods
    }

    init(names: [String]) {
        var mods: Mods = []
        for info in Mods.all where names.contains(info.name) { mods.insert(info.mod) }
        self = mods
    }

    var names: [String] { Mods.all.filter { contains($0.mod) }.map(\.name) }
    var symbols: String { Mods.all.filter { contains($0.mod) }.map(\.symbol).joined() }
    var count: Int { rawValue.nonzeroBitCount }

    // Stored as ["control", "shift"] so the saved rules stay readable.
    init(from decoder: Decoder) throws {
        self.init(names: try decoder.singleValueContainer().decode([String].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(names)
    }

    /// Replaces the modifier bits of `flags` (device-independent and
    /// device-dependent) so that exactly these modifiers are down. Device bits
    /// of modifiers that stay are kept; an added modifier counts as its left key.
    func applied(to flags: UInt64) -> UInt64 {
        var out = flags
        for info in Mods.all {
            if contains(info.mod) {
                out |= info.flag
                if out & (info.leftBit | info.rightBit) == 0 { out |= info.leftBit }
            } else {
                out &= ~(info.flag | info.leftBit | info.rightBit)
            }
        }
        return out
    }
}

/// Bits of the raw `CGEventFlags` value that are not modifiers.
enum RawFlag {
    static let numericPad: UInt64 = 0x20_0000
    static let secondaryFn: UInt64 = 0x80_0000
}

/// One key Bosun knows about. `id` is the Karabiner-Elements name, which keeps
/// stored rules readable and makes importing a Karabiner config a lookup.
struct KeyInfo: Identifiable, Hashable {
    enum Group: String, CaseIterable {
        case modifiers = "Modifiers"
        case letters = "Letters"
        case numbers = "Numbers and Symbols"
        case editing = "Editing and Navigation"
        case function = "Function Keys"
        case keypad = "Keypad"
        case media = "Media and System"
    }

    let id: String
    let label: String
    let group: Group
    /// `usagePage << 32 | usage`, what `hidutil` remaps.
    let usage: UInt64
    /// Virtual keycode, what the event tap sees. Keys without one (media keys,
    /// F21–F24) can only be used in key remaps.
    let keycode: UInt16?
}

enum KeyCatalog {
    static let all: [KeyInfo] = build()
    private static let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    private static let byKeycode = Dictionary(all.compactMap { info in info.keycode.map { ($0, info) } },
                                              uniquingKeysWith: { a, _ in a })
    private static let byUsage = Dictionary(all.map { ($0.usage, $0) }, uniquingKeysWith: { a, _ in a })

    static func key(_ id: String) -> KeyInfo? { byID[id] ?? byID[aliases[id] ?? ""] }
    static func key(keycode: UInt16) -> KeyInfo? { byKeycode[keycode] }
    static func key(usage: UInt64) -> KeyInfo? { byUsage[usage] }
    static func label(_ id: String) -> String { key(id)?.label ?? id }

    /// Compact form for dense lists: "↑", "W", "Esc".
    static func shortLabel(_ id: String) -> String {
        let short = ["up_arrow": "↑", "down_arrow": "↓", "left_arrow": "←", "right_arrow": "→", "escape": "Esc",
                     "return_or_enter": "↩", "delete_or_backspace": "⌫", "delete_forward": "⌦", "tab": "⇥",
                     "spacebar": "Space", "home": "Home", "end": "End", "page_up": "PgUp", "page_down": "PgDn"]
        if let known = short[key(id)?.id ?? id] { return known }
        let label = self.label(id)
        // "- Hyphen" → "-"
        if let first = label.split(separator: " ").first, first.count == 1, label.count > 1 { return String(first) }
        return label
    }

    /// Other names Karabiner accepts for the same key.
    static let aliases: [String: String] = [
        "keyboard_fn": "fn", "left_alt": "left_option", "right_alt": "right_option",
        "left_gui": "left_command", "right_gui": "right_command", "expose_all": "mission_control",
        "fastforward": "next_track", "rewind": "previous_track", "scan_next_track": "next_track",
        "scan_previous_track": "previous_track", "spacebar": "spacebar", "space": "spacebar",
        "delete": "delete_or_backspace", "backspace": "delete_or_backspace", "enter": "return_or_enter",
        "volume_up": "volume_increment", "volume_down": "volume_decrement",
    ]

    // MARK: Modifier keys

    struct ModifierKey: Equatable {
        let mod: Mods           // empty for fn
        let downBit: UInt64     // flag bit that is set while this very key is down
    }

    /// Keys that arrive as `flagsChanged` rather than key-down/up.
    static func modifierKey(keycode: UInt16) -> ModifierKey? {
        switch keycode {
        case 59: ModifierKey(mod: .control, downBit: 0x1)
        case 62: ModifierKey(mod: .control, downBit: 0x2000)
        case 56: ModifierKey(mod: .shift, downBit: 0x2)
        case 60: ModifierKey(mod: .shift, downBit: 0x4)
        case 55: ModifierKey(mod: .command, downBit: 0x8)
        case 54: ModifierKey(mod: .command, downBit: 0x10)
        case 58: ModifierKey(mod: .option, downBit: 0x20)
        case 61: ModifierKey(mod: .option, downBit: 0x40)
        case 63: ModifierKey(mod: [], downBit: RawFlag.secondaryFn)
        default: nil
        }
    }

    static let capsLockKeycode: UInt16 = 57

    /// Flags a real press of this key carries besides the modifiers.
    static func intrinsicFlags(keycode: UInt16) -> UInt64 {
        switch keycode {
        case 123...126: RawFlag.numericPad | RawFlag.secondaryFn                        // arrows
        case 65, 67, 69, 71, 75, 76, 78, 81...89, 91, 92: RawFlag.numericPad            // keypad
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,                    // F1–F12
             105, 107, 113, 106, 64, 79, 80, 90,                                        // F13–F20
             114, 115, 116, 117, 119, 121: RawFlag.secondaryFn                          // help, home, pgup, del, end, pgdn
        default: 0
        }
    }

    // MARK: Table

    private static func build() -> [KeyInfo] {
        var keys: [KeyInfo] = []
        func add(_ id: String, _ label: String, _ group: KeyInfo.Group, _ usage: UInt64, _ keycode: UInt16?) {
            keys.append(KeyInfo(id: id, label: label, group: group, usage: usage, keycode: keycode))
        }
        let kb: UInt64 = 0x7_0000_0000, consumer: UInt64 = 0xC_0000_0000
        let appleTopCase: UInt64 = 0xFF_0000_0000, appleKeyboard: UInt64 = 0xFF01_0000_0000

        add("caps_lock", "Caps Lock", .modifiers, kb | 0x39, 57)
        add("left_control", "Left Control", .modifiers, kb | 0xE0, 59)
        add("left_shift", "Left Shift", .modifiers, kb | 0xE1, 56)
        add("left_option", "Left Option", .modifiers, kb | 0xE2, 58)
        add("left_command", "Left Command", .modifiers, kb | 0xE3, 55)
        add("right_control", "Right Control", .modifiers, kb | 0xE4, 62)
        add("right_shift", "Right Shift", .modifiers, kb | 0xE5, 60)
        add("right_option", "Right Option", .modifiers, kb | 0xE6, 61)
        add("right_command", "Right Command", .modifiers, kb | 0xE7, 54)
        add("fn", "fn (Globe)", .modifiers, appleTopCase | 0x03, 63)

        let letterCodes: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (index, code) in letterCodes.enumerated() {
            let letter = String(UnicodeScalar(UInt8(97 + index)))
            add(letter, letter.uppercased(), .letters, kb | UInt64(0x04 + index), code)
        }

        let digitCodes: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]     // 1…9, 0
        for (index, code) in digitCodes.enumerated() {
            let digit = String((index + 1) % 10)
            add(digit, digit, .numbers, kb | UInt64(0x1E + index), code)
        }
        add("hyphen", "- Hyphen", .numbers, kb | 0x2D, 27)
        add("equal_sign", "= Equals", .numbers, kb | 0x2E, 24)
        add("open_bracket", "[ Open Bracket", .numbers, kb | 0x2F, 33)
        add("close_bracket", "] Close Bracket", .numbers, kb | 0x30, 30)
        add("backslash", "\\ Backslash", .numbers, kb | 0x31, 42)
        add("semicolon", "; Semicolon", .numbers, kb | 0x33, 41)
        add("quote", "' Quote", .numbers, kb | 0x34, 39)
        add("grave_accent_and_tilde", "` Backtick", .numbers, kb | 0x35, 50)
        add("comma", ", Comma", .numbers, kb | 0x36, 43)
        add("period", ". Period", .numbers, kb | 0x37, 47)
        add("slash", "/ Slash", .numbers, kb | 0x38, 44)
        add("non_us_backslash", "§ Section (ISO)", .numbers, kb | 0x64, 10)

        add("return_or_enter", "Return", .editing, kb | 0x28, 36)
        add("escape", "Escape", .editing, kb | 0x29, 53)
        add("delete_or_backspace", "Delete (Backspace)", .editing, kb | 0x2A, 51)
        add("delete_forward", "Forward Delete", .editing, kb | 0x4C, 117)
        add("tab", "Tab", .editing, kb | 0x2B, 48)
        add("spacebar", "Space", .editing, kb | 0x2C, 49)
        add("up_arrow", "Up Arrow", .editing, kb | 0x52, 126)
        add("down_arrow", "Down Arrow", .editing, kb | 0x51, 125)
        add("left_arrow", "Left Arrow", .editing, kb | 0x50, 123)
        add("right_arrow", "Right Arrow", .editing, kb | 0x4F, 124)
        add("home", "Home", .editing, kb | 0x4A, 115)
        add("end", "End", .editing, kb | 0x4D, 119)
        add("page_up", "Page Up", .editing, kb | 0x4B, 116)
        add("page_down", "Page Down", .editing, kb | 0x4E, 121)
        add("insert", "Insert (Help)", .editing, kb | 0x49, 114)
        add("application", "Menu (Application)", .editing, kb | 0x65, 110)

        let fCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in fCodes.enumerated() {
            add("f\(index + 1)", "F\(index + 1)", .function, kb | UInt64(0x3A + index), code)
        }
        let highFCodes: [UInt16?] = [105, 107, 113, 106, 64, 79, 80, 90, nil, nil, nil, nil]   // F13…F24
        for (index, code) in highFCodes.enumerated() {
            add("f\(index + 13)", "F\(index + 13)", .function, kb | UInt64(0x68 + index), code)
        }

        add("keypad_num_lock", "Keypad Clear", .keypad, kb | 0x53, 71)
        add("keypad_slash", "Keypad /", .keypad, kb | 0x54, 75)
        add("keypad_asterisk", "Keypad *", .keypad, kb | 0x55, 67)
        add("keypad_hyphen", "Keypad -", .keypad, kb | 0x56, 78)
        add("keypad_plus", "Keypad +", .keypad, kb | 0x57, 69)
        add("keypad_enter", "Keypad Enter", .keypad, kb | 0x58, 76)
        let keypadCodes: [UInt16] = [83, 84, 85, 86, 87, 88, 89, 91, 92, 82]      // 1…9, 0
        for (index, code) in keypadCodes.enumerated() {
            add("keypad_\((index + 1) % 10)", "Keypad \((index + 1) % 10)", .keypad, kb | UInt64(0x59 + index), code)
        }
        add("keypad_period", "Keypad .", .keypad, kb | 0x63, 65)
        add("keypad_equal_sign", "Keypad =", .keypad, kb | 0x67, 81)

        add("volume_increment", "Volume Up", .media, consumer | 0xE9, nil)
        add("volume_decrement", "Volume Down", .media, consumer | 0xEA, nil)
        add("mute", "Mute", .media, consumer | 0xE2, nil)
        add("play_or_pause", "Play / Pause", .media, consumer | 0xCD, nil)
        add("next_track", "Next Track", .media, consumer | 0xB5, nil)
        add("previous_track", "Previous Track", .media, consumer | 0xB6, nil)
        add("display_brightness_increment", "Brightness Up", .media, consumer | 0x6F, nil)
        add("display_brightness_decrement", "Brightness Down", .media, consumer | 0x70, nil)
        add("dictation", "Dictation", .media, consumer | 0xCF, nil)
        add("eject", "Eject", .media, consumer | 0xB8, nil)
        add("mission_control", "Mission Control", .media, appleKeyboard | 0x10, nil)
        add("launchpad", "Launchpad", .media, appleKeyboard | 0x04, nil)
        add("spotlight", "Spotlight", .media, appleKeyboard | 0x01, nil)
        add("illumination_increment", "Keyboard Brightness Up", .media, appleTopCase | 0x08, nil)
        add("illumination_decrement", "Keyboard Brightness Down", .media, appleTopCase | 0x09, nil)
        return keys
    }
}
