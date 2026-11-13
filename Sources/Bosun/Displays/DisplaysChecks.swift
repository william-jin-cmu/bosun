import AppKit
import CoreGraphics

/// Headless checks for `Bosun --selftest`.
enum DisplaysChecks {
    static let all: [SelfTest.Check] = [
        (name: "displays: DDC packet format", run: packetFormat),
        (name: "displays: key step maths", run: stepMaths),
        (name: "displays: DDC range clamps", run: rangeClamps),
        (name: "displays: software dimming split", run: dimmingSplit),
        (name: "displays: brightness sync mapping", run: syncMapping),
        (name: "displays: mute fallback state", run: muteFallback),
        (name: "displays: media key decoding", run: keyDecoding),
        (name: "displays: key routing", run: keyRouting),
        (name: "displays: volume key takeover", run: volumeTakeover),
        (name: "displays: settings storage", run: settingsStorage),
        (name: "displays: readings to state", run: readingsToState),
        (name: "displays: enumerate", run: enumerate),
        (name: "displays: built-in brightness read", run: builtInBrightness),
        (name: "displays: DDC brightness write, read back, restore", run: ddcRoundTrip),
    ]

    /// Known-good bytes: the requests MonitorControl puts on the wire, and a
    /// reply as captured from a real display.
    private static func packetFormat() -> String? {
        let get = DDC.packet(for: [0x10])
        if get != [0x82, 0x01, 0x10, 0xFD] { return "get packet is \(hex(get))" }
        let set = DDC.packet(for: [0x10, 0x00, 0x32])
        if set != [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A] { return "set packet is \(hex(set))" }

        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x00]
        reply[10] = reply[0..<10].reduce(0x50, ^)
        guard let parsed = DDC.parseReply(reply, vcp: 0x10), parsed.current == 75, parsed.max == 100 else {
            return "valid reply did not parse to 75/100"
        }
        if DDC.parseReply(reply, vcp: 0x62) != nil { return "reply for another feature was accepted" }
        var unsupported = reply
        unsupported[3] = 0x01
        unsupported[10] = unsupported[0..<10].reduce(0x50, ^)
        if DDC.parseReply(unsupported, vcp: 0x10) != nil { return "unsupported-feature reply was accepted" }
        var corrupt = reply
        corrupt[9] ^= 0xFF
        if DDC.parseReply(corrupt, vcp: 0x10) != nil { return "reply with a bad checksum was accepted" }
        return nil
    }

    private static func enumerate() -> String? {
        let ids = DisplaysModule.activeDisplayIDs()
        // No displays at all is legitimate (headless session); nothing to check.
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        let services = DDC.externalServices()
        let matched = DDC.match(displays: external, services: services)
        for id in ids {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let name = DisplaysModule.fallbackName(id, builtIn: builtIn)
            Log.info("display \(id): \(name)\(builtIn ? " (built-in)" : matched[id] != nil ? " (DDC channel found)" : " (no DDC channel)")", "displays")
        }
        if Set(matched.values.map { ObjectIdentifier($0) }).count != matched.count {
            return "one DDC channel was matched to two displays"
        }
        // A display that enumerates as external but has no channel is reported,
        // not failed: virtual, AirPlay and Sidecar displays never have one.
        return nil
    }

    private static func builtInBrightness() -> String? {
        guard let id = DisplaysModule.activeDisplayIDs().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            Log.info("no built-in display, skipped", "displays")
            return nil
        }
        guard NativeBrightness.isAvailable else { return "DisplayServices symbols not found" }
        guard let value = NativeBrightness.get(id) else { return "DisplayServicesGetBrightness failed for display \(id)" }
        Log.info("built-in brightness \(Int((value * 100).rounded()))%", "displays")
        return nil
    }

    private static func ddcRoundTrip() -> String? {
        let external = DisplaysModule.activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
        let matched = DDC.match(displays: external, services: DDC.externalServices())
        var tested = 0
        var failures: [String] = []
        for id in external.sorted() {
            guard let service = matched[id], let original = DDC.read(service, vcp: DDC.VCP.brightness), original.max > 0 else {
                continue    // not DDC-capable: shown as "No DDC control" in the panel
            }
            tested += 1
            let name = DisplaysModule.fallbackName(id, builtIn: false)
            let target = original.current >= 5 ? original.current - 5 : original.current + 5

            var failure: String?
            if !DDC.write(service, vcp: DDC.VCP.brightness, value: target) {
                failure = "write of \(target) failed"
            } else if let seen = readBack(service, expecting: target) {
                if seen != target { failure = "wrote \(target), read back \(seen)" }
            } else {
                failure = "read back after writing \(target) failed"
            }

            // Always restore, whatever happened above.
            var restored = false
            for _ in 0..<3 where !restored {
                restored = DDC.write(service, vcp: DDC.VCP.brightness, value: original.current)
                    && readBack(service, expecting: original.current) == original.current
            }
            if !restored {
                failure = (failure.map { $0 + "; " } ?? "") + "COULD NOT RESTORE brightness to \(original.current)"
            }

            Log.info("\(name): brightness \(original.current)/\(original.max), wrote \(target), \(failure ?? "read back matched, restored")", "displays")
            if let failure { failures.append("\(name): \(failure)") }
        }
        if tested == 0 { Log.info("no DDC-capable external display, skipped", "displays") }
        return failures.isEmpty ? nil : failures.joined(separator: " | ")
    }

    /// Displays can take a moment to apply a value; poll briefly for it.
    private static func readBack(_ service: DDC.Service, expecting value: UInt16) -> UInt16? {
        var last: UInt16?
        for _ in 0..<4 {
            usleep(50_000)
            last = DDC.read(service, vcp: DDC.VCP.brightness)?.current ?? last
            if last == value { return last }
        }
        return last
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: Pure logic

    private static func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    private static func stepMaths() -> String? {
        let sixteenth = 1.0 / 16
        let cases: [(current: Double, up: Bool, step: Double, expected: Double)] = [
            (0.5, true, sixteenth, 0.5625),          // on a line: one step
            (0.5, false, sixteenth, 0.4375),
            (0.51, true, sixteenth, 0.5625),         // between lines: snap ahead
            (0.51, false, sixteenth, 0.4375),        // too close to the line behind: skip it
            (0.55, false, sixteenth, 0.5),
            (0.56, true, sixteenth, 0.625),          // too close to the line ahead: skip it
            (1.0, true, sixteenth, 1.0),             // clamps
            (0.0, false, sixteenth, 0.0),
            (0.03, false, sixteenth, 0.0),
            (0.97, true, sixteenth, 1.0),
            (0.5, true, 0.1, 0.6),
            (0.75, true, 0.05, 0.8),                 // 0.75 / 0.05 is not exact in binary
            (0.5, true, DisplayStepMath.step(base: sixteenth, fine: true), 0.515625),
        ]
        for test in cases {
            let result = DisplayStepMath.next(test.current, up: test.up, step: test.step)
            if !near(result, test.expected) {
                return "\(test.current) \(test.up ? "up" : "down") by \(test.step) gave \(result), expected \(test.expected)"
            }
        }
        // Sixteen presses cover the whole range in either direction.
        var value = 0.0
        for _ in 0..<16 { value = DisplayStepMath.next(value, up: true, step: sixteenth) }
        if !near(value, 1) { return "16 steps up from 0 ended at \(value)" }
        for _ in 0..<16 { value = DisplayStepMath.next(value, up: false, step: sixteenth) }
        if !near(value, 0) { return "16 steps down from 1 ended at \(value)" }
        if !near(DisplayStepMath.step(base: 0.1, fine: true), 0.025) { return "fine step is not a quarter" }

        // Smooth writes approach the goal and always arrive.
        var raw: UInt16 = 100
        var writes = 0
        while raw != 94, writes < 20 { raw = DDCWorker.nextStep(from: raw, to: 94, smooth: true); writes += 1 }
        if raw != 94 || writes < 2 { return "smooth ramp 100 to 94 took \(writes) writes, ended at \(raw)" }
        if DDCWorker.nextStep(from: 100, to: 20, smooth: false) != 20 { return "direct write did not jump" }
        if DDCWorker.nextStep(from: nil, to: 20, smooth: true) != 20 { return "smooth write without a known start did not jump" }
        return nil
    }

    private static func rangeClamps() -> String? {
        let full = DDCRange(deviceMax: 100)
        if full.raw(for: 0.5) != 50 || full.raw(for: 2) != 100 || full.raw(for: -1) != 0 { return "full range maps wrongly" }
        if !near(full.fraction(for: 75), 0.75) { return "full range fraction wrong" }
        let clamped = DDCRange(deviceMax: 100, clampMin: 20, clampMax: 80)
        if clamped.raw(for: 0) != 20 || clamped.raw(for: 1) != 80 || clamped.raw(for: 0.5) != 50 { return "clamped range maps wrongly" }
        if !near(clamped.fraction(for: 10), 0) || !near(clamped.fraction(for: 90), 1) { return "values outside the clamp are not pinned" }
        for value in stride(from: UInt16(20), through: 80, by: 1) where clamped.raw(for: clamped.fraction(for: value)) != value {
            return "raw \(value) does not survive a round trip"
        }
        let nonsense = DDCRange(deviceMax: 100, clampMin: 90, clampMax: 10)
        if nonsense.min != 0 || nonsense.max != 100 { return "inverted clamps were not ignored" }
        let beyond = DDCRange(deviceMax: 100, clampMin: -5, clampMax: 500)
        if beyond.min != 0 || beyond.max != 100 { return "clamps beyond the device range were not limited" }
        if DDCRange(deviceMax: 0).max != 1 { return "zero device maximum would divide by zero" }
        return nil
    }

    private static func dimmingSplit() -> String? {
        let off = BrightnessSplit.split(0.4, mode: .off)
        if off.hardware != 0.4 || off.shade != 0 { return "mode off must not shade" }
        let top = BrightnessSplit.split(1, mode: .belowMinimum)
        if top.hardware != 1 || top.shade != 0 { return "full brightness must be full backlight, no shade" }
        let edge = BrightnessSplit.split(BrightnessSplit.softwareShare, mode: .belowMinimum)
        if edge.hardware != 0 || edge.shade != 0 { return "switch point must be minimum backlight, no shade" }
        let bottom = BrightnessSplit.split(0, mode: .belowMinimum)
        if bottom.hardware != 0 || !near(bottom.shade, BrightnessSplit.maxShadeOpacity) { return "zero must be the darkest shade" }
        if BrightnessSplit.maxShadeOpacity >= 1 { return "the shade may never be fully black" }
        let software = BrightnessSplit.split(0.5, mode: .softwareOnly)
        if software.hardware != nil || !near(software.shade, 0.4) { return "software-only must leave the backlight alone" }
        // Monotonic: a lower value is never brighter.
        var previous = (hardware: 2.0, shade: -1.0)
        for step in stride(from: 100, through: 0, by: -1) {
            let split = BrightnessSplit.split(Double(step) / 100, mode: .belowMinimum)
            if split.hardware! > previous.hardware + 1e-9 || split.shade < previous.shade - 1e-9 { return "split is not monotonic at \(step)%" }
            previous = (split.hardware!, split.shade)
        }
        // Reading back: the backlight part comes from the display, the shaded part from memory.
        for value in [1.0, 0.8, 0.5, 0.26] {
            let split = BrightnessSplit.split(value, mode: .belowMinimum)
            if !near(BrightnessSplit.combine(hardware: split.hardware, remembered: 0.1, mode: .belowMinimum), value) {
                return "backlight level for \(value) does not read back"
            }
        }
        if !near(BrightnessSplit.combine(hardware: 0, remembered: 0.1, mode: .belowMinimum), 0.1) { return "shaded level is not remembered" }
        if !near(BrightnessSplit.combine(hardware: 0, remembered: 0.9, mode: .belowMinimum), 0.25) { return "stale memory above the switch point must be capped" }
        if !near(BrightnessSplit.combine(hardware: 0.6, remembered: 0.1, mode: .off), 0.6) { return "mode off must report the backlight" }
        if !near(BrightnessSplit.combine(hardware: nil, remembered: nil, mode: .softwareOnly), 1) { return "an undimmed display must start at full" }
        return nil
    }

    private static func syncMapping() -> String? {
        if !near(DisplaySyncMath.target(source: 0.5, offset: 0.2), 0.7) { return "offset not added" }
        if DisplaySyncMath.target(source: 0.9, offset: 0.3) != 1 || DisplaySyncMath.target(source: 0.1, offset: -0.3) != 0 { return "target not clamped" }
        if !DisplaySyncMath.changed(from: nil, to: 0.5) { return "first reading must count as a change" }
        if DisplaySyncMath.changed(from: 0.5, to: 0.503) { return "jitter must not count as a change" }
        if !DisplaySyncMath.changed(from: 0.5, to: 0.51) { return "a 1% move must count as a change" }
        return nil
    }

    private static func muteFallback() -> String? {
        // Mute stores the volume and goes silent; unmute brings it back.
        let muted = DisplayMuteLogic.toggle(DisplaySoftMute(), volume: 0.4)
        if !muted.state.muted || muted.volume != 0 || muted.state.savedVolume != 0.4 { return "mute did not store the volume" }
        let unmuted = DisplayMuteLogic.toggle(muted.state, volume: 0)
        if unmuted.state.muted || unmuted.volume != 0.4 { return "unmute did not restore the volume" }
        // Muting at volume zero must still unmute to something audible.
        let silent = DisplayMuteLogic.toggle(DisplayMuteLogic.toggle(DisplaySoftMute(), volume: 0).state, volume: 0)
        if silent.volume <= 0 { return "unmute from zero stayed silent" }
        // Turning the volume up, here or on the display itself, ends the mute.
        if DisplayMuteLogic.volumeSet(muted.state, to: 0.2).muted { return "raising the volume did not unmute" }
        if !DisplayMuteLogic.volumeSet(muted.state, to: 0).muted { return "setting zero must stay muted" }
        if DisplayMuteLogic.reconcile(muted.state, hardwareVolume: 0.3).muted { return "an audible display must not be shown as muted" }
        if !DisplayMuteLogic.reconcile(muted.state, hardwareVolume: 0).muted { return "a silent display must stay muted" }
        // Probe: only a write that reads back changed proves hardware mute.
        if DisplayMuteLogic.probe(before: 2, wrote: 1, after: 1) != .hardware { return "working mute not recognised" }
        if DisplayMuteLogic.probe(before: 1, wrote: 2, after: 1) != .fallback { return "ignored write not recognised (the DELL S2725QC case)" }
        if DisplayMuteLogic.probe(before: 1, wrote: 1, after: 1) != .fallback { return "a write of the same value proves nothing" }
        if DisplayMuteLogic.probe(before: nil, wrote: 1, after: nil) != .fallback { return "missing mute feature not recognised" }
        return nil
    }

    private static func keyDecoding() -> String? {
        func data(_ keyType: Int, down: Bool, isRepeat: Bool = false) -> Int { keyType << 16 | (down ? 0x0A : 0x0B) << 8 | (isRepeat ? 1 : 0) }
        let expected: [(Int, DisplayMediaKey)] = [(0, .volumeUp), (1, .volumeDown), (2, .brightnessUp), (3, .brightnessDown), (7, .mute)]
        for (keyType, key) in expected {
            guard let down = DisplayKeyDecode.mediaKey(subtype: 8, data1: data(keyType, down: true)), down.key == key, down.isDown, !down.isRepeat else {
                return "key type \(keyType) down not decoded"
            }
            guard let up = DisplayKeyDecode.mediaKey(subtype: 8, data1: data(keyType, down: false)), up.key == key, !up.isDown else {
                return "key type \(keyType) up not decoded"
            }
        }
        if DisplayKeyDecode.mediaKey(subtype: 8, data1: data(2, down: true, isRepeat: true))?.isRepeat != true { return "repeat flag lost" }
        if DisplayKeyDecode.mediaKey(subtype: 8, data1: data(16, down: true)) != nil { return "play/pause must not be taken" }
        if DisplayKeyDecode.mediaKey(subtype: 7, data1: data(2, down: true)) != nil { return "non-media subtype must not be taken" }
        if DisplayKeyDecode.mediaKey(keyCode: 144, alternateBrightnessKeys: false) != .brightnessUp
            || DisplayKeyDecode.mediaKey(keyCode: 145, alternateBrightnessKeys: false) != .brightnessDown { return "brightness key codes wrong" }
        if DisplayKeyDecode.mediaKey(keyCode: 113, alternateBrightnessKeys: true) != .brightnessUp
            || DisplayKeyDecode.mediaKey(keyCode: 107, alternateBrightnessKeys: true) != .brightnessDown { return "F14/F15 not mapped" }
        if DisplayKeyDecode.mediaKey(keyCode: 113, alternateBrightnessKeys: false) != nil { return "F15 taken although switched off" }
        if DisplayKeyDecode.mediaKey(keyCode: 0, alternateBrightnessKeys: true) != nil { return "letter key taken" }

        // The tap reads subtype and data1 from undocumented CGEvent fields.
        // Build the event the way AppKit does and check they are where we look.
        let flags: NSEvent.ModifierFlags = [.option, .shift]
        guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 8, data1: data(3, down: true, isRepeat: true), data2: -1)?.cgEvent else {
            return "could not build a system-defined event"
        }
        guard let decoded = DisplayKeyTap.decode(type: event.type, event: event, alternateBrightnessKeys: true) else {
            return "CGEvent fields for subtype/data1 have moved (type \(event.type.rawValue))"
        }
        if decoded.key != .brightnessDown || !decoded.isDown || !decoded.isRepeat { return "CGEvent decoded to \(decoded)" }
        if DisplayKeyModifiers(cgFlags: event.flags) != [.option, .shift] { return "modifier flags not carried over" }
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 113, keyDown: true),
              DisplayKeyTap.decode(type: .keyDown, event: keyDown, alternateBrightnessKeys: true)?.key == .brightnessUp else {
            return "F15 key-down event not decoded"
        }
        if DisplayHotKeys.carbonModifiers([.command, .shift]) != 256 + 512 || DisplayHotKeys.carbonModifiers([.option, .control]) != 2048 + 4096 {
            return "hot key modifier flags wrong"
        }
        return nil
    }

    private static let builtIn = DisplayKeyRouting.Display(id: 1, key: "builtin", name: "Built-in", isBuiltIn: true, controls: [.brightness])
    private static let dell = DisplayKeyRouting.Display(id: 3, key: "dell", name: "DELL S2725QC", isBuiltIn: false, controls: [.brightness, .contrast, .volume])
    private static let plain = DisplayKeyRouting.Display(id: 4, key: "plain", name: "Projector", isBuiltIn: false, controls: [])
    private static let second = DisplayKeyRouting.Display(id: 5, key: "lg", name: "LG HDR 4K", isBuiltIn: false, controls: [.brightness, .volume])

    private static func keyRouting() -> String? {
        typealias Decision = DisplayKeyRouting.Decision
        var config = DisplayKeyRouting.Config()
        var env = DisplayKeyRouting.Environment(displays: [builtIn, dell, plain, second], pointerDisplay: 3, focusDisplay: 5)

        func expect(_ what: String, _ key: DisplayMediaKey, _ modifiers: DisplayKeyModifiers = [], _ expected: Decision) -> String? {
            let got = DisplayKeyRouting.decide(key: key, modifiers: modifiers, config: config, env: env)
            return got == expected ? nil : "\(what): got \(got), expected \(expected)"
        }
        func up(_ targets: [CGDirectDisplayID], fine: Bool = false, swallow: Bool = true) -> Decision {
            .handle(action: .brightnessUp, fine: fine, targets: targets, swallow: swallow)
        }

        // Default settings intercept nothing at all.
        for key in [DisplayMediaKey.brightnessUp, .brightnessDown, .volumeUp, .volumeDown, .mute] {
            if let failure = expect("defaults, \(key)", key, [], .passThrough) { return failure }
        }
        if DisplayKeyRouting.needsTap(config, env) { return "defaults must not need an event tap" }

        config.brightnessKeys = true
        if !DisplayKeyRouting.needsTap(config, env) { return "brightness keys with a DDC display need the tap" }
        if DisplayKeyRouting.needsTap(config, DisplayKeyRouting.Environment(displays: [builtIn, plain])) { return "no controllable external display: no tap" }

        let checks: [String?] = [
            expect("pointer on DELL", .brightnessUp, [], up([3])),
            expect("pointer on DELL, down", .brightnessDown, [], .handle(action: .brightnessDown, fine: false, targets: [3], swallow: true)),
            expect("fine step", .brightnessUp, [.option, .shift], up([3], fine: true)),
            expect("option alone opens Settings", .brightnessUp, [.option], .passThrough),
            expect("control is macOS's", .brightnessUp, [.control], .passThrough),
            expect("contrast", .brightnessUp, [.control, .option, .command],
                   .handle(action: .contrastUp, fine: false, targets: [3], swallow: true)),
            expect("volume keys still off", .volumeUp, [], .passThrough),
        ]
        if let failure = checks.compactMap({ $0 }).first { return failure }

        env.pointerDisplay = 1
        if let failure = expect("pointer on built-in", .brightnessUp, [], .passThrough) { return failure }
        env.pointerDisplay = 4
        if let failure = expect("pointer on display without DDC", .brightnessUp, [], .passThrough) { return failure }
        if let failure = expect("contrast on display without it", .brightnessUp, [.control, .option, .command], .passThrough) { return failure }
        env.pointerDisplay = nil
        if let failure = expect("pointer nowhere", .brightnessUp, [], .passThrough) { return failure }

        config.brightnessTarget = .focus
        if let failure = expect("focus on LG", .brightnessUp, [], up([5])) { return failure }
        // All displays: externals are ours, and the event still reaches macOS for the built-in one.
        config.brightnessTarget = .all
        if let failure = expect("all displays", .brightnessUp, [], up([3, 5], swallow: false)) { return failure }
        env.displays = [dell, second]
        if let failure = expect("all displays, lid closed", .brightnessUp, [], up([3, 5])) { return failure }
        env.displays = [builtIn, dell, plain, second]

        config.brightnessTarget = .chosen
        config.brightnessChosen = "lg"
        env.pointerDisplay = 3
        if let failure = expect("chosen LG", .brightnessUp, [], up([5])) { return failure }
        config.brightnessChosen = "unplugged"
        if let failure = expect("chosen display missing falls back to pointer", .brightnessUp, [], up([3])) { return failure }

        // Shortcuts include the built-in display, because nothing else handles them.
        config.brightnessTarget = .all
        if DisplayKeyRouting.shortcutTargets(.brightnessUp, config: config, env: env) != [1, 3, 5] { return "shortcut targets for all displays wrong" }
        if DisplayKeyRouting.shortcutTargets(.contrastUp, config: config, env: env) != [3] { return "contrast shortcut targets wrong" }
        return nil
    }

    private static func volumeTakeover() -> String? {
        var config = DisplayKeyRouting.Config()
        config.volumeKeys = true
        let speakers = DisplayAudioOutput(name: "MacBook Pro Speakers", canSetVolume: true, isDisplayTransport: false)
        let dellAudio = DisplayAudioOutput(name: "DELL S2725QC", canSetVolume: false, isDisplayTransport: true)
        var env = DisplayKeyRouting.Environment(displays: [builtIn, dell, second], pointerDisplay: 5, output: speakers)

        func decide(_ key: DisplayMediaKey, _ modifiers: DisplayKeyModifiers = []) -> DisplayKeyRouting.Decision {
            DisplayKeyRouting.decide(key: key, modifiers: modifiers, config: config, env: env)
        }
        func handled(_ action: DisplayKeyAction, _ targets: [CGDirectDisplayID], fine: Bool = false) -> DisplayKeyRouting.Decision {
            .handle(action: action, fine: fine, targets: targets, swallow: true)
        }

        // The Mac's own speakers: macOS keeps the keys.
        if decide(.volumeUp) != .passThrough || decide(.mute) != .passThrough { return "keys taken although macOS controls the output" }
        // The monitor is the output: it gets the keys, wherever the pointer is.
        env.output = dellAudio
        if decide(.volumeUp) != handled(.volumeUp, [3]) { return "monitor output: got \(decide(.volumeUp))" }
        if decide(.volumeDown, [.option, .shift]) != handled(.volumeDown, [3], fine: true) { return "fine volume step wrong" }
        if decide(.mute) != handled(.muteToggle, [3]) { return "mute not routed" }
        if decide(.volumeUp, [.option]) != .passThrough { return "option alone must open Sound settings" }
        // A numbered duplicate name still matches.
        env.output = DisplayAudioOutput(name: "DELL S2725QC (2)", canSetVolume: false, isDisplayTransport: true)
        if decide(.volumeUp) != handled(.volumeUp, [3]) { return "numbered device name did not match" }
        // Display audio under a name no display has: the display under the pointer.
        env.output = DisplayAudioOutput(name: "HDMI Dock", canSetVolume: false, isDisplayTransport: true)
        if decide(.volumeUp) != handled(.volumeUp, [5]) { return "unnamed display audio: got \(decide(.volumeUp))" }
        // An uncontrollable output that is not a display (a fixed-level DAC) is none of our business.
        env.output = DisplayAudioOutput(name: "USB DAC", canSetVolume: false, isDisplayTransport: false)
        if decide(.volumeUp) != .passThrough { return "non-display output taken" }
        env.output = nil
        if decide(.volumeUp) != .passThrough { return "no output: keys taken" }

        // Explicit choices.
        env.output = speakers
        config.volumeAlways = true
        config.volumeTarget = .pointer
        if decide(.volumeUp) != handled(.volumeUp, [5]) { return "always + pointer wrong" }
        config.volumeTarget = .all
        if decide(.volumeUp) != handled(.volumeUp, [3, 5]) { return "always + all wrong" }
        config.volumeTarget = .chosen
        config.volumeChosen = "dell"
        if decide(.volumeUp) != handled(.volumeUp, [3]) { return "always + chosen wrong" }
        config.volumeTarget = .output
        if decide(.volumeUp) != .passThrough { return "always + output must still need a matching display" }

        // No display with speakers: nothing to do, and no tap for it.
        env.displays = [builtIn, plain]
        if decide(.volumeUp) != .passThrough { return "keys taken with no volume-capable display" }
        if DisplayKeyRouting.needsTap(config, env) { return "tap wanted with no volume-capable display" }

        // A volume shortcut with one capable display just works, whatever the output.
        config = DisplayKeyRouting.Config()
        env = DisplayKeyRouting.Environment(displays: [builtIn, dell], pointerDisplay: 1, output: speakers)
        if DisplayKeyRouting.shortcutTargets(.volumeUp, config: config, env: env) != [3] { return "volume shortcut found no target" }
        if DisplayKeyRouting.normalizedName("DELL U2720Q (2)") != DisplayKeyRouting.normalizedName("dell u2720q") { return "name normalisation wrong" }
        return nil
    }

    private static func settingsStorage() -> String? {
        let defaults = DisplaysConfig()
        // Nothing is intercepted, written or changed automatically out of the box.
        if defaults.brightnessKeys || defaults.volumeKeys || defaults.volumeAlways || defaults.syncEnabled
            || defaults.restore || defaults.smooth || !defaults.shortcuts.isEmpty {
            return "a default setting takes over keys or writes to displays unasked"
        }
        if DisplayPrefs().softwareDimming || !DisplayPrefs().enabled { return "per-display defaults wrong" }
        if DisplaysConfig.decode(nil) != defaults || DisplaysConfig.decode(Data("garbage".utf8)) != defaults { return "bad data must give defaults" }

        var config = defaults
        config.brightnessKeys = true
        config.brightnessTarget = .chosen
        config.brightnessChosen = "4268-41586-1"
        config.stepPercent = 5
        config.shortcuts[DisplayKeyAction.brightnessUp.rawValue] = DisplayShortcut(keyCode: 126, modifiers: [.control, .option], keyLabel: "↑")
        var prefs = DisplayPrefs()
        prefs.friendlyName = "Desk"
        prefs.clampMin[DisplayControl.brightness.rawValue] = 10
        prefs.muteSupport = .fallback
        prefs.softMute = DisplaySoftMute(muted: true, savedVolume: 0.3)
        prefs.last[DisplayControl.contrast.rawValue] = 0.75
        config.displays["4268-41586-1"] = prefs
        guard let data = config.encoded() else { return "could not encode" }
        if DisplaysConfig.decode(data) != config { return "settings do not survive a round trip" }

        // Data from an older build with fewer fields keeps what it has and
        // gets defaults for the rest.
        let old = #"{"brightnessKeys":true,"displays":{"x":{"friendlyName":"Old"}}}"#
        let upgraded = DisplaysConfig.decode(Data(old.utf8))
        if !upgraded.brightnessKeys || upgraded.stepPercent != 6.25 || upgraded.prefs("x").friendlyName != "Old"
            || !upgraded.prefs("x").enabled || upgraded.prefs("x").muteSupport != .unknown {
            return "partial settings did not merge with defaults"
        }
        if config.prefs("4268-41586-1").range(.brightness, deviceMax: 100).min != 10 { return "clamp not applied to range" }
        if config.shortcuts[DisplayKeyAction.brightnessUp.rawValue]?.label != "⌃⌥↑" { return "shortcut label wrong" }
        return nil
    }

    private static func readingsToState() -> String? {
        var raw = RawDisplay(id: 3, key: "dell", systemName: "DELL S2725QC", isBuiltIn: false)
        raw.readings = [.brightness: .init(current: 50, max: 100), .contrast: .init(current: 75, max: 100), .volume: .init(current: 6, max: 100)]
        raw.mute = 1                // what the DELL always reports
        raw.input = 0x1B1B          // Dell puts vendor data in the high byte

        var prefs = DisplayPrefs()
        var state = DisplaysModule.state(from: raw, prefs: prefs)
        if state.control != .ddc || !near(state.brightness, 0.5) || state.contrast != 0.75 || state.volume != 0.06 { return "plain readings mapped wrongly: \(state)" }
        if state.muted { return "an unverified mute report must not be shown as muted" }
        if state.input != 0x1B || DisplayInputSource.name(0x1B) != "USB-C" { return "input source not taken from the low byte" }

        prefs.muteSupport = .hardware
        if !DisplaysModule.state(from: raw, prefs: prefs).muted { return "verified hardware mute not shown" }

        prefs.muteSupport = .fallback
        prefs.softMute = DisplaySoftMute(muted: true, savedVolume: 0.3)
        if DisplaysModule.state(from: raw, prefs: prefs).muted { return "audible display shown as muted" }
        raw.readings[.volume] = .init(current: 0, max: 100)
        state = DisplaysModule.state(from: raw, prefs: prefs)
        if !state.muted || state.volume != 0 { return "volume-zero mute not shown" }

        prefs = DisplayPrefs()
        prefs.friendlyName = " Desk "
        prefs.clampMin[DisplayControl.brightness.rawValue] = 50
        state = DisplaysModule.state(from: raw, prefs: prefs)
        if state.name != "Desk" || state.systemName != "DELL S2725QC" { return "friendly name not applied" }
        if state.brightness != 0 { return "clamped minimum must read as 0%" }

        prefs = DisplayPrefs()
        prefs.softwareDimming = true
        prefs.last[DisplayControl.brightness.rawValue] = 0.1
        raw.readings[.brightness] = .init(current: 0, max: 100)
        if !near(DisplaysModule.state(from: raw, prefs: prefs).brightness, 0.1) { return "software-dimmed level not restored from memory" }
        raw.readings[.brightness] = .init(current: 100, max: 100)
        if !near(DisplaysModule.state(from: raw, prefs: prefs).brightness, 1) { return "full backlight must read as 100% with dimming on" }

        prefs = DisplayPrefs()
        prefs.enabled = false
        state = DisplaysModule.state(from: raw, prefs: prefs)
        if state.control != .none || state.volume != nil { return "a display the user turned off must expose no controls" }

        var silent = RawDisplay(id: 4, key: "plain", systemName: "Projector", isBuiltIn: false)
        if DisplaysModule.state(from: silent, prefs: DisplayPrefs()).control != .none { return "display without DDC must have no control" }
        prefs = DisplayPrefs()
        prefs.softwareDimming = true
        if DisplaysModule.state(from: silent, prefs: prefs).control != .software { return "software dimming not offered without DDC" }
        silent.isBuiltIn = true
        silent.native = 0.8
        state = DisplaysModule.state(from: silent, prefs: prefs)
        if state.control != .native || state.brightness != 0.8 { return "built-in display mapped wrongly" }
        return nil
    }
}

