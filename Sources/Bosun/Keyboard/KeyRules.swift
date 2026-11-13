import Foundation

// MARK: Building blocks

/// A key with modifiers, as the source of a tap-level rule.
struct KeyCombo: Codable, Hashable {
    var key: String
    var mods: Mods = []

    var label: String { mods.symbols + (mods.isEmpty ? "" : " ") + KeyCatalog.label(key) }
    var shortLabel: String { mods.symbols + KeyCatalog.shortLabel(key) }
}

/// What a tap-level rule produces: a key (with modifiers) or opening an app.
struct KeyAction: Codable, Hashable {
    var key: String?
    var mods: Mods = []
    /// Bundle identifier of the app to open instead of sending a key.
    var app: String?
    var appName: String?

    static func key(_ key: String, _ mods: Mods = []) -> KeyAction { KeyAction(key: key, mods: mods) }
    static func openApp(_ bundleID: String, name: String) -> KeyAction { KeyAction(app: bundleID, appName: name) }

    var isEmpty: Bool { key == nil && app == nil }
    var label: String {
        if let app { return "Open \(appName ?? app)" }
        guard let key else { return "Nothing" }
        return mods.symbols + (mods.isEmpty ? "" : " ") + KeyCatalog.label(key)
    }
    var shortLabel: String {
        if app != nil { return appName ?? "app" }
        return key.map { mods.symbols + KeyCatalog.shortLabel($0) } ?? "–"
    }
}

/// Limits a tap-level rule to some apps.
struct AppFilter: Codable, Hashable {
    enum Mode: String, Codable, CaseIterable { case all, only, except }
    struct App: Codable, Hashable, Identifiable {
        var bundleID: String
        var name: String
        var id: String { bundleID }
    }
    var mode: Mode = .all
    var apps: [App] = []

    func allows(_ bundleID: String?) -> Bool {
        switch mode {
        case .all: true
        case .only: bundleID.map { id in apps.contains { $0.bundleID == id } } ?? false
        case .except: bundleID.map { id in !apps.contains { $0.bundleID == id } } ?? true
        }
    }

    var label: String? {
        guard mode != .all else { return nil }
        let names = apps.map(\.name).joined(separator: ", ")
        return (mode == .only ? "only in " : "except in ") + (names.isEmpty ? "no apps" : names)
    }
}

/// One attached keyboard model, for scoping a key remap.
struct KeyboardDevice: Codable, Hashable, Identifiable {
    var vendorID: Int
    var productID: Int
    var name: String = ""
    var id: String { "\(vendorID):\(productID)" }

    // The name is only a label; two records for the same hardware are equal.
    static func == (a: KeyboardDevice, b: KeyboardDevice) -> Bool { a.vendorID == b.vendorID && a.productID == b.productID }
    func hash(into hasher: inout Hasher) { hasher.combine(vendorID); hasher.combine(productID) }
}

// MARK: Rule types

/// Key → key in the HID event system (`hidutil`). Works everywhere, including
/// password fields, and needs no permission.
struct RemapRule: Codable, Hashable {
    var from: String
    var to: String
    var device: KeyboardDevice?
}

/// Key + modifiers → key + modifiers (or open an app), done by the event tap.
struct ShortcutRule: Codable, Hashable {
    var from: KeyCombo
    /// Also match when more modifiers are held; they carry over to the output.
    var anyModifiers = false
    var to: KeyAction
    var apps = AppFilter()
}

/// A key with a second life while held: it can act as modifiers, turn other
/// keys into something else (a layer), and still send a key when tapped alone.
struct HoldRule: Codable, Hashable {
    struct Mapping: Codable, Hashable, Identifiable {
        var id = UUID().uuidString
        var from: KeyCombo
        var to: KeyAction
    }
    /// What the key does when pressed and released on its own.
    enum Alone: String, Codable, CaseIterable {
        case normal     // what the key always did (Caps Lock stays Caps Lock)
        case nothing
        case send       // `tap`
    }
    var trigger: String
    var alone: Alone = .normal
    /// Sent when pressed alone, if `alone == .send`.
    var tap = KeyAction()
    /// Modifiers the key also acts as while held, for keys that are not in
    /// `mappings` (all four = Hyper). Layer outputs spell out their own modifiers.
    var holdMods: Mods = []
    var mappings: [Mapping] = []
    /// false: hold applies at once, tap fires if released alone within the threshold.
    /// true: a quick press is always a tap (safe for keys you type), hold starts after the threshold.
    var holdAfterThreshold = false
    var thresholdMs = 300
    var apps = AppFilter()

