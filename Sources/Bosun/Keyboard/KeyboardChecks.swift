import Foundation

/// Headless checks for `Bosun --selftest`.
enum KeyboardChecks {
    static let all: [SelfTest.Check] = [
        ("keyboard rewrite: layer keys", rewriteBasics),
        ("keyboard rewrite: hold released before key-up", rewriteRelease),
        ("keyboard rewrite: autorepeat", rewriteRepeat),
        ("keyboard rewrite: plain arrows", rewritePlain),
        ("keyboard rewrite: disabled rules", rewriteDisabled),
        ("keyboard rules: defaults and persistence", rulesRoundTrip),
        ("keyboard mapping: merge and unmerge", mergeFixtures),
        ("keyboard mapping: hidutil JSON and parsing", jsonFixtures),
        ("keyboard mapping: live round trip", liveRoundTrip),
    ]

    // MARK: Rewrite

    private static let base: UInt64 = 0x100                                   // NX_NONCOALSESCEDMASK, always present
    private static let caps = base | RawFlag.control | RawFlag.deviceRightControl
    private static let arrow = RawFlag.numericPad | RawFlag.secondaryFn

    /// Feeds events through the rewriter and compares each output.
    private struct Run {
        var config = KeyRewriter.Config(layers: KeyboardRules.defaults.activeLayers)
        var state = KeyRewriter.State()
        var failure: String?

        mutating func expect(_ kind: KeyRewriter.Kind, _ keycode: UInt16, _ flags: UInt64, repeat isRepeat: Bool = false,
                             gives outKey: UInt16, _ outFlags: UInt64, _ label: String) {
            let out = KeyRewriter.rewrite(kind: kind, keycode: keycode, flags: flags, isRepeat: isRepeat,
                                          config: config, state: &state)
            guard failure == nil, out != .init(keycode: outKey, flags: outFlags) else { return }
            failure = "\(label): got key \(out.keycode) flags 0x\(String(out.flags, radix: 16)),"
                + " want key \(outKey) flags 0x\(String(outFlags, radix: 16))"
        }
    }

    private static func rewriteBasics() -> String? {
        var run = Run()
        for (from, to) in [(KeyCode.w, KeyCode.up), (KeyCode.a, KeyCode.left),
                           (KeyCode.s, KeyCode.down), (KeyCode.d, KeyCode.right)] {
            run.expect(.keyDown, from, caps, gives: to, caps | arrow, "caps+\(from) down")
            run.expect(.keyUp, from, caps, gives: to, caps | arrow, "caps+\(from) up")
            run.expect(.keyDown, from, base, gives: from, base, "plain \(from) down")
            run.expect(.keyUp, from, base, gives: from, base, "plain \(from) up")
        }
        if !run.state.held.isEmpty { return "state not empty after all keys released" }
        // Other modifiers pass through.
        let shifted = caps | RawFlag.shift | RawFlag.command
        run.expect(.keyDown, KeyCode.w, shifted, gives: KeyCode.up, shifted | arrow, "caps+shift+cmd+w")
        run.expect(.keyUp, KeyCode.w, shifted, gives: KeyCode.up, shifted | arrow, "caps+shift+cmd+w up")
        // Keys outside the layer, and the real Left Control, are untouched.
        run.expect(.keyDown, 14, caps, gives: 14, caps, "caps+e")
        let leftControl = base | RawFlag.control | RawFlag.deviceLeftControl
        run.expect(.keyDown, KeyCode.w, leftControl, gives: KeyCode.w, leftControl, "left control+w")
        run.expect(.keyUp, KeyCode.w, leftControl, gives: KeyCode.w, leftControl, "left control+w up")
        run.expect(.flagsChanged, 62, caps, gives: 62, caps, "flagsChanged")
        // Two layer keys at once.
        run.expect(.keyDown, KeyCode.w, caps, gives: KeyCode.up, caps | arrow, "w of w+d")
        run.expect(.keyDown, KeyCode.d, caps, gives: KeyCode.right, caps | arrow, "d of w+d")
        run.expect(.keyUp, KeyCode.w, caps, gives: KeyCode.up, caps | arrow, "w up of w+d")
        run.expect(.keyUp, KeyCode.d, caps, gives: KeyCode.right, caps | arrow, "d up of w+d")
        return run.failure
    }

