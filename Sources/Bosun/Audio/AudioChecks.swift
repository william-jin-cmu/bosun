import CBridge
import CoreAudio
import Foundation

/// Headless checks for `Bosun --selftest`. Silent, need no permission, create
/// no taps, start no audio IO and leave the system exactly as they found it.
enum AudioChecks {
    static let all: [SelfTest.Check] = [
        // System state: read-only, or written back unchanged.
        ("audio: output devices enumerate, default is among them", {
            let outputs = AudioDevices.list(.output)
            guard let current = AudioDevices.defaultDevice(.output) else {
                return outputs.isEmpty ? nil : "\(outputs.count) output devices but no default"
            }
            if let bad = outputs.first(where: { $0.uid.isEmpty || $0.name.isEmpty || $0.streamCount < 1 }) {
                return "device \(bad.id) has empty uid, name or no streams"
            }
            guard Set(outputs.map(\.uid)).count == outputs.count else { return "duplicate device UIDs" }
            if let bad = outputs.first(where: { $0.sampleRate <= 0 }) { return "device \(bad.name) reports no sample rate" }
            if let bad = outputs.first(where: { !$0.sampleRates.isEmpty && !$0.sampleRates.contains($0.sampleRate) }) {
                return "device \(bad.name) runs at \(bad.sampleRate), not one of \(bad.sampleRates)"
            }
            if let bad = outputs.first(where: { $0.balance.map { !(0...1).contains($0) } == true }) {
                return "device \(bad.name) balance out of range"
            }
            // The default may legitimately be a device that is hidden from pickers.
            return outputs.contains(where: { $0.id == current }) || AudioDevices.uid(current) != nil
                ? nil : "default output \(current) has no UID"
        }),
        ("audio: input devices enumerate", {
            let inputs = AudioDevices.list(.input)
            if let bad = inputs.first(where: { $0.uid.isEmpty || $0.name.isEmpty }) { return "input \(bad.id) has empty uid or name" }
            guard let current = AudioDevices.defaultDevice(.input) else { return nil }
            return inputs.contains(where: { $0.id == current }) || AudioDevices.uid(current) != nil
                ? nil : "default input \(current) has no UID"
        }),
        ("audio: every device's volume, mute and balance write back unchanged", {
            for (direction, devices) in [(AudioDevices.Direction.output, AudioDevices.list(.output)),
                                         (.input, AudioDevices.list(.input))] {
                for device in devices {
                    if device.canSetVolume {
                        guard let before = AudioDevices.volume(device.id, direction), (0...1).contains(before) else {
                            return "\(device.name): volume settable but unreadable"
                        }
                        guard AudioDevices.setVolume(device.id, before, direction) else { return "\(device.name): volume write failed" }
                        guard let after = AudioDevices.volume(device.id, direction), abs(after - before) < 0.005 else {
                            return "\(device.name): volume moved from \(before)"
                        }
                    }
                    if device.canMute {
                        guard let before = AudioDevices.isMuted(device.id, direction) else { return "\(device.name): mute unreadable" }
                        guard AudioDevices.setMuted(device.id, before, direction), AudioDevices.isMuted(device.id, direction) == before else {
                            return "\(device.name): mute changed"
                        }
                    }
                    if direction == .output, let before = AudioDevices.balance(device.id) {
                        guard AudioDevices.setBalance(device.id, before), let after = AudioDevices.balance(device.id),
                              abs(after - before) < 0.005 else { return "\(device.name): balance moved from \(before)" }
                    }
                }
            }
            return nil
        }),
        ("audio: default device and sample rate write-back are no-ops", {
            guard let device = AudioDevices.defaultDevice(.input) else { return nil }
            guard AudioDevices.setDefault(device, .input) else { return "setting the same default input failed" }
            guard AudioDevices.defaultDevice(.input) == device else { return "default input changed" }
            guard let rate = AudioDevices.sampleRate(device) else { return "no sample rate on default input" }
            guard AudioDevices.setSampleRate(device, rate), AudioDevices.sampleRate(device) == rate else {
                return "sample rate changed on same-value write"
            }
            return nil
        }),
        ("audio: processes enumerate and group", {
            let processes = AudioProcesses.list()
            if let bad = processes.first(where: { $0.pid <= 0 || $0.objectID == kAudioObjectUnknown }) {
                return "bad process entry \(bad)"
            }
            if processes.contains(where: { $0.pid == getpid() }) { return "own process not excluded" }
            let apps = AudioProcesses.group(processes)
            let grouped = apps.flatMap(\.processObjects)
            guard grouped.count == processes.count, Set(grouped) == Set(processes.map(\.objectID)) else {
                return "grouping lost or duplicated processes (\(processes.count) in, \(grouped.count) out)"
            }
            guard Set(apps.map(\.id)).count == apps.count else { return "duplicate app IDs" }
            return apps.contains(where: { $0.id.isEmpty || $0.name.isEmpty }) ? "app with empty id or name" : nil
        }),
        ("audio: permissions can be read without prompting", {
            // Any answer is fine; this must just not prompt, block or crash.
            _ = AudioCaptureAccess.current()
            _ = AudioMicAccess.status
            return nil
        }),

        // Pure logic.
        ("audio: slider-to-gain curve, snapping and boost limit", {
            guard AudioMath.gain(forSlider: 0) == 0, AudioMath.gain(forSlider: 1) == 1, AudioMath.gain(forSlider: 2) == 4 else {
                return "endpoints wrong"
            }
            guard AudioMath.gain(forSlider: 9) == 4, AudioMath.gain(forSlider: -1) == 0 else { return "not clamped" }
            let steps = (0...200).map { AudioMath.gain(forSlider: Double($0) / 100) }
            guard zip(steps, steps.dropFirst()).allSatisfy({ $0 < $1 }) else { return "not strictly increasing" }
            guard AudioMath.snap(0.99, limit: 2) == 1, AudioMath.snap(1.015, limit: 2) == 1, AudioMath.snap(0.9, limit: 2) == 0.9 else {
                return "snap to 100% wrong"
            }
            guard AudioMath.snap(1.8, limit: 1.5) == 1.5, AudioMath.snap(1.8, limit: 1) == 1, AudioMath.snap(-3, limit: 2) == 0 else {
                return "snap does not respect the boost limit"
            }
            var s = AudioAppSettings()
            s.volume = 2
            guard AudioMath.effectiveGain(s, boostLimit: 1.5) == 2.25, AudioMath.effectiveGain(s, boostLimit: 1) == 1 else {
                return "boost limit not applied to gain"
            }
            s.muted = true
            guard AudioMath.effectiveGain(s, boostLimit: 2) == 0 else { return "mute is not zero gain" }
            guard AudioMath.validBoostLimit(7) == AudioMath.defaultBoostLimit, AudioMath.validRecent(-1) == AudioMath.defaultRecent else {
                return "invalid preferences not replaced by defaults"
            }
            return nil
        }),
        ("audio: sample-rate lists, labels and meter scale", {
            guard AudioMath.discreteRates([(44100, 44100), (48000, 48000), (48000, 48000)]) == [44100, 48000] else { return "discrete rates" }
            guard AudioMath.discreteRates([(44100, 96000)]) == [44100, 48000, 88200, 96000] else { return "ranged rates" }
            guard AudioMath.discreteRates([(0, 0), (5, 1)]).isEmpty else { return "bad ranges accepted" }
            guard AudioMath.rateLabel(44100) == "44.1 kHz", AudioMath.rateLabel(48000) == "48 kHz", AudioMath.rateLabel(0) == "—" else {
                return "rate labels"
            }
            guard AudioMath.meterFraction(peak: 0) == 0, AudioMath.meterFraction(peak: 1) == 1, AudioMath.meterFraction(peak: 4) == 1,
                  AudioMath.meterFraction(peak: 0.001) < 1e-6, abs(AudioMath.meterFraction(peak: 0.0316) - 0.5) < 0.01 else {
                return "meter scale"
            }
            return nil
        }),
        ("audio: saved app settings round-trip and migrate", {
            var a = AudioAppSettings()
            a.volume = 1.4; a.muted = true; a.outputUID = "dev-uid"; a.pinned = true; a.name = "App A"; a.path = "/Applications/A.app"
            var pinnedOnly = AudioAppSettings()
            pinnedOnly.pinned = true
            let original = ["com.a": a, "com.b": pinnedOnly, "com.empty": AudioAppSettings()]
            let encoded = AudioStore.encode(original)
            guard encoded["com.empty"] == nil else { return "empty settings were saved" }
            guard PropertyListSerialization.propertyList(encoded, isValidFor: .binary) else { return "not a property list" }
            let decoded = AudioStore.decode(encoded)
            guard decoded == ["com.a": a, "com.b": pinnedOnly] else { return "round trip changed settings: \(decoded)" }
            let junk: [String: Any] = ["": ["volume": 0.5], "x": 3, "y": ["volume": 99.0], "z": ["volume": Double.nan, "muted": true], "w": ["output": ""]]
            let cleaned = AudioStore.decode(junk)
            guard cleaned.count == 2, cleaned["y"]?.volume == AudioMath.maxSlider, cleaned["z"]?.volume == 1, cleaned["z"]?.muted == true else {
                return "bad stored data not sanitised: \(cleaned)"
            }
            guard AudioStore.decode(nil).isEmpty, AudioStore.decode("nope").isEmpty else { return "non-dictionary accepted" }
            let migrated = AudioStore.migrate(legacyVolumes: ["com.a": 0.3, "com.full": 1.0, "com.bad": -2.0])
            guard migrated.count == 1, migrated["com.a"]?.volume == 0.3 else { return "legacy migration wrong: \(migrated)" }
            return nil
        }),
        ("audio: app list (playing, recent, pinned, customised, saved)", {
            func app(_ id: String, _ name: String, playing: Bool) -> AudioApp {
                AudioApp(id: id, name: name, ownerPID: 100, processObjects: [1], isPlaying: playing)
            }
            let now = Date(timeIntervalSince1970: 10_000)
            let live = [app("play", "Zeta", playing: true), app("recent", "beta", playing: false),
                        app("old", "Old", playing: false), app("quiet", "Quiet", playing: false),
                        app("custom", "Alpha", playing: false), app("pinlive", "Mid", playing: false)]
            var custom = AudioAppSettings(); custom.volume = 0.5
            var pinned = AudioAppSettings(); pinned.pinned = true; pinned.name = "Gone App"
            var pinnedLive = AudioAppSettings(); pinnedLive.pinned = true
            var routedGone = AudioAppSettings(); routedGone.outputUID = "x"; routedGone.name = "Routed"
            let settings = ["custom": custom, "gone": pinned, "pinlive": pinnedLive, "routedgone": routedGone]
            let lastPlayed = ["recent": now.addingTimeInterval(-20), "old": now.addingTimeInterval(-90)]
            let rows = AudioAppList.panelRows(live: live, settings: settings, lastPlayed: lastPlayed, now: now, recentWindow: 60)
            guard rows.map(\.id) == ["custom", "recent", "gone", "pinlive", "play"] else { return "panel rows: \(rows.map(\.id))" }
            guard let gone = rows.first(where: { $0.id == "gone" }), !gone.isLive, gone.isPinned, gone.name == "Gone App", gone.ownerPID == nil else {
                return "pinned app that is not running is wrong"
            }
            guard rows.first(where: { $0.id == "play" })?.isPlaying == true else { return "playing flag lost" }
            let shorter = AudioAppList.panelRows(live: live, settings: settings, lastPlayed: lastPlayed, now: now, recentWindow: 10)
            guard !shorter.contains(where: { $0.id == "recent" }) else { return "recent window not applied" }
            let saved = AudioAppList.savedRows(live: live, settings: settings)
            guard saved.map(\.id) == ["custom", "gone", "pinlive", "routedgone"] else { return "saved rows: \(saved.map(\.id))" }
            guard saved.first(where: { $0.id == "routedgone" })?.isLive == false else { return "saved row for absent app marked live" }
            let expiry = AudioAppList.nextExpiry(live: live, lastPlayed: lastPlayed, now: now, recentWindow: 60)
            guard expiry == now.addingTimeInterval(40) else { return "next expiry \(String(describing: expiry))" }
            guard AudioAppList.nextExpiry(live: live, lastPlayed: ["play": now], now: now, recentWindow: 60) == nil else {
                return "playing app scheduled to expire"
            }
            return nil
        }),
        ("audio: routing plan", {
            let simple = AudioOutputFacts(streamCount: 1, isMultiOutput: false, stereoLeft: 0, stereoRight: 1)
            let multi = AudioOutputFacts(streamCount: 3, isMultiOutput: false, stereoLeft: 2, stereoRight: 3)
            let stacked = AudioOutputFacts(streamCount: 1, isMultiOutput: true, stereoLeft: 0, stereoRight: 1)
            let outputs = ["spk": simple, "hdmi": simple, "pro": multi, "both": stacked]
            var s = AudioAppSettings()
            guard AudioRouting.plan(s, defaultUID: "spk", outputs: outputs) == nil else { return "untouched app got a tap" }
            s.volume = 0.5
            guard AudioRouting.plan(s, defaultUID: "spk", outputs: outputs)
                    == TapPlan(outputUID: "spk", captureUID: "spk", captureStreams: 1, stereoLeft: 0, stereoRight: 1, mirror: false) else {
                return "volume change should tap the default device 1:1"
            }
            guard AudioRouting.plan(s, defaultUID: nil, outputs: outputs) == nil else { return "plan without an output device" }
            guard AudioRouting.plan(s, defaultUID: "gone", outputs: outputs) == nil else { return "plan for a device that is not there" }
            guard let pro = AudioRouting.plan(s, defaultUID: "pro", outputs: outputs), pro.captureUID == "pro", pro.captureStreams == 3 else {
                return "multi-stream device should be tapped stream by stream"
            }
            guard AudioRouting.plan(s, defaultUID: "both", outputs: outputs)?.mirror == true else { return "multi-output device not flagged" }
            s = AudioAppSettings(); s.muted = true
            guard AudioRouting.plan(s, defaultUID: "spk", outputs: outputs)?.captureUID == "spk" else { return "mute needs a tap" }
            s = AudioAppSettings(); s.outputUID = "pro"
            guard AudioRouting.plan(s, defaultUID: "spk", outputs: outputs)
                    == TapPlan(outputUID: "pro", captureUID: nil, captureStreams: 0, stereoLeft: 2, stereoRight: 3, mirror: false) else {
                return "routed app should be mixed down onto the chosen device's stereo pair"
            }
            s.outputUID = "hdmi"
            guard AudioRouting.plan(s, defaultUID: "hdmi", outputs: outputs) == nil else { return "route equal to the default still tapped" }
            s.outputUID = "unplugged"
            guard AudioRouting.plan(s, defaultUID: "spk", outputs: outputs) == nil,
                  AudioRouting.override(s, defaultUID: "spk", outputs: outputs) == nil else {
                return "missing route target should fall back to untouched default"
            }
            s.volume = 1.5
            guard AudioRouting.plan(s, defaultUID: "spk", outputs: outputs)?.outputUID == "spk" else {
                return "missing route target with a volume should play on the default"
            }
            return nil
        }),
        ("audio: watchdog restarts a stalled tap, then lets go", {
            var t = TapWatchdog.Track()
            // Idle app: never an action, however long.
            for _ in 0..<10 where TapWatchdog.step(&t, cycles: 0, expectingIO: false) != .none { return "acted on an idle tap" }
            // Healthy: cycles advance.
            for i in 1...5 where TapWatchdog.step(&t, cycles: UInt64(i * 100), expectingIO: true) != .none { return "acted on a healthy tap" }
            // Stall while the app plays.
            var actions: [TapWatchdog.Action] = []
            for _ in 0..<6 { actions.append(TapWatchdog.step(&t, cycles: 500, expectingIO: true)) }
            guard actions == [.none, .restart, .none, .restart, .none, .giveUp] else { return "stall sequence \(actions)" }
            // A restart that works clears the count.
            t = TapWatchdog.Track()
            _ = TapWatchdog.step(&t, cycles: 0, expectingIO: true)
            guard TapWatchdog.step(&t, cycles: 0, expectingIO: true) == .restart else { return "no restart after stall" }
            guard TapWatchdog.step(&t, cycles: 40, expectingIO: true) == .none, t.restarts == 0 else { return "recovery did not reset" }
            // Pausing in the middle of a stall resets the stall count.
            t = TapWatchdog.Track()
            _ = TapWatchdog.step(&t, cycles: 0, expectingIO: true)
            _ = TapWatchdog.step(&t, cycles: 0, expectingIO: false)
            guard TapWatchdog.step(&t, cycles: 0, expectingIO: true) == .none else { return "stall count survived a pause" }
            return nil
        }),
        ("audio: leftover cleanup only ever targets a dead Bosun's objects", {
            let own: pid_t = 500
            let alive: (pid_t) -> Bool = { $0 == 600 }
            guard TapOrphans.ownerPID(of: "Bosun-Tap-123-ABCD") == 123, TapOrphans.ownerPID(of: "Bosun-Tap-77 Safari") == 77 else {
                return "owner PID not parsed"
            }
            for name in ["Bosun-Tap-", "Bosun-Tap-x12", "Bosun-Tap--5", "BuiltInSpeakerDevice", "Other-Tap-123", "Bosun-Tap-0-x", ""] {
                if TapOrphans.ownerPID(of: name) != nil { return "parsed a PID out of \(name)" }
                if TapOrphans.shouldDestroy(name: name, ownPID: own, isLiveBosun: { _ in false }) { return "would destroy \(name)" }
            }
            guard !TapOrphans.shouldDestroy(name: "Bosun-Tap-500-X", ownPID: own, isLiveBosun: { _ in false }) else { return "would destroy its own objects" }
            guard !TapOrphans.shouldDestroy(name: "Bosun-Tap-600-X", ownPID: own, isLiveBosun: alive) else { return "would destroy a live instance's objects" }
            guard TapOrphans.shouldDestroy(name: "Bosun-Tap-700-X", ownPID: own, isLiveBosun: alive) else { return "dead instance's objects not cleaned" }
            guard AppTap.isLiveBosun(getpid()) else { return "does not recognise itself as live" }
            return nil
        }),

        // DSP: the C code that runs on the IO thread, driven with synthetic buffers.
        ("audio: tap renderer is a bit-exact delayed copy at 100%", { TapRenderChecks.unity() }),
        ("audio: tap renderer ramps gain and maps channels", { TapRenderChecks.gainAndChannels() }),
        ("audio: limiter never exceeds the ceiling when boosting", { TapRenderChecks.limiterCeiling() }),
        ("audio: limiter is transparent below the ceiling and recovers", { TapRenderChecks.limiterTransparency() }),
        ("audio: input meter measures peaks", {
            guard let state = BosunMeterStateCreate() else { return "allocation failed" }
            defer { BosunMeterStateDestroy(state) }
            let list = AudioBufferList.allocate(maximumBuffers: 1)
            defer { free(list.unsafeMutablePointer) }
            var samples: [Float] = [0.1, -0.7, 0.3, 0.2]
            let failure: String? = samples.withUnsafeMutableBytes { raw in
                list[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: raw.baseAddress)
                BosunMeterMeasure(state, list.unsafePointer)
                guard BosunMeterStateTakePeak(state) == 0.7 else { return "peak wrong" }
                guard BosunMeterStateTakePeak(state) == 0 else { return "peak not cleared after reading" }
                BosunMeterMeasure(state, nil)
                return BosunMeterStateCycles(state) == 2 ? nil : "cycles not counted"
            }
            return failure
        }),
    ]
}