    var aloneLabel: String {
        switch alone {
        case .normal: "normal"
        case .nothing: "nothing"
        case .send: tap.label
        }
    }

    enum Flavor { case hyper, layer, tapHold }
    var flavor: Flavor {
        if holdMods == .hyper && mappings.isEmpty { return .hyper }
        return mappings.isEmpty ? .tapHold : .layer
    }
}

struct KeyRule: Codable, Hashable, Identifiable {
    enum Body: Hashable {
        case remap(RemapRule)
        case shortcut(ShortcutRule)
        case hold(HoldRule)
    }
    var id = UUID().uuidString
    /// Optional user-given name; the summary is shown when empty.
    var name = ""
    var enabled = true
    var body: Body

    var title: String { name.isEmpty ? summary : name }

    var summary: String {
        switch body {
        case .remap(let rule):
            return "\(KeyCatalog.label(rule.from)) → \(KeyCatalog.label(rule.to))"
        case .shortcut(let rule):
            return "\(rule.from.label) → \(rule.to.label)"
        case .hold(let rule):
            let key = KeyCatalog.label(rule.trigger)
            switch rule.flavor {
            case .hyper: return "\(key) → Hyper (⌃⌥⇧⌘)"
            case .layer: return "\(key) layer (\(rule.mappings.count) key\(rule.mappings.count == 1 ? "" : "s"))"
            case .tapHold: return "\(key): tap \(rule.aloneLabel), hold \(rule.holdMods.symbols.isEmpty ? "nothing" : rule.holdMods.symbols)"
            }
        }
    }

    /// The second line of a rule row.
    var detail: String {
        switch body {
        case .remap(let rule):
            return rule.device.map { "Key remap · only \($0.name.isEmpty ? $0.id : $0.name)" } ?? "Key remap · all keyboards"
        case .shortcut(let rule):
            return (["Shortcut"] + (rule.anyModifiers ? ["with any modifiers"] : []) + [rule.apps.label].compactMap { $0 })
                .joined(separator: " · ")
        case .hold(let rule):
            var parts: [String] = []
            if !rule.mappings.isEmpty {
                let shown = rule.mappings.prefix(4).map { "\($0.from.shortLabel)→\($0.to.shortLabel)" }.joined(separator: "  ")
                parts.append(shown + (rule.mappings.count > 4 ? " …" : ""))
            }
            parts.append("alone: \(rule.aloneLabel)")
            if !rule.holdMods.isEmpty { parts.append("held: \(rule.holdMods.symbols)") }
            if let apps = rule.apps.label { parts.append(apps) }
            return parts.isEmpty ? "Does nothing yet" : parts.joined(separator: " · ")
        }
    }

    var symbol: String {
        switch body {
        case .remap: "arrow.right"
        case .shortcut: "command"
        case .hold(let rule): rule.flavor == .hyper ? "sparkles" : rule.flavor == .layer ? "square.stack.3d.up" : "hand.tap"
        }
    }

    // {"id":…,"name":…,"enabled":…,"type":"remap","remap":{…}}
    private enum CodingKeys: String, CodingKey { case id, name, enabled, type, remap, shortcut, hold }

    init(id: String = UUID().uuidString, name: String = "", enabled: Bool = true, _ body: Body) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        switch try c.decode(String.self, forKey: .type) {
        case "remap": body = .remap(try c.decode(RemapRule.self, forKey: .remap))
        case "shortcut": body = .shortcut(try c.decode(ShortcutRule.self, forKey: .shortcut))
        case "hold": body = .hold(try c.decode(HoldRule.self, forKey: .hold))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown rule type \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(enabled, forKey: .enabled)
        switch body {
        case .remap(let rule): try c.encode("remap", forKey: .type); try c.encode(rule, forKey: .remap)
        case .shortcut(let rule): try c.encode("shortcut", forKey: .type); try c.encode(rule, forKey: .shortcut)
        case .hold(let rule): try c.encode("hold", forKey: .type); try c.encode(rule, forKey: .hold)
        }
    }
}

// MARK: Storage

/// The user's rules, in priority order. Stored as a JSON string under
/// `keyboard.ruleset` (the round-one `keyboard.rules` value is migrated once
/// and left in place as a backup).
struct KeyRuleSet: Codable, Equatable {
    var version = 2
    var rules: [KeyRule] = []