    private static func rewriteRelease() -> String? {
        var run = Run()
        // Caps released while W is down: the key-up must still be an arrow.
        run.expect(.keyDown, KeyCode.w, caps, gives: KeyCode.up, caps | arrow, "down")
        run.expect(.flagsChanged, 62, base, gives: 62, base, "caps up")
        run.expect(.keyUp, KeyCode.w, base, gives: KeyCode.up, base | arrow, "up after caps released")
        run.expect(.keyUp, KeyCode.w, base, gives: KeyCode.w, base, "stray second key-up")
        // W pressed first, Caps afterwards: it stays a W to the end.
        run.expect(.keyDown, KeyCode.w, base, gives: KeyCode.w, base, "w before caps")
        run.expect(.keyUp, KeyCode.w, caps, gives: KeyCode.w, caps, "w up while caps held")
        // A key-up the tap never saw must not turn the next plain W into an arrow.
        run.expect(.keyDown, KeyCode.w, caps, gives: KeyCode.up, caps | arrow, "down, key-up lost")
        run.expect(.keyDown, KeyCode.w, base, gives: KeyCode.w, base, "fresh plain w after lost key-up")
        run.expect(.keyUp, KeyCode.w, base, gives: KeyCode.w, base, "its key-up")
        return run.failure
    }

    private static func rewriteRepeat() -> String? {
        var run = Run()
        run.expect(.keyDown, KeyCode.a, caps, gives: KeyCode.left, caps | arrow, "down")
        run.expect(.keyDown, KeyCode.a, caps, repeat: true, gives: KeyCode.left, caps | arrow, "repeat")
        run.expect(.keyDown, KeyCode.a, base, repeat: true, gives: KeyCode.left, base | arrow, "repeat after caps released")
        run.expect(.keyUp, KeyCode.a, base, gives: KeyCode.left, base | arrow, "up")
        // Held as a letter, Caps pressed mid-repeat: keeps repeating the letter.
        run.expect(.keyDown, KeyCode.a, base, gives: KeyCode.a, base, "plain down")
        run.expect(.keyDown, KeyCode.a, caps, repeat: true, gives: KeyCode.a, caps, "repeat with caps pressed later")
        run.expect(.keyUp, KeyCode.a, caps, gives: KeyCode.a, caps, "plain up")
        return run.failure
    }

    private static func rewritePlain() -> String? {
        var run = Run()
        run.config.plainArrows = true
        run.expect(.keyDown, KeyCode.s, caps, gives: KeyCode.down, base | arrow, "down")
        run.expect(.keyDown, KeyCode.s, caps, repeat: true, gives: KeyCode.down, base | arrow, "repeat")
        run.expect(.keyUp, KeyCode.s, base, gives: KeyCode.down, base | arrow, "up")
        let shifted = caps | RawFlag.shift
        run.expect(.keyDown, KeyCode.d, shifted, gives: KeyCode.right, base | RawFlag.shift | arrow, "shift kept")
        run.expect(.keyUp, KeyCode.d, shifted, gives: KeyCode.right, base | RawFlag.shift | arrow, "shift kept up")
        // Real Left Control held as well: Control is meant, keep it.
        let both = caps | RawFlag.deviceLeftControl
        run.expect(.keyDown, KeyCode.w, both, gives: KeyCode.up,
                   base | RawFlag.control | RawFlag.deviceLeftControl | arrow, "left control kept")
        run.expect(.keyDown, 14, caps, gives: 14, caps, "caps+e still control+e")
        return run.failure
    }

    private static func rewriteDisabled() -> String? {
        var rules = KeyboardRules.defaults
        rules.layers[0].enabled = false
        if !rules.activeLayers.isEmpty { return "disabled layer still active" }
        rules = .defaults
        rules.remaps[0].enabled = false
        if !rules.activeLayers.isEmpty { return "layer active without the Caps Lock remap" }
        if rules.activeRemaps != [.init(src: HIDUsage.rightControl, dst: HIDUsage.appleFn)] { return "wrong remaps left" }
        var run = Run()
        run.config.layers = []
        run.expect(.keyDown, KeyCode.w, caps, gives: KeyCode.w, caps, "no layers")
        return run.failure
    }