/// Drives `BosunTapRender` block by block, as the IO thread would.
enum TapRenderChecks {
    static let block = 512

    /// Renders interleaved input (`channels` wide) into the given output
    /// layout and returns each output channel, flattened across buffers.
    static func render(
        _ state: UnsafeMutableRawPointer, input: [[Float]], outputLayout: [Int],
        gainAt: [Int: Float] = [:]
    ) -> [[Float]] {
        let channels = input.count
        let total = input.first?.count ?? 0
        let outChannels = outputLayout.reduce(0, +)
        var result = [[Float]](repeating: [], count: outChannels)
        let inList = AudioBufferList.allocate(maximumBuffers: 1)
        let outList = AudioBufferList.allocate(maximumBuffers: outputLayout.count)
        defer { free(inList.unsafeMutablePointer); free(outList.unsafeMutablePointer) }
        let inData = UnsafeMutablePointer<Float32>.allocate(capacity: block * max(channels, 1))
        defer { inData.deallocate() }
        let outData = outputLayout.map { UnsafeMutablePointer<Float32>.allocate(capacity: block * $0) }
        defer { outData.forEach { $0.deallocate() } }

        var offset = 0
        var blockIndex = 0
        while offset < total {
            if let gain = gainAt[blockIndex] { BosunTapStateSetGain(state, gain) }
            let frames = min(block, total - offset)
            for f in 0..<frames { for c in 0..<channels { inData[f * channels + c] = input[c][offset + f] } }
            inList[0] = AudioBuffer(mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: inData)
            for (i, width) in outputLayout.enumerated() {
                outData[i].initialize(repeating: 9, count: block * width)     // stale memory must not survive
                outList[i] = AudioBuffer(mNumberChannels: UInt32(width), mDataByteSize: UInt32(frames * width * 4), mData: outData[i])
            }
            BosunTapRender(state, inList.unsafePointer, outList.unsafeMutablePointer)
            var channel = 0
            for (i, width) in outputLayout.enumerated() {
                for c in 0..<width {
                    for f in 0..<frames { result[channel].append(outData[i][f * width + c]) }
                    channel += 1
                }
            }
            offset += frames
            blockIndex += 1
        }
        return result
    }

