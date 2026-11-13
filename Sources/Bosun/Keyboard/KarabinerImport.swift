import Foundation

/// Reads a Karabiner-Elements `karabiner.json` and turns what maps onto
/// Bosun's rule types into rules. Everything else is reported, never dropped
/// silently.
enum KarabinerImport {
    struct Result: Equatable {
        struct Item: Equatable, Identifiable {
            var id = UUID().uuidString
            var title: String
            /// nil when imported; otherwise why it was skipped.
            var skipped: String?
            var note: String?

            static func == (a: Item, b: Item) -> Bool { a.title == b.title && a.skipped == b.skipped && a.note == b.note }
        }
        var profile = ""
        var rules: [KeyRule] = []
        var items: [Item] = []
        var error: String?

        var imported: [Item] { items.filter { $0.skipped == nil } }
        var skipped: [Item] { items.filter { $0.skipped != nil } }
    }

    static let defaultPath = ("~/.config/karabiner/karabiner.json" as NSString).expandingTildeInPath

    typealias JSON = [String: Any]

    /// `appID` resolves an app name from `open -a Name` to a bundle identifier.
    static func run(data: Data, appID: (String) -> String? = { _ in nil }) -> Result {
        var result = Result()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let profiles = root["profiles"] as? [JSON], !profiles.isEmpty else {
            result.error = "This is not a Karabiner-Elements configuration (no profiles found)."
            return result
        }
        let profile = profiles.first { $0["selected"] as? Bool == true } ?? profiles[0]
        result.profile = profile["name"] as? String ?? "Profile"

        func skip(_ title: String, _ why: String) { result.items.append(.init(title: title, skipped: why)) }
        func add(_ rule: KeyRule, note: String? = nil) {
            result.rules.append(rule)
            result.items.append(.init(title: rule.title + " — " + rule.detail, note: note))
        }

        // MARK: Simple modifications

        func simple(_ list: [JSON], device: KeyboardDevice?) {
            for item in list {
                let title = "Simple modification \(describe(item["from"])) → \(describe(item["to"]))"
                guard let from = keyID(item["from"] as? JSON) else {
                    skip(title, "Bosun does not know the source key.")
                    continue
                }
                let targets = (item["to"] as? [JSON]) ?? (item["to"] as? JSON).map { [$0] } ?? []
                guard targets.count == 1, let to = keyID(targets[0]) else {
                    skip(title, targets.count > 1 ? "It sends several keys." : "Bosun does not know the target key.")
                    continue
                }
                add(KeyRule(.remap(RemapRule(from: from, to: to, device: device))))
            }
        }
        simple(profile["simple_modifications"] as? [JSON] ?? [], device: nil)
        for device in profile["devices"] as? [JSON] ?? [] {
            let ids = device["identifiers"] as? JSON ?? [:]
            let list = device["simple_modifications"] as? [JSON] ?? []
            guard !list.isEmpty else { continue }
            guard let vendor = ids["vendor_id"] as? Int, let product = ids["product_id"] as? Int else {
                skip("Simple modifications for one device", "The device has no vendor and product id.")
                continue
            }
            simple(list, device: KeyboardDevice(vendorID: vendor, productID: product, name: "Keyboard \(vendor):\(product)"))
        }
        let fnKeys = (profile["fn_function_keys"] as? [JSON] ?? []) + (profile["devices"] as? [JSON] ?? []).flatMap { $0["fn_function_keys"] as? [JSON] ?? [] }
        if !fnKeys.isEmpty {
            skip("Function key assignments (\(fnKeys.count))", "Bosun leaves the F-key row to macOS; add key remaps for the ones you need.")
        }

        // MARK: Complex modifications

        let complex = (profile["complex_modifications"] as? JSON)?["rules"] as? [JSON] ?? []
        for rule in complex {
            let name = rule["description"] as? String ?? "Complex rule"
            if rule["enabled"] as? Bool == false {
                skip(name, "It is disabled in Karabiner.")
                continue
            }
            let manipulators = rule["manipulators"] as? [JSON] ?? []
            // Layers are written as "key sets variable" plus "if variable, key → key".
            var layers: [String: HoldRule] = [:]
            var layerOrder: [String] = []
            var pending: [(JSON, String)] = []      // manipulators that depend on a variable
            var index = 0
            for manipulator in manipulators {
                index += 1
                let title = manipulators.count == 1 ? name : "\(name) (#\(index): \(describe(manipulator["from"])))"
                guard manipulator["type"] as? String ?? "basic" == "basic" else {
                    skip(title, "Type “\(manipulator["type"] as? String ?? "?")” (mouse motion to scroll etc.) is not supported.")
                    continue
                }
                for key in ["to_if_held_down", "to_delayed_action"] where manipulator[key] != nil {
                    skip(title, "“\(key)” is not supported.")
                    continue
                }
                if manipulator["to_if_held_down"] != nil || manipulator["to_delayed_action"] != nil { continue }
                let fromSpec = manipulator["from"] as? JSON ?? [:]
                if fromSpec["simultaneous"] != nil {
                    skip(title, "Simultaneous key presses are not supported.")
                    continue
                }
                if fromSpec["pointing_button"] != nil || fromSpec["any"] != nil {
                    skip(title, "Mouse buttons and “any key” sources are not supported.")
                    continue
                }
                guard let fromKey = keyID(fromSpec) else {
                    skip(title, "Bosun does not know the source key.")
                    continue
                }
                let modifiers = fromSpec["modifiers"] as? JSON ?? [:]
                guard let mandatory = mods(modifiers["mandatory"]) else {
                    skip(title, "It requires Caps Lock, fn or “any” as a mandatory modifier.")
                    continue
                }
                let optionalAny = (modifiers["optional"] as? [String] ?? []).contains("any")

                // Conditions: apps and layer variables only.
                var apps = AppFilter()
                var variable: String?
                var unsupported: String?
                for condition in manipulator["conditions"] as? [JSON] ?? [] {
                    switch condition["type"] as? String ?? "" {
                    case "frontmost_application_if", "frontmost_application_unless":
                        guard condition["file_paths"] == nil,
                              let ids = (condition["bundle_identifiers"] as? [String])?.map(bundleID), !ids.contains(nil) else {
                            unsupported = "Its app condition uses a pattern Bosun cannot turn into a list of apps."
                            continue
                        }
                        apps.mode = condition["type"] as? String == "frontmost_application_if" ? .only : .except
                        apps.apps += ids.compactMap { $0 }.map { .init(bundleID: $0, name: $0.split(separator: ".").last.map(String.init) ?? $0) }
                    case "variable_if":
                        if let name = condition["name"] as? String, (condition["value"] as? Int ?? 0) != 0, variable == nil {
                            variable = name
                        } else {
                            unsupported = "It depends on a variable in a way that is not a simple layer."
                        }
                    case let other:
                        unsupported = "Condition “\(other)” is not supported."
                    }
                }
                if let unsupported {
                    skip(title, unsupported)
                    continue
                }

                let to = manipulator["to"] as? [JSON] ?? (manipulator["to"] as? JSON).map { [$0] } ?? []
                let setOn = to.compactMap { $0["set_variable"] as? JSON }.first { ($0["value"] as? Int ?? 0) != 0 }?["name"] as? String
                let afterUp = manipulator["to_after_key_up"] as? [JSON] ?? []
                let alone = manipulator["to_if_alone"] as? [JSON] ?? []
                let keyEvents = to.filter { $0["set_variable"] == nil }

                if let variable {
                    pending.append((manipulator, variable))
                    continue
                }

                // A key that turns a variable on while held is a layer's hold key.
                if let setOn {
                    guard afterUp.contains(where: { ($0["set_variable"] as? JSON)?["name"] as? String == setOn }) else {
                        skip(title, "It sets variable “\(setOn)” but never clears it on key-up, so it is not a hold layer.")
                        continue
                    }
                    guard mandatory.isEmpty, keyEvents.count <= 1 else {
                        skip(title, "A layer key with mandatory modifiers or several outputs is not supported.")
                        continue
                    }
                    var hold = HoldRule(trigger: fromKey, alone: .nothing, apps: apps)
                    if let event = keyEvents.first {
                        guard let held = holdMods(event) else {
                            skip(title, "While held it sends \(describe(event)), which is not a modifier.")
                            continue
                        }
                        hold.holdMods = held
                    }
                    if let first = alone.first {
                        guard alone.count == 1, let action = action(first, appID: appID) else {
                            skip(title, "Its “alone” action cannot be expressed.")
                            continue
                        }
                        hold.alone = .send
                        hold.tap = action
                    }
                    if let ms = (manipulator["parameters"] as? JSON)?["basic.to_if_alone_timeout_milliseconds"] as? Int { hold.thresholdMs = ms }
                    layers[setOn] = hold
                    layerOrder.append(setOn)
                    continue
                }

                guard afterUp.isEmpty else {
                    skip(title, "“to_after_key_up” is only supported for layer variables.")
                    continue
                }
                guard keyEvents.count == 1 else {
                    skip(title, keyEvents.isEmpty ? "It has no output." : "It sends a sequence of \(keyEvents.count) keys; sequences are not supported.")
                    continue
                }
                let target = keyEvents[0]

                // Dual-role: a modifier while held, something else when alone.
                if !alone.isEmpty {
                    guard mandatory.isEmpty, let held = holdMods(target), alone.count == 1,
                          let tap = action(alone[0], appID: appID) else {
                        skip(title, "“to_if_alone” is only supported on keys that act as modifiers while held and send one key alone.")
                        continue
                    }
                    var hold = HoldRule(trigger: fromKey, alone: .send, tap: tap, holdMods: held, apps: apps)
                    if let ms = (manipulator["parameters"] as? JSON)?["basic.to_if_alone_timeout_milliseconds"] as? Int { hold.thresholdMs = ms }
                    add(KeyRule(name: manipulators.count == 1 ? name : "", .hold(hold)))
                    continue
                }

                // Key that just acts as modifiers (a Hyper key without a tap action).
                if mandatory.isEmpty, apps.mode == .all, let held = holdMods(target), held.count > 1 {
                    add(KeyRule(name: manipulators.count == 1 ? name : "",
                                .hold(HoldRule(trigger: fromKey, alone: .nothing, holdMods: held))))
                    continue
                }

                guard let output = action(target, appID: appID) ?? keyID(target).map({ KeyAction.key($0) }) else {
                    skip(title, target["shell_command"] != nil
                         ? "It runs a shell command; Bosun only opens apps (“open -a” / “open -b”)."
                         : "Its output \(describe(target)) cannot be expressed.")
                    continue
                }
                // Plain key → key with nothing else is a key remap, which also works in password fields.
                if mandatory.isEmpty, output.mods.isEmpty, apps.mode == .all, let key = output.key,
                   KeyCompiler.sourceKeycode(fromKey) == nil || KeyCompiler.sourceKeycode(key) == nil || optionalAny {
                    add(KeyRule(name: manipulators.count == 1 ? name : "", .remap(RemapRule(from: fromKey, to: key))))
                    continue
                }
                guard KeyCompiler.action(output) != nil else {
                    skip(title, "Its output \(describe(target)) is a modifier key, which only works as a plain key remap or a hold key.")
                    continue
                }
                guard KeyCompiler.sourceKeycode(fromKey) != nil else {
                    skip(title, "\(KeyCatalog.label(fromKey)) with modifiers or app conditions cannot start a shortcut.")
                    continue
                }
                add(KeyRule(name: manipulators.count == 1 ? name : "",
                            .shortcut(ShortcutRule(from: KeyCombo(key: fromKey, mods: mandatory), anyModifiers: optionalAny,
                                                   to: output, apps: apps))))
            }

            // Attach the variable-dependent manipulators to their layers.
            for (manipulator, variable) in pending {
                let title = "\(name) (\(describe(manipulator["from"])) while “\(variable)”)"
                guard var hold = layers[variable] else {
                    skip(title, "Nothing in this rule turns variable “\(variable)” on with a held key.")
                    continue
                }
                let fromSpec = manipulator["from"] as? JSON ?? [:]
                let to = (manipulator["to"] as? [JSON] ?? []).filter { $0["set_variable"] == nil }
                guard let fromKey = keyID(fromSpec), KeyCompiler.sourceKeycode(fromKey) != nil,
                      let mandatory = mods((fromSpec["modifiers"] as? JSON)?["mandatory"]) else {
                    skip(title, "Its source key cannot be a layer key.")
                    continue
                }
                guard to.count == 1, var output = action(to[0], appID: appID) else {
                    skip(title, to.count > 1 ? "It sends a sequence of keys." : "Its output cannot be expressed.")
                    continue
                }
                guard manipulator["to_if_alone"] == nil, manipulator["to_after_key_up"] == nil else {
                    skip(title, "Extra actions on a layer key are not supported.")
                    continue
                }
                // Karabiner leaves the layer key's modifier down, so the output carries it.
                if output.key != nil { output.mods.formUnion(hold.holdMods) }
                hold.mappings.append(.init(from: KeyCombo(key: fromKey, mods: mandatory), to: output))
                layers[variable] = hold
            }
            for variable in layerOrder {
                guard let hold = layers[variable] else { continue }
                let note = hold.holdMods.isEmpty ? nil
                    : "As in Karabiner, \(KeyCatalog.label(hold.trigger)) also acts as \(hold.holdMods.symbols) while held and does nothing alone. Both are settings of the rule."
                add(KeyRule(name: layerOrder.count == 1 ? name : "\(name) (\(variable))", .hold(hold)), note: note)
            }
        }
        if result.items.isEmpty { result.error = "Profile “\(result.profile)” has no modifications." }
        return result
    }

