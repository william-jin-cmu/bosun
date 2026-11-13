import ColorSync
import QuartzCore
import SwiftUI

struct TintApp: Identifiable, Equatable {
    /// Bundle identifier.
    var id: String
    var name: String
}

struct TintDisplayPref: Equatable {
    var excluded = false
    /// Kelvin added to the scheduled colour on this display (negative = warmer).
    var offset = 0.0
}

struct TintDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    /// Stable across reconnects; what preferences are stored under.
    let key: String
    let name: String
    let isBuiltin: Bool
}

/// Loading, migrating and saving the module's preferences.
enum TintPreferences {
    static let knownTintApps = ["org.herf.Flux": "f.lux"]

    /// Order of precedence for each value: Bosun's own key, the key an earlier
    /// version used, f.lux's setting, the default.
    static func loadSchedule(defaults: UserDefaults, flux: [String: Any]?) -> TintSchedule {
        var s = TintSchedule()
        func number(_ key: String) -> Double? {
            // double(forKey:) rather than a cast, so command-line overrides (strings) work too.
            defaults.object(forKey: key) != nil ? defaults.double(forKey: key) : nil
        }
        func fluxNumber(_ key: String) -> Double? { (flux?[key] as? NSNumber)?.doubleValue }
        var fluxLocation: (Double, Double)?
        if let text = flux?["location"] as? String {
            let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { fluxLocation = (parts[0], parts[1]) }
        }
        func kelvin(_ value: Double) -> Double {
            min(max(value, ColorTemperature.range.lowerBound), ColorTemperature.range.upperBound)
        }
        func minutes(_ value: Double) -> Int { ((Int(value) % 1440) + 1440) % 1440 }

        let legacyNight = number("tint.night")
        s.dayKelvin = kelvin(number("tint.day") ?? fluxNumber("dayColorTemp") ?? s.dayKelvin)
        s.sunsetKelvin = kelvin(number("tint.sunset") ?? legacyNight ?? fluxNumber("nightColorTemp") ?? s.sunsetKelvin)
        s.bedtimeKelvin = kelvin(number("tint.bedtime") ?? legacyNight ?? fluxNumber("lateColorTemp") ?? s.bedtimeKelvin)
        s.latitude = min(90, max(-90, number("tint.latitude") ?? fluxLocation?.0 ?? s.latitude))
        s.longitude = min(180, max(-180, number("tint.longitude") ?? fluxLocation?.1 ?? s.longitude))
        s.wakeMinutes = minutes(number("tint.wake") ?? fluxNumber("wakeTime") ?? Double(s.wakeMinutes))
        if defaults.object(forKey: "tint.bedtimeEnabled") != nil { s.bedtimeEnabled = defaults.bool(forKey: "tint.bedtimeEnabled") }
        s.bedtimeLeadMinutes = min(14 * 60, max(60, Int(number("tint.bedtimeLead") ?? Double(s.bedtimeLeadMinutes))))
        s.fixedDayStart = minutes(number("tint.fixedDayStart") ?? Double(s.fixedDayStart))
        s.fixedEveningStart = minutes(number("tint.fixedEveningStart") ?? Double(s.fixedEveningStart))
        s.mode = defaults.string(forKey: "tint.mode").flatMap(TintSchedule.Mode.init(rawValue:)) ?? s.mode
        s.ramp = defaults.string(forKey: "tint.ramp").flatMap(TintRamp.init(rawValue:)) ?? s.ramp
        return s
    }

    static func save(_ s: TintSchedule, to defaults: UserDefaults) {
        defaults.set(s.dayKelvin, forKey: "tint.day")
        defaults.set(s.sunsetKelvin, forKey: "tint.sunset")
        defaults.set(s.bedtimeKelvin, forKey: "tint.bedtime")
        defaults.set(s.latitude, forKey: "tint.latitude")
        defaults.set(s.longitude, forKey: "tint.longitude")
        defaults.set(s.wakeMinutes, forKey: "tint.wake")
        defaults.set(s.bedtimeEnabled, forKey: "tint.bedtimeEnabled")
        defaults.set(s.bedtimeLeadMinutes, forKey: "tint.bedtimeLead")
        defaults.set(s.fixedDayStart, forKey: "tint.fixedDayStart")
        defaults.set(s.fixedEveningStart, forKey: "tint.fixedEveningStart")
        defaults.set(s.mode.rawValue, forKey: "tint.mode")
        defaults.set(s.ramp.rawValue, forKey: "tint.ramp")
        // Superseded by tint.sunset / tint.bedtime.
        defaults.removeObject(forKey: "tint.night")
    }

