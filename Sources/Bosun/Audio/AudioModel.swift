import Foundation

// Pure data and decision logic for the Sound module: no Core Audio calls here,
// so all of it is covered by `AudioChecks`.

/// What the user has chosen for one app. Keyed by app ID (bundle ID).
struct AudioAppSettings: Equatable {
    /// Slider position: 0…1 attenuates, above 1 boosts (up to the boost limit).
    var volume: Double = 1
    var muted = false
    /// UID of the output device this app is sent to; nil follows the system default.
    var outputUID: String?
    /// Always listed in the panel, playing or not.
    var pinned = false
    /// Remembered so the app can be shown while it is not running.
    var name: String?
    var path: String?

    /// True when Bosun leaves the app's audio alone.
    var isAudioDefault: Bool { volume == 1 && !muted && outputUID == nil }
    /// True when there is nothing worth saving.
    var isEmpty: Bool { isAudioDefault && !pinned }

    var plist: [String: Any] {
        var out: [String: Any] = [:]
        if volume != 1 { out["volume"] = volume }
        if muted { out["muted"] = true }
        if let outputUID { out["output"] = outputUID }
        if pinned { out["pinned"] = true }
        if let name { out["name"] = name }
        if let path { out["path"] = path }
        return out
    }

    init() {}

    init(plist: [String: Any]) {
        if let v = (plist["volume"] as? NSNumber)?.doubleValue, v.isFinite { volume = min(max(v, 0), AudioMath.maxSlider) }
        muted = (plist["muted"] as? NSNumber)?.boolValue ?? false
        outputUID = (plist["output"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        pinned = (plist["pinned"] as? NSNumber)?.boolValue ?? false
        name = plist["name"] as? String
        path = plist["path"] as? String
    }
}

enum AudioStore {
    static func decode(_ value: Any?) -> [String: AudioAppSettings] {
        guard let raw = value as? [String: Any] else { return [:] }
        var out: [String: AudioAppSettings] = [:]
        for (id, entry) in raw where !id.isEmpty {
            guard let entry = entry as? [String: Any] else { continue }
            let settings = AudioAppSettings(plist: entry)
            if !settings.isEmpty { out[id] = settings }
        }
        return out
    }

    static func encode(_ settings: [String: AudioAppSettings]) -> [String: Any] {
        settings.filter { !$0.value.isEmpty }.mapValues { $0.plist }
    }

    /// The first version stored only `[appID: volume]`.
    static func migrate(legacyVolumes value: Any?) -> [String: AudioAppSettings] {
        guard let raw = value as? [String: Double] else { return [:] }
        var out: [String: AudioAppSettings] = [:]
        for (id, volume) in raw where !id.isEmpty && volume.isFinite && volume >= 0 && volume < 1 {
            var settings = AudioAppSettings()
            settings.volume = volume
            out[id] = settings
        }
        return out
    }
}

enum AudioMath {
    /// Top of the per-app slider at the highest boost limit (200%).
    static let maxSlider = 2.0
    static let boostLimits: [Double] = [1.0, 1.5, 2.0]
    static let defaultBoostLimit = 2.0
    static let recentChoices: [TimeInterval] = [10, 30, 60, 300, 1800]
    static let defaultRecent: TimeInterval = 60

    /// Slider position to linear gain. Squared, so the lower half of the slider
    /// is usable (50% is about −12 dB) and 200% is +12 dB.
    static func gain(forSlider value: Double) -> Float {
        let v = min(max(value, 0), maxSlider)
        return Float(v * v)
    }

    /// Cleans up a slider value: clamps to the boost limit and snaps to exactly
    /// 100% nearby, so "back to normal" is easy to hit and removes the tap.
    static func snap(_ value: Double, limit: Double) -> Double {
        let v = min(max(value, 0), min(max(limit, 1), maxSlider))
        return abs(v - 1) < 0.02 ? 1 : v
    }

    static func validBoostLimit(_ value: Double) -> Double {
        boostLimits.contains(value) ? value : defaultBoostLimit
    }

    static func validRecent(_ value: Double) -> TimeInterval {
        recentChoices.contains(value) ? value : defaultRecent
    }

    /// The gain actually applied for an app's settings.
    static func effectiveGain(_ settings: AudioAppSettings, boostLimit: Double) -> Float {
        settings.muted ? 0 : gain(forSlider: min(settings.volume, boostLimit))
    }

    /// Turns a device's supported ranges into the list offered in the UI.
    static func discreteRates(_ ranges: [(Double, Double)]) -> [Double] {
        let common: [Double] = [8000, 16000, 22050, 24000, 32000, 44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000]
        var out = Set<Double>()
        for (low, high) in ranges where low > 0 && high >= low {
            if low == high { out.insert(low) } else { common.filter { $0 >= low && $0 <= high }.forEach { out.insert($0) } }
        }
        return out.sorted()
    }

    static func rateLabel(_ rate: Double) -> String {
        guard rate > 0 else { return "—" }
        let khz = rate / 1000
        return khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz)
    }

    /// Peak sample (0…1) to meter position on a −60…0 dB scale.
    static func meterFraction(peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        let db = 20 * log10(Double(peak))
        return min(max((db + 60) / 60, 0), 1)
    }

    static func percent(_ value: Double) -> Int { Int((value * 100).rounded()) }
}

/// One row of the app list.
struct AudioAppRow: Identifiable, Equatable {
    let id: String
    let name: String
    /// Nil when the app has no audio process right now.
    let ownerPID: pid_t?
    let isLive: Bool
    let isPlaying: Bool
    let isPinned: Bool
}

enum AudioAppList {
    /// Rows for the panel: apps that are playing, played within `recentWindow`,
    /// are pinned (running or not), or are running with non-default settings.
    static func panelRows(
        live: [AudioApp], settings: [String: AudioAppSettings], lastPlayed: [String: Date],
        now: Date, recentWindow: TimeInterval
    ) -> [AudioAppRow] {
        var rows: [String: AudioAppRow] = [:]
        for app in live {
            let saved = settings[app.id]
            let recent = lastPlayed[app.id].map { now.timeIntervalSince($0) < recentWindow } ?? false
            guard app.isPlaying || recent || saved?.pinned == true || saved?.isAudioDefault == false else { continue }
            rows[app.id] = AudioAppRow(
                id: app.id, name: app.name, ownerPID: app.ownerPID, isLive: true,
                isPlaying: app.isPlaying, isPinned: saved?.pinned ?? false)
        }
        for (id, saved) in settings where saved.pinned && rows[id] == nil {
            rows[id] = AudioAppRow(
                id: id, name: saved.name ?? id, ownerPID: nil, isLive: false, isPlaying: false, isPinned: true)
        }
        return sorted(Array(rows.values))
    }

