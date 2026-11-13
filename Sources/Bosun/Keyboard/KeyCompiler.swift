import Foundation

/// What the rules boil down to: entries for the HID event system, a config for
/// the event tap, and anything worth telling the user about a rule.
struct KeyProgram: Equatable {
    struct Issue: Equatable {
        var text: String
        /// An error means the rule (or part of it) is not in effect.
        var isError: Bool
    }
    var global: [HIDMapping.Entry] = []
    var devices: [KeyboardDevice: [HIDMapping.Entry]] = [:]
    /// The entries in `global` that Bosun adds on its own so that a rule on Caps
    /// Lock can see the key: an event tap cannot watch Caps Lock (it toggles, is
    /// delayed, and has no key-up), so it is moved to a function key no keyboard
    /// has, which the tap swallows. They must only be applied while the tap runs —
    /// otherwise Caps Lock would be a dead key.
    var carriers: [HIDMapping.Entry] = []
    var tap = KeyEngine.Config()
    var issues: [String: [Issue]] = [:]

    var needsTap: Bool { !tap.isEmpty }
    var remapCount: Int { global.count + devices.values.reduce(0) { $0 + $1.count } }
}

enum KeyCompiler {
    /// F-keys no Mac keyboard has, used to carry Caps Lock to the event tap.
    static let carrierPool = ["f18", "f19", "f20", "f17", "f16", "f15", "f14", "f13"]