    static func loadApps(defaults: UserDefaults) -> [TintApp] {
        (defaults.array(forKey: "tint.excludedApps") as? [[String: String]] ?? []).compactMap { entry in
            guard let id = entry["id"], !id.isEmpty else { return nil }
            return TintApp(id: id, name: entry["name"] ?? id)
        }
    }

    static func save(_ apps: [TintApp], to defaults: UserDefaults) {
        defaults.set(apps.map { ["id": $0.id, "name": $0.name] }, forKey: "tint.excludedApps")
    }

    static func loadDisplays(defaults: UserDefaults) -> [String: TintDisplayPref] {
        var result: [String: TintDisplayPref] = [:]
        for (key, value) in defaults.dictionary(forKey: "tint.displays") ?? [:] {
            guard let entry = value as? [String: Any] else { continue }
            let offset = (entry["offset"] as? NSNumber)?.doubleValue ?? 0
            result[key] = TintDisplayPref(excluded: (entry["excluded"] as? NSNumber)?.boolValue ?? false,
                                          offset: min(2000, max(-2000, offset)))
        }
        return result
    }

    static func save(_ prefs: [String: TintDisplayPref], to defaults: UserDefaults) {
        defaults.set(prefs.mapValues { ["excluded": $0.excluded, "offset": $0.offset] as [String: Any] }, forKey: "tint.displays")
    }
}

@MainActor
final class TintModule: ObservableObject, BosunModule {
    let id = "tint"
    let title = "Color Temperature"
    let symbol = "sun.max"
    // Off until asked for: two apps tinting the screen at once fight each other.
    let enabledByDefault = false

    // MARK: Settings

    @Published var schedule: TintSchedule { didSet { scheduleChanged(from: oldValue) } }
    /// 0...1: how much of the scheduled tint is applied.
    @Published var strength: Double {
        didSet {
            UserDefaults.standard.set(strength, forKey: "tint.strength")
            settingsChanged()
        }
    }
    @Published var excludedApps: [TintApp] {
        didSet {
            TintPreferences.save(excludedApps, to: .standard)
            settingsChanged(gently: true)
        }
    }
    @Published var displayPrefs: [String: TintDisplayPref] {
        didSet {
            TintPreferences.save(displayPrefs, to: .standard)
            settingsChanged()
        }
    }

    // MARK: Status

    @Published private(set) var timeline: TintTimeline
    @Published private(set) var isRunning = false
    /// What the main tinted display shows right now.
    @Published private(set) var currentKelvin = ColorTemperature.neutral
    @Published private(set) var phase: TintPhase = .day
    @Published private(set) var nextChange: (date: Date, phase: TintPhase)?
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var suppression: TintSuppression?
    /// Another app is tinting the screen, so Bosun is leaving the gamma tables alone.
    @Published private(set) var standby = false
    @Published private(set) var otherTintApp: String?
    @Published private(set) var nightShift: NightShift.Status?
    @Published private(set) var displays: [TintDisplay] = []
    /// The app the user was last in (never Bosun itself).
    @Published private(set) var frontApp: TintApp?
    /// The pretend time while the 24-hour preview runs.
    @Published private(set) var sweepDate: Date?
    @Published private(set) var reassertCount = 0
    @Published private(set) var lastReassert: Date?

    let location = TintLocation()

    // MARK: Private state

    private let gamma = GammaController()
    private var springs: [CGDirectDisplayID: TintSpring] = [:]
    private var slowTimer: Timer?
    private var fastTimer: Timer?
    private var lastFrame: CFTimeInterval = 0
    private var lastPublish: CFTimeInterval = 0
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var running = false
    private var animateIn = false
    private var takeOverOnce = false
    private var omega = TintModule.gentle
    private var foreignEvents: [Date] = []
    private var previewPhase: TintPhase?
    private var sweep: (started: CFTimeInterval, from: Date)?
    private var slowTicks = 0
    private var reconfigurationPending = false