    /// Every app with something saved, for the settings window.
    static func savedRows(live: [AudioApp], settings: [String: AudioAppSettings]) -> [AudioAppRow] {
        let liveByID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return sorted(settings.filter { !$0.value.isEmpty }.map { id, saved in
            let app = liveByID[id]
            return AudioAppRow(
                id: id, name: app?.name ?? saved.name ?? id, ownerPID: app?.ownerPID, isLive: app != nil,
                isPlaying: app?.isPlaying ?? false, isPinned: saved.pinned)
        })
    }

    /// When the next "recent" row runs out, so one timer can be set for it.
    static func nextExpiry(
        live: [AudioApp], lastPlayed: [String: Date], now: Date, recentWindow: TimeInterval
    ) -> Date? {
        let playing = Set(live.filter(\.isPlaying).map(\.id))
        return lastPlayed
            .filter { !playing.contains($0.key) && now.timeIntervalSince($0.value) < recentWindow }
            .map { $0.value.addingTimeInterval(recentWindow) }
            .min()
    }

    private static func sorted(_ rows: [AudioAppRow]) -> [AudioAppRow] {
        rows.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }
}

/// How one app's audio is captured and where it is played.
struct TapPlan: Equatable {
    /// Device the processed audio is played on.
    let outputUID: String
    /// Device whose streams are tapped, one tap per stream, channels mapped
    /// 1:1. Nil taps a stereo mix of everything the app plays, on any device.
    let captureUID: String?
    /// Number of output streams on the captured device.
    let captureStreams: Int
    /// For a stereo mix: 0-based output channels it lands on.
    let stereoLeft: Int
    let stereoRight: Int
    /// For a stereo mix on a multi-output device: copy it to every stream.
    let mirror: Bool
}

struct AudioOutputFacts: Equatable {
    let streamCount: Int
    let isMultiOutput: Bool
    let stereoLeft: Int
    let stereoRight: Int
}

enum AudioRouting {
    /// The app's own output device, if it is set, connected and not simply the default.
    static func override(
        _ settings: AudioAppSettings, defaultUID: String?, outputs: [String: AudioOutputFacts]
    ) -> String? {
        guard let uid = settings.outputUID, uid != defaultUID, outputs[uid] != nil else { return nil }
        return uid
    }

