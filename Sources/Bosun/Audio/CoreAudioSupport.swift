import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Thin typed wrappers over the AudioObject property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        return AudioObjectHasProperty(object, &a)
    }

    static func isSettable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var a = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(object, &a),
              AudioObjectIsPropertySettable(object, &a, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// Reads a plain-old-data property (UInt32, Float32, Float64, pid_t, ASBD…).
    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, initial: T) -> T? {
        var a = address
        var v = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &v) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        return status == noErr ? v : nil
    }

    @discardableResult
    static func set<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var a = address
        var v = value
        return withUnsafePointer(to: &v) {
            AudioObjectSetPropertyData(object, &a, 0, nil, UInt32(MemoryLayout<T>.size), $0)
        }
    }

    static func objectIDs(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var a = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var a = address
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0) }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as String
    }
}

/// Called on a Core Audio thread; `client` is just a token, so there is
/// nothing here whose lifetime could race with removal.
private let audioListenerProc: AudioObjectPropertyListenerProc = { _, _, _, client in
    let token = Int(bitPattern: client)
    DispatchQueue.main.async {
        MainActor.assumeIsolated { AudioListener.handlers[token]?() }
    }
    return noErr
}

/// A registered property listener; removes itself when released.
///
/// This uses the C-function form on purpose: the block form cannot be removed
/// reliably from Swift, because a closure is re-bridged to a new block object
/// on every call and removal matches on block identity.
@MainActor
final class AudioListener {
    fileprivate static var handlers: [Int: @MainActor () -> Void] = [:]
    private static var nextToken = 1

    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let token: Int

    /// `handler` always runs on the main queue.
    init?(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, handler: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = address
        token = Self.nextToken
        Self.nextToken += 1
        guard AudioObjectAddPropertyListener(
            object, &self.address, audioListenerProc, UnsafeMutableRawPointer(bitPattern: token)) == noErr
        else { return nil }
        Self.handlers[token] = handler
    }

    deinit {
        // Fails harmlessly when the object (a device or process) is already gone.
        AudioObjectRemovePropertyListener(object, &address, audioListenerProc, UnsafeMutableRawPointer(bitPattern: token))
        let token = self.token
        DispatchQueue.main.async { MainActor.assumeIsolated { _ = AudioListener.handlers.removeValue(forKey: token) } }
    }
}

/// Everything the UI shows about one device in one direction.
struct AudioDeviceState: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    let isAggregate: Bool
    /// A "Multi-Output Device": every sub-device plays the same audio.
    let isMultiOutput: Bool
    /// Streams in this direction.
    let streamCount: Int
    var volume: Float?
    var canSetVolume: Bool
    var isMuted: Bool
    var canMute: Bool
    /// 0 = left, 0.5 = centre, 1 = right; nil when the device has no balance control.
    var balance: Float?
    var sampleRate: Double
    /// Rates the device can be switched to (empty or one entry: nothing to choose).
    var sampleRates: [Double]
    /// 0-based channel indexes of the device's stereo pair.
    var stereoLeft: Int
    var stereoRight: Int

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "display"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire: "cable.connector"
        case kAudioDeviceTransportTypeAggregate: "square.stack.3d.up"
        case kAudioDeviceTransportTypeVirtual: "waveform"
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless: "iphone"
        default: "hifispeaker"
        }
    }
}

enum AudioDevices {
    enum Direction {
        case output, input
        var scope: AudioObjectPropertyScope {
            self == .output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
        }
        var defaultSelector: AudioObjectPropertySelector {
            self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
        }
    }

    /// UID prefix of the private aggregate devices Bosun creates for per-app
    /// volume, and name prefix of its taps. The owning PID follows the prefix.
    static let privatePrefix = "Bosun-Tap-"

    static func allDeviceIDs() -> [AudioDeviceID] {
        CA.objectIDs(CA.system, CA.address(kAudioHardwarePropertyDevices))
    }

    /// Devices the user could pick as default for `direction`.
    static func list(_ direction: Direction) -> [AudioDeviceState] {
        allDeviceIDs().compactMap { state($0, direction) }
    }