    /// Spring rates: `brisk` tracks a slider, `gentle` is for on/off changes (about a second).
    private static let brisk = 11.0
    private static let gentle = 4.5
    private static let sweepDuration: CFTimeInterval = 12

    init() {
        let defaults = UserDefaults.standard
        // First run: carry over f.lux's settings if it has been used on this Mac.
        let flux = defaults.persistentDomain(forName: "org.herf.Flux")
        let loaded = TintPreferences.loadSchedule(defaults: defaults, flux: flux)
        schedule = loaded
        strength = defaults.object(forKey: "tint.strength") != nil ? TintMath.clamp01(defaults.double(forKey: "tint.strength")) : 1
        excludedApps = TintPreferences.loadApps(defaults: defaults)
        displayPrefs = TintPreferences.loadDisplays(defaults: defaults)
        timeline = TintTimeline(schedule: loaded, around: Date(), calendar: .current)
        // Freeze what was imported or migrated, so it no longer depends on f.lux staying installed.
        if defaults.object(forKey: "tint.sunset") == nil, !CommandLine.arguments.contains("--selftest") {
            TintPreferences.save(loaded, to: defaults)
        }
        location.onFix = { [weak self] latitude, longitude in
            self?.schedule.latitude = latitude
            self?.schedule.longitude = longitude
        }
        refreshDisplays()
        refreshEnvironment()
        refreshStatus()
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        isRunning = true
        animateIn = true
        // Test hook: write over another app's tint instead of standing by.
        takeOverOnce = ProcessInfo.processInfo.environment["BOSUN_TINT_TAKEOVER"] != nil
        omega = Self.gentle
        foreignEvents = []
        springs = [:]
        refreshDisplays()
        refreshEnvironment()
        frontApp = Self.app(NSWorkspace.shared.frontmostApplication) ?? frontApp
        rebuildTimeline()

        let slow = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowTick() }
        }
        slow.tolerance = 0.1
        RunLoop.main.add(slow, forMode: .common)
        slowTimer = slow

        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification) { $0.systemChangedDisplays() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.systemChangedDisplays() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.systemChangedDisplays() }
        observe(workspace, NSWorkspace.didTerminateApplicationNotification) { $0.refreshEnvironment() }
        observe(workspace, NSWorkspace.didLaunchApplicationNotification) { $0.refreshEnvironment() }
        let token = workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.appActivated(activated) }
        }
        observers.append((workspace, token))
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.systemChangedDisplays() }
        observe(.default, .NSSystemTimeZoneDidChange) { $0.rebuildTimeline(); $0.evaluate() }
        observe(.default, .NSSystemClockDidChange) { $0.rebuildTimeline(); $0.evaluate() }
        observe(.default, .NSCalendarDayChanged) { $0.rebuildTimeline() }
        // Posted when a display's ColorSync profile is switched; the system reloads the gamma table with it.
        let profileChange = kColorSyncDisplayDeviceProfilesNotification.takeUnretainedValue() as String
        observe(DistributedNotificationCenter.default(), Notification.Name(profileChange)) { $0.systemChangedDisplays() }
        CGDisplayRegisterReconfigurationCallback(tintReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())

        evaluate()
    }

    func stop() {
        guard running else { return }
        running = false
        isRunning = false
        slowTimer?.invalidate()
        slowTimer = nil
        fastTimer?.invalidate()
        fastTimer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers.removeAll()
        CGDisplayRemoveReconfigurationCallback(tintReconfigurationCallback, Unmanaged.passUnretained(self).toOpaque())

        // A short fade instead of a jump back to the untinted screen. Synchronous
        // (plain sleeps, no run loop) because this also runs while the app quits.
        let fading = gamma.ownedDisplays.compactMap { id in gamma.appliedKelvin(id).map { (id, $0) } }
            .filter { $0.1 < ColorTemperature.neutral - 20 }
        if !fading.isEmpty {
            let steps = 24
            for step in 1...steps {
                let t = TintMath.smoothstep(Double(step) / Double(steps))
                for (id, from) in fading { gamma.apply(kelvin: TintMath.lerp(from, ColorTemperature.neutral, t), to: id) }
                usleep(11_000)
            }
        }
        gamma.restore()
        springs = [:]
        standby = false
        pausedUntil = nil
        previewPhase = nil
        sweep = nil
        sweepDate = nil
        currentKelvin = ColorTemperature.neutral
        refreshStatus()
    }

    func panelVisibilityChanged(_ visible: Bool) {
        guard visible, running else { return }
        refreshEnvironment()
        refreshStatus()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (TintModule) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                action(self)
            }
        }
        observers.append((center, token))
    }

    // MARK: Commands

    func pause(for interval: TimeInterval) { pause(until: Date().addingTimeInterval(interval)) }

    /// Until the next sunrise (or fixed day start); falls back to the wake time, then to 12 hours.
    func pauseUntilSunrise() {
        let now = Date()
        pause(until: timeline.nextDayStart(after: now) ?? timeline.nextWake(after: now) ?? now.addingTimeInterval(12 * 3600))
    }

    func pauseIndefinitely() { pause(until: .distantFuture) }

    private func pause(until date: Date) {
        pausedUntil = date
        omega = Self.gentle
        evaluate()
    }

    func resume() {
        pausedUntil = nil
        omega = Self.gentle
        evaluate()
    }

    func isExcluded(_ app: TintApp) -> Bool {
        excludedApps.contains { $0.id.caseInsensitiveCompare(app.id) == .orderedSame }
    }

    func exclude(_ app: TintApp) {
        guard !isExcluded(app) else { return }
        excludedApps.append(app)
    }

    func removeExclusion(_ app: TintApp) {
        excludedApps.removeAll { $0.id.caseInsensitiveCompare(app.id) == .orderedSame }
    }

    func pref(for display: TintDisplay) -> TintDisplayPref { displayPrefs[display.key] ?? TintDisplayPref() }

    func setPref(_ pref: TintDisplayPref, for display: TintDisplay) {
        if pref == TintDisplayPref() { displayPrefs[display.key] = nil } else { displayPrefs[display.key] = pref }
    }

    /// While a colour slider is held, show that phase's colour whatever the time is.
    func beginPreview(of phase: TintPhase) {
        guard running else { return }
        previewPhase = phase
        omega = Self.brisk
        evaluate()
    }

    func endPreview() {
        guard previewPhase != nil else { return }
        previewPhase = nil
        omega = Self.gentle
        evaluate()
    }

    /// Runs the next 24 hours of the schedule in a few seconds.
    func toggleDayPreview() {
        guard running else { return }
        if sweep != nil {
            sweep = nil
            sweepDate = nil
            omega = Self.gentle
        } else {
            sweep = (CACurrentMediaTime(), Date())
            omega = Self.brisk
        }
        evaluate()
    }

    /// Stop yielding to the other tinting app and write our tint over its.
    func takeOver() {
        guard running, standby else { return }
        standby = false
        takeOverOnce = true
        animateIn = false
        foreignEvents = []
        springs = [:]
        evaluate()
    }

    // MARK: Reacting to changes

    private func scheduleChanged(from old: TintSchedule) {
        guard schedule != old else { return }
        TintPreferences.save(schedule, to: .standard)
        if schedule.hasSameTiming(as: old) {
            timeline.schedule = schedule
        } else {
            rebuildTimeline()
        }
        settingsChanged()
    }

    private func settingsChanged(gently: Bool = false) {
        omega = gently ? Self.gentle : Self.brisk
        if running { evaluate() } else { refreshStatus() }
    }

    private func rebuildTimeline() {
        timeline = TintTimeline(schedule: schedule, around: Date(), calendar: .current)
    }

    private func appActivated(_ app: NSRunningApplication?) {
        guard running, let app = Self.app(app) else { return }
        frontApp = app
        omega = Self.gentle
        evaluate()
    }

    private static func app(_ running: NSRunningApplication?) -> TintApp? {
        guard let running, running.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let id = running.bundleIdentifier else { return nil }
        return TintApp(id: id, name: running.localizedName ?? id)
    }

    /// Wake, display reconfiguration, profile switch: the system has probably
    /// reloaded the gamma tables, so look immediately instead of waiting for the poll.
    fileprivate func systemChangedDisplays() {
        guard running else { return }
        refreshDisplays()
        for display in displays { gamma.refreshProfile(display.id) }
        audit()
        advance(dt: nil)
    }

    fileprivate func reconfigured() {
        guard !reconfigurationPending else { return }
        reconfigurationPending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.reconfigurationPending = false
                self?.systemChangedDisplays()
            }
        }
    }

    private func refreshDisplays() {
        let online = GammaController.onlineDisplays()
        gamma.prune(keeping: online)
        springs = springs.filter { online.contains($0.key) }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        let main = CGMainDisplayID()
        let list = online.sorted { ($0 == main ? 0 : 1, $0) < ($1 == main ? 0 : 1, $1) }.map { id -> TintDisplay in
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            let builtin = CGDisplayIsBuiltin(id) != 0
            return TintDisplay(id: id, key: uuid ?? "display-\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))",
                               name: names[id] ?? (builtin ? "Built-in Display" : "Display \(id)"), isBuiltin: builtin)
        }
        if list != displays { displays = list }
    }

    private func refreshEnvironment() {
        let other = NSWorkspace.shared.runningApplications.lazy
            .compactMap { $0.bundleIdentifier.flatMap { TintPreferences.knownTintApps[$0] } }.first
        if other != otherTintApp { otherTintApp = other }
        let shift = NightShift.status()
        if shift != nightShift { nightShift = shift }
    }

    // MARK: The loop

    private func clock() -> Date {
        guard let sweep else { return Date() }
        let progress = (CACurrentMediaTime() - sweep.started) / Self.sweepDuration
        return sweep.from.addingTimeInterval(min(1, progress) * 24 * 3600)
    }

    private func slowTick() {
        guard running else { return }
        slowTicks += 1
        if slowTicks % 30 == 0 { refreshEnvironment() }
        if Set(GammaController.onlineDisplays()) != Set(displays.map(\.id)) { refreshDisplays() }
        refreshStatus()
        audit()
        if fastTimer == nil { advance(dt: nil) }
    }

    /// Recomputes and applies everything now (after a setting or state change).
    private func evaluate() {
        guard running else { refreshStatus(); return }
        refreshStatus()
        advance(dt: nil)
    }

    /// Checks that the gamma tables still hold what we wrote.
    private func audit() {
        if standby {
            // The other app let go (it quit, or went neutral): the tables are back to the profile.
            let managed = displays.filter { !pref(for: $0).excluded }
            if !managed.isEmpty, managed.allSatisfy({ gamma.inspect($0.id) != .foreign }) {
                Log.info("gamma tables are free again, taking over", "tint")
                standby = false
                animateIn = true
                omega = Self.gentle
                foreignEvents = []
                springs = [:]
            }
            return
        }
        var sawForeign: [CGDirectDisplayID] = []
        for id in gamma.ownedDisplays {
            switch gamma.inspect(id) {
            case .ours, .unreadable:
                continue
            case .baseline:
                // The system reset the table (wake, reconfiguration, HDR switch, another gamma app quitting).
                gamma.apply(kelvin: gamma.appliedKelvin(id) ?? ColorTemperature.neutral, to: id, force: true)
                reassertCount += 1
                lastReassert = Date()
            case .foreign:
                sawForeign.append(id)
            }
        }
        guard !sawForeign.isEmpty else { return }
        let now = Date()
        foreignEvents = foreignEvents.filter { now.timeIntervalSince($0) < 90 } + [now]
        if foreignEvents.count >= 2 {
            // Writing again would only make the screen flicker between two tints.
            enterStandby(reason: "another app keeps rewriting the gamma tables")
        } else {
            for id in sawForeign {
                gamma.apply(kelvin: gamma.appliedKelvin(id) ?? ColorTemperature.neutral, to: id, force: true)
            }
        }
    }

    private func enterStandby(reason: String) {
        Log.info("standing by: \(reason)", "tint")
        for id in gamma.ownedDisplays { gamma.abandon(id) }
        springs = [:]
        standby = true
        sweep = nil
        sweepDate = nil
        previewPhase = nil
        setFast(false)
        refreshEnvironment()
        publishKelvin(force: true)
    }

    /// Moves every display one step towards where it should be and writes the result.
    /// `dt == nil` is the once-a-second pass; otherwise an animation frame.
    private func advance(dt: Double?) {
        guard running, !standby else { return }
        if sweep != nil, CACurrentMediaTime() - (sweep?.started ?? 0) >= Self.sweepDuration {
            sweep = nil
            sweepDate = nil
            omega = Self.gentle
        }
        let date = clock()
        if sweep != nil { sweepDate = date }
        if !timeline.covers(Date()) { rebuildTimeline() }

        let overriding = previewPhase != nil || sweep != nil
        let scheduled = previewPhase.map(schedule.kelvin(for:)) ?? timeline.kelvin(at: date)
        let suppressed = !overriding && suppression != nil
        var animating = false

        for display in displays {
            let pref = pref(for: display)
            let target = TintLevel.kelvin(scheduled: scheduled, strength: strength, offset: pref.offset,
                                          active: !suppressed && !pref.excluded)
            var spring = springs[display.id] ?? TintSpring(value: animateIn ? ColorTemperature.neutral : target)
            if let dt { spring.step(toward: target, dt: dt, omega: omega) }
            // A scheduled ramp moves a few Kelvin per second at most; follow it directly.
            let settled = spring.isSettled(at: target) || (dt == nil && fastTimer == nil && abs(spring.value - target) < 4)
            if settled { spring = TintSpring(value: target) } else { animating = true }
            spring.value = min(ColorTemperature.neutral, max(1000, spring.value))
            springs[display.id] = spring

            if settled, spring.value >= ColorTemperature.neutral - 0.01 {
                // Nothing to tint: hand the table back rather than guarding an identity.
                if gamma.owns(display.id) { gamma.release(display.id) }
                continue
            }
            if !gamma.owns(display.id) {
                // About to take the display: never tint on top of someone else's tint.
                if !takeOverOnce, gamma.inspect(display.id) == .foreign {
                    enterStandby(reason: "\(display.name) is already tinted by another app")
                    return
                }
            }
            gamma.apply(kelvin: spring.value, to: display.id)
        }
        animateIn = false
        takeOverOnce = false
        let ramping = !suppressed && previewPhase == nil && timeline.slope(at: date) > 2
        setFast(animating || sweep != nil || ramping)
        if !animating, sweep == nil { omega = Self.brisk }
        publishKelvin(force: !animating)
    }

    private func setFast(_ on: Bool) {
        if on, fastTimer == nil {
            lastFrame = CACurrentMediaTime()
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame() }
            }
            // .common, so the tint keeps gliding while a slider or menu is tracking.
            RunLoop.main.add(timer, forMode: .common)
            fastTimer = timer
        } else if !on, let timer = fastTimer {
            timer.invalidate()
            fastTimer = nil
        }
    }

    private func frame() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, max(0.001, now - lastFrame))
        lastFrame = now
        advance(dt: dt)
    }

    private func publishKelvin(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastPublish > 0.1 else { return }
        lastPublish = now
        var value = ColorTemperature.neutral
        if !standby, let primary = displays.first(where: { !pref(for: $0).excluded }) {
            value = springs[primary.id]?.value ?? value
        }
        value = value.rounded()
        if value != currentKelvin { currentKelvin = value }
    }

    /// Phase, next change and what is suppressing the tint. Cheap; only publishes real changes.
    private func refreshStatus() {
        let now = Date()
        if let until = pausedUntil, until <= now { pausedUntil = nil }
        if !timeline.covers(now) { rebuildTimeline() }
        let newSuppression = TintSuppression.evaluate(
            now: now, pausedUntil: pausedUntil, frontmostBundleID: frontApp?.id, frontmostName: frontApp?.name,
            excludedBundleIDs: Set(excludedApps.map { $0.id.lowercased() }))
        if newSuppression != suppression {
            suppression = newSuppression
            omega = Self.gentle
        }
        let newPhase = timeline.phase(at: now)
        if newPhase != phase { phase = newPhase }
        let change = timeline.nextChange(after: now)
        if change?.date != nextChange?.date || change?.phase != nextChange?.phase { nextChange = change }
        if !running {
            let scheduled = TintLevel.kelvin(scheduled: timeline.kelvin(at: now), strength: strength, offset: 0, active: true).rounded()
            if scheduled != currentKelvin { currentKelvin = scheduled }
        }
    }
}

private func tintReconfigurationCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag), let userInfo else { return }
    let module = Unmanaged<TintModule>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        MainActor.assumeIsolated { module.reconfigured() }
    }
}