    /// Nil means the app needs no tap at all and plays untouched.
    static func plan(
        _ settings: AudioAppSettings, defaultUID: String?, outputs: [String: AudioOutputFacts]
    ) -> TapPlan? {
        let route = override(settings, defaultUID: defaultUID, outputs: outputs)
        guard settings.muted || settings.volume != 1 || route != nil else { return nil }
        guard let target = route ?? defaultUID, let facts = outputs[target], facts.streamCount > 0 else { return nil }
        // Staying on the default device: tap exactly what the app sends to
        // that device, stream by stream, in the device's own channel layout.
        // Audio the app sends to some other device is left alone.
        // Moving to another device: take a stereo mix of everything the app
        // plays, wherever it plays it, and put it on the target's stereo pair.
        return TapPlan(
            outputUID: target, captureUID: route == nil ? target : nil,
            captureStreams: route == nil ? facts.streamCount : 0,
            stereoLeft: facts.stereoLeft, stereoRight: facts.stereoRight, mirror: facts.isMultiOutput)
    }
}

/// Decides when a tap that should be passing audio has stopped doing so.
enum TapWatchdog {
    struct Track: Equatable {
        var lastCycles: UInt64 = 0
        var stalledChecks = 0
        var restarts = 0
    }

    enum Action: Equatable { case none, restart, giveUp }

    static let interval: TimeInterval = 2
    /// Consecutive checks without progress before acting (so about 4 s).
    static let stallChecks = 2
    static let maxRestarts = 2

    /// `cycles` is the tap's IO cycle count; `expectingIO` is whether the app
    /// is playing on the tapped device right now. While a tapped app plays,
    /// cycles must advance: if they do not, the app may be muted with nothing
    /// replaying it, so the tap is rebuilt, and after repeated failures removed
    /// (which returns the app to its own, untouched output).
    static func step(_ track: inout Track, cycles: UInt64, expectingIO: Bool) -> Action {
        defer { track.lastCycles = cycles }
        if cycles != track.lastCycles {
            track.stalledChecks = 0
            track.restarts = 0
            return .none
        }
        guard expectingIO else {
            track.stalledChecks = 0
            return .none
        }
        track.stalledChecks += 1
        guard track.stalledChecks >= stallChecks else { return .none }
        track.stalledChecks = 0
        track.restarts += 1
        return track.restarts > maxRestarts ? .giveUp : .restart
    }
}

/// Cleanup of taps and aggregate devices a previous Bosun left behind.
///
/// Every object Bosun creates carries `Bosun-Tap-<pid>` at the start of its
/// name (taps) or UID (aggregate devices). A leftover is only ever destroyed
/// when that PID is not a running Bosun, so one instance can never remove
/// another live instance's objects.
enum TapOrphans {
    static func ownerPID(of name: String) -> pid_t? {
        guard name.hasPrefix(AudioDevices.privatePrefix) else { return nil }
        let digits = name.dropFirst(AudioDevices.privatePrefix.count).prefix { $0.isNumber }
        guard !digits.isEmpty, let pid = pid_t(digits), pid > 0 else { return nil }
        return pid
    }

    static func shouldDestroy(name: String, ownPID: pid_t, isLiveBosun: (pid_t) -> Bool) -> Bool {
        guard let owner = ownerPID(of: name), owner != ownPID else { return false }
        return !isLiveBosun(owner)
    }
}
