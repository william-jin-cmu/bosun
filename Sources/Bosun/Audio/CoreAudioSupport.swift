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

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
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

    /// UID prefix of the private aggregate devices Bosun creates for per-app volume.
    static let privateUIDPrefix = "Bosun-Tap-"

    /// Devices the user could pick as default for `direction`.
    static func list(_ direction: Direction) -> [AudioDeviceInfo] {
        CA.objectIDs(CA.system, CA.address(kAudioHardwarePropertyDevices)).compactMap { id in
            guard !CA.objectIDs(id, CA.address(kAudioDevicePropertyStreams, scope: direction.scope)).isEmpty,
                  let uid = uid(id), !uid.hasPrefix(privateUIDPrefix) else { return nil }
            let canBeDefault = CA.value(
                id, CA.address(kAudioDevicePropertyDeviceCanBeDefaultDevice, scope: direction.scope), initial: UInt32(1))
            let hidden = CA.value(id, CA.address(kAudioDevicePropertyIsHidden), initial: UInt32(0))
            guard canBeDefault != 0, (hidden ?? 0) == 0 else { return nil }
            let name = CA.string(id, CA.address(kAudioObjectPropertyName)) ?? "Unknown Device"
            return AudioDeviceInfo(id: id, uid: uid, name: name)
        }
    }

    static func uid(_ device: AudioDeviceID) -> String? {
        CA.string(device, CA.address(kAudioDevicePropertyDeviceUID))
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

    // MARK: Master volume

    private static let volumeAddress = CA.address(
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioObjectPropertyScopeOutput)
    private static let muteAddress = CA.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeOutput)

    static var volumeSelector: AudioObjectPropertyAddress { volumeAddress }
    static var muteSelector: AudioObjectPropertyAddress { muteAddress }

    static func volume(_ device: AudioDeviceID) -> Float? {
        CA.value(device, volumeAddress, initial: Float32(0))
    }

    static func canSetVolume(_ device: AudioDeviceID) -> Bool { CA.isSettable(device, volumeAddress) }

    @discardableResult
    static func setVolume(_ device: AudioDeviceID, _ volume: Float) -> Bool {
        CA.set(device, volumeAddress, Float32(min(max(volume, 0), 1))) == noErr
    }

    static func isMuted(_ device: AudioDeviceID) -> Bool? {
        CA.value(device, muteAddress, initial: UInt32(0)).map { $0 != 0 }
    }

    static func canMute(_ device: AudioDeviceID) -> Bool { CA.isSettable(device, muteAddress) }

    @discardableResult
    static func setMuted(_ device: AudioDeviceID, _ muted: Bool) -> Bool {
        CA.set(device, muteAddress, UInt32(muted ? 1 : 0)) == noErr
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

enum AudioMath {
    /// Slider position (0…1) to linear gain. Squared so the lower half of the
    /// slider is usable: 50% is about −12 dB. Never above unity.
    static func gain(forSlider value: Double) -> Float {
        let v = min(max(value, 0), 1)
        return Float(v * v)
    }
}