    private static func rulesRoundTrip() -> String? {
        let rules = KeyboardRules.defaults
        let expected: [HIDMapping.Entry] = [.init(src: 0x7_0000_0039, dst: 0x7_0000_00E4),
                                            .init(src: 0x7_0000_00E4, dst: 0xFF_0000_0003)]
        if rules.activeRemaps != expected { return "default remaps are \(rules.activeRemaps)" }
        if rules.activeLayers.count != 1 { return "default layer missing" }
        let suite = "local.jinqiu.Bosun.selftest.keyboard"
        guard let defaults = UserDefaults(suiteName: suite) else { return "no scratch defaults" }
        defer { defaults.removePersistentDomain(forName: suite) }
        if KeyboardRules.load(from: defaults) != .defaults { return "empty store did not give defaults" }
        var changed = rules
        changed.remaps[1].enabled = false
        changed.save(to: defaults)
        if KeyboardRules.load(from: defaults) != changed { return "saved rules did not load back" }
        defaults.set("not json", forKey: KeyboardRules.rulesKey)
        if KeyboardRules.load(from: defaults) != .defaults { return "corrupt store did not give defaults" }
        return nil
    }

    // MARK: Mapping

    private typealias Entry = HIDMapping.Entry

    private static func mergeFixtures() -> String? {
        let ours = KeyboardRules.defaults.activeRemaps
        let foreign = Entry(src: 0x7_0000_0064, dst: 0x7_0000_0035)          // someone's § → ` fix
        let clash = Entry(src: HIDUsage.capsLock, dst: 0x7_0000_0029)        // someone's caps → escape

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
        if HIDMapping.unmerge(current: merged + [later], applied: applied) != [foreign, later, clash] {
            return "entry added later was lost"
        }
        // Someone remapped caps themselves meanwhile: don't bring the old clash back.
        let theirs = Entry(src: HIDUsage.capsLock, dst: 0x7_0000_002A)
        if HIDMapping.unmerge(current: [foreign, theirs, ours[1]], applied: applied) != [foreign, theirs] {
            return "restored a clash over a newer entry"
        }
        // Rule switched off: only the other one is ours.
        var rules = KeyboardRules.defaults
        rules.remaps[1].enabled = false
        (merged, applied) = HIDMapping.merge(existing: [foreign], ours: rules.activeRemaps)
        if merged != [foreign, ours[0]] { return "fn rule off: \(merged)" }
        return nil
    }

    private static func jsonFixtures() -> String? {
        let ours = KeyboardRules.defaults.activeRemaps
        let text = HIDMapping.json(ours)
        let want = #"{"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":30064771129,"HIDKeyboardModifierMappingDst":30064771300},"#
            + #"{"HIDKeyboardModifierMappingSrc":30064771300,"HIDKeyboardModifierMappingDst":1095216660483}]}"#
        if text != want { return "json is \(text)" }
        if HIDMapping.json([]) != #"{"UserKeyMapping":[]}"# { return "empty json is \(HIDMapping.json([]))" }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return "json does not parse"
        }
        if HIDMapping.parse(object[HIDMapping.property]) != ours { return "parse(json) differs" }
        if !HIDMapping.parse(nil).isEmpty || !HIDMapping.parse("junk").isEmpty { return "junk parsed as entries" }
        let partial: [[String: Any]] = [[HIDMapping.srcKey: 1], [HIDMapping.srcKey: 2, HIDMapping.dstKey: 3]]
        if HIDMapping.parse(partial) != [Entry(src: 2, dst: 3)] { return "malformed entry not skipped" }
        return nil
    }

    /// Writes a mapping through hidutil, reads it back, and always puts the
    /// original back. It uses F23/F24 as sources — keys no keyboard here has —
    /// with the real destinations, so nothing typed during the check changes.
    private static func liveRoundTrip() -> String? {
        let original = HIDMapping.read()
        let probe = [Entry(src: HIDUsage.f23, dst: HIDUsage.rightControl),
                     Entry(src: HIDUsage.f24, dst: HIDUsage.appleFn)]
        let (merged, applied) = HIDMapping.merge(existing: original, ours: probe)
        var failure = HIDMapping.write(merged)
        if failure == nil {
            let seen = HIDMapping.read()
            if seen != merged { failure = "read back \(seen), wrote \(merged)" }
        }
        let restored = HIDMapping.unmerge(current: HIDMapping.read(), applied: applied)
        if restored != original { failure = failure ?? "unmerge gave \(restored), original was \(original)" }
        if let restoreFailure = HIDMapping.write(original) { return "RESTORE FAILED: \(restoreFailure)" }
        let final = HIDMapping.read()
        if final != original { return "RESTORE FAILED: mapping is \(final), was \(original)" }
        return failure
    }
}
