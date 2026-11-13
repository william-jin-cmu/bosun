import CBridge
import CoreAudio
import Foundation

/// Headless checks for `Bosun --selftest`. Silent, need no permission, create
/// no taps and leave the system exactly as they found it.
enum AudioChecks {
    static let all: [SelfTest.Check] = [
        ("audio: output devices enumerate, default is among them", {
            let outputs = AudioDevices.list(.output)
            guard let current = AudioDevices.defaultDevice(.output) else {
                return outputs.isEmpty ? nil : "\(outputs.count) output devices but no default"
            }
            guard outputs.contains(where: { $0.id == current }) else {
                return "default output \(current) not in list \(outputs.map(\.id))"
            }
            if let bad = outputs.first(where: { $0.uid.isEmpty || $0.name.isEmpty }) {
                return "device \(bad.id) has empty uid or name"
            }
            return Set(outputs.map(\.uid)).count == outputs.count ? nil : "duplicate device UIDs"
        }),
        ("audio: input devices enumerate", {
            let inputs = AudioDevices.list(.input)
            guard let current = AudioDevices.defaultDevice(.input) else { return nil }
            return inputs.contains(where: { $0.id == current }) ? nil : "default input \(current) not in list"
        }),
        ("audio: master volume reads and writes back unchanged", {
            guard let device = AudioDevices.defaultDevice(.output) else { return nil }
            guard AudioDevices.canSetVolume(device) else { return nil }   // e.g. HDMI: nothing to check
            guard let before = AudioDevices.volume(device) else { return "volume is settable but not readable" }
            guard (0...1).contains(before) else { return "volume \(before) out of range" }
            guard AudioDevices.setVolume(device, before) else { return "writing the same volume failed" }
            guard let after = AudioDevices.volume(device) else { return "volume unreadable after write" }
            return abs(after - before) < 0.005 ? nil : "volume moved from \(before) to \(after)"
        }),
        ("audio: mute reads and writes back unchanged", {
            guard let device = AudioDevices.defaultDevice(.output), AudioDevices.canMute(device) else { return nil }
            guard let before = AudioDevices.isMuted(device) else { return "mute is settable but not readable" }
            guard AudioDevices.setMuted(device, before) else { return "writing the same mute state failed" }
            return AudioDevices.isMuted(device) == before ? nil : "mute state changed"
        }),
        ("audio: default device write-back is a no-op", {
            guard let device = AudioDevices.defaultDevice(.input) else { return nil }
            guard AudioDevices.setDefault(device, .input) else { return "setting the same default input failed" }
            return AudioDevices.defaultDevice(.input) == device ? nil : "default input changed"
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
        ("audio: capture permission can be read without prompting", {
            // Any answer is fine; this must just not prompt, block or crash.
            _ = AudioCaptureAccess.current()
            return nil
        }),
        ("audio: slider-to-gain curve", {
            guard AudioMath.gain(forSlider: 0) == 0, AudioMath.gain(forSlider: 1) == 1 else { return "endpoints wrong" }
            guard AudioMath.gain(forSlider: 1.5) == 1, AudioMath.gain(forSlider: -1) == 0 else { return "not clamped" }
            let steps = (0...100).map { AudioMath.gain(forSlider: Double($0) / 100) }
            return zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 } ? nil : "not strictly increasing"
        }),
        ("audio: tap renderer scales, ramps and maps channels", { rendererCheck() }),
    ]

    /// Drives the C render function (the code that runs on the IO thread) with
    /// synthetic buffers. No audio device is involved.
    private static func rendererCheck() -> String? {
        let frames = 256
        guard let state = BosunTapStateCreate(1) else { return "state allocation failed" }
        defer { BosunTapStateDestroy(state) }

        func makeList(_ channelsPerBuffer: [Int], fill: Float) -> UnsafeMutableAudioBufferListPointer {
            let list = AudioBufferList.allocate(maximumBuffers: channelsPerBuffer.count)
            for (i, channels) in channelsPerBuffer.enumerated() {
                let data = UnsafeMutablePointer<Float32>.allocate(capacity: frames * channels)
                data.initialize(repeating: fill, count: frames * channels)
                list[i] = AudioBuffer(
                    mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4), mData: data)
            }
            return list
        }
        func release(_ list: UnsafeMutableAudioBufferListPointer) {
            for buffer in list { buffer.mData?.deallocate() }
            free(list.unsafeMutablePointer)
        }
        func samples(_ list: UnsafeMutableAudioBufferListPointer, _ buffer: Int) -> [Float] {
            let b = list[buffer]
            return Array(UnsafeBufferPointer(
                start: b.mData!.assumingMemoryBound(to: Float32.self), count: Int(b.mDataByteSize) / 4))
        }

        // Interleaved stereo in (L = 0.5, R = -0.25) -> two mono buffers out.
        let input = makeList([2], fill: 0)
        defer { release(input) }
        let inPtr = input[0].mData!.assumingMemoryBound(to: Float32.self)
        for f in 0..<frames { inPtr[f * 2] = 0.5; inPtr[f * 2 + 1] = -0.25 }
        let split = makeList([1, 1], fill: 9)
        defer { release(split) }

        BosunTapRender(state, input.unsafePointer, split.unsafeMutablePointer)
        guard samples(split, 0).allSatisfy({ $0 == 0.5 }), samples(split, 1).allSatisfy({ $0 == -0.25 }) else {
            return "unity gain is not a bit-exact copy"
        }

        // Gain change: one buffer of monotonic ramp, then steady at the target.
        BosunTapStateSetGain(state, 0.25)
        BosunTapRender(state, input.unsafePointer, split.unsafeMutablePointer)
        let ramp = samples(split, 0)
        guard zip(ramp, ramp.dropFirst()).allSatisfy({ $0 > $1 }), ramp[0] < 0.5, ramp[0] > 0.49,
              abs(ramp[frames - 1] - 0.125) < 1e-5 else { return "gain change is not a smooth ramp" }
        BosunTapRender(state, input.unsafePointer, split.unsafeMutablePointer)
        guard samples(split, 0).allSatisfy({ abs($0 - 0.125) < 1e-7 }),
              samples(split, 1).allSatisfy({ abs($0 + 0.0625) < 1e-7 }) else { return "steady gain wrong" }

        // Gain is capped at unity, so the path can never clip.
        BosunTapStateSetGain(state, 4)
        BosunTapRender(state, input.unsafePointer, split.unsafeMutablePointer)
        BosunTapRender(state, input.unsafePointer, split.unsafeMutablePointer)
        guard samples(split, 0).allSatisfy({ $0 == 0.5 }) else { return "gain above unity was not clamped" }

        // More output channels than input: extras stay silent.
        let wide = makeList([4], fill: 9)
        defer { release(wide) }
        BosunTapRender(state, input.unsafePointer, wide.unsafeMutablePointer)
        let w = samples(wide, 0)
        guard (0..<frames).allSatisfy({ w[$0 * 4] == 0.5 && w[$0 * 4 + 1] == -0.25 && w[$0 * 4 + 2] == 0 && w[$0 * 4 + 3] == 0 })
        else { return "channel mapping to a wider output is wrong" }

        // Mono in feeds both front channels.
        let mono = makeList([1], fill: 0.5)
        defer { release(mono) }
        let stereo = makeList([2], fill: 9)
        defer { release(stereo) }
        BosunTapRender(state, mono.unsafePointer, stereo.unsafeMutablePointer)
        guard samples(stereo, 0).allSatisfy({ $0 == 0.5 }) else { return "mono input not copied to both channels" }

        // No input at all: output must be silence, not stale memory.
        let stale = makeList([2], fill: 9)
        defer { release(stale) }
        BosunTapRender(state, nil, stale.unsafeMutablePointer)
        guard samples(stale, 0).allSatisfy({ $0 == 0 }) else { return "output not cleared when there is no input" }

        // Short input buffer: only the frames that exist are copied.
        input[0].mDataByteSize = UInt32(frames * 2 * 4 / 2)
        let partial = makeList([2], fill: 9)
        defer { release(partial) }
        BosunTapRender(state, input.unsafePointer, partial.unsafeMutablePointer)
        let p = samples(partial, 0)
        guard p[0] == 0.5, p[frames - 2] == 0.5, p[frames] == 0, p[frames * 2 - 1] == 0 else {
            return "short input buffer handled wrong"
        }
        return nil
    }
}
