import CBridge
import CoreAudio
import Foundation

/// Volume, mute, boost and output routing for one app without an audio driver.
///
/// A Core Audio process tap captures the app's output and, because the tap is
/// `mutedWhenTapped`, the system stops sending the app's own audio to the
/// hardware for as long as something reads the tap. A private aggregate device
/// (the chosen output device + the tap) lets one IOProc read the tap and write
/// it to that output through the gain and limiter in `AudioBridge.h`.
///
/// The mute only lasts while this process reads the tap: if the IOProc stops,
/// or Bosun quits or crashes, the app plays at full volume again. Both the tap
/// and the aggregate device are private to this process, so no other process
/// (including another Bosun) can see or touch them.
///
/// Everything except `setGain` and `takeStats` must be called on `AppTap.queue`.
final class AppTap: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    /// Serial queue for tap setup and teardown, which can block for a while.
    static let queue = DispatchQueue(label: "bosun.audio.taps", qos: .userInitiated)

    let label: String
    private let state: UnsafeMutableRawPointer
    /// One tap per captured stream, or a single stereo-mix tap.
    private var tapIDs: [AudioObjectID] = []
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var plan: TapPlan?
    private var usesMixdown = false

    init?(label: String, gain: Float) {
        guard let state = BosunTapStateCreate(gain) else { return nil }
        self.label = label
        self.state = state
    }

    deinit {
        stop()
        // The IOProc is gone by now; wait a moment anyway before freeing what it read.
        let state = self.state
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { BosunTapStateDestroy(state) }
    }

    /// Safe from any thread; the IO thread ramps to the new value.
    func setGain(_ gain: Float) { BosunTapStateSetGain(state, gain) }

    var isRunning: Bool { ioProcID != nil }

    struct Stats {
        let cycles: UInt64
        let inputPeak: Float
        let outputPeak: Float
        /// Lowest limiter gain since the last call; 1 means the limiter was idle.
        let limiterFloor: Float
    }

    /// Safe from any thread. Peaks and limiter floor cover the time since the last call.
    func takeStats() -> Stats {
        Stats(cycles: BosunTapStateCycles(state), inputPeak: BosunTapStateTakeInputPeak(state),
              outputPeak: BosunTapStateTakeOutputPeak(state), limiterFloor: BosunTapStateTakeLimiterFloor(state))
    }

    var cycles: UInt64 { BosunTapStateCycles(state) }

    /// `stream` nil describes the stereo-mix tap.
    private func description(processes: [AudioObjectID], uuid: UUID, stream: Int?) -> CATapDescription {
        let description: CATapDescription
        if let stream, let captureUID = plan?.captureUID {
            description = CATapDescription(processes: processes, deviceUID: captureUID, stream: UInt(stream))
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        description.name = "\(AudioDevices.privatePrefix)\(getpid()) \(label)"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    private func createTap(processes: [AudioObjectID], stream: Int?) throws -> (id: AudioObjectID, uid: String) {
        let uuid = UUID()
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check("create tap", AudioHardwareCreateProcessTap(description(processes: processes, uuid: uuid, stream: stream), &tap))
        tapIDs.append(tap)
        // The render path assumes Float32 linear PCM; refuse anything else
        // rather than mute the app and play garbage.
        guard let format = CA.value(tap, CA.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription()),
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw Failure(step: "tap format", status: kAudioDeviceUnsupportedFormatError) }
        return (tap, CA.string(tap, CA.address(kAudioTapPropertyUID)) ?? uuid.uuidString)
    }

    private func destroyTaps() {
        for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        tapIDs = []
    }

    /// The aggregate device: the output device (or, if that is itself an
    /// aggregate, its sub-devices, since aggregates cannot be nested) plus the tap.
    private static func aggregateDescription(outputUID: String, tapUIDs: [String], driftCompensation: Bool, label: String) -> [String: Any] {
        var description: [String: Any] = [
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
        ]
        if let device = AudioDevices.device(uid: outputUID), let composition = AudioDevices.composition(device),
           let subDevices = composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]], !subDevices.isEmpty {
            description[kAudioAggregateDeviceSubDeviceListKey] = subDevices
            description[kAudioAggregateDeviceIsStackedKey] = composition[kAudioAggregateDeviceIsStackedKey] ?? false
            let main = composition[kAudioAggregateDeviceMainSubDeviceKey] as? String
                ?? subDevices.first?[kAudioSubDeviceUIDKey] as? String
            description[kAudioAggregateDeviceMainSubDeviceKey] = main ?? outputUID
            if let clock = composition[kAudioAggregateDeviceClockDeviceKey] {
                description[kAudioAggregateDeviceClockDeviceKey] = clock
            }
        }
        description[kAudioAggregateDeviceNameKey] = "Bosun \(label)"
        description[kAudioAggregateDeviceUIDKey] = "\(AudioDevices.privatePrefix)\(getpid())-\(UUID().uuidString)"
        description[kAudioAggregateDeviceIsPrivateKey] = true
        description[kAudioAggregateDeviceTapAutoStartKey] = true
        description[kAudioAggregateDeviceTapListKey] = tapUIDs.map {
            [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: driftCompensation] as [String: Any]
        }
        return description
    }

    func start(processes: [AudioObjectID], plan: TapPlan) throws {
        stop()
        self.plan = plan
        do {
            // One tap per stream of the captured device; if the device will
            // not have that (or the app is being moved), one stereo-mix tap.
            var tapUIDs: [String] = []
            usesMixdown = plan.captureUID == nil || plan.captureStreams < 1
            if !usesMixdown {
                do {
                    for stream in 0..<plan.captureStreams {
                        tapUIDs.append(try createTap(processes: processes, stream: stream).uid)
                    }
                } catch {
                    destroyTaps()
                    tapUIDs = []
                    usesMixdown = true
                }
            }
            if usesMixdown { tapUIDs = [try createTap(processes: processes, stream: nil).uid] }

            // A tap on the output device's own streams runs on that device's
            // clock and is passed through sample for sample. A stereo-mix tap
            // may come from another device's clock, so it is resampled against
            // the output device and cannot slowly over- or underrun.
            let aggregate = Self.aggregateDescription(
                outputUID: plan.outputUID, tapUIDs: tapUIDs, driftCompensation: usesMixdown, label: label)
            var device = AudioObjectID(kAudioObjectUnknown)
            try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
            aggregateID = device

            BosunTapStateConfigure(state, AudioDevices.sampleRate(device) ?? 48000)
            if usesMixdown {
                BosunTapStateSetStereoMap(state, Int32(max(plan.stereoLeft, 0)), Int32(max(plan.stereoRight, 1)), plan.mirror ? 1 : 0)
            } else {
                BosunTapStateSetStereoMap(state, -1, -1, 0)
            }

            // The aggregate's input side is the output device's own input
            // streams (if it has any: a headset's microphone, a loopback
            // device) followed by the tap. Only the tap may ever be played.
            let inputStreams = CA.objectIDs(device, CA.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput))
            guard inputStreams.count >= tapUIDs.count else { throw Failure(step: "tap stream", status: kAudioHardwareBadStreamError) }
            let deviceInputs = inputStreams.count - tapUIDs.count
            BosunTapStateSetInputSkip(state, Int32(deviceInputs))

            var proc: AudioDeviceIOProcID?
            try check("create IO proc", AudioDeviceCreateIOProcID(device, BosunTapIOProcPointer(), state, &proc))
            ioProcID = proc
            // And do not even open those streams, so a device's microphone is
            // never switched on by adjusting an app's volume.
            if deviceInputs > 0, let proc {
                Self.disableLeadingInputStreams(deviceInputs, device: device, proc: proc, streamCount: inputStreams.count)
            }
            try check("start device", AudioDeviceStart(device, proc))
        } catch {
            stop()
            throw error
        }
    }

    private static func disableLeadingInputStreams(_ count: Int, device: AudioObjectID, proc: AudioDeviceIOProcID, streamCount: Int) {
        // AudioHardwareIOProcStreamUsage: { void *mIOProc; UInt32 mNumberStreams; UInt32 mStreamIsOn[]; }
        let header = MemoryLayout<UnsafeRawPointer>.size + MemoryLayout<UInt32>.size
        let size = header + streamCount * MemoryLayout<UInt32>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<UnsafeRawPointer>.alignment)
        defer { raw.deallocate() }
        raw.storeBytes(of: unsafeBitCast(proc, to: UnsafeRawPointer.self), as: UnsafeRawPointer.self)
        raw.storeBytes(of: UInt32(streamCount), toByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
        for index in 0..<streamCount {
            raw.storeBytes(of: UInt32(index < count ? 0 : 1), toByteOffset: header + index * 4, as: UInt32.self)
        }
        var address = CA.address(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput)
        let status = AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(size), raw)
        if status != noErr { Log.info("could not switch off device input streams (\(status)); they are ignored instead", "audio") }
    }

    /// Changes which processes are tapped (helpers come and go) without
    /// interrupting audio. Returns false if the tap has to be rebuilt.
    func update(processes: [AudioObjectID]) -> Bool {
        guard !tapIDs.isEmpty else { return false }
        for (index, tap) in tapIDs.enumerated() {
            guard let uidString = CA.string(tap, CA.address(kAudioTapPropertyUID)),
                  let uuid = UUID(uuidString: uidString) else { return false }
            let description = description(processes: processes, uuid: uuid, stream: usesMixdown ? nil : index)
            guard CA.set(tap, CA.address(kAudioTapPropertyDescription), description) == noErr else { return false }
        }
        return true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        destroyTaps()
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }

    // MARK: Leftovers from a previous run

    /// Whether `pid` is a running process with this executable's name.
    static func isLiveBosun(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 || errno == EPERM else { return false }
        // Unknown name: assume it is Bosun and leave its objects alone.
        guard let theirs = AudioProcesses.processName(pid), let ours = AudioProcesses.processName(getpid()) else {
            return true
        }
        return theirs == ours
    }

    /// Destroys taps and aggregate devices named as Bosun's whose owning
    /// process is gone. Returns how many were removed.
    ///
    /// Bosun's objects are private, so normally none are visible here at all
    /// (not even a live second instance's); this only matters if the audio
    /// server ever keeps one alive and exposes it after its owner died.
    @discardableResult
    static func sweepOrphans() -> Int {
        let own = getpid()
        var removed = 0
        for device in AudioDevices.allDeviceIDs() {
            guard let uid = AudioDevices.uid(device),
                  TapOrphans.shouldDestroy(name: uid, ownPID: own, isLiveBosun: isLiveBosun) else { continue }
            if AudioHardwareDestroyAggregateDevice(device) == noErr { removed += 1 }
        }
        for tap in CA.objectIDs(CA.system, CA.address(kAudioHardwarePropertyTapList)) {
            guard let name = CA.string(tap, CA.address(kAudioObjectPropertyName)),
                  TapOrphans.shouldDestroy(name: name, ownPID: own, isLiveBosun: isLiveBosun) else { continue }
            if AudioHardwareDestroyProcessTap(tap) == noErr { removed += 1 }
        }
        return removed
    }
}