    static func state(_ id: AudioDeviceID, _ direction: Direction) -> AudioDeviceState? {
        let streams = CA.objectIDs(id, CA.address(kAudioDevicePropertyStreams, scope: direction.scope)).count
        guard streams > 0, let uid = uid(id), !uid.hasPrefix(privatePrefix) else { return nil }
        let canBeDefault = CA.value(
            id, CA.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope), initial: UInt32(1))
        let hidden = CA.value(id, CA.address(kAudioDevicePropertyIsHidden), initial: UInt32(0))
        guard canBeDefault != 0, (hidden ?? 0) == 0 else { return nil }
        let stereo = CA.value(
            id, CA.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: direction.scope),
            initial: (UInt32(1), UInt32(2))) ?? (1, 2)
        let balance = balanceAddress(id)
        return AudioDeviceState(
            id: id, uid: uid,
            name: CA.string(id, CA.address(kAudioObjectPropertyName)) ?? "Unknown Device",
            transport: CA.value(id, CA.address(kAudioDevicePropertyTransportType), initial: UInt32(0)) ?? 0,
            isAggregate: isAggregate(id),
            isMultiOutput: isMultiOutput(id),
            streamCount: streams,
            volume: volume(id, direction),
            canSetVolume: canSetVolume(id, direction),
            isMuted: isMuted(id, direction) ?? false,
            canMute: canMute(id, direction),
            balance: direction == .output ? balance.flatMap { CA.value(id, $0, initial: Float32(0.5)) } : nil,
            sampleRate: sampleRate(id) ?? 0,
            sampleRates: availableSampleRates(id),
            stereoLeft: max(0, Int(stereo.0) - 1),
            stereoRight: max(0, Int(stereo.1) - 1))
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        CA.string(device, CA.address(kAudioDevicePropertyDeviceUID))
    }

    static func device(uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { self.uid($0) == uid }
    }

    static func isAggregate(_ device: AudioDeviceID) -> Bool {
        CA.value(device, CA.address(kAudioObjectPropertyClass), initial: AudioClassID(0)) == kAudioAggregateDeviceClassID
    }

    /// The dictionary an aggregate device was built from (sub-devices, clock, stacking).
    static func composition(_ device: AudioDeviceID) -> [String: Any]? {
        guard isAggregate(device) else { return nil }
        var address = CA.address(kAudioAggregateDevicePropertyComposition)
        var ref: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0) }
        guard status == noErr, let ref else { return nil }
        return ref.takeRetainedValue() as? [String: Any]
    }

    static func isMultiOutput(_ device: AudioDeviceID) -> Bool {
        guard let composition = composition(device) else { return false }
        return (composition[kAudioAggregateDeviceIsStackedKey] as? NSNumber)?.boolValue ?? false
    }

    static func defaultDevice(_ direction: Direction) -> AudioDeviceID? {
        guard let id = CA.value(CA.system, CA.address(direction.defaultSelector), initial: AudioDeviceID(0)),
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    @discardableResult
    static func setDefault(_ device: AudioDeviceID, _ direction: Direction) -> Bool {
        let ok = CA.set(CA.system, CA.address(direction.defaultSelector), device) == noErr
        if ok, direction == .output {
            // Alerts and UI sounds follow the main output, as in System Settings.
            CA.set(CA.system, CA.address(kAudioHardwarePropertyDefaultSystemOutputDevice), device)
        }
        return ok
    }

    // MARK: Volume, mute, balance

    static func volumeAddress(_ direction: Direction) -> AudioObjectPropertyAddress {
        CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: direction.scope)
    }
    static func muteAddress(_ direction: Direction) -> AudioObjectPropertyAddress {
        CA.address(kAudioDevicePropertyMute, scope: direction.scope)
    }
    /// Devices expose balance either as the virtual main balance or as a stereo pan.
    static func balanceAddress(_ device: AudioDeviceID) -> AudioObjectPropertyAddress? {
        let candidates = [
            CA.address(kAudioHardwareServiceDeviceProperty_VirtualMainBalance, scope: kAudioObjectPropertyScopeOutput),
            CA.address(kAudioDevicePropertyStereoPan, scope: kAudioObjectPropertyScopeOutput),
        ]
        return candidates.first { CA.isSettable(device, $0) }
    }

    static func volume(_ device: AudioDeviceID, _ direction: Direction = .output) -> Float? {
        CA.value(device, volumeAddress(direction), initial: Float32(0))
    }
    static func canSetVolume(_ device: AudioDeviceID, _ direction: Direction = .output) -> Bool {
        CA.isSettable(device, volumeAddress(direction))
    }
    @discardableResult
    static func setVolume(_ device: AudioDeviceID, _ volume: Float, _ direction: Direction = .output) -> Bool {
        CA.set(device, volumeAddress(direction), Float32(min(max(volume, 0), 1))) == noErr
    }
    static func isMuted(_ device: AudioDeviceID, _ direction: Direction = .output) -> Bool? {
        CA.value(device, muteAddress(direction), initial: UInt32(0)).map { $0 != 0 }
    }
    static func canMute(_ device: AudioDeviceID, _ direction: Direction = .output) -> Bool {
        CA.isSettable(device, muteAddress(direction))
    }
    @discardableResult
    static func setMuted(_ device: AudioDeviceID, _ muted: Bool, _ direction: Direction = .output) -> Bool {
        CA.set(device, muteAddress(direction), UInt32(muted ? 1 : 0)) == noErr
    }
    static func balance(_ device: AudioDeviceID) -> Float? {
        balanceAddress(device).flatMap { CA.value(device, $0, initial: Float32(0.5)) }
    }
    @discardableResult
    static func setBalance(_ device: AudioDeviceID, _ balance: Float) -> Bool {
        guard let address = balanceAddress(device) else { return false }
        return CA.set(device, address, Float32(min(max(balance, 0), 1))) == noErr
    }

    // MARK: Sample rate

    static func sampleRate(_ device: AudioDeviceID) -> Double? {
        CA.value(device, CA.address(kAudioDevicePropertyNominalSampleRate), initial: Float64(0))
    }

    static func availableSampleRates(_ device: AudioDeviceID) -> [Double] {
        var address = CA.address(kAudioDevicePropertyAvailableNominalSampleRates)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ranges = [AudioValueRange](
            repeating: AudioValueRange(), count: Int(size) / MemoryLayout<AudioValueRange>.size)
        let status = ranges.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return AudioMath.discreteRates(ranges.map { ($0.mMinimum, $0.mMaximum) })
    }

    @discardableResult
    static func setSampleRate(_ device: AudioDeviceID, _ rate: Double) -> Bool {
        CA.set(device, CA.address(kAudioDevicePropertyNominalSampleRate), Float64(rate)) == noErr
    }

    /// Devices (by ID) the process is currently playing on.
    static func outputDevices(ofProcess object: AudioObjectID) -> [AudioDeviceID] {
        CA.objectIDs(object, CA.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
    }
}