    // MARK: Pieces

    /// The key named by a Karabiner event (`key_code`, `consumer_key_code`, …).
    static func keyID(_ event: JSON?) -> String? {
        guard let event else { return nil }
        for field in ["key_code", "consumer_key_code", "apple_vendor_top_case_key_code", "apple_vendor_keyboard_key_code"] {
            if let name = event[field] as? String { return KeyCatalog.key(name)?.id }
        }
        return nil
    }

    /// Karabiner modifier names → Mods; nil if one cannot be expressed.
    static func mods(_ value: Any?) -> Mods? {
        var result: Mods = []
        for name in value as? [String] ?? [] {
            switch name.replacingOccurrences(of: "left_", with: "").replacingOccurrences(of: "right_", with: "") {
            case "control": result.insert(.control)
            case "shift": result.insert(.shift)
            case "option", "alt": result.insert(.option)
            case "command", "gui": result.insert(.command)
            default: return nil
            }
        }
        return result
    }

    /// The modifiers an event holds down, if it is nothing but modifiers.
    static func holdMods(_ event: JSON) -> Mods? {
        guard let key = keyID(event), let keycode = KeyCatalog.key(key)?.keycode,
              let modifier = KeyCatalog.modifierKey(keycode: keycode), !modifier.mod.isEmpty,
              let extra = mods(event["modifiers"]) else { return nil }
        return modifier.mod.union(extra)
    }

