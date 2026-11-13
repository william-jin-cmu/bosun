import CBridge
import CoreAudio
import Foundation

/// Volume control for one app without an audio driver.
///
/// A Core Audio process tap captures the app's output and, because the tap is
/// `mutedWhenTapped`, the system stops sending the app's own audio to the
/// hardware for as long as something reads the tap. A private aggregate device
/// (the real output device + the tap) lets one IOProc read the tap and write
/// it back to the output, scaled by the gain.
///
/// The mute only lasts while this process reads the tap: if the IOProc stops,
/// or Bosun quits or crashes, the audio server drops the tap and the app plays
/// at full volume again. Nothing persists outside this process.
///
/// Everything except `setGain` must be called on `AppTap.queue`.
final class AppTap: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let step: String
        let status: OSStatus
        var description: String { "\(step) failed (\(status))" }
    }

    /// Serial queue for tap setup and teardown, which can block for a while.
    static let queue = DispatchQueue(label: "bosun.audio.taps", qos: .userInitiated)

    /// The tap is resampled against the output device's clock, so a tap whose
    /// rate ever differs from the device cannot slowly over- or underrun.
    private static let driftCompensation = true

    let label: String
    private let state: UnsafeMutableRawPointer
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var outputUID = ""
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

    /// IO cycles rendered, and the peak levels since the last call.
    func takeStats() -> (cycles: UInt64, inputPeak: Float, outputPeak: Float) {
        (BosunTapStateCycles(state), BosunTapStateTakeInputPeak(state), BosunTapStateTakeOutputPeak(state))
    }

    private func description(processes: [AudioObjectID], uuid: UUID) -> CATapDescription {
        // Only what the processes send to this output device, in that device's
        // own stream format: apps playing to some other device are left alone,
        // and channels map 1:1 with no up/down-mix.
        // If the device refuses that, fall back to a stereo mix of everything
        // the processes play.
        let description = usesMixdown
            ? CATapDescription(stereoMixdownOfProcesses: processes)
            : CATapDescription(processes: processes, deviceUID: outputUID, stream: 0)
        description.name = "Bosun \(label)"
        description.uuid = uuid
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    func start(processes: [AudioObjectID], outputUID: String) throws {
        stop()
        self.outputUID = outputUID
        do {
            let uuid = UUID()
            var tap = AudioObjectID(kAudioObjectUnknown)
            usesMixdown = false
            if AudioHardwareCreateProcessTap(description(processes: processes, uuid: uuid), &tap) != noErr {
                usesMixdown = true
                try check("create tap", AudioHardwareCreateProcessTap(description(processes: processes, uuid: uuid), &tap))
            }
            tapID = tap

            // The render path assumes Float32 linear PCM; refuse anything else
            // rather than mute the app and play garbage.
            guard let format = CA.value(tap, CA.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription()),
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  format.mBitsPerChannel == 32
            else { throw Failure(step: "tap format", status: kAudioDeviceUnsupportedFormatError) }

            let tapUID = CA.string(tap, CA.address(kAudioTapPropertyUID)) ?? uuid.uuidString
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Bosun \(label)",
                kAudioAggregateDeviceUIDKey: AudioDevices.privateUIDPrefix + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
                // The output device is the clock; the tap is resampled to it.
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: Self.driftCompensation]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try check("create aggregate device", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device))
            aggregateID = device

            var proc: AudioDeviceIOProcID?
            try check("create IO proc", AudioDeviceCreateIOProcID(device, BosunTapIOProcPointer(), state, &proc))
            ioProcID = proc
            try check("start device", AudioDeviceStart(device, proc))
        } catch {
            stop()
            throw error
        }
    }

    /// Changes which processes are tapped (helpers come and go) without
    /// interrupting audio. Returns false if the tap has to be rebuilt.
    func update(processes: [AudioObjectID]) -> Bool {
        guard tapID != kAudioObjectUnknown,
              let uidString = CA.string(tapID, CA.address(kAudioTapPropertyUID)),
              let uuid = UUID(uuidString: uidString) else { return false }
        return CA.set(tapID, CA.address(kAudioTapPropertyDescription), description(processes: processes, uuid: uuid)) == noErr
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        if status != noErr { throw Failure(step: step, status: status) }
    }
}
