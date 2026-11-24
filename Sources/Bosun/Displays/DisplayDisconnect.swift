import CoreGraphics
import Foundation

/// Turns a display off as far as macOS is concerned while the cable stays in:
/// it leaves the arrangement, windows move to the remaining screens and the
/// GPU stops rendering for it. Power delivery and USB over the same cable are
/// not affected, so a monitor that charges the Mac keeps charging it.
///
/// Uses the private `CGSConfigureDisplayEnabled` inside a display
/// configuration transaction (the same call BetterDisplay's "Disconnect"
/// uses), resolved at run time. Committed for the session only, so a logout
/// or restart always brings every display back.
enum DisplayEnabler {
    private typealias ConfigureFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32

    private static let configure: ConfigureFn? = {
        let path = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
        guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: ConfigureFn.self)
    }()

    static var isAvailable: Bool { configure != nil }

    /// Blocking for a moment while the window server reconfigures.
    @discardableResult
    static func set(_ displayID: CGDirectDisplayID, enabled: Bool) -> Bool {
        guard let configure else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let result = configure(config, displayID, enabled)
        guard result == 0 else {
            CGCancelDisplayConfiguration(config)
            Log.info("CGSConfigureDisplayEnabled(\(displayID), \(enabled)) returned \(result)", "displays")
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    /// Displays the Mac sees, connected or not.
    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}

/// A display Bosun disconnected and can bring back.
struct DisconnectedDisplay: Codable, Equatable, Identifiable {
    let id: CGDirectDisplayID
    var key: String
    var name: String
    var isBuiltIn: Bool
    var since: Date
}

/// Pure rules around disconnecting, checked by the self-test.
enum DisplayDisconnectLogic {
    /// Never take away the last screen: there would be no way to click
    /// Reconnect.
    static func canDisconnect(_ id: CGDirectDisplayID, active: [CGDirectDisplayID]) -> Bool {
        active.contains(id) && active.count > 1
    }

    /// Entries that are no longer ours to reconnect because the display is
    /// active again (re-plugged, or reconnected by another tool). A re-plugged
    /// display usually comes back under a new ID, so an active display with
    /// the same key also clears the entry.
    static func prune(_ list: [DisconnectedDisplay], active: [CGDirectDisplayID],
                      activeKeys: Set<String> = []) -> [DisconnectedDisplay] {
        list.filter { !active.contains($0.id) && !activeKeys.contains($0.key) }
    }

    /// Adds a freshly disconnected display, replacing any older entry for the
    /// same physical display (same key, possibly an older ID).
    static func adding(_ entry: DisconnectedDisplay, to list: [DisconnectedDisplay]) -> [DisconnectedDisplay] {
        list.filter { $0.id != entry.id && $0.key != entry.key } + [entry]
    }

    /// One entry per physical display; the most recent wins. Cleans up lists
    /// stored before entries were keyed.
    static func deduplicated(_ list: [DisconnectedDisplay]) -> [DisconnectedDisplay] {
        var seen = Set<String>()
        return list.sorted { $0.since > $1.since }
            .filter { seen.insert($0.key).inserted }
            .sorted { $0.since < $1.since }
    }

    static let defaultsKey = "displays.disconnected"

    static func load(_ defaults: UserDefaults = .standard) -> [DisconnectedDisplay] {
        guard let data = defaults.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([DisconnectedDisplay].self, from: data) else { return [] }
        return deduplicated(list)
    }

    static func save(_ list: [DisconnectedDisplay], _ defaults: UserDefaults = .standard) {
        if list.isEmpty {
            defaults.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}