    static func sine(_ frequency: Double, amplitude: Float, frames: Int, rate: Double = 48000) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * frequency * Double($0) / rate)) }
    }

    static func makeState(gain: Float, rate: Double = 48000) -> UnsafeMutableRawPointer? {
        guard let state = BosunTapStateCreate(gain) else { return nil }
        BosunTapStateConfigure(state, rate)
        return state
    }

    static func unity() -> String? {
        for rate in [44100.0, 48000, 96000, 192000] {
            guard let state = makeState(gain: 1, rate: rate) else { return "allocation failed" }
            defer { BosunTapStateDestroy(state) }
            let delay = Int(BosunTapStateLookahead(state))
            guard delay == min(Int((rate * 0.0015).rounded()), Int(BOSUN_TAP_MAX_LOOKAHEAD)) else { return "look-ahead \(delay) at \(rate)" }
            // Full-scale, even over-full-scale, input: at 100% nothing may be altered.
            let left = sine(997, amplitude: 1.0, frames: 6000, rate: rate)
            let right = sine(61, amplitude: 1.3, frames: 6000, rate: rate)
            let out = render(state, input: [left, right], outputLayout: [2])
            for (source, result) in [(left, out[0]), (right, out[1])] {
                guard result.prefix(delay).allSatisfy({ $0 == 0 }) else { return "delay line did not start silent" }
                guard Array(result.dropFirst(delay)) == Array(source.dropLast(delay)) else { return "not bit-exact at \(rate) Hz" }
            }
            guard BosunTapStateTakeLimiterFloor(state) == 1 else { return "limiter acted at 100%" }
        }
        return nil
    }

    static func gainAndChannels() -> String? {
        guard let state = makeState(gain: 1) else { return "allocation failed" }
        defer { BosunTapStateDestroy(state) }
        let delay = Int(BosunTapStateLookahead(state))
        let frames = block * 4
        let left = [Float](repeating: 0.5, count: frames), right = [Float](repeating: -0.25, count: frames)

        // Gain change at block 1: a monotonic ramp across exactly that block, then steady.
        var out = render(state, input: [left, right], outputLayout: [1, 1], gainAt: [1: 0.25])
        let l = out[0]
        guard l[delay..<(block + delay)].allSatisfy({ $0 == 0.5 }) else { return "audio before the gain change was altered" }
        let ramp = Array(l[(block + delay)..<(2 * block + delay)])
        guard zip(ramp, ramp.dropFirst()).allSatisfy({ $0 > $1 }), ramp[0] < 0.5, ramp[0] > 0.499 else { return "gain change is not a smooth ramp" }
        guard l[(2 * block + delay)...].allSatisfy({ abs($0 - 0.125) < 1e-6 }) else { return "steady gain wrong" }
        guard out[1][(2 * block + delay)...].allSatisfy({ abs($0 + 0.0625) < 1e-6 }) else { return "second channel wrong" }

        // Gain requests are clamped to the maximum boost.
        BosunTapStateSetGain(state, 100)
        let quiet = [Float](repeating: 0.01, count: frames)
        out = render(state, input: [quiet, quiet], outputLayout: [2])
        guard abs(out[0][frames - 1] - 0.01 * BOSUN_TAP_MAX_GAIN) < 1e-6 else { return "gain not clamped to the maximum boost" }

        // Channel mapping, on a fresh state at 100%.
        guard let state = makeState(gain: 1) else { return "allocation failed" }
        defer { BosunTapStateDestroy(state) }
        // Wider output than input: extra channels stay silent.
        out = render(state, input: [left, right], outputLayout: [4])
        guard out[0].last == 0.5, out[1].last == -0.25, out[2].allSatisfy({ $0 == 0 }), out[3].allSatisfy({ $0 == 0 }) else {
            return "mapping to a wider output is wrong"
        }
        // Mono in feeds both front channels.
        out = render(state, input: [left], outputLayout: [2])
        guard out[0].last == 0.5, out[1].last == 0.5 else { return "mono input not copied to both channels" }
        // Stereo mix placed on a chosen pair (channels 3 and 4 of a 6-channel device).
        BosunTapStateSetStereoMap(state, 2, 3, 0)
        out = render(state, input: [left, right], outputLayout: [6])
        guard out[2].last == 0.5, out[3].last == -0.25, [0, 1, 4, 5].allSatisfy({ out[$0].allSatisfy { $0 == 0 } }) else {
            return "stereo pair placement is wrong"
        }
        // A pair that does not exist on the device falls back to 1:1.
        BosunTapStateSetStereoMap(state, 8, 9, 0)
        out = render(state, input: [left, right], outputLayout: [2])
        guard out[0].last == 0.5, out[1].last == -0.25 else { return "out-of-range stereo pair not handled" }
        // Multi-output device: the pair is copied to every stream.
        BosunTapStateSetStereoMap(state, 0, 1, 1)
        out = render(state, input: [left, right], outputLayout: [2, 2, 1])
        guard out[0].last == 0.5, out[1].last == -0.25, out[2].last == 0.5, out[3].last == -0.25, out[4].last == 0.5 else {
            return "mirroring to every stream is wrong"
        }
        BosunTapStateSetStereoMap(state, -1, -1, 0)

        // Input buffers before the tap (a device's own microphone) are never played.
        let micList = AudioBufferList.allocate(maximumBuffers: 2)
        let micOut = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(micList.unsafeMutablePointer); free(micOut.unsafeMutablePointer) }
        var mic = [Float](repeating: 0.9, count: 64), tapIn = [Float](repeating: 0.25, count: 64), played = [Float](repeating: 9, count: 64)
        let micLeak: Bool = mic.withUnsafeMutableBytes { m in tapIn.withUnsafeMutableBytes { t in played.withUnsafeMutableBytes { o in
            micList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 256, mData: m.baseAddress)
            micList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 256, mData: t.baseAddress)
            micOut[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 256, mData: o.baseAddress)
            guard let fresh = makeState(gain: 1) else { return true }
            defer { BosunTapStateDestroy(fresh) }
            BosunTapStateSetInputSkip(fresh, 1)
            for _ in 0..<4 { BosunTapRender(fresh, micList.unsafePointer, micOut.unsafeMutablePointer) }
            return o.bindMemory(to: Float.self).contains { $0 != 0.25 }
        } } }
        guard !micLeak else { return "a device input buffer ahead of the tap reached the output" }

        // No input at all: silence, not stale memory, and the delay line is
        // flushed so old audio cannot come out later.
        let outList = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(outList.unsafeMutablePointer) }
        var scratch = [Float](repeating: 9, count: 64)
        let silent: Bool = scratch.withUnsafeMutableBytes { raw in
            outList[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 64 * 4, mData: raw.baseAddress)
            BosunTapRender(state, nil, outList.unsafeMutablePointer)
            return raw.bindMemory(to: Float.self).allSatisfy { $0 == 0 }
        }
        guard silent else { return "output not cleared when there is no input" }
        out = render(state, input: [[Float](repeating: 0, count: block)], outputLayout: [2])
        guard out[0].allSatisfy({ $0 == 0 }) else { return "stale audio left the delay line after a gap" }
        return nil
    }

    /// Worst case over several signals and rates: the largest output sample.
    static func limiterCeiling() -> String? {
        for rate in [44100.0, 48000, 96000] {
            for gain in [1.2 as Float, 2.25, 4] {
                var signals: [(String, [Float], [Float])] = []
                let n = Int(rate)
                for f in [30.0, 100, 1000, 7000, 15000] {
                    signals.append(("sine \(Int(f)) Hz", sine(f, amplitude: 0.95, frames: n, rate: rate), sine(f * 1.01, amplitude: 0.6, frames: n, rate: rate)))
                }
                // Sudden full-scale burst after silence, a single-sample spike, and a square wave.
                var burst = [Float](repeating: 0, count: n)
                for i in (n / 4)..<(n / 2) { burst[i] = sin(Float(i) * 0.3) }
                burst[n * 3 / 4] = -1
                signals.append(("burst and spike", burst, burst.map { -$0 }))
                signals.append(("square", (0..<n).map { ($0 / 37) % 2 == 0 ? 1 : -1 }, (0..<n).map { ($0 / 91) % 2 == 0 ? 0.8 : -0.8 }))
                // Deterministic noise.
                var seed: UInt32 = 12345
                let noise: [Float] = (0..<n).map { _ in seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 23) - 1 }
                signals.append(("noise", noise, noise.reversed()))

                for (name, left, right) in signals {
                    guard let state = makeState(gain: gain, rate: rate) else { return "allocation failed" }
                    defer { BosunTapStateDestroy(state) }
                    let out = render(state, input: [left, right], outputLayout: [2])
                    let peak = max(out[0].map(abs).max() ?? 0, out[1].map(abs).max() ?? 0)
                    guard peak <= BOSUN_TAP_CEILING else { return "\(name) at gain \(gain), \(Int(rate)) Hz peaked at \(peak)" }
                    guard !out[0].contains(where: { !$0.isFinite }) else { return "\(name): non-finite output" }
                    guard BosunTapStateTakeLimiterFloor(state) < 1 else { return "\(name) at gain \(gain): limiter never engaged" }
                }
            }
        }
        // Gain swept up and down across 100% mid-stream.
        guard let state = makeState(gain: 0.5) else { return "allocation failed" }
        defer { BosunTapStateDestroy(state) }
        let tone = sine(440, amplitude: 1, frames: block * 40)
        let out = render(state, input: [tone, tone], outputLayout: [2], gainAt: [5: 4, 12: 0.2, 20: 2, 30: 1])
        guard (out[0].map(abs).max() ?? 9) <= 1.0 else { return "gain sweep exceeded full scale" }
        return nil
    }

    static func limiterTransparency() -> String? {
        guard let state = makeState(gain: 2) else { return "allocation failed" }
        defer { BosunTapStateDestroy(state) }
        let delay = Int(BosunTapStateLookahead(state))
        let rate = 48000

        // Boosted but still under the ceiling: plain gain, limiter idle.
        let quiet = sine(1000, amplitude: 0.4, frames: rate / 2)
        var out = render(state, input: [quiet, quiet], outputLayout: [2])
        guard zip(out[0].dropFirst(delay), quiet).allSatisfy({ $0 == $1 * 2 }) else { return "limiter altered audio that was under the ceiling" }
        guard BosunTapStateTakeLimiterFloor(state) == 1 else { return "limiter engaged under the ceiling" }

        // Loud passage (+6 dB over), then the same quiet tone: the limiter must
        // let go again. One second later the quiet tone is within 0.2% of 2x,
        // and after two seconds it is bit-exact again.
        let loud = sine(1000, amplitude: 1.0, frames: rate / 2)
        let stream = loud + quiet + quiet + quiet + quiet + quiet
        out = render(state, input: [stream, stream], outputLayout: [2])
        let loudPart = out[0][(rate / 4)..<(rate / 2)].map(abs).max() ?? 0
        guard loudPart <= BOSUN_TAP_CEILING, loudPart > BOSUN_TAP_CEILING * 0.98 else { return "steady loud tone settled at \(loudPart), not at the ceiling" }
        func want(_ index: Int) -> Float { stream[index - delay] * 2 }
        for index in (rate / 2 + rate)..<(rate / 2 + rate + 4800) where abs(out[0][index] - want(index)) > 0.002 * 0.8 {
            return "limiter had not released 1 s after the loud passage"
        }
        for index in (rate / 2 + 2 * rate + rate / 4)..<stream.count where out[0][index] != want(index) {
            return "limiter gain did not return to exactly 1"
        }
        // While limiting a steady tone the gain must be nearly constant (no
        // pumping within a cycle): check the ripple of the limiter gain at 100 Hz.
        guard let bass = makeState(gain: 2) else { return "allocation failed" }
        defer { BosunTapStateDestroy(bass) }
        let low = sine(100, amplitude: 1.0, frames: rate)
        let limited = render(bass, input: [low, low], outputLayout: [2])[0]
        var minGain: Float = 9, maxGain: Float = 0
        for i in (rate / 2)..<rate where abs(low[i - delay]) > 0.3 {
            let g = limited[i] / (low[i - delay] * 2)
            minGain = min(minGain, g); maxGain = max(maxGain, g)
        }
        guard maxGain - minGain < 0.03 else { return "limiter gain ripples by \(maxGain - minGain) on a 100 Hz tone" }
        return nil
    }
}