    /// A `to` event as an action: one non-modifier key with modifiers, or opening an app.
    static func action(_ event: JSON, appID: (String) -> String?) -> KeyAction? {
        if let command = event["shell_command"] as? String {
            let words = command.split(separator: " ", maxSplits: 2).map(String.init)
            guard words.count == 3, words[0] == "open" else { return nil }
            let argument = words[2].trimmingCharacters(in: CharacterSet(charactersIn: "'\" "))
            if words[1] == "-b" { return .openApp(argument, name: argument.split(separator: ".").last.map(String.init) ?? argument) }
            if words[1] == "-a", let id = appID(argument) {
                return .openApp(id, name: argument.replacingOccurrences(of: ".app", with: ""))
            }
            return nil
        }
        guard let key = keyID(event), KeyCompiler.action(.key(key)) != nil, let extra = mods(event["modifiers"]) else { return nil }
        return .key(key, extra)
    }

    /// Karabiner's bundle identifiers are regular expressions; accept the ones
    /// that spell out exactly one identifier.
    static func bundleID(_ pattern: String) -> String? {
        var text = pattern
        guard text.hasPrefix("^"), text.hasSuffix("$") else { return nil }
        text = String(text.dropFirst().dropLast()).replacingOccurrences(of: "\\.", with: ".")
        return text.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil ? text : nil
    }

    static func describe(_ value: Any?) -> String {
        if let list = value as? [JSON] { return list.map { describe($0) }.joined(separator: ", ") }
        guard let event = value as? JSON else { return "?" }
        let name = ["key_code", "consumer_key_code", "apple_vendor_top_case_key_code", "apple_vendor_keyboard_key_code",
                    "pointing_button", "shell_command"].compactMap { event[$0] as? String }.first
        let modifiers = (event["modifiers"] as? JSON)?["mandatory"] as? [String] ?? event["modifiers"] as? [String] ?? []
        if let set = event["set_variable"] as? JSON { return "set \(set["name"] as? String ?? "?")" }
        return (modifiers + [name ?? "?"]).joined(separator: "+")
    }
}