    static func compile(_ rules: [KeyRule]) -> KeyProgram {
        var program = KeyProgram()
        func note(_ rule: KeyRule, _ text: String, error: Bool = false) {
            program.issues[rule.id, default: []].append(.init(text: text, isError: error))
        }
        let active = rules.filter(\.enabled)

        // MARK: Key remaps

        var globalOwner: [UInt64: KeyRule] = [:]
        var deviceOwner: [KeyboardDevice: [UInt64: KeyRule]] = [:]
        for rule in active {
            guard case .remap(let remap) = rule.body else { continue }
            guard let from = KeyCatalog.key(remap.from), let to = KeyCatalog.key(remap.to) else {
                note(rule, "Unknown key “\(KeyCatalog.key(remap.from) == nil ? remap.from : remap.to)”.", error: true)
                continue
            }
            guard from.usage != to.usage else {
                note(rule, "Maps a key to itself.", error: true)
                continue
            }
            let entry = HIDMapping.Entry(src: from.usage, dst: to.usage)
            if let device = remap.device {
                if let owner = deviceOwner[device]?[from.usage] {
                    note(rule, "Not in effect: “\(owner.title)” already remaps \(from.label) on this keyboard.", error: true)
                    continue
                }
                deviceOwner[device, default: [:]][from.usage] = rule
                program.devices[device, default: []].append(entry)
            } else {
                if let owner = globalOwner[from.usage] {
                    note(rule, "Not in effect: “\(owner.title)” already remaps \(from.label).", error: true)
                    continue
                }
                globalOwner[from.usage] = rule
                program.global.append(entry)
            }
        }

        // MARK: Hold keys

        var referenced = Set<String>()
        for rule in rules {
            switch rule.body {
            case .remap(let remap): referenced.formUnion([remap.from, remap.to])
            case .shortcut(let shortcut): referenced.formUnion([shortcut.from.key, shortcut.to.key].compactMap { $0 })
            case .hold(let hold):
                referenced.insert(hold.trigger)
                referenced.formUnion(hold.mappings.flatMap { [$0.from.key, $0.to.key].compactMap { $0 } })
                if let key = hold.tap.key { referenced.insert(key) }
            }
        }
        let caps = KeyCatalog.key("caps_lock")!
        var capsCarrier: KeyInfo?

        for rule in active {
            guard case .hold(let hold) = rule.body else { continue }
            guard var trigger = KeyCatalog.key(hold.trigger) else {
                note(rule, "Unknown key “\(hold.trigger)”.", error: true)
                continue
            }
            if trigger.id == caps.id {
                if let owner = globalOwner[caps.usage], case .remap(let remap) = owner.body, let target = KeyCatalog.key(remap.to) {
                    // The user already turned Caps Lock into something; follow it.
                    trigger = target
                    note(rule, "“\(owner.title)” remaps Caps Lock, so this rule listens for \(target.label).")
                } else if let carrier = capsCarrier {
                    trigger = carrier
                } else {
                    guard let carrier = carrierPool.first(where: { !referenced.contains($0) }).flatMap(KeyCatalog.key) else {
                        note(rule, "No spare function key (F13–F20) is left to carry Caps Lock.", error: true)
                        continue
                    }
                    capsCarrier = carrier
                    let entry = HIDMapping.Entry(src: caps.usage, dst: carrier.usage)
                    program.global.append(entry)
                    program.carriers.append(entry)
                    trigger = carrier
                }
            }
            if hold.trigger != caps.id, let owner = globalOwner[trigger.usage],
               !program.global.contains(where: { $0.dst == trigger.usage }) {
                note(rule, "“\(owner.title)” remaps \(trigger.label) to another key, so pressing it will not reach this rule.")
            }
            guard let keycode = trigger.keycode else {
                note(rule, "\(trigger.label) cannot be watched; pick another hold key.", error: true)
                continue
            }
            guard keycode != KeyCatalog.capsLockKeycode else {
                note(rule, "Caps Lock is remapped to itself.", error: true)
                continue
            }
            var compiled = KeyEngine.Hold(ruleID: rule.id, trigger: keycode)
            compiled.thresholdMs = UInt64(max(50, min(hold.thresholdMs, 2000)))
            compiled.apps = hold.apps
            if let modifier = KeyCatalog.modifierKey(keycode: keycode) {
                compiled.modifier = modifier
                compiled.injected = hold.holdMods.subtracting(modifier.mod)
                if hold.holdAfterThreshold {
                    note(rule, "\(trigger.label) is a modifier key, so holding it takes effect at once.")
                }
            } else {
                compiled.injected = hold.holdMods
                compiled.holdAfterThreshold = hold.holdAfterThreshold
            }
            switch hold.alone {
            case .nothing:
                break
            case .send:
                compiled.tap = action(hold.tap)
                if compiled.tap == nil {
                    note(rule, hold.tap.isEmpty ? "Choose what the key sends when pressed alone."
                                                : "\(hold.tap.label) cannot be sent.", error: true)
                }
            case .normal:
                // A modifier key is never swallowed, so it already acts normally.
                if program.carriers.contains(where: { $0.dst == trigger.usage }) {
                    compiled.tap = .capsLock
                } else if compiled.modifier == nil {
                    compiled.tap = .key(keycode, [])
                }
            }
            for mapping in hold.mappings {
                guard let from = sourceKeycode(mapping.from.key) else {
                    note(rule, "\(KeyCatalog.label(mapping.from.key)) cannot be a layer key.", error: true)
                    continue
                }
                guard let to = action(mapping.to) else {
                    note(rule, "\(mapping.from.label) has no valid output.", error: true)
                    continue
                }
                if compiled.mappings.contains(where: { $0.keycode == from && $0.mods == mapping.from.mods }) {
                    note(rule, "\(mapping.from.label) is listed twice; the first one wins.")
                    continue
                }
                compiled.mappings.append(.init(keycode: from, mods: mapping.from.mods, action: to))
            }
            if compiled.injected.isEmpty && compiled.mappings.isEmpty && (hold.alone == .normal || compiled.tap == nil) {
                note(rule, "Does nothing yet: add layer keys, hold modifiers, or something to send when pressed alone.")
            }
            if let earlier = program.tap.holds.first(where: { $0.trigger == keycode && $0.apps.mode == .all }),
               let owner = rules.first(where: { $0.id == earlier.ruleID }) {
                note(rule, "Never reached: “\(owner.title)” already uses \(trigger.label).", error: true)
                continue
            }
            program.tap.holds.append(compiled)
        }

        // MARK: Shortcuts

        for rule in active {
            guard case .shortcut(let shortcut) = rule.body else { continue }
            guard let keycode = sourceKeycode(shortcut.from.key) else {
                let label = KeyCatalog.label(shortcut.from.key)
                note(rule, "\(label) cannot start a shortcut. For modifier keys use a Tap / Hold rule; for media keys a key remap.", error: true)
                continue
            }
            guard let to = action(shortcut.to) else {
                note(rule, "The output \(shortcut.to.label) cannot be sent.", error: true)
                continue
            }
            if case .key(let target, let mods) = to, target == keycode, mods == shortcut.from.mods {
                note(rule, "Maps a shortcut to itself.", error: true)
                continue
            }
            if let earlier = program.tap.shortcuts.first(where: {
                $0.keycode == keycode && $0.apps.mode == .all && ($0.anyMods
                    ? shortcut.from.mods.isSuperset(of: $0.mods)
                    : !shortcut.anyModifiers && $0.mods == shortcut.from.mods)
            }), let owner = rules.first(where: { $0.id == earlier.ruleID }) {
                note(rule, "Never reached: “\(owner.title)” above matches first.", error: true)
                continue
            }
            program.tap.shortcuts.append(.init(ruleID: rule.id, keycode: keycode, mods: shortcut.from.mods,
                                               anyMods: shortcut.anyModifiers, action: to, apps: shortcut.apps))
        }
        return program
    }

    /// A key the tap can match on: it has a keycode and arrives as key-down/up.
    static func sourceKeycode(_ id: String) -> UInt16? {
        guard let keycode = KeyCatalog.key(id)?.keycode, keycode != KeyCatalog.capsLockKeycode,
              KeyCatalog.modifierKey(keycode: keycode) == nil else { return nil }
        return keycode
    }

    static func action(_ action: KeyAction) -> KeyEngine.Action? {
        if let app = action.app, !app.isEmpty { return .app(app) }
        if action.key.flatMap(KeyCatalog.key)?.keycode == KeyCatalog.capsLockKeycode { return .capsLock }
        guard let key = action.key, let keycode = sourceKeycode(key) else { return nil }
        return .key(keycode, action.mods)
    }
}
