import CoreGraphics
import Foundation

/// Headless checks for `Bosun --selftest`.
enum KeyboardChecks {
    static let all: [SelfTest.Check] = [
        ("keyboard catalog: keycodes and usages", catalog),
        ("keyboard rules: storage round trip", storage),
        ("keyboard rules: migration from the first format", migration),
        ("keyboard compiler: key remaps", compileRemaps),
        ("keyboard compiler: Caps Lock carrier and hold keys", compileHolds),
        ("keyboard compiler: shortcuts", compileShortcuts),
        ("keyboard engine: Caps Lock layer", engineLayer),
        ("keyboard engine: layer key-up and repeat when the state changes mid-press", engineMidPress),
        ("keyboard engine: pressed alone", engineAlone),
        ("keyboard engine: hold modifiers and Hyper", engineHoldMods),
        ("keyboard engine: modifier key as hold key", engineModifierTrigger),
        ("keyboard engine: tap-first keys (rollover, threshold, repeat)", engineTapFirst),
        ("keyboard engine: shortcuts", engineShortcuts),
        ("keyboard engine: precedence between rule kinds", enginePrecedence),
        ("keyboard engine: per-app rules", engineApps),
        ("keyboard engine: nothing left behind", engineHygiene),
        ("keyboard tap: event plumbing", tapPlumbing),
        ("keyboard mapping: merge and unmerge", mergeFixtures),
        ("keyboard mapping: plans for global and per-keyboard remaps", planFixtures),
        ("keyboard mapping: built-in keyboard disable and device classification", builtInDisableFixtures),
        ("keyboard mapping: hidutil arguments and parsing", jsonFixtures),
        ("keyboard import: the user's Karabiner config", importUserConfig),
        ("keyboard import: unsupported pieces are reported", importSkips),
        ("keyboard presets: all compile cleanly", presets),
        ("keyboard live: system mapping round trip", liveRoundTrip),
        ("keyboard live: per-keyboard mapping round trip", liveDeviceRoundTrip),
        ("keyboard live: Caps Lock state and input sources (read-only)", liveCapsLock),
    ]

    // Generated from Carbon's kVK_ constants.
    private static let carbonKeycodes: [String: UInt16] = ["a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29, "hyphen": 27, "equal_sign": 24, "open_bracket": 33, "close_bracket": 30, "backslash": 42, "semicolon": 41, "quote": 39, "grave_accent_and_tilde": 50, "comma": 43, "period": 47, "slash": 44, "non_us_backslash": 10, "return_or_enter": 36, "escape": 53, "delete_or_backspace": 51, "delete_forward": 117, "tab": 48, "spacebar": 49, "up_arrow": 126, "down_arrow": 125, "left_arrow": 123, "right_arrow": 124, "home": 115, "end": 119, "page_up": 116, "page_down": 121, "insert": 114, "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90, "keypad_num_lock": 71, "keypad_slash": 75, "keypad_asterisk": 67, "keypad_hyphen": 78, "keypad_plus": 69, "keypad_enter": 76, "keypad_1": 83, "keypad_2": 84, "keypad_3": 85, "keypad_4": 86, "keypad_5": 87, "keypad_6": 88, "keypad_7": 89, "keypad_8": 91, "keypad_9": 92, "keypad_0": 82, "keypad_period": 65, "keypad_equal_sign": 81, "caps_lock": 57, "left_control": 59, "left_shift": 56, "left_option": 58, "left_command": 55, "right_control": 62, "right_shift": 60, "right_option": 61, "right_command": 54, "fn": 63]

    // MARK: Catalog and storage

    private static func catalog() -> String? {
        for (id, keycode) in carbonKeycodes {
            guard let info = KeyCatalog.key(id) else { return "missing key \(id)" }
            if info.keycode != keycode { return "\(id) has keycode \(String(describing: info.keycode)), Carbon says \(keycode)" }
        }
        let withKeycode = KeyCatalog.all.filter { $0.keycode != nil && $0.id != "application" }
        if withKeycode.count != carbonKeycodes.count { return "\(withKeycode.count) keys with keycodes, \(carbonKeycodes.count) verified" }
        if Set(KeyCatalog.all.map(\.id)).count != KeyCatalog.all.count { return "duplicate key ids" }
        if Set(KeyCatalog.all.map(\.usage)).count != KeyCatalog.all.count { return "duplicate usages" }
        if Set(KeyCatalog.all.compactMap(\.keycode)).count != KeyCatalog.all.compactMap(\.keycode).count { return "duplicate keycodes" }
        let usages: [(String, UInt64)] = [("caps_lock", 0x7_0000_0039), ("right_control", 0x7_0000_00E4), ("fn", 0xFF_0000_0003),
                                          ("a", 0x7_0000_0004), ("z", 0x7_0000_001D), ("1", 0x7_0000_001E), ("0", 0x7_0000_0027),
                                          ("f1", 0x7_0000_003A), ("f12", 0x7_0000_0045), ("f13", 0x7_0000_0068), ("f18", 0x7_0000_006D),
                                          ("f24", 0x7_0000_0073), ("keypad_1", 0x7_0000_0059), ("keypad_0", 0x7_0000_0062),
                                          ("up_arrow", 0x7_0000_0052), ("left_command", 0x7_0000_00E3), ("escape", 0x7_0000_0029),
                                          ("volume_increment", 0xC_0000_00E9), ("mission_control", 0xFF01_0000_0010)]
        for (id, usage) in usages where KeyCatalog.key(id)?.usage != usage { return "\(id) has the wrong usage" }
        if KeyCatalog.key("keyboard_fn")?.id != "fn" || KeyCatalog.key("left_alt")?.id != "left_option" { return "aliases broken" }
        // Mods ↔ flags
        let flags = Mods([.control, .shift]).applied(to: 0x100 | 0x10_0000 | 0x10)
        if flags != 0x100 | 0x4_0000 | 0x1 | 0x2_0000 | 0x2 { return "Mods.applied gave 0x\(String(flags, radix: 16))" }
        if Mods(flags: 0x4_0000 | 0x8_0000) != [.control, .option] { return "Mods(flags:) wrong" }
        if Mods.hyper.symbols != "⌃⌥⇧⌘" { return "symbols are \(Mods.hyper.symbols)" }
        // Right-hand device bit of a modifier that stays is kept.
        if Mods.control.applied(to: 0x4_0000 | 0x2000) != 0x4_0000 | 0x2000 { return "device bit not kept" }
        return nil
    }