    static let key = "keyboard.ruleset"
    static let legacyKey = "keyboard.rules"
    static let legacyPlainArrowsKey = "keyboard.plainArrows"

    /// A fresh install starts with the two rules Bosun shipped with before the
    /// editor existed (the module itself is off until the user enables it).
    static var initial: KeyRuleSet {
        KeyRuleSet(rules: [KeyPresets.rightControlToFn, KeyPresets.capsControlWASD].map {
            var rule = $0
            rule.enabled = true
            return rule
        })
    }

    static func load(from defaults: UserDefaults = .standard) -> KeyRuleSet {
        if let text = defaults.string(forKey: key) {
            if let set = decode(text) { return set }
            // Never let an unreadable store be overwritten without a copy.
            defaults.set(text, forKey: key + ".unreadable")
        }
        if let text = defaults.string(forKey: legacyKey),
           let set = migrate(legacyJSON: text, plainArrows: defaults.bool(forKey: legacyPlainArrowsKey)) {
            set.save(to: defaults)
            return set
        }
        return .initial
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(encoded(), forKey: Self.key)
    }

    func encoded(pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func decode(_ text: String) -> KeyRuleSet? {
        try? JSONDecoder().decode(KeyRuleSet.self, from: Data(text.utf8))
    }

    // MARK: Migration from the round-one format

    private struct Legacy: Decodable {
        struct Remap: Decodable {
            var id: String
            var title: String
            var src: UInt64
            var dst: UInt64
            var enabled: Bool
        }
        struct Layer: Decodable {
            struct Key: Decodable { var from: UInt16; var to: UInt16 }
            var id: String
            var title: String
            var requires: String?
            var holdFlag: UInt64
            var keys: [Key]
            var enabled: Bool
        }
        var remaps: [Remap]
        var layers: [Layer]
    }

    /// Old remaps carry over one to one, keeping their on/off state. An old
    /// layer listened for a modifier that a separate remap had to put on Caps
    /// Lock, which made Caps Lock a real Control key. It becomes a self-contained
    /// layer on the key the user presses, with the modifier spelled out in each
    /// output and the key keeping its normal function when pressed alone; the
    /// remap that only existed to feed it is dropped.
    static func migrate(legacyJSON: String, plainArrows: Bool) -> KeyRuleSet? {
        guard let legacy = try? JSONDecoder().decode(Legacy.self, from: Data(legacyJSON.utf8)) else { return nil }
        var rules: [KeyRule] = []
        var folded = Set<String>()
        for remap in legacy.remaps {
            guard let from = KeyCatalog.key(usage: remap.src), let to = KeyCatalog.key(usage: remap.dst) else { continue }
            rules.append(KeyRule(id: remap.id, name: remap.title, enabled: remap.enabled,
                                 .remap(RemapRule(from: from.id, to: to.id))))
        }
        for layer in legacy.layers {
            // The hold key was identified by its device-dependent flag bit.
            guard let held = KeyCatalog.all.first(where: { info in
                info.keycode.flatMap(KeyCatalog.modifierKey(keycode:)).map { $0.downBit == layer.holdFlag && !$0.mod.isEmpty } ?? false
            }), let heldMod = held.keycode.flatMap(KeyCatalog.modifierKey(keycode:))?.mod else { continue }
            let mappings = layer.keys.compactMap { key -> HoldRule.Mapping? in
                guard let from = KeyCatalog.key(keycode: key.from), let to = KeyCatalog.key(keycode: key.to) else { return nil }
                // The old layer kept the hold modifier on its output unless "plain arrows" was on.
                return HoldRule.Mapping(from: KeyCombo(key: from.id), to: .key(to.id, plainArrows ? [] : heldMod))
            }
            var hold = HoldRule(trigger: held.id, mappings: mappings)
            if let source = legacy.remaps.first(where: { $0.id == layer.requires && $0.dst == held.usage }),
               let physical = KeyCatalog.key(usage: source.src) {
                hold.trigger = physical.id
                folded.insert(source.id)
            }
            rules.append(KeyRule(id: layer.id, name: layer.title, enabled: layer.enabled, .hold(hold)))
        }
        rules.removeAll { folded.contains($0.id) }
        return KeyRuleSet(rules: rules)
    }
}
