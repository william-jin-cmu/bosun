import Foundation
import AppKit
import UserNotifications

/// Threshold rule with hysteresis. A rule fires once when its value has been past the
/// threshold for `sustain` evaluations in a row, then stays quiet until the value has
/// come back past the threshold by `margin` (re-arming it), and in any case never fires
/// twice within `cooldown` seconds. Pure, so the behaviour is covered by the self-test.
struct AlertRule: Equatable {
    var threshold: Double
    var above: Bool            // true: fires when value >= threshold; false: when value <= threshold
    var margin: Double         // how far back past the threshold the value must go to re-arm
    var sustain: Int           // consecutive breaching evaluations required
    var cooldown: TimeInterval // minimum seconds between two notifications

    struct State: Equatable {
        var active = false
        var streak = 0
        var lastFired: TimeInterval?
    }

    /// Feeds one reading; returns true when a notification should be posted now.
    /// A nil value (reading unavailable) changes nothing.
    func step(_ state: inout State, value: Double?, now: TimeInterval) -> Bool {
        guard let value else { return false }
        let breached = above ? value >= threshold : value <= threshold
        let recovered = above ? value < threshold - margin : value > threshold + margin
        if state.active {
            if recovered {
                state.active = false
                state.streak = 0
            }
            return false
        }
        guard breached else {
            state.streak = 0
            return false
        }
        state.streak += 1
        guard state.streak >= max(1, sustain) else { return false }
        state.active = true
        if let last = state.lastFired, now - last < cooldown, now >= last { return false }
        state.lastFired = now
        return true
    }

    static func rule(for kind: AlertKind, threshold: Double) -> AlertRule {
        switch kind {
        case .cpuTemperature:   // evaluated every ~10 s: must hold for ~30 s
            AlertRule(threshold: threshold, above: true, margin: 5, sustain: 3, cooldown: 15 * 60)
        case .memoryPressure:
            AlertRule(threshold: threshold, above: true, margin: 0, sustain: 3, cooldown: 30 * 60)
        case .diskSpace:        // GB free
            AlertRule(threshold: threshold, above: false, margin: 2, sustain: 1, cooldown: 6 * 3600)
        case .batteryLow:
            AlertRule(threshold: threshold, above: false, margin: 5, sustain: 1, cooldown: 30 * 60)
        case .batteryCharged:
            AlertRule(threshold: threshold, above: true, margin: 5, sustain: 1, cooldown: 60 * 60)
        case .batteryHealth:
            AlertRule(threshold: threshold, above: false, margin: 2, sustain: 1, cooldown: 7 * 24 * 3600)
        }
    }
}

struct AlertEvent: Equatable {
    var kind: AlertKind
    var title: String
    var body: String
}

/// The readings the alert rules look at; nil = not available this round.
struct AlertInputs: Equatable {
    var cpuTemperature: Double?
    var memoryPressure: MemoryUsage.Pressure?
    var bootFreeBytes: Int64?
    var battery: BatteryInfo?
}

/// Holds one rule state per alert. Touched from the sampling queue only.
struct AlertEngine {
    private(set) var states: [AlertKind: AlertRule.State] = [:]

    init(lastFired: [AlertKind: TimeInterval] = [:]) {
        for (kind, time) in lastFired { states[kind] = AlertRule.State(lastFired: time) }
    }

    /// The value each rule compares against its threshold, in the threshold's unit.
    static func value(_ kind: AlertKind, _ inputs: AlertInputs) -> Double? {
        switch kind {
        case .cpuTemperature: return inputs.cpuTemperature
        case .memoryPressure: return inputs.memoryPressure.map { Double($0.rawValue) }
        case .diskSpace: return inputs.bootFreeBytes.map { Double($0) / 1e9 }
        case .batteryLow:
            // Only while running on the battery; plugging in counts as recovered.
            return inputs.battery.map { $0.onAC ? 100 : Double($0.percent) }
        case .batteryCharged:
            return inputs.battery.map { $0.onAC ? Double($0.percent) : 0 }
        case .batteryHealth:
            return inputs.battery.flatMap { $0.health.map { $0 * 100 } }
        }
    }