/// "System Audio Recording Only" consent. There is no public API to read it,
/// so this asks TCC directly and reports `.unknown` if that ever stops working.
enum AudioCaptureAccess: Equatable {
    case granted, denied, undetermined, unknown

    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    /// Never prompts.
    static func current() -> AudioCaptureAccess {
        #if DEBUG
        // Lets the denied / not-yet-asked paths be exercised in debug builds.
        switch ProcessInfo.processInfo.environment["BOSUN_AUDIO_FAKE_ACCESS"] {
        case "denied": return .denied
        case "undetermined": return .undetermined
        default: break
        }
        #endif
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: PreflightFn.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .undetermined
        }
    }

    /// Shows the system prompt if the user has not decided yet.
    static func request(_ completion: @escaping @MainActor (AudioCaptureAccess) -> Void) {
        guard let tcc, let symbol = dlsym(tcc, "TCCAccessRequest") else {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(.unknown) } }
            return
        }
        unsafeBitCast(symbol, to: RequestFn.self)(service, nil) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted ? .granted : .denied) } }
        }
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture")!
}

/// Microphone consent, needed only for the input level meter.
enum AudioMicAccess {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// macOS terminates a process that asks for the microphone without a usage
    /// string, so the prompt is only ever shown when the bundle declares one.
    static var canRequest: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    @MainActor
    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        guard canRequest else { return completion(false) }
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } }
        }
    }

    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone")!
}