    private static let sampleRules: [KeyRule] = [
        KeyRule(name: "r", .remap(RemapRule(from: "right_control", to: "fn", device: KeyboardDevice(vendorID: 1, productID: 2, name: "K")))),
        KeyRule(enabled: false, .shortcut(ShortcutRule(from: KeyCombo(key: "h", mods: .control), anyModifiers: true,
                                                      to: .key("delete_or_backspace"),
                                                      apps: AppFilter(mode: .except, apps: [.init(bundleID: "com.apple.Terminal", name: "Terminal")])))),
        KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "t", mods: .hyper), to: .openApp("com.apple.Terminal", name: "Terminal")))),
        KeyRule(.hold(HoldRule(trigger: "caps_lock", alone: .send, tap: .key("escape"), holdMods: .control,
                               mappings: [.init(from: KeyCombo(key: "w", mods: .shift), to: .key("up_arrow", [.control, .shift]))],
                               holdAfterThreshold: true, thresholdMs: 250))),
    ]

    private static func storage() -> String? {
        let set = KeyRuleSet(rules: sampleRules)
        guard let back = KeyRuleSet.decode(set.encoded()) else { return "encoded rules do not decode" }
        if back != set { return "rules changed in a round trip" }
        if !set.encoded().contains(#""mods":["control"]"#) { return "modifiers are not stored by name: \(set.encoded())" }
        let suite = "local.jinqiu.Bosun.selftest.keyboard"
        guard let defaults = UserDefaults(suiteName: suite) else { return "no scratch defaults" }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        if KeyRuleSet.load(from: defaults).rules.count != KeyRuleSet.initial.rules.count { return "empty store did not give the initial rules" }
        if defaults.object(forKey: KeyRuleSet.key) != nil { return "loading an empty store wrote to it" }
        set.save(to: defaults)
        if KeyRuleSet.load(from: defaults) != set { return "saved rules did not load back" }
        // An unreadable store is copied aside rather than silently replaced.
        defaults.set("{broken", forKey: KeyRuleSet.key)
        _ = KeyRuleSet.load(from: defaults)
        if defaults.string(forKey: KeyRuleSet.key + ".unreadable") != "{broken" { return "unreadable store was not kept" }
        // An empty rule list is a valid state and must stay empty.
        KeyRuleSet(rules: []).save(to: defaults)
        if !KeyRuleSet.load(from: defaults).rules.isEmpty { return "an empty rule list did not stay empty" }
        return nil
    }

    /// The value stored by the first version, with the given switches.
    private static func legacy(caps: Bool, fn: Bool, layer: Bool) -> String {
        #"{"layers":[{"addFlags":10485760,"detail":"Sent as Control+Arrow, like Karabiner did","enabled":\#(layer),"holdFlag":8192,"holdModifier":262144,"holdTwinFlag":1,"id":"caps-wasd","keys":[{"from":13,"to":126},{"from":0,"to":123},{"from":1,"to":125},{"from":2,"to":124}],"requires":"caps-to-control","title":"Caps Lock + W A S D → arrows"}],"remaps":[{"detail":"Acts as Right Control system-wide","dst":30064771300,"enabled":\#(caps),"id":"caps-to-control","src":30064771129,"title":"Caps Lock → Control"},{"detail":"Turn off if fn \/ Globe misbehaves","dst":1095216660483,"enabled":\#(fn),"id":"rctrl-to-fn","src":30064771300,"title":"Right Control → fn"}]}"#
    }

    private static func migration() -> String? {
        func layerRule(_ mods: Mods, enabled: Bool) -> KeyRule {
            KeyRule(id: "caps-wasd", name: "Caps Lock + W A S D → arrows", enabled: enabled, .hold(HoldRule(
                trigger: "caps_lock", alone: .normal, holdMods: [],
                mappings: [("w", "up_arrow"), ("a", "left_arrow"), ("s", "down_arrow"), ("d", "right_arrow")].map {
                    .init(from: KeyCombo(key: $0.0), to: .key($0.1, mods))
                })))
        }
        /// Mapping ids are random; compare everything else.
        func same(_ a: [KeyRule], _ b: [KeyRule]) -> Bool {
            func strip(_ rules: [KeyRule]) -> [KeyRule] {
                rules.map { rule in
                    guard case .hold(var hold) = rule.body else { return rule }
                    hold.mappings = hold.mappings.map { .init(id: "", from: $0.from, to: $0.to) }
                    var copy = rule
                    copy.body = .hold(hold)
                    return copy
                }
            }
            return strip(a) == strip(b)
        }
        let fnRule = KeyRule(id: "rctrl-to-fn", name: "Right Control → fn", enabled: true, .remap(RemapRule(from: "right_control", to: "fn")))

        // The exact shape found on the user's machine: Caps remap off, fn remap on, layer on.
        guard let found = KeyRuleSet.migrate(legacyJSON: legacy(caps: false, fn: true, layer: true), plainArrows: false) else {
            return "the stored shape did not migrate"
        }
        if !same(found.rules, [fnRule, layerRule(.control, enabled: true)]) { return "stored shape became \(found.encoded())" }
        // Its later state, everything on: same result, and no Caps Lock → Control remap survives.
        guard let allOn = KeyRuleSet.migrate(legacyJSON: legacy(caps: true, fn: true, layer: true), plainArrows: false),
              same(allOn.rules, found.rules) else { return "all-on shape migrated differently" }
        // The migrated layer works by itself: Caps Lock is carried to the tap, pressed alone it stays Caps Lock.
        let program = KeyCompiler.compile(found.rules)
        if program.global != [.init(src: 0x7_0000_00E4, dst: 0xFF_0000_0003), .init(src: 0x7_0000_0039, dst: 0x7_0000_006D)] {
            return "migrated rules compile to \(program.global)"
        }
        if program.tap.holds.first?.tap != .capsLock || program.tap.holds.first?.injected != [] { return "migrated layer changes Caps Lock alone" }
        if program.issues.values.contains(where: { $0.contains(where: \.isError) }) { return "migrated rules have errors: \(program.issues)" }
        // Switches carry over.
        guard let off = KeyRuleSet.migrate(legacyJSON: legacy(caps: true, fn: false, layer: false), plainArrows: true) else { return "no migration" }
        var fnOff = fnRule
        fnOff.enabled = false
        if !same(off.rules, [fnOff, layerRule([], enabled: false)]) { return "off/plain shape became \(off.encoded())" }
        if KeyRuleSet.migrate(legacyJSON: "{}", plainArrows: false) != nil { return "garbage migrated" }

        // Through UserDefaults: migrated once, old value left in place.
        let suite = "local.jinqiu.Bosun.selftest.keyboard.migration"
        guard let defaults = UserDefaults(suiteName: suite) else { return "no scratch defaults" }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removePersistentDomain(forName: suite)
        let old = legacy(caps: false, fn: true, layer: true)
        defaults.set(old, forKey: KeyRuleSet.legacyKey)
        let first = KeyRuleSet.load(from: defaults)
        if !same(first.rules, found.rules) { return "load() did not migrate" }
        if defaults.string(forKey: KeyRuleSet.legacyKey) != old { return "the old value was touched" }
        if KeyRuleSet.load(from: defaults) != first { return "second load differs (migration is not stable)" }
        // The old "what we applied" record still decodes, so the old mapping is taken out on upgrade.
        let record = #"{"ours":[{"src":30064771129,"dst":30064771300},{"src":30064771300,"dst":1095216660483}],"displaced":[]}"#
        guard let applied = try? JSONDecoder().decode(HIDMapping.Applied.self, from: Data(record.utf8)), applied.ours.count == 2 else {
            return "old applied-mapping record does not decode"
        }
        let upgrade = HIDMapping.plan(current: .init(global: applied.ours), previous: applied,
                                      desired: .init(global: [.init(src: 0x7_0000_00E4, dst: 0xFF_0000_0003)]))
        if upgrade.global != [.init(src: 0x7_0000_00E4, dst: 0xFF_0000_0003)] { return "upgrade leaves the old Caps Lock remap: \(String(describing: upgrade.global))" }
        return nil
    }

    // MARK: Compiler

    private static func errors(_ program: KeyProgram, _ rule: KeyRule) -> [String] {
        (program.issues[rule.id] ?? []).filter(\.isError).map(\.text)
    }

    private static func compileRemaps() -> String? {
        let board = KeyboardDevice(vendorID: 0x5AC, productID: 0x342, name: "Board")
        let a = KeyRule(.remap(RemapRule(from: "caps_lock", to: "escape")))
        let b = KeyRule(.remap(RemapRule(from: "caps_lock", to: "left_control")))            // loses to a
        let c = KeyRule(.remap(RemapRule(from: "caps_lock", to: "left_control", device: board)))   // own scope
        let d = KeyRule(.remap(RemapRule(from: "f13", to: "mute")))
        let e = KeyRule(.remap(RemapRule(from: "a", to: "a")))
        let f = KeyRule(enabled: false, .remap(RemapRule(from: "b", to: "c")))
        let g = KeyRule(.remap(RemapRule(from: "nope", to: "c")))
        let program = KeyCompiler.compile([a, b, c, d, e, f, g])
        if program.global != [.init(src: 0x7_0000_0039, dst: 0x7_0000_0029), .init(src: 0x7_0000_0068, dst: 0xC_0000_00E2)] {
            return "global is \(program.global)"
        }
        if program.devices != [board: [.init(src: 0x7_0000_0039, dst: 0x7_0000_00E0)]] { return "devices are \(program.devices)" }
        if errors(program, b).count != 1 || errors(program, e).count != 1 || errors(program, g).count != 1 { return "expected errors missing: \(program.issues)" }
        if !errors(program, a).isEmpty || !errors(program, c).isEmpty || program.issues[f.id] != nil { return "unexpected errors: \(program.issues)" }
        if program.needsTap || !program.carriers.isEmpty { return "remaps alone must not need the tap" }
        return nil
    }

    private static func compileHolds() -> String? {
        let caps = HIDMapping.Entry(src: 0x7_0000_0039, dst: 0x7_0000_006D)      // Caps Lock → F18
        let layer = KeyRule(.hold(HoldRule(trigger: "caps_lock", mappings: [.init(from: KeyCombo(key: "w"), to: .key("up_arrow", .control))])))
        var program = KeyCompiler.compile([layer])
        if program.global != [caps] || program.carriers != [caps] { return "carrier is \(program.global)" }
        guard let hold = program.tap.holds.first, program.tap.holds.count == 1 else { return "no hold compiled" }
        if hold.trigger != 79 || hold.modifier != nil || hold.injected != [] || hold.tap != .capsLock { return "caps layer compiled to \(hold)" }
        if hold.mappings != [.init(keycode: 13, mods: [], action: .key(126, .control))] { return "mappings are \(hold.mappings)" }

        // Hold modifiers never turn Caps Lock into a real modifier key.
        let dual = KeyRule(.hold(HoldRule(trigger: "caps_lock", alone: .send, tap: .key("escape"), holdMods: .control)))
        program = KeyCompiler.compile([dual])
        if program.global != [caps] || program.tap.holds.first?.injected != .control || program.tap.holds.first?.tap != .key(53, []) {
            return "dual-role caps compiled to \(program.global) \(program.tap.holds)"
        }
        // A carrier that the user's own rules mention is not taken.
        let usesF18 = KeyRule(enabled: false, .shortcut(ShortcutRule(from: KeyCombo(key: "f18"), to: .key("a"))))
        program = KeyCompiler.compile([usesF18, layer])
        if program.global != [.init(src: 0x7_0000_0039, dst: 0x7_0000_006E)] { return "carrier did not avoid F18: \(program.global)" }
        // Two rules on Caps Lock in different apps share one carrier; a second unconditional one is unreachable.
        var inTerminal = HoldRule(trigger: "caps_lock", alone: .nothing, holdMods: .control)
        inTerminal.apps = AppFilter(mode: .only, apps: [.init(bundleID: "com.apple.Terminal", name: "Terminal")])
        let scoped = KeyRule(.hold(inTerminal))
        program = KeyCompiler.compile([scoped, layer, dual])
        if program.global != [caps] || program.tap.holds.map(\.ruleID) != [scoped.id, layer.id] { return "shared carrier: \(program.global) \(program.tap.holds.map(\.ruleID))" }
        if errors(program, dual).count != 1 { return "unreachable hold not reported" }
        // The user remapped Caps Lock explicitly: the hold follows that key and adds no carrier.
        let toControl = KeyRule(.remap(RemapRule(from: "caps_lock", to: "right_control")))
        program = KeyCompiler.compile([toControl, layer])
        if program.global != [.init(src: 0x7_0000_0039, dst: 0x7_0000_00E4)] || !program.carriers.isEmpty { return "explicit remap: \(program.global)" }
        if program.tap.holds.first?.trigger != 62 || program.tap.holds.first?.modifier?.mod != .control || program.tap.holds.first?.tap != nil {
            return "hold did not follow the remap: \(program.tap.holds)"
        }
        if (program.issues[layer.id] ?? []).isEmpty { return "following a remap is not mentioned" }
        // Regular and modifier hold keys.
        let space = KeyRule(.hold(HoldRule(trigger: "spacebar", holdMods: .shift, holdAfterThreshold: true, thresholdMs: 180)))
        let option = KeyRule(.hold(HoldRule(trigger: "right_option", alone: .send, tap: .key("escape"), holdMods: [.option, .control], holdAfterThreshold: true)))
        program = KeyCompiler.compile([space, option])
        guard program.tap.holds.count == 2, program.global.isEmpty else { return "space/option holds: \(program.tap.holds.count)" }
        let s = program.tap.holds[0], o = program.tap.holds[1]
        if s.trigger != 49 || s.tap != .key(49, []) || s.injected != .shift || !s.holdAfterThreshold || s.thresholdMs != 180 { return "space hold: \(s)" }
        if o.trigger != 61 || o.modifier?.downBit != 0x40 || o.injected != .control || o.holdAfterThreshold { return "option hold: \(o)" }
        // Things that cannot work are errors, not silence.
        let media = KeyRule(.hold(HoldRule(trigger: "mute", alone: .nothing, holdMods: .control)))
        let noTap = KeyRule(.hold(HoldRule(trigger: "f19", alone: .send, holdMods: .control)))
        let badKey = KeyRule(.hold(HoldRule(trigger: "f20", mappings: [.init(from: KeyCombo(key: "left_shift"), to: .key("a")),
                                                                       .init(from: KeyCombo(key: "b"), to: KeyAction())])))
        program = KeyCompiler.compile([media, noTap, badKey])
        if errors(program, media).count != 1 || errors(program, noTap).count != 1 || errors(program, badKey).count != 2 { return "hold errors: \(program.issues)" }
        // Rules are inert when off: no carrier either.
        var offLayer = layer
        offLayer.enabled = false
        if KeyCompiler.compile([offLayer]) != KeyProgram() { return "a disabled rule still compiles to something" }
        return nil
    }

    private static func compileShortcuts() -> String? {
        let a = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "h", mods: .control), to: .key("delete_or_backspace"))))
        let shadowed = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "h", mods: .control), to: .key("a"))))
        let wider = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "h", mods: .control), anyModifiers: true, to: .key("b"))))
        let modifier = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "left_shift"), to: .key("a"))))
        let empty = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "j"), to: KeyAction())))
        let itself = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "k", mods: .command), to: .key("k", .command))))
        let app = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "t", mods: .hyper), to: .openApp("com.apple.Terminal", name: "Terminal"))))
        let caps = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "f16"), to: .key("caps_lock"))))
        let program = KeyCompiler.compile([a, shadowed, wider, modifier, empty, itself, app, caps])
        if program.tap.shortcuts.map(\.ruleID) != [a.id, wider.id, app.id, caps.id] { return "compiled \(program.tap.shortcuts.map(\.action))" }
        for rule in [shadowed, modifier, empty, itself] where errors(program, rule).count != 1 { return "missing error for \(rule.summary): \(program.issues)" }
        if program.tap.shortcuts[2].action != .app("com.apple.Terminal") || program.tap.shortcuts[3].action != .capsLock { return "actions wrong" }
        if !program.global.isEmpty { return "shortcuts must not touch the HID mapping" }
        return nil
    }

    // MARK: Engine

    private static let base: UInt64 = 0x100                         // NX_NONCOALSESCEDMASK, always present
    private static let fnFlag = RawFlag.secondaryFn
    private static let arrow = RawFlag.numericPad | RawFlag.secondaryFn
    private static let ctl: UInt64 = 0x4_0000 | 0x1                  // Control as its left key
    private static let shift: UInt64 = 0x2_0000 | 0x2
    private static let opt: UInt64 = 0x8_0000 | 0x20
    private static let cmd: UInt64 = 0x10_0000 | 0x8

    private typealias Out = KeyEngine.Output

    private static func code(_ id: String) -> UInt16 { KeyCatalog.key(id)!.keycode! }
    private static func down(_ id: String, _ flags: UInt64, isRepeat: Bool = false) -> Out {
        .key(down: true, keycode: code(id), isRepeat: isRepeat, flags: flags)
    }
    private static func up(_ id: String, _ flags: UInt64) -> Out { .key(down: false, keycode: code(id), isRepeat: false, flags: flags) }
    private static func pass(_ flags: UInt64) -> Out { .original(flags: flags) }

    /// Feeds events through the compiled rules and compares each result.
    private struct Sim {
        var config: KeyEngine.Config
        var state = KeyEngine.State()
        var time: UInt64 = 10_000
        var app: String? = "com.example.editor"
        var failure: String?

        init(_ rules: [KeyRule]) { config = KeyCompiler.compile(rules).tap }

        /// `after` is the time since the previous event, in milliseconds.
        mutating func send(_ kind: KeyEngine.Input.Kind, _ key: String = "", _ flags: UInt64, isRepeat: Bool = false, after: UInt64 = 20,
                           gives expected: [Out], _ label: String) {
            time += after
            let input = KeyEngine.Input(kind: kind, keycode: key.isEmpty ? 0 : KeyboardChecks.code(key), flags: flags,
                                        isRepeat: isRepeat, timeMs: time, app: app)
            let got = KeyEngine.process(input, config: config, state: &state)
            if failure == nil, got != expected { failure = "\(label): got \(Self.text(got)), want \(Self.text(expected))" }
        }

        mutating func idle(_ label: String) {
            if failure == nil, !state.isIdle { failure = "\(label): state not idle: \(state)" }
        }

        static func text(_ outputs: [Out]) -> String {
            "[" + outputs.map { output in
                switch output {
                case .original(let flags): "pass 0x\(String(flags, radix: 16))"
                case .key(let down, let keycode, let isRepeat, let flags):
                    "\(down ? (isRepeat ? "repeat" : "down") : "up") \(KeyCatalog.key(keycode: keycode)?.id ?? "\(keycode)") 0x\(String(flags, radix: 16))"
                case .launch(let id): "launch \(id)"
                case .capsLock(let long): "capsLock(long: \(long))"
                }
            }.joined(separator: ", ") + "]"
        }
    }

    /// The user's rule: Caps Lock + W/A/S/D → ⌃↑ ⌃← ⌃↓ ⌃→, Caps Lock alone unchanged.
    private static var spacesLayer: KeyRule { KeyPresets.capsControlWASD }
    private static let f18 = base | RawFlag.secondaryFn     // what the carrier key's own events carry

    private static func engineLayer() -> String? {
        var sim = Sim([spacesLayer])
        sim.send(.keyDown, "f18", f18, gives: [], "caps down is swallowed")
        for (from, to) in [("w", "up_arrow"), ("a", "left_arrow"), ("s", "down_arrow"), ("d", "right_arrow")] {
            sim.send(.keyDown, from, base, gives: [down(to, base | ctl | arrow)], "caps+\(from)")
            sim.send(.keyUp, from, base, gives: [up(to, base | ctl | arrow)], "caps+\(from) up")
        }
        // Other modifiers the user holds pass through to the output.
        sim.send(.keyDown, "d", base | shift | cmd, gives: [down("right_arrow", base | ctl | shift | cmd | arrow)], "caps+shift+cmd+d")
        sim.send(.keyUp, "d", base | shift | cmd, gives: [up("right_arrow", base | ctl | shift | cmd | arrow)], "caps+shift+cmd+d up")
        // Caps Lock is not a modifier here: a key outside the layer is itself, with nothing added.
        sim.send(.keyDown, "e", base, gives: [pass(base)], "caps+e")
        sim.send(.keyUp, "e", base, gives: [pass(base)], "caps+e up")
        sim.send(.keyDown, "c", base | cmd, gives: [pass(base | cmd)], "caps+cmd+c")
        sim.send(.keyUp, "c", base | cmd, gives: [pass(base | cmd)], "caps+cmd+c up")
        // Two layer keys at once.
        sim.send(.keyDown, "w", base, gives: [down("up_arrow", base | ctl | arrow)], "w of w+d")
        sim.send(.keyDown, "d", base, gives: [down("right_arrow", base | ctl | arrow)], "d of w+d")
        sim.send(.keyUp, "w", base, gives: [up("up_arrow", base | ctl | arrow)], "w up of w+d")
        sim.send(.keyUp, "d", base, gives: [up("right_arrow", base | ctl | arrow)], "d up of w+d")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up after use does nothing")
        sim.idle("after layer use")
        // Without Caps Lock the keys are just keys, and Control+W stays Control+W.
        sim.send(.keyDown, "w", base, gives: [pass(base)], "plain w")
        sim.send(.keyUp, "w", base, gives: [pass(base)], "plain w up")
        sim.send(.flagsChanged, "left_control", base | ctl, gives: [pass(base | ctl)], "left control down")
        sim.send(.keyDown, "w", base | ctl, gives: [pass(base | ctl)], "control+w")
        sim.send(.keyUp, "w", base | ctl, gives: [pass(base | ctl)], "control+w up")
        sim.send(.flagsChanged, "left_control", base, gives: [pass(base)], "left control up")
        // The layer's Control is added even when the user holds the right-hand one (its device bit is kept).
        let rightCtl: UInt64 = 0x4_0000 | 0x2000
        sim.send(.keyDown, "f18", f18 | rightCtl, gives: [], "caps down with right control")
        sim.send(.keyDown, "a", base | rightCtl, gives: [down("left_arrow", base | rightCtl | arrow)], "right control+caps+a")
        sim.send(.keyUp, "a", base | rightCtl, gives: [up("left_arrow", base | rightCtl | arrow)], "its key-up")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up")
        sim.idle("end")
        return sim.failure
    }

    private static func engineMidPress() -> String? {
        var sim = Sim([spacesLayer])
        // Caps Lock released while W is down: repeats and the key-up are still the arrow.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "w", base, gives: [down("up_arrow", base | ctl | arrow)], "w down")
        sim.send(.keyDown, "w", base, isRepeat: true, gives: [down("up_arrow", base | ctl | arrow, isRepeat: true)], "repeat")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up first")
        sim.send(.keyDown, "w", base, isRepeat: true, gives: [down("up_arrow", base | ctl | arrow, isRepeat: true)], "repeat after caps up")
        sim.send(.keyUp, "w", base, gives: [up("up_arrow", base | ctl | arrow)], "w up after caps up")
        sim.send(.keyUp, "w", base, gives: [pass(base)], "stray second key-up")
        sim.idle("after release order swap")
        // W pressed first, Caps Lock afterwards: it stays a W to the end.
        sim.send(.keyDown, "w", base, gives: [pass(base)], "w before caps")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down later")
        sim.send(.keyDown, "w", base, isRepeat: true, gives: [pass(base)], "repeat stays w")
        sim.send(.keyUp, "w", base, gives: [pass(base)], "w up while caps held")
        sim.send(.keyUp, "f18", f18, gives: [.capsLock(long: false)], "caps tapped while another key was already down still counts as alone")
        // A key-up the tap never saw must not turn the next plain W into an arrow.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "w", base, gives: [down("up_arrow", base | ctl | arrow)], "w down, key-up lost")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up")
        sim.send(.keyDown, "w", base, gives: [pass(base)], "fresh plain w after a lost key-up")
        sim.send(.keyUp, "w", base, gives: [pass(base)], "its key-up")
        // Caps Lock's own key-up lost: pressing it again starts over rather than nesting.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down, key-up lost")
        sim.send(.keyDown, "f18", f18, after: 5_000, gives: [], "caps down again")
        if sim.state.holds.count != 1 { return "a lost hold key-up left \(sim.state.holds.count) holds" }
        sim.send(.keyDown, "f18", f18, isRepeat: true, gives: [], "caps repeat is swallowed")
        sim.send(.keyUp, "f18", f18, gives: [.capsLock(long: false)], "the second press was a tap of its own")
        sim.idle("end")
        // The tap can drop a hold whose key is no longer down.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        if KeyEngine.heldTriggers(config: sim.config, state: sim.state) != [code("f18")] { return "held trigger not reported" }
        KeyEngine.forget(trigger: code("f18"), config: sim.config, state: &sim.state)
        sim.send(.keyDown, "w", base, gives: [pass(base)], "w after the hold was forgotten")
        sim.send(.keyUp, "w", base, gives: [pass(base)], "w up")
        sim.idle("after forget")
        return sim.failure
    }

    private static func engineAlone() -> String? {
        // Normal Caps Lock when pressed alone (threshold 300 ms).
        var sim = Sim([spacesLayer])
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, after: 120, gives: [.capsLock(long: false)], "quick tap is Caps Lock")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, after: 300, gives: [.capsLock(long: false)], "exactly at the threshold still taps")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, after: 301, gives: [.capsLock(long: true)], "long press alone is reported as long")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "f18", f18, isRepeat: true, after: 100, gives: [], "own repeat does not count as use")
        sim.send(.keyUp, "f18", f18, after: 50, gives: [.capsLock(long: false)], "tap after own repeat")
        // Used with a layer key, a non-layer key, or a click: not a tap.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "w", base, gives: [down("up_arrow", base | ctl | arrow)], "w")
        sim.send(.keyUp, "w", base, gives: [up("up_arrow", base | ctl | arrow)], "w up")
        sim.send(.keyUp, "f18", f18, gives: [], "no Caps Lock after layer use")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "e", base, gives: [pass(base)], "e")
        sim.send(.keyUp, "f18", f18, gives: [], "no Caps Lock after another key")
        sim.send(.keyUp, "e", base, gives: [pass(base)], "e up")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.mouseDown, "", base, gives: [pass(base)], "click")
        sim.send(.mouseUp, "", base, gives: [pass(base)], "click up")
        sim.send(.keyUp, "f18", f18, gives: [], "no Caps Lock after a click")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.flagsChanged, "left_shift", base | shift, gives: [pass(base | shift)], "shift down")
        sim.send(.flagsChanged, "left_shift", base, gives: [pass(base)], "shift up")
        sim.send(.keyUp, "f18", f18, gives: [], "no Caps Lock after another modifier")
        sim.idle("normal")
        if let failure = sim.failure { return failure }

        // "Does nothing" and "Sends…".
        var nothing = KeyPresets.capsControlWASD
        if case .hold(var hold) = nothing.body { hold.alone = .nothing; nothing.body = .hold(hold) }
        sim = Sim([nothing])
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, gives: [], "alone: nothing")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, after: 900, gives: [], "alone long: nothing")
        if let failure = sim.failure { return failure }

        sim = Sim([KeyRule(.hold(HoldRule(trigger: "caps_lock", alone: .send, tap: .key("escape"), thresholdMs: 200)))])
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, after: 150, gives: [down("escape", base), up("escape", base)], "tap sends Escape, without the carrier's fn flag")
        sim.send(.keyDown, "f18", f18 | shift, gives: [], "shift+caps down")
        sim.send(.keyUp, "f18", f18 | shift, after: 150, gives: [down("escape", base | shift), up("escape", base | shift)], "shift+tap sends Shift+Escape")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, after: 201, gives: [], "too slow to be a tap")
        // An ordinary key keeps its own function when "normal".
        sim = Sim([KeyRule(.hold(HoldRule(trigger: "grave_accent_and_tilde", mappings: [.init(from: KeyCombo(key: "1"), to: .key("f1"))])))])
        sim.send(.keyDown, "grave_accent_and_tilde", base, gives: [], "` down")
        sim.send(.keyUp, "grave_accent_and_tilde", base, gives: [down("grave_accent_and_tilde", base), up("grave_accent_and_tilde", base)], "` alone is `")
        sim.send(.keyDown, "grave_accent_and_tilde", base, gives: [], "` down")
        sim.send(.keyDown, "1", base, gives: [down("f1", base | fnFlag)], "`+1 is F1")
        sim.send(.keyUp, "1", base, gives: [up("f1", base | fnFlag)], "F1 up")
        sim.send(.keyUp, "grave_accent_and_tilde", base, gives: [], "` up after use")
        sim.idle("end")
        return sim.failure
    }

    private static func engineHoldMods() -> String? {
        // Caps Lock: tap Escape, hold Control — Control is added to events, Caps Lock is no real modifier key.
        var sim = Sim([KeyRule(.hold(HoldRule(trigger: "caps_lock", alone: .send, tap: .key("escape"), holdMods: .control)))])
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "c", base, gives: [pass(base | ctl)], "caps+c is control+c")
        sim.send(.keyDown, "c", base, isRepeat: true, gives: [pass(base | ctl)], "repeat")
        sim.send(.keyUp, "c", base, gives: [pass(base | ctl)], "c up")
        sim.send(.mouseDown, "", base, gives: [pass(base | ctl)], "caps+click is control-click")
        sim.send(.mouseUp, "", base, gives: [pass(base | ctl)], "click up")
        sim.send(.flagsChanged, "left_shift", base | shift, gives: [pass(base | shift | ctl)], "other modifiers show the held one too")
        sim.send(.keyDown, "a", base | shift, gives: [pass(base | shift | ctl)], "caps+shift+a")
        sim.send(.keyUp, "a", base | shift, gives: [pass(base | shift | ctl)], "a up")
        sim.send(.flagsChanged, "left_shift", base, gives: [pass(base | ctl)], "shift up")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up after use: no Escape")
        sim.send(.keyDown, "c", base, gives: [pass(base)], "c afterwards is plain")
        sim.send(.keyUp, "c", base, gives: [pass(base)], "c up")
        // The user's real Control is left exactly as it is.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "c", base | 0x4_0000 | 0x2000, gives: [pass(base | 0x4_0000 | 0x2000)], "already control: untouched")
        sim.send(.keyUp, "c", base | 0x4_0000 | 0x2000, gives: [pass(base | 0x4_0000 | 0x2000)], "c up")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up")
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyUp, "f18", f18, after: 100, gives: [down("escape", base), up("escape", base)], "tap is Escape")
        sim.idle("dual role")
        if let failure = sim.failure { return failure }

        // Layer keys do not get the hold modifier; everything else does.
        sim = Sim([KeyRule(.hold(HoldRule(trigger: "caps_lock", alone: .nothing, holdMods: .control,
                                          mappings: [.init(from: KeyCombo(key: "h"), to: .key("left_arrow")),
                                                     .init(from: KeyCombo(key: "h", mods: .shift), to: .key("home")),
                                                     .init(from: KeyCombo(key: "d"), to: .key("right_arrow", .control))])))])
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "h", base, gives: [down("left_arrow", base | arrow)], "layer key: plain arrow, no control")
        sim.send(.keyUp, "h", base, gives: [up("left_arrow", base | arrow)], "up")
        sim.send(.keyDown, "h", base | shift, gives: [down("home", base | fnFlag)], "the more specific layer key wins and consumes its modifier")
        sim.send(.keyUp, "h", base | shift, gives: [up("home", base | fnFlag)], "up")
        sim.send(.keyDown, "h", base | opt, gives: [down("left_arrow", base | opt | arrow)], "extra modifier passes through")
        sim.send(.keyUp, "h", base | opt, gives: [up("left_arrow", base | opt | arrow)], "up")
        sim.send(.keyDown, "d", base, gives: [down("right_arrow", base | ctl | arrow)], "explicit output modifier")
        sim.send(.keyUp, "d", base, gives: [up("right_arrow", base | ctl | arrow)], "up")
        sim.send(.keyDown, "x", base, gives: [pass(base | ctl)], "other keys get the hold modifier")
        sim.send(.keyUp, "x", base, gives: [pass(base | ctl)], "up")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up")
        if let failure = sim.failure { return failure }

        // Hyper.
        let hyper = ctl | opt | shift | cmd
        sim = Sim([KeyRule(.hold(HoldRule(trigger: "caps_lock", alone: .send, tap: .key("escape"), holdMods: .hyper)))])
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "t", base, gives: [pass(base | hyper)], "hyper+t")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up before t")
        sim.send(.keyUp, "t", base, gives: [pass(base)], "t up after release is plain")
        sim.idle("hyper")
        return sim.failure
    }

    private static func engineModifierTrigger() -> String? {
        let rOpt: UInt64 = 0x8_0000 | 0x40
        // Right Option: a layer while held, Escape when tapped; it stays a real Option key.
        var sim = Sim([KeyRule(.hold(HoldRule(trigger: "right_option", alone: .send, tap: .key("escape"),
                                              mappings: [.init(from: KeyCombo(key: "j"), to: .key("down_arrow")),
                                                         .init(from: KeyCombo(key: "k"), to: .key("up_arrow", .command))])))])
        sim.send(.flagsChanged, "right_option", base | rOpt, gives: [pass(base | rOpt)], "right option down passes")
        sim.send(.keyDown, "j", base | rOpt, gives: [down("down_arrow", base | arrow)], "its own Option is left off the layer output")
        sim.send(.keyUp, "j", base | rOpt, gives: [up("down_arrow", base | arrow)], "up")
        sim.send(.keyDown, "k", base | rOpt, gives: [down("up_arrow", base | cmd | arrow)], "explicit modifier")
        sim.send(.keyUp, "k", base | rOpt, gives: [up("up_arrow", base | cmd | arrow)], "up")
        sim.send(.keyDown, "e", base | rOpt, gives: [pass(base | rOpt)], "other keys still get Option")
        sim.send(.keyUp, "e", base | rOpt, gives: [pass(base | rOpt)], "up")
        sim.send(.flagsChanged, "right_option", base, gives: [pass(base)], "release after use: no Escape")
        sim.send(.flagsChanged, "right_option", base | rOpt, gives: [pass(base | rOpt)], "down")
        sim.send(.flagsChanged, "right_option", base, after: 100, gives: [pass(base), down("escape", base), up("escape", base)], "tap: release first, then Escape")
        sim.send(.flagsChanged, "right_option", base | rOpt, gives: [pass(base | rOpt)], "down")
        sim.send(.flagsChanged, "right_option", base, after: 400, gives: [pass(base)], "slow release: nothing")
        // Left Option held as well: Option is really wanted, so it stays.
        sim.send(.flagsChanged, "left_option", base | opt, gives: [pass(base | opt)], "left option down")
        sim.send(.flagsChanged, "right_option", base | opt | 0x40, gives: [pass(base | opt | 0x40)], "right option down")
        sim.send(.keyDown, "j", base | opt | 0x40, gives: [down("down_arrow", base | opt | 0x40 | arrow)], "both options: Option stays on")
        sim.send(.keyUp, "j", base | opt | 0x40, gives: [up("down_arrow", base | opt | 0x40 | arrow)], "up")
        sim.send(.flagsChanged, "right_option", base | opt, gives: [pass(base | opt)], "right option up")
        sim.send(.keyDown, "j", base | opt, gives: [pass(base | opt)], "left option alone is not the layer")
        sim.send(.keyUp, "j", base | opt, gives: [pass(base | opt)], "up")
        sim.send(.flagsChanged, "left_option", base, gives: [pass(base)], "left option up")
        sim.idle("modifier trigger")
        // Release never seen: the next key event without the bit ends the layer.
        sim.send(.flagsChanged, "right_option", base | rOpt, gives: [pass(base | rOpt)], "down, release lost")
        sim.send(.keyDown, "j", base, gives: [pass(base)], "j without the option bit is a j")
        sim.send(.keyUp, "j", base, gives: [pass(base)], "up")
        sim.idle("after lost release")
        // Release during a layer key press: key-up still matches.
        sim.send(.flagsChanged, "right_option", base | rOpt, gives: [pass(base | rOpt)], "down")
        sim.send(.keyDown, "j", base | rOpt, gives: [down("down_arrow", base | arrow)], "j down")
        sim.send(.flagsChanged, "right_option", base, gives: [pass(base)], "option up first")
        sim.send(.keyDown, "j", base, isRepeat: true, gives: [down("down_arrow", base | arrow, isRepeat: true)], "repeat stays an arrow")
        sim.send(.keyUp, "j", base, gives: [up("down_arrow", base | arrow)], "j up is the arrow's")
        sim.idle("end")
        if let failure = sim.failure { return failure }

        // Right Command as Hyper: its own Command is real, the other three are added.
        let rCmd: UInt64 = 0x10_0000 | 0x10
        sim = Sim([KeyRule(.hold(HoldRule(trigger: "right_command", alone: .nothing, holdMods: .hyper)))])
        sim.send(.flagsChanged, "right_command", base | rCmd, gives: [pass(base | rCmd | ctl | opt | shift)], "right command down shows hyper")
        sim.send(.keyDown, "t", base | rCmd, gives: [pass(base | rCmd | ctl | opt | shift)], "hyper+t")
        sim.send(.keyUp, "t", base | rCmd, gives: [pass(base | rCmd | ctl | opt | shift)], "up")
        sim.send(.flagsChanged, "right_command", base, gives: [pass(base)], "release")
        sim.send(.keyDown, "t", base, gives: [pass(base)], "t afterwards")
        sim.send(.keyUp, "t", base, gives: [pass(base)], "up")
        sim.idle("right command hyper")
        return sim.failure
    }

    private static func engineTapFirst() -> String? {
        // Space: Shift when held past 200 ms, Space otherwise — safe for typing.
        var sim = Sim([KeyRule(.hold(HoldRule(trigger: "spacebar", alone: .normal, holdMods: .shift, holdAfterThreshold: true, thresholdMs: 200)))])
        sim.send(.keyDown, "spacebar", base, gives: [], "space down waits")
        sim.send(.keyUp, "spacebar", base, after: 80, gives: [down("spacebar", base), up("spacebar", base)], "quick press is a space")
        sim.idle("tap")
        // Rollover: the next letter arrives before Space is released.
        sim.send(.keyDown, "spacebar", base, gives: [], "space down")
        sim.send(.keyDown, "a", base, after: 60, gives: [down("spacebar", base), up("spacebar", base), pass(base)], "rollover: space first, then a, no shift")
        sim.send(.keyDown, "b", base, after: 30, gives: [pass(base)], "the next key is plain too")
        sim.send(.keyUp, "spacebar", base, after: 30, gives: [], "late space key-up adds nothing")
        sim.send(.keyUp, "a", base, gives: [pass(base)], "a up")
        sim.send(.keyUp, "b", base, gives: [pass(base)], "b up")
        sim.idle("rollover")
        // Held past the threshold: Shift.
        sim.send(.keyDown, "spacebar", base, gives: [], "space down")
        sim.send(.keyDown, "spacebar", base, isRepeat: true, after: 150, gives: [], "its repeats are swallowed")
        sim.send(.keyDown, "a", base, after: 60, gives: [pass(base | shift)], "after 210 ms it is shift+a")
        sim.send(.keyUp, "a", base, gives: [pass(base | shift)], "a up")
        sim.send(.keyUp, "spacebar", base, gives: [], "release after holding: no space")
        sim.idle("hold")
        // Held past the threshold and released without anything else: nothing.
        sim.send(.keyDown, "spacebar", base, gives: [], "space down")
        sim.send(.keyUp, "spacebar", base, after: 500, gives: [], "long lonely press: nothing")
        // Exactly at the threshold counts as held.
        sim.send(.keyDown, "spacebar", base, gives: [], "space down")
        sim.send(.keyDown, "a", base, after: 200, gives: [pass(base | shift)], "at the threshold it is held")
        sim.send(.keyUp, "a", base, gives: [pass(base | shift)], "a up")
        sim.send(.keyUp, "spacebar", base, gives: [], "space up")
        // A modifier pressed during the wait does not settle it; the key that follows does.
        sim.send(.keyDown, "spacebar", base, gives: [], "space down")
        sim.send(.flagsChanged, "left_shift", base | shift, after: 40, gives: [pass(base | shift)], "shift down while waiting")
        sim.send(.keyDown, "a", base | shift, after: 40, gives: [down("spacebar", base | shift), up("spacebar", base | shift), pass(base | shift)], "space, then shift+a")
        sim.send(.keyUp, "a", base | shift, gives: [pass(base | shift)], "a up")
        sim.send(.flagsChanged, "left_shift", base, gives: [pass(base)], "shift up")
        sim.send(.keyUp, "spacebar", base, gives: [], "space up")
        sim.idle("end")
        if let failure = sim.failure { return failure }

        // Immediate mode for comparison: the same rollover is a hold.
        sim = Sim([KeyRule(.hold(HoldRule(trigger: "spacebar", alone: .normal, holdMods: .shift, thresholdMs: 200)))])
        sim.send(.keyDown, "spacebar", base, gives: [], "space down")
        sim.send(.keyDown, "a", base, after: 60, gives: [pass(base | shift)], "immediate: shift+a at once")
        sim.send(.keyUp, "a", base, gives: [pass(base | shift)], "a up")
        sim.send(.keyUp, "spacebar", base, gives: [], "space up: used")
        return sim.failure
    }

    private static func engineShortcuts() -> String? {
        var sim = Sim([
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "h", mods: .control), to: .key("delete_or_backspace")))),
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "home"), anyModifiers: true, to: .key("left_arrow", .command)))),
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "t", mods: .hyper), to: .openApp("com.apple.Terminal", name: "Terminal")))),
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "j", mods: [.control, .shift]), to: .key("down_arrow", .shift)))),
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "f16"), to: .key("caps_lock")))),
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "up_arrow", mods: .option), to: .key("k", .command)))),
        ])
        sim.send(.keyDown, "h", base | ctl, gives: [down("delete_or_backspace", base)], "control+h is delete, control consumed")
        sim.send(.keyDown, "h", base | ctl, isRepeat: true, gives: [down("delete_or_backspace", base, isRepeat: true)], "repeat")
        sim.send(.keyUp, "h", base | ctl, gives: [up("delete_or_backspace", base)], "up")
        sim.send(.keyDown, "h", base | ctl | shift, gives: [pass(base | ctl | shift)], "exact match only: control+shift+h untouched")
        sim.send(.keyUp, "h", base | ctl | shift, gives: [pass(base | ctl | shift)], "up")
        sim.send(.keyDown, "h", base, gives: [pass(base)], "plain h untouched")
        sim.send(.keyUp, "h", base, gives: [pass(base)], "up")
        sim.send(.keyDown, "home", base | fnFlag, gives: [down("left_arrow", base | cmd | arrow)], "home is command+left")
        sim.send(.keyUp, "home", base | fnFlag, gives: [up("left_arrow", base | cmd | arrow)], "up")
        sim.send(.keyDown, "home", base | fnFlag | shift, gives: [down("left_arrow", base | cmd | shift | arrow)], "any modifiers: shift carries over")
        sim.send(.keyUp, "home", base | fnFlag | shift, gives: [up("left_arrow", base | cmd | shift | arrow)], "up")
        let hyper = ctl | opt | shift | cmd
        sim.send(.keyDown, "t", base | hyper, gives: [.launch("com.apple.Terminal")], "hyper+t opens the app")
        sim.send(.keyDown, "t", base | hyper, isRepeat: true, gives: [], "its repeat is swallowed")
        sim.send(.keyUp, "t", base | hyper, gives: [], "its key-up is swallowed")
        sim.send(.keyDown, "j", base | ctl | shift, gives: [down("down_arrow", base | shift | arrow)], "control+shift+j is shift+down")
        // Modifier released before the key: the key-up still belongs to the output key.
        sim.send(.flagsChanged, "left_control", base | shift, gives: [pass(base | shift)], "control up mid-press")
        sim.send(.keyUp, "j", base | shift, gives: [up("down_arrow", base | shift | arrow)], "up is still the arrow's")
        sim.send(.keyDown, "f16", base | fnFlag, gives: [.capsLock(long: false)], "a key can be made Caps Lock")
        sim.send(.keyUp, "f16", base | fnFlag, gives: [], "up")
        sim.send(.keyDown, "up_arrow", base | opt | arrow, gives: [down("k", base | cmd)], "arrow to letter drops the arrow flags")
        sim.send(.keyUp, "up_arrow", base | opt | arrow, gives: [up("k", base | cmd)], "up")
        sim.idle("shortcuts")
        return sim.failure
    }

    private static func enginePrecedence() -> String? {
        let hyper = ctl | opt | shift | cmd
        let layer = KeyRule(.hold(HoldRule(trigger: "caps_lock", alone: .nothing, mappings: [
            .init(from: KeyCombo(key: "h"), to: .key("left_arrow")),
            .init(from: KeyCombo(key: "f19"), to: .key("page_down")),
            .init(from: KeyCombo(key: "x"), to: .key("f5")),
        ])))
        let second = KeyRule(.hold(HoldRule(trigger: "f19", alone: .send, tap: .key("escape"), holdMods: .hyper,
                                            mappings: [.init(from: KeyCombo(key: "x"), to: .key("f6"))])))
        let first = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "h"), anyModifiers: true, to: .key("1"))))
        let later = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "h", mods: .hyper), to: .key("2"))))
        let hyperQ = KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "q", mods: .hyper), to: .key("3"))))
        var sim = Sim([first, later, hyperQ, layer, second])
        // Shortcut order: the one higher in the list wins.
        sim.send(.keyDown, "h", base, gives: [down("1", base)], "shortcut")
        sim.send(.keyUp, "h", base, gives: [up("1", base)], "up")
        // A held layer beats a shortcut on the same key.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "h", base, gives: [down("left_arrow", base | arrow)], "layer beats shortcut")
        sim.send(.keyUp, "h", base, gives: [up("left_arrow", base | arrow)], "up")
        // A held layer beats a hold key: F19 is a layer key here, not the second hold.
        sim.send(.keyDown, "f19", base | fnFlag, gives: [down("page_down", base | fnFlag)], "layer beats hold key")
        sim.send(.keyUp, "f19", base | fnFlag, gives: [up("page_down", base | fnFlag)], "up")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up")
        sim.idle("layer vs others")
        // A hold key beats a shortcut; its injected modifiers reach shortcut matching.
        sim.send(.keyDown, "f19", base | fnFlag, gives: [], "f19 down is the hold key")
        sim.send(.keyDown, "q", base, gives: [down("3", base)], "hyper from the hold key triggers the hyper+q shortcut, modifiers consumed")
        sim.send(.keyUp, "q", base, gives: [up("3", base)], "up")
        sim.send(.keyDown, "h", base, gives: [down("1", base | hyper)], "first matching shortcut wins; extra modifiers carry over")
        sim.send(.keyUp, "h", base, gives: [up("1", base | hyper)], "up")
        // Nested: the most recently pressed hold key's layer is consulted first.
        sim.send(.keyDown, "f18", f18, gives: [], "caps down inside f19")
        sim.send(.keyDown, "x", base, gives: [down("f5", base | hyper | fnFlag)], "inner layer first, outer hold's modifiers still apply")
        sim.send(.keyUp, "x", base, gives: [up("f5", base | hyper | fnFlag)], "up")
        sim.send(.keyUp, "f18", f18, gives: [], "caps up")
        sim.send(.keyDown, "x", base, gives: [down("f6", base | fnFlag)], "outer layer, its own modifiers left off")
        sim.send(.keyUp, "x", base, gives: [up("f6", base | fnFlag)], "up")
        sim.send(.keyUp, "f19", base | fnFlag, gives: [], "f19 up: used, no Escape")
        sim.idle("end")
        return sim.failure
    }

    private static func engineApps() -> String? {
        let terminal = AppFilter(mode: .only, apps: [.init(bundleID: "com.apple.Terminal", name: "Terminal")])
        let notTerminal = AppFilter(mode: .except, apps: [.init(bundleID: "com.apple.Terminal", name: "Terminal")])
        if !AppFilter().allows(nil) || terminal.allows(nil) || !notTerminal.allows(nil) { return "unknown app handled wrongly" }
        var inTerminal = HoldRule(trigger: "f19", alone: .send, tap: .key("escape"), holdMods: .control)
        inTerminal.apps = terminal
        var elsewhere = HoldRule(trigger: "f19", alone: .nothing, mappings: [.init(from: KeyCombo(key: "h"), to: .key("left_arrow"))])
        elsewhere.apps = notTerminal
        var sim = Sim([
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "c", mods: .control), to: .key("c", .command), apps: notTerminal))),
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "k", mods: .command), to: .key("l", .control), apps: terminal))),
            KeyRule(.hold(inTerminal)), KeyRule(.hold(elsewhere)),
        ])
        sim.send(.keyDown, "c", base | ctl, gives: [down("c", base | cmd)], "control+c is copy outside Terminal")
        sim.send(.keyUp, "c", base | ctl, gives: [up("c", base | cmd)], "up")
        sim.send(.keyDown, "k", base | cmd, gives: [pass(base | cmd)], "terminal-only shortcut does not apply here")
        sim.send(.keyUp, "k", base | cmd, gives: [pass(base | cmd)], "up")
        sim.send(.keyDown, "f19", base | fnFlag, gives: [], "f19 is the layer here")
        sim.send(.keyDown, "h", base, gives: [down("left_arrow", base | arrow)], "layer key")
        // Switching apps mid-press does not strand the key.
        sim.app = "com.apple.Terminal"
        sim.send(.keyUp, "h", base, gives: [up("left_arrow", base | arrow)], "key-up after an app switch still matches")
        sim.send(.keyUp, "f19", base | fnFlag, gives: [], "hold key up after an app switch")
        sim.idle("after app switch")
        sim.send(.keyDown, "c", base | ctl, gives: [pass(base | ctl)], "control+c stays in Terminal")
        sim.send(.keyUp, "c", base | ctl, gives: [pass(base | ctl)], "up")
        sim.send(.keyDown, "k", base | cmd, gives: [down("l", base | ctl)], "command+k is control+l in Terminal")
        sim.send(.keyUp, "k", base | cmd, gives: [up("l", base | ctl)], "up")
        sim.send(.keyDown, "f19", base | fnFlag, gives: [], "f19 is the dual-role key in Terminal")
        sim.send(.keyDown, "h", base, gives: [pass(base | ctl)], "control+h, not the layer")
        sim.send(.keyUp, "h", base, gives: [pass(base | ctl)], "up")
        sim.send(.keyUp, "f19", base | fnFlag, gives: [], "up")
        sim.send(.keyDown, "f19", base | fnFlag, gives: [], "down")
        sim.send(.keyUp, "f19", base | fnFlag, after: 100, gives: [down("escape", base), up("escape", base)], "tap is Escape in Terminal")
        // Where no rule on a hold key applies, the key is just the key.
        var onlyTerminal = Sim([KeyRule(.hold(inTerminal))])
        onlyTerminal.send(.keyDown, "f19", base | fnFlag, gives: [pass(base | fnFlag)], "f19 elsewhere is f19")
        onlyTerminal.send(.keyUp, "f19", base | fnFlag, gives: [pass(base | fnFlag)], "up")
        onlyTerminal.idle("unfiltered")
        sim.idle("end")
        return sim.failure ?? onlyTerminal.failure
    }

    /// Random event soup must never leave the engine holding on to anything
    /// once every key is up, and events must pass untouched without rules.
    private static func engineHygiene() -> String? {
        var empty = Sim([])
        empty.send(.keyDown, "a", base | ctl, gives: [pass(base | ctl)], "no rules: untouched")
        empty.send(.flagsChanged, "left_shift", base | shift, gives: [pass(base | shift)], "no rules: flags untouched")
        empty.idle("no rules")
        if let failure = empty.failure { return failure }

        let rules = sampleRules.map { rule -> KeyRule in var rule = rule; rule.enabled = true; return rule } + [
            KeyRule(.hold(HoldRule(trigger: "spacebar", holdMods: .shift, holdAfterThreshold: true, thresholdMs: 150))),
            KeyRule(.hold(HoldRule(trigger: "right_option", alone: .send, tap: .key("escape"), mappings: [.init(from: KeyCombo(key: "j"), to: .key("down_arrow"))]))),
        ]
        let config = KeyCompiler.compile(rules).tap
        let keys = ["f18", "spacebar", "w", "h", "j", "t", "a"].map(code)
        var generator = SystemRandomNumberGenerator()
        for round in 0..<300 {
            var state = KeyEngine.State()
            var held = Set<UInt16>()
            var optionDown = false
            var time: UInt64 = 1
            var flags = base
            func feed(_ kind: KeyEngine.Input.Kind, _ key: UInt16, _ isRepeat: Bool = false) {
                time += UInt64.random(in: 1...260, using: &generator)
                _ = KeyEngine.process(.init(kind: kind, keycode: key, flags: flags, isRepeat: isRepeat, timeMs: time,
                                            app: Bool.random(using: &generator) ? "com.apple.Terminal" : "x"), config: config, state: &state)
            }
            for _ in 0..<40 {
                switch Int.random(in: 0..<10, using: &generator) {
                case 0:
                    optionDown.toggle()
                    flags = optionDown ? flags | 0x8_0000 | 0x40 : flags & ~(0x8_0000 | 0x40)
                    feed(.flagsChanged, 61)
                case 1:
                    feed(.mouseDown, 0)
                case 2:
                    if let key = held.randomElement(using: &generator) { feed(.keyDown, key, true) }
                default:
                    let key = keys.randomElement(using: &generator)!
                    if held.remove(key) != nil { feed(.keyUp, key) } else { held.insert(key); feed(.keyDown, key) }
                }
            }
            for key in held { feed(.keyUp, key) }
            if optionDown { flags = base; feed(.flagsChanged, 61) }
            if !state.isIdle { return "round \(round): state left behind after all keys were released: \(state)" }
        }
        return nil
    }

    // MARK: Tap plumbing (events are built and inspected, never posted)

    private static func tapPlumbing() -> String? {
        let tap = KeyTap()
        var launched: [String] = [], caps: [Bool] = []
        var physicallyDown = true
        tap.keyIsDown = { _ in physicallyDown }
        tap.onLaunch = { launched.append($0) }
        tap.onCapsLock = { caps.append($0) }
        tap.update(KeyCompiler.compile([
            spacesLayer,
            KeyRule(.hold(HoldRule(trigger: "f19", alone: .send, tap: .key("escape"), holdMods: .control))),
            KeyRule(.shortcut(ShortcutRule(from: KeyCombo(key: "t", mods: .command), to: .openApp("com.apple.Terminal", name: "Terminal")))),
        ]).tap)

        var clock: UInt64 = 5_000_000_000
        var posted: [CGEvent] = []
        /// Runs one made-up key event through the tap; returns what comes out, in order.
        func run(_ id: String, down: Bool, flags: UInt64 = 0x100, isRepeat: Bool = false, afterMs: UInt64 = 20) -> [CGEvent]? {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code(id), keyDown: down) else { return nil }
            clock += afterMs * 1_000_000
            event.timestamp = clock
            event.flags = CGEventFlags(rawValue: flags)
            if isRepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
            posted = []
            let kept = tap.handle(type: down ? .keyDown : .keyUp, event: event) { posted.append($0) }
            return (kept.map { [$0] } ?? []) + posted
        }
        func describe(_ events: [CGEvent]?) -> String {
            guard let events else { return "no event" }
            return events.map { "\($0.type == .keyDown ? "down" : "up") \($0.getIntegerValueField(.keyboardEventKeycode)) 0x\(String($0.flags.rawValue, radix: 16))" }
                .joined(separator: ", ")
        }
        func expect(_ events: [CGEvent]?, _ want: [(CGEventType, String, UInt64)], _ label: String) -> String? {
            guard let events else { return "\(label): could not build an event" }
            let ok = events.count == want.count && zip(events, want).allSatisfy { event, want in
                event.type == want.0 && event.getIntegerValueField(.keyboardEventKeycode) == Int64(code(want.1)) && event.flags.rawValue == want.2
            }
            return ok ? nil : "\(label): got [\(describe(events))]"
        }

        if let f = expect(run("w", down: true), [(.keyDown, "w", base)], "plain w passes") { return f }
        if let f = expect(run("w", down: false), [(.keyUp, "w", base)], "plain w up passes") { return f }
        if let f = expect(run("f18", down: true, flags: f18), [], "carrier key-down is swallowed") { return f }
        guard let rewritten = run("a", down: true) else { return "no event" }
        if let f = expect(rewritten, [(.keyDown, "left_arrow", base | ctl | arrow)], "caps+a becomes control+left") { return f }
        if !posted.isEmpty { return "a simple rewrite must edit the event in place, not post a new one" }
        if let f = expect(run("a", down: true, isRepeat: true), [(.keyDown, "left_arrow", base | ctl | arrow)], "repeat") { return f }
        if let f = expect(run("a", down: false), [(.keyUp, "left_arrow", base | ctl | arrow)], "key-up") { return f }
        if let f = expect(run("f18", down: false, flags: f18), [], "carrier key-up is swallowed") { return f }
        if !caps.isEmpty { return "Caps Lock fired after layer use" }
        _ = run("f18", down: true, flags: f18)
        if let f = expect(run("f18", down: false, flags: f18, afterMs: 90), [], "tap is swallowed") { return f }
        if caps != [false] { return "a tap on Caps Lock should ask for Caps Lock once, got \(caps)" }

        // A tap action is posted as new, marked events.
        _ = run("f19", down: true, flags: base | fnFlag)
        guard let escape = run("f19", down: false, flags: base | fnFlag, afterMs: 90) else { return "no event" }
        if let f = expect(escape, [(.keyDown, "escape", base), (.keyUp, "escape", base)], "tap posts Escape") { return f }
        if posted.count != 2 || !posted.allSatisfy({ $0.getIntegerValueField(.eventSourceUserData) == KeyTap.marker }) {
            return "posted events are not marked"
        }
        // …and the tap leaves its own events alone when they come back around.
        let again = tap.handle(type: .keyDown, event: posted[0]) { _ in }
        if again == nil || again?.getIntegerValueField(.keyboardEventKeycode) != Int64(code("escape")) { return "own event was processed again" }
        // Injected modifiers are edited into the passing event.
        _ = run("f19", down: true, flags: base | fnFlag)
        if let f = expect(run("c", down: true), [(.keyDown, "c", base | ctl)], "hold modifier is added in place") { return f }
        if let f = expect(run("c", down: false), [(.keyUp, "c", base | ctl)], "and on key-up") { return f }
        // The hold key's release never arrives (secure input): the keyboard says it is up, so the modifier must not stick.
        physicallyDown = false
        if let f = expect(run("c", down: true), [(.keyDown, "c", base)], "stuck hold is dropped") { return f }
        _ = run("c", down: false)
        physicallyDown = true

        if let f = expect(run("t", down: true, flags: base | cmd), [], "app shortcut is swallowed") { return f }
        if launched != ["com.apple.Terminal"] { return "launch not requested: \(launched)" }
        _ = run("t", down: false, flags: base | cmd)

        // Paused (key recorder): everything passes untouched.
        tap.setPaused(true)
        if let f = expect(run("f18", down: true, flags: f18), [(.keyDown, "f18", f18)], "paused tap passes the carrier") { return f }
        tap.setPaused(false)
        _ = run("f18", down: false, flags: f18)
        if tap.isRunning { return "the tap must not be running in a check" }
        return nil
    }

    // MARK: Mapping

    private typealias Entry = HIDMapping.Entry
    private static let capsToF18 = Entry(src: 0x7_0000_0039, dst: 0x7_0000_006D)
    private static let rctrlToFn = Entry(src: 0x7_0000_00E4, dst: 0xFF_0000_0003)

    private static func mergeFixtures() -> String? {
        let ours = [capsToF18, rctrlToFn]
        let foreign = Entry(src: 0x7_0000_0064, dst: 0x7_0000_0035)          // someone's § → ` fix
        let clash = Entry(src: 0x7_0000_0039, dst: 0x7_0000_0029)            // someone's caps → escape

        var (merged, applied) = HIDMapping.merge(existing: [], ours: ours)
        if merged != ours || applied != .init(ours: ours, displaced: []) { return "merge into empty: \(merged)" }
        if !HIDMapping.unmerge(current: merged, applied: applied).isEmpty { return "unmerge to empty" }

        (merged, applied) = HIDMapping.merge(existing: [foreign], ours: ours)
        if merged != [foreign] + ours { return "foreign entry not kept: \(merged)" }
        if HIDMapping.unmerge(current: merged, applied: applied) != [foreign] { return "foreign entry not restored" }

        (merged, applied) = HIDMapping.merge(existing: [foreign, clash], ours: ours)
        if merged != [foreign] + ours || applied.displaced != [clash] { return "clash not displaced: \(merged)" }
        if HIDMapping.unmerge(current: merged, applied: applied) != [foreign, clash] { return "clash not restored" }

        // Applying twice (wake, or a start after a crash) must not duplicate.
        let again = HIDMapping.merge(existing: merged, ours: ours)
        if again.merged != merged || !again.applied.displaced.isEmpty { return "second merge changed things: \(again.merged)" }

        // Someone added an entry while ours were in place: it survives the unmerge.
        let later = Entry(src: 0x7_0000_0049, dst: 0x7_0000_004C)
        if HIDMapping.unmerge(current: merged + [later], applied: applied) != [foreign, later, clash] { return "entry added later was lost" }
        // Someone remapped caps themselves meanwhile: don't bring the old clash back.
        let theirs = Entry(src: 0x7_0000_0039, dst: 0x7_0000_002A)
        if HIDMapping.unmerge(current: [foreign, theirs, ours[1]], applied: applied) != [foreign, theirs] { return "restored a clash over a newer entry" }
        return nil
    }

    /// What the system does with a plan: a global write lands on every keyboard.
    private static func simulate(_ snapshot: HIDMapping.Snapshot, _ plan: HIDMapping.Plan) -> HIDMapping.Snapshot {
        var result = snapshot
        if let global = plan.global {
            result.global = global
            for device in result.devices.keys { result.devices[device] = global }
        }
        for (device, entries) in plan.devices { result.devices[device] = entries }
        return result
    }

    private static func sameState(_ a: HIDMapping.Snapshot, _ b: HIDMapping.Snapshot) -> Bool {
        HIDMapping.sameMapping(a.global, b.global) && a.devices.keys == b.devices.keys
            && a.devices.allSatisfy { HIDMapping.sameMapping($0.value, b.devices[$0.key] ?? []) }
    }

    private static func planFixtures() -> String? {
        let board = KeyboardDevice(vendorID: 12815, productID: 20565, name: "Rainy 75")
        let builtIn = KeyboardDevice(vendorID: 1452, productID: 835, name: "Apple Internal Keyboard")
        let mouse = KeyboardDevice(vendorID: 5426, productID: 197, name: "Mouse")
        let userGlobal = Entry(src: 0x7_0000_0064, dst: 0x7_0000_0035)       // set by the user with hidutil
        let userOnMouse = Entry(src: 0x7_0000_0068, dst: 0x7_0000_0069)      // set by the user on one device
        let swapA = Entry(src: 0x7_0000_00E2, dst: 0x7_0000_00E3), swapB = Entry(src: 0x7_0000_00E3, dst: 0x7_0000_00E2)
        let boardCaps = Entry(src: 0x7_0000_0039, dst: 0x7_0000_0029)        // on the board, Caps Lock is Escape instead

        let start = HIDMapping.Snapshot(global: [userGlobal], devices: [board: [userGlobal], builtIn: [userGlobal], mouse: [userGlobal, userOnMouse]])
        let desired = HIDMapping.Desired(global: [capsToF18, rctrlToFn], devices: [board: [swapA, swapB, boardCaps]])

        // Apply.
        let plan = HIDMapping.plan(current: start, previous: nil, desired: desired)
        let applied = simulate(start, plan)
        let wantGlobal = [userGlobal, capsToF18, rctrlToFn]
        let want = HIDMapping.Snapshot(global: wantGlobal, devices: [
            board: [userGlobal, rctrlToFn, swapA, swapB, boardCaps],          // its own Caps Lock rule replaces the global one
            builtIn: wantGlobal,
            mouse: wantGlobal + [userOnMouse],                                // the user's per-device entry survives the global write
        ])
        if !sameState(applied, want) { return "apply gave \(applied)" }
        if plan.devices[builtIn] != nil { return "a keyboard without its own rules was written separately" }
        // Applying again is a no-op with the same record.
        let again = HIDMapping.plan(current: applied, previous: plan.applied, desired: desired)
        if !again.isNoop { return "second apply is not a no-op: \(again)" }
        if again.applied != plan.applied { return "record changed on a no-op: \(again.applied) vs \(plan.applied)" }

        // Someone resets the global mapping behind our back (as `hidutil` without --matching does).
        let clobbered = simulate(applied, .init(global: [userGlobal]))
        let repair = HIDMapping.plan(current: clobbered, previous: plan.applied, desired: desired)
        if !sameState(simulate(clobbered, repair), want) { return "repair after outside reset gave \(simulate(clobbered, repair))" }

        // A rule is switched off: only that entry goes, on every keyboard.
        var fewer = desired
        fewer.global = [rctrlToFn]
        fewer.devices[board] = [boardCaps]
        let shrink = HIDMapping.plan(current: applied, previous: plan.applied, desired: fewer)
        let shrunk = simulate(applied, shrink)
        if !sameState(shrunk, .init(global: [userGlobal, rctrlToFn], devices: [
            board: [userGlobal, rctrlToFn, boardCaps], builtIn: [userGlobal, rctrlToFn], mouse: [userGlobal, rctrlToFn, userOnMouse],
        ])) { return "shrink gave \(shrunk)" }

        // Stop: exactly the starting state comes back, including the user's per-device entry.
        let stop = HIDMapping.plan(current: shrunk, previous: shrink.applied, desired: .init())
        if !sameState(simulate(shrunk, stop), start) { return "stop gave \(simulate(shrunk, stop))" }
        let stopDirect = HIDMapping.plan(current: applied, previous: plan.applied, desired: .init())
        if !sameState(simulate(applied, stopDirect), start) { return "direct stop gave \(simulate(applied, stopDirect))" }

        // Only per-keyboard rules: the global list is never written.
        let onlyBoard = HIDMapping.plan(current: start, previous: nil, desired: .init(devices: [board: [swapA]]))
        if onlyBoard.global != nil || onlyBoard.devices != [board: [userGlobal, swapA]] { return "board-only plan: \(onlyBoard)" }
        let boardState = simulate(start, onlyBoard)
        let boardStop = HIDMapping.plan(current: boardState, previous: onlyBoard.applied, desired: .init())
        if boardStop.global != nil || !sameState(simulate(boardState, boardStop), start) { return "board-only stop: \(boardStop)" }

        // The keyboard is unplugged and comes back with just the global list: its rules are written again.
        var unplugged = applied
        unplugged.devices[board] = nil
        let waiting = HIDMapping.plan(current: unplugged, previous: plan.applied, desired: desired)
        if !waiting.isNoop || !waiting.applied.devices.contains(where: { $0.device == board }) { return "unplugged keyboard: \(waiting)" }
        var replugged = unplugged
        replugged.devices[board] = wantGlobal
        let back = HIDMapping.plan(current: replugged, previous: waiting.applied, desired: desired)
        if !sameState(simulate(replugged, back), want) { return "replug gave \(simulate(replugged, back))" }

        // Nothing to do and nothing recorded on a clean system.
        let nothing = HIDMapping.plan(current: .init(global: [], devices: [board: []]), previous: nil, desired: .init())
        if !nothing.isNoop || !nothing.applied.isEmpty { return "empty plan is not empty: \(nothing)" }
        return nil
    }

    private static func builtInDisableFixtures() -> String? {
        let builtIn = KeyboardDevice(vendorID: 0x5AC, productID: 0x343, name: "Apple Internal Keyboard / Trackpad")
        let external = KeyboardDevice(vendorID: 0x320F, productID: 0x5088, name: "Wireless Gaming Keyboard")
        let mouse = KeyboardDevice(vendorID: 0x1532, productID: 0xC5, name: "Razer DeathAdder V3 HyperSpeed")
        let virtual = KeyboardDevice(vendorID: 0x16C0, productID: 0x27DB, name: "Karabiner VirtualHIDKeyboard")

        let services: [HIDMapping.ServiceInfo] = [
            // Built-in keyboard + built-in trackpad share VID/PID
            .init(device: builtIn, builtIn: true, isKeyboard: true, primaryUsagePage: 1, primaryUsage: 6, transport: "SPI"),
            .init(device: builtIn, builtIn: true, isKeyboard: false, primaryUsagePage: 1, primaryUsage: 2, transport: "SPI"),
            // Gaming mouse exposes both a primary mouse service and keyboard macro interfaces
            .init(device: mouse, builtIn: false, isKeyboard: false, primaryUsagePage: 1, primaryUsage: 2, transport: "USB"),
            .init(device: mouse, builtIn: false, isKeyboard: true, primaryUsagePage: 1, primaryUsage: 6, transport: "USB"),
            // Real external keyboard (two keyboard interfaces, no primary mouse)
            .init(device: external, builtIn: false, isKeyboard: true, primaryUsagePage: 1, primaryUsage: 6, transport: "USB"),
            .init(device: external, builtIn: false, isKeyboard: true, primaryUsagePage: 1, primaryUsage: 6, transport: "USB"),
            // Virtual keyboard
            .init(device: virtual, builtIn: false, isKeyboard: true, primaryUsagePage: 1, primaryUsage: 6, transport: "Virtual"),
        ]
        let classified = HIDMapping.classify(services)
        if classified.builtIn != [builtIn] { return "built-in classified as \(classified.builtIn)" }
        if classified.external != [external] { return "external classified as \(classified.external)" }

        // Only a mouse plugged in: no external keyboard detected.
        let mouseOnly = HIDMapping.classify(services.filter { $0.device != external })
        if !mouseOnly.external.isEmpty { return "mouse-only still found external: \(mouseOnly.external)" }

        // Disable entries cover standard keys + fn + Apple built-in F1–F12 media usages, never touch power.
        let entries = HIDMapping.disableEntries
        if Set(entries.map(\.src)).count != entries.count { return "duplicate src in disableEntries" }
        if !entries.allSatisfy({ $0.dst == HIDMapping.noEvent }) { return "not all disableEntries map to noEvent" }
        for id in ["a", "caps_lock", "fn", "spacebar", "left_command", "volume_increment"] {
            guard let usage = KeyCatalog.key(id)?.usage else { return "missing \(id)" }
            if !entries.contains(where: { $0.src == usage }) { return "disableEntries missing \(id)" }
        }
        for usage: UInt64 in [0xFF_0000_0005, 0xFF_0000_0004, 0xC_0000_0221, 0x1_0000_009B, 0xC_0000_00B4, 0xC_0000_00B3] {
            if !entries.contains(where: { $0.src == usage }) { return "disableEntries missing 0x\(String(usage, radix: 16))" }
        }
        if entries.contains(where: { $0.src == 0xC_0000_0030 }) { return "disableEntries must not map power key" }
        let parsed = HIDMapping.parseFnUsageMap("0x0007003a,0x00ff0005,0x0007003b,0x00ff0004,0x0007003f,0x0001009b,0x00070040,0x000c0030")
        if parsed != [0xFF_0000_0005, 0xFF_0000_0004, 0x1_0000_009B] { return "parseFnUsageMap gave \(parsed)" }

        // Plan round-trip: disabling built-in leaves external untouched, and turning off restores everything.
        let start = HIDMapping.Snapshot(global: [], devices: [builtIn: [], external: []])
        let desiredDisabled = HIDMapping.Desired(global: [rctrlToFn], devices: [builtIn: entries])
        let applyPlan = HIDMapping.plan(current: start, previous: nil, desired: desiredDisabled)
        let disabledState = simulate(start, applyPlan)
        if disabledState.devices[external] != [rctrlToFn] { return "external keyboard mapping changed: \(String(describing: disabledState.devices[external]))" }
        if !(disabledState.devices[builtIn] ?? []).contains(Entry(src: KeyCatalog.key("a")!.usage, dst: HIDMapping.noEvent)) {
            return "built-in keyboard does not have disable entry for A"
        }
        let restorePlan = HIDMapping.plan(current: disabledState, previous: applyPlan.applied, desired: .init(global: [rctrlToFn]))
        let restoredState = simulate(disabledState, restorePlan)
        if !sameState(restoredState, .init(global: [rctrlToFn], devices: [builtIn: [rctrlToFn], external: [rctrlToFn]])) {
            return "turning off disable did not restore built-in keyboard"
        }
        let stopPlan = HIDMapping.plan(current: disabledState, previous: applyPlan.applied, desired: .init())
        if !sameState(simulate(disabledState, stopPlan), start) { return "stopping module did not restore clean state" }
        return nil
    }

    private static func jsonFixtures() -> String? {
        let ours = [Entry(src: 0x7_0000_0039, dst: 0x7_0000_00E4), rctrlToFn]
        let text = HIDMapping.json(ours)
        let want = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771300},"#
            + #"{"HIDKeyboardModifierMappingSrc":30064771300,"HIDKeyboardModifierMappingDst":1095216660483}]}"#
        if text != want { return "json is \(text)" }
        if HIDMapping.json([]) != #"{"UserKeyMapping":[]}"# { return "empty json is \(HIDMapping.json([]))" }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return "json does not parse" }
        if HIDMapping.parse(object[HIDMapping.property]) != ours { return "parse(json) differs" }
        if !HIDMapping.parse(nil).isEmpty || !HIDMapping.parse("junk").isEmpty { return "junk parsed as entries" }
        let partial: [[String: Any]] = [[HIDMapping.srcKey: 1], [HIDMapping.srcKey: 2, HIDMapping.dstKey: 3]]
        if HIDMapping.parse(partial) != [Entry(src: 2, dst: 3)] { return "malformed entry not skipped" }
        if HIDMapping.matching(KeyboardDevice(vendorID: 1452, productID: 835)) != #"{"VendorID":1452,"ProductID":835}"# { return "matching is wrong" }
        return nil
    }

    // MARK: Import

    /// The user's actual ~/.config/karabiner/karabiner.json (complex rule abbreviated to the same shapes).
    private static let userKarabiner = #"""
    {"profiles":[{"name":"Default profile","selected":true,
      "complex_modifications":{"rules":[{"description":"CapsLock as Control + WASD(rainy87)","manipulators":[
        {"conditions":[{"name":"caps_lock pressed","type":"variable_if","value":1}],"from":{"key_code":"w","modifiers":{"optional":["any"]}},"to":[{"key_code":"up_arrow"}],"type":"basic"},
        {"conditions":[{"name":"caps_lock pressed","type":"variable_if","value":1}],"from":{"key_code":"s","modifiers":{"optional":["any"]}},"to":[{"key_code":"down_arrow"}],"type":"basic"},
        {"conditions":[{"name":"caps_lock pressed","type":"variable_if","value":1}],"from":{"key_code":"a","modifiers":{"optional":["any"]}},"to":[{"key_code":"left_arrow"}],"type":"basic"},
        {"conditions":[{"name":"caps_lock pressed","type":"variable_if","value":1}],"from":{"key_code":"d","modifiers":{"optional":["any"]}},"to":[{"key_code":"right_arrow"}],"type":"basic"},
        {"from":{"key_code":"caps_lock","modifiers":{"optional":["any"]}},"to":[{"set_variable":{"name":"caps_lock pressed","value":1}},{"key_code":"left_control"}],"to_after_key_up":[{"set_variable":{"name":"caps_lock pressed","value":0}}],"type":"basic"}]}]},
      "devices":[{"identifiers":{"is_keyboard":true,"is_pointing_device":true,"product_id":12292,"vendor_id":14000},"ignore":false}],
      "simple_modifications":[{"from":{"key_code":"right_control"},"to":[{"apple_vendor_top_case_key_code":"keyboard_fn"}]}],
      "virtual_hid_keyboard":{"keyboard_type_v2":"ansi"}}]}
    """#

    private static func importUserConfig() -> String? {
        let result = KarabinerImport.run(data: Data(userKarabiner.utf8))
        if let error = result.error { return error }
        if result.profile != "Default profile" || !result.skipped.isEmpty { return "skipped: \(result.skipped.map { $0.title + ": " + ($0.skipped ?? "") })" }
        guard result.rules.count == 2, result.items.count == 2 else { return "imported \(result.rules.count) rules" }
        guard case .remap(let remap) = result.rules[0].body, remap == RemapRule(from: "right_control", to: "fn") else { return "simple modification became \(result.rules[0])" }
        guard case .hold(let hold) = result.rules[1].body else { return "complex rule became \(result.rules[1])" }
        // Faithful to Karabiner: Caps Lock is also Control while held, does nothing alone, and the arrows carry Control.
        if hold.trigger != "caps_lock" || hold.holdMods != .control || hold.alone != .nothing { return "hold key imported as \(hold)" }
        let got = hold.mappings.map { "\($0.from.label)>\($0.to.label)" }
        if got != ["W>⌃ Up Arrow", "S>⌃ Down Arrow", "A>⌃ Left Arrow", "D>⌃ Right Arrow"] { return "layer keys are \(got)" }
        if result.rules[1].name != "CapsLock as Control + WASD(rainy87)" || result.items[1].note == nil { return "name or note missing" }
        let program = KeyCompiler.compile(result.rules)
        if program.issues.values.contains(where: { $0.contains(where: \.isError) }) { return "imported rules have errors: \(program.issues)" }
        // And it behaves like the Karabiner rule did.
        var sim = Sim(result.rules)
        sim.send(.keyDown, "f18", f18, gives: [], "caps down")
        sim.send(.keyDown, "a", base, gives: [down("left_arrow", base | ctl | arrow)], "caps+a is control+left")
        sim.send(.keyUp, "a", base, gives: [up("left_arrow", base | ctl | arrow)], "up")
        sim.send(.keyDown, "c", base, gives: [pass(base | ctl)], "caps+c is control+c")
        sim.send(.keyUp, "c", base, gives: [pass(base | ctl)], "up")
        sim.send(.keyUp, "f18", f18, gives: [], "caps alone does nothing")
        // The real file, if present, must import the same way.
        if let data = FileManager.default.contents(atPath: KarabinerImport.defaultPath) {
            let live = KarabinerImport.run(data: data)
            if live.error == nil, live.rules.count + live.skipped.count < live.items.count { return "live config lost items" }
        }
        return sim.failure
    }

    private static func importSkips() -> String? {
        let config = #"""
        {"profiles":[{"name":"Other"},{"name":"Mine","selected":true,
          "simple_modifications":[
            {"from":{"key_code":"caps_lock"},"to":[{"key_code":"escape"}]},
            {"from":{"consumer_key_code":"mute"},"to":[{"key_code":"f13"}]},
            {"from":{"key_code":"f6"},"to":[{"key_code":"a"},{"key_code":"b"}]},
            {"from":{"key_code":"japanese_kana"},"to":[{"key_code":"a"}]}],
          "fn_function_keys":[{"from":{"key_code":"f1"},"to":[{"consumer_key_code":"display_brightness_decrement"}]}],
          "devices":[{"identifiers":{"vendor_id":1452,"product_id":835},"simple_modifications":[{"from":{"key_code":"left_option"},"to":[{"key_code":"left_command"}]}]}],
          "complex_modifications":{"rules":[
            {"description":"Caps dual","manipulators":[{"type":"basic","from":{"key_code":"caps_lock","modifiers":{"optional":["any"]}},"to":[{"key_code":"left_control"}],"to_if_alone":[{"key_code":"escape"}],"parameters":{"basic.to_if_alone_timeout_milliseconds":250}}]},
            {"description":"Hyper","manipulators":[{"type":"basic","from":{"key_code":"right_command"},"to":[{"key_code":"left_shift","modifiers":["left_command","left_control","left_option"]}]}]},
            {"description":"Ctrl-H","manipulators":[{"type":"basic","from":{"key_code":"h","modifiers":{"mandatory":["control"],"optional":["any"]}},"to":[{"key_code":"delete_or_backspace"}],"conditions":[{"type":"frontmost_application_unless","bundle_identifiers":["^com\\.apple\\.Terminal$","^com\\.googlecode\\.iterm2$"]}]}]},
            {"description":"Open Terminal","manipulators":[{"type":"basic","from":{"key_code":"t","modifiers":{"mandatory":["command","option"]}},"to":[{"shell_command":"open -a 'Terminal.app'"}]}]},
            {"description":"Open by id","manipulators":[{"type":"basic","from":{"key_code":"s","modifiers":{"mandatory":["command","option"]}},"to":[{"shell_command":"open -b com.apple.Safari"}]}]},
            {"description":"Shell","manipulators":[{"type":"basic","from":{"key_code":"f5"},"to":[{"shell_command":"say hello"}]}]},
            {"description":"Sequence","manipulators":[{"type":"basic","from":{"key_code":"f7"},"to":[{"key_code":"a"},{"key_code":"b"}]}]},
            {"description":"Simultaneous","manipulators":[{"type":"basic","from":{"simultaneous":[{"key_code":"j"},{"key_code":"k"}]},"to":[{"key_code":"escape"}]}]},
            {"description":"Mouse","manipulators":[{"type":"mouse_motion_to_scroll","from":{"modifiers":{"mandatory":["control"]}}}]},
            {"description":"Regex app","manipulators":[{"type":"basic","from":{"key_code":"f8"},"to":[{"key_code":"a"}],"conditions":[{"type":"frontmost_application_if","bundle_identifiers":["^com\\.jetbrains\\..*$"]}]}]},
            {"description":"Device cond","manipulators":[{"type":"basic","from":{"key_code":"f9"},"to":[{"key_code":"a"}],"conditions":[{"type":"device_if","identifiers":[{"vendor_id":1}]}]}]},
            {"description":"Orphan variable","manipulators":[{"type":"basic","from":{"key_code":"f10"},"to":[{"key_code":"a"}],"conditions":[{"type":"variable_if","name":"nobody sets me","value":1}]}]},
            {"description":"Held down","manipulators":[{"type":"basic","from":{"key_code":"f11"},"to":[{"key_code":"a"}],"to_if_held_down":[{"key_code":"b"}]}]},
            {"description":"Disabled","enabled":false,"manipulators":[{"type":"basic","from":{"key_code":"f12"},"to":[{"key_code":"a"}]}]},
            {"description":"Plain swap","manipulators":[{"type":"basic","from":{"key_code":"f2"},"to":[{"key_code":"f3"}]}]}
          ]}}]}
        """#
        let result = KarabinerImport.run(data: Data(config.utf8)) { $0 == "Terminal.app" ? "com.apple.Terminal" : nil }
        if let error = result.error { return error }
        if result.profile != "Mine" { return "wrong profile: \(result.profile)" }
        // 5 simple + fn keys + 15 complex rules, one item each: nothing vanishes.
        if result.items.count != 21 { return "\(result.items.count) items reported, expected 21: \(result.items.map(\.title))" }
        if result.imported.count != result.rules.count { return "imported items and rules disagree" }
        let titles = result.rules.map(\.summary)
        let want = ["Caps Lock → Escape", "Mute → F13", "Left Option → Left Command", "Caps Lock: tap Escape, hold ⌃",
                    "Right Command → Hyper (⌃⌥⇧⌘)", "⌃ H → Delete (Backspace)", "⌘⌥ T → Open Terminal", "⌘⌥ S → Open Safari", "F2 → F3"]
        if titles.map({ $0.replacingOccurrences(of: "⌥⌘", with: "⌘⌥") }) != want { return "imported \(titles)" }
        guard case .remap(let scoped) = result.rules[2].body, scoped.device == KeyboardDevice(vendorID: 1452, productID: 835) else { return "device scope lost" }
        guard case .hold(let dual) = result.rules[3].body, dual.thresholdMs == 250, dual.alone == .send, dual.tap == .key("escape") else { return "dual-role lost details" }
        guard case .shortcut(let ctrlH) = result.rules[5].body, ctrlH.anyModifiers, ctrlH.apps.mode == .except,
              ctrlH.apps.apps.map(\.bundleID) == ["com.apple.Terminal", "com.googlecode.iterm2"] else { return "app condition lost: \(result.rules[5])" }
        guard case .shortcut(let plain) = result.rules[8].body, !plain.anyModifiers else { return "f2 → f3 without “any” should be an exact shortcut" }
        if result.skipped.count != 12 || result.skipped.contains(where: { ($0.skipped ?? "").isEmpty }) { return "skipped \(result.skipped.count): \(result.skipped.map(\.title))" }
        // Garbage in, explanation out.
        if KarabinerImport.run(data: Data("[]".utf8)).error == nil || KarabinerImport.run(data: Data(#"{"profiles":[{"name":"Empty"}]}"#.utf8)).error == nil {
            return "bad input not reported"
        }
        return nil
    }

    private static func presets() -> String? {
        for preset in KeyPresets.all {
            let rules = preset.instantiate()
            if Set(rules.map(\.id)).intersection(preset.rules.map(\.id)).count > 0 { return "\(preset.title): ids not fresh" }
            let program = KeyCompiler.compile(rules)
            if let issue = program.issues.values.flatMap({ $0 }).first(where: \.isError) { return "\(preset.title): \(issue.text)" }
            if program.remapCount == 0 && !program.needsTap { return "\(preset.title) compiles to nothing" }
        }
        let initial = KeyCompiler.compile(KeyRuleSet.initial.rules)
        if initial.global != [rctrlToFn, capsToF18] || initial.tap.holds.count != 1 { return "initial rules compile to \(initial.global)" }
        return nil
    }

    // MARK: Live

    /// Writes a mapping through hidutil, reads it back, and always puts the
    /// original back — per keyboard too, since a global write resets them. It
    /// uses F23/F24 as sources, keys no keyboard here has, so nothing typed
    /// during the check changes and other apps' entries stay in place.
    private static func liveRoundTrip() -> String? {
        let original = HIDMapping.snapshot()
        let probe = [Entry(src: 0x7_0000_0072, dst: 0x7_0000_00E4), Entry(src: 0x7_0000_0073, dst: 0xFF_0000_0003)]
        let plan = HIDMapping.plan(current: original, previous: nil, desired: .init(global: probe))
        var failure = HIDMapping.execute(plan)
        if failure == nil {
            let seen = HIDMapping.snapshot()
            if !sameState(seen, simulate(original, plan)) { failure = "after the write the system has \(seen.global)" }
            if !original.global.allSatisfy(seen.global.contains) { failure = "existing entries were dropped: \(seen.global)" }
            let undo = HIDMapping.plan(current: seen, previous: plan.applied, desired: .init())
            if failure == nil, let undoFailure = HIDMapping.execute(undo) { failure = undoFailure }
        }
        if let restoreFailure = HIDMapping.restore(original) { return "RESTORE FAILED: \(restoreFailure)" }
        let final = HIDMapping.snapshot()
        if !sameState(final, original) { return "RESTORE FAILED: mapping is \(final), was \(original)" }
        return failure
    }

    private static func liveDeviceRoundTrip() -> String? {
        let original = HIDMapping.snapshot()
        guard let device = original.devices.keys.sorted(by: { $0.id < $1.id }).first else { return nil }     // no keyboard attached
        let probe = [Entry(src: 0x7_0000_0072, dst: 0x7_0000_0073)]
        let plan = HIDMapping.plan(current: original, previous: nil, desired: .init(devices: [device: probe]))
        if plan.global != nil { return "a per-keyboard rule planned a global write" }
        var failure = HIDMapping.execute(plan)
        if failure == nil {
            let seen = HIDMapping.snapshot()
            if !(seen.devices[device] ?? []).contains(probe[0]) { failure = "the keyboard does not have the entry: \(seen.devices[device] ?? [])" }
            if !sameState(seen, simulate(original, plan)) { failure = failure ?? "another keyboard or the global mapping changed" }
            let undo = HIDMapping.plan(current: seen, previous: plan.applied, desired: .init())
            if failure == nil, let undoFailure = HIDMapping.execute(undo) { failure = undoFailure }
            if failure == nil, !sameState(HIDMapping.snapshot(), original) { failure = "undo did not restore the keyboard's list" }
        }
        if let restoreFailure = HIDMapping.restore(original) { return "RESTORE FAILED: \(restoreFailure)" }
        if !sameState(HIDMapping.snapshot(), original) { return "RESTORE FAILED: mapping differs from the start" }
        return failure
    }

    /// Reads the lock state and writes the same value back (a no-op that
    /// proves the call is accepted), and resolves the input source to switch
    /// to without switching.
    private static func liveCapsLock() -> String? {
        guard let on = CapsLock.isOn else { return "Caps Lock state cannot be read" }
        if !CapsLock.set(on) { return "Caps Lock state cannot be set" }
        if CapsLock.isOn != on { return "Caps Lock state changed" }
        _ = CapsLock.switchesInputSource
        _ = CapsLock.inputSourceToSwitchTo()
        if HIDMapping.keyboards().contains(where: { $0.name.isEmpty }) { return "a keyboard has no name" }
        return nil
    }
}