    mutating func evaluate(_ inputs: AlertInputs, enabled: Set<AlertKind>, thresholds: (AlertKind) -> Double,
                           fahrenheit: Bool, now: TimeInterval) -> [AlertEvent] {
        var events: [AlertEvent] = []
        for kind in AlertKind.allCases {
            guard enabled.contains(kind) else {
                // Disabling an alert re-arms it but keeps the cooldown clock.
                if let state = states[kind] { states[kind] = AlertRule.State(lastFired: state.lastFired) }
                continue
            }
            let rule = AlertRule.rule(for: kind, threshold: thresholds(kind))
            var state = states[kind] ?? AlertRule.State()
            let value = Self.value(kind, inputs)
            let fire = rule.step(&state, value: value, now: now)
            states[kind] = state
            if fire, let value { events.append(Self.event(kind, value: value, inputs: inputs, fahrenheit: fahrenheit)) }
        }
        return events
    }

    static func event(_ kind: AlertKind, value: Double, inputs: AlertInputs, fahrenheit: Bool) -> AlertEvent {
        switch kind {
        case .cpuTemperature:
            return AlertEvent(kind: kind, title: "CPU is running hot",
                              body: "The CPU has stayed at \(Format.temperature(value, fahrenheit: fahrenheit)) for a while.")
        case .memoryPressure:
            let level = inputs.memoryPressure?.label.lowercased() ?? "high"
            return AlertEvent(kind: kind, title: "Memory pressure is \(level)",
                              body: "macOS is short on memory. Closing apps or browser tabs will help.")
        case .diskSpace:
            return AlertEvent(kind: kind, title: "Startup disk is almost full",
                              body: "\(Format.disk(inputs.bootFreeBytes ?? Int64(value * 1e9))) available.")
        case .batteryLow:
            return AlertEvent(kind: kind, title: "Battery at \(Int(value))%",
                              body: inputs.battery?.remainingText.map { "About \($0)." } ?? "Running on battery power.")
        case .batteryCharged:
            return AlertEvent(kind: kind, title: "Battery charged to \(Int(value))%",
                              body: "You can unplug the charger.")
        case .batteryHealth:
            return AlertEvent(kind: kind, title: "Battery health is \(Int(value.rounded()))%",
                              body: "Full-charge capacity has dropped below your alert level.")
        }
    }
}

/// Posts the alerts as user notifications. Nothing here touches UserNotifications until
/// the user turns an alert on, and never when Bosun runs outside an app bundle (the
/// framework aborts the process without a bundle identifier).
@MainActor
final class MonitorNotifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum Status: Equatable {
        case unknown, unavailable, notDetermined, denied, authorized
    }
    @Published private(set) var status: Status = .unknown

    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    private var center: UNUserNotificationCenter? {
        guard Self.isAvailable else { return nil }
        let center = UNUserNotificationCenter.current()
        if center.delegate == nil { center.delegate = self }
        return center
    }

    static func status(from settings: UNAuthorizationStatus) -> Status {
        switch settings {
        case .authorized, .provisional: .authorized
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Re-reads the permission state (the user may have changed it in System Settings).
    func refresh() {
        guard let center else {
            status = .unavailable
            return
        }
        center.getNotificationSettings { [weak self] settings in
            let status = Self.status(from: settings.authorizationStatus)
            DispatchQueue.main.async { self?.status = status }
        }
    }

    /// Shows the system permission prompt if it has not been answered yet.
    func requestAuthorization() {
        guard let center else {
            status = .unavailable
            return
        }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] _, error in
            if let error { Log.info("notification permission: \(error.localizedDescription)", "monitor") }
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Dropped silently (with a log line) when notifications are unavailable or denied.
    func post(_ event: AlertEvent) {
        guard let center else {
            Log.info("alert not shown (no app bundle): \(event.title)", "monitor")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default
        // Same identifier per kind: a newer alert replaces the older one instead of stacking.
        let request = UNNotificationRequest(identifier: "monitor.\(event.kind.rawValue)", content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let error else { return }
            Log.info("alert not delivered: \(error.localizedDescription)", "monitor")
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // Show the banner even while a Bosun window is frontmost.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