/// Reads the level of an input device while the settings tab is open.
/// Samples are only measured, never stored. Needs microphone permission.
/// `start` and `stop` must be called on `AppTap.queue`.
final class InputLevelTap: @unchecked Sendable {
    private let state: UnsafeMutableRawPointer
    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init?() {
        guard let state = BosunMeterStateCreate() else { return nil }
        self.state = state
    }

    deinit {
        stop()
        let state = self.state
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { BosunMeterStateDestroy(state) }
    }

    var runningDevice: AudioDeviceID? { ioProcID != nil ? device : nil }

    func start(device: AudioDeviceID) -> Bool {
        stop()
        var proc: AudioDeviceIOProcID?
        guard AudioDeviceCreateIOProcID(device, BosunMeterIOProcPointer(), state, &proc) == noErr, let proc else {
            return false
        }
        guard AudioDeviceStart(device, proc) == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            return false
        }
        self.device = device
        ioProcID = proc
        return true
    }

    func stop() {
        guard let ioProcID else { return }
        AudioDeviceStop(device, ioProcID)
        AudioDeviceDestroyIOProcID(device, ioProcID)
        self.ioProcID = nil
    }

    func takePeak() -> Float { BosunMeterStateTakePeak(state) }
    var cycles: UInt64 { BosunMeterStateCycles(state) }
}
