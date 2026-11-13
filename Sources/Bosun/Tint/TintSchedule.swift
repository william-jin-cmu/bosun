import Foundation

enum TintPhase: String, CaseIterable, Identifiable {
    case day, sunset, bedtime
    var id: String { rawValue }
    var title: String {
        switch self {
        case .day: "Daytime"
        case .sunset: "Sunset"
        case .bedtime: "Bedtime"
        }
    }
    var symbol: String {
        switch self {
        case .day: "sun.max"
        case .sunset: "sunset"
        case .bedtime: "moon.zzz"
        }
    }
}

/// How long a scheduled change takes.
enum TintRamp: String, CaseIterable, Identifiable {
    case natural, fast, medium, slow, verySlow
    var id: String { rawValue }
    var title: String {
        switch self {
        case .natural: "Follow the twilight"
        case .fast: "Fast (20 seconds)"
        case .medium: "Medium (5 minutes)"
        case .slow: "Slow (20 minutes)"
        case .verySlow: "Very slow (60 minutes)"
        }
    }
    /// Nil for `.natural`, which follows the sun's elevation instead of a clock.
    var duration: TimeInterval? {
        switch self {
        case .natural: nil
        case .fast: 20
        case .medium: 300
        case .slow: 1200
        case .verySlow: 3600
        }
    }
}

/// Everything that decides what colour the screen should be at a given moment.
struct TintSchedule: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case sun, fixed
        var id: String { rawValue }
        var title: String { self == .sun ? "Sunrise and sunset" : "Fixed times" }
    }

    var mode: Mode = .sun
    var dayKelvin = 6500.0
    var sunsetKelvin = 3400.0
    var bedtimeKelvin = 2700.0
    var latitude = 31.2
    var longitude = 121.4
    /// Minutes after local midnight.
    var wakeMinutes = 8 * 60 + 30
    var bedtimeEnabled = true
    /// Bedtime starts this long before the wake time.
    var bedtimeLeadMinutes = 9 * 60
    /// Fixed-times mode: when the daytime colour starts and ends.
    var fixedDayStart = 7 * 60
    var fixedEveningStart = 19 * 60
    var ramp: TintRamp = .natural

    func kelvin(for phase: TintPhase) -> Double {
        switch phase {
        case .day: dayKelvin
        case .sunset: sunsetKelvin
        case .bedtime: bedtimeKelvin
        }
    }

    mutating func setKelvin(_ value: Double, for phase: TintPhase) {
        switch phase {
        case .day: dayKelvin = value
        case .sunset: sunsetKelvin = value
        case .bedtime: bedtimeKelvin = value
        }
    }

    /// Minutes after local midnight at which bedtime starts.
    var bedtimeStartMinutes: Int {
        ((wakeMinutes - bedtimeLeadMinutes) % 1440 + 1440) % 1440
    }

    /// Duration of the day/evening change. Fixed times have no twilight to follow.
    var sunRampDuration: TimeInterval? {
        if let duration = ramp.duration { return duration }
        return mode == .sun ? nil : 3600
    }

    var bedtimeRampDuration: TimeInterval { ramp.duration ?? 3600 }

    /// True when `other` differs only in colours, so the same event times apply.
    func hasSameTiming(as other: TintSchedule) -> Bool {
        var a = self, b = other
        for phase in TintPhase.allCases { a.setKelvin(0, for: phase); b.setKelvin(0, for: phase) }
        return a == b
    }

    static func clockString(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        return String(format: "%02d:%02d", m / 60, m % 60)
    }
}

/// The schedule laid out on the real time line around one moment: when the
/// sun (or the fixed clock times) switches between day and evening, and when
/// bedtime starts and ends. Pure data; all colour questions are answered from it.
struct TintTimeline {
    struct Toggle: Equatable {
        let date: Date
        let on: Bool
    }

    var schedule: TintSchedule
    let builtAt: Date
    let start: Date
    let end: Date
    /// `on` = daytime begins.
    let sunInitial: Bool
    let sun: [Toggle]
    /// `on` = bedtime begins.
    let bedInitial: Bool
    let bed: [Toggle]

    static let lookBehind: TimeInterval = 30 * 3600
    static let lookAhead: TimeInterval = 54 * 3600

    init(schedule: TintSchedule, around now: Date, calendar: Calendar) {
        self.schedule = schedule
        builtAt = now
        start = now.addingTimeInterval(-Self.lookBehind)
        end = now.addingTimeInterval(Self.lookAhead)

        switch schedule.mode {
        case .sun:
            sunInitial = Solar.isUp(at: start, latitude: schedule.latitude, longitude: schedule.longitude)
            sun = Solar.crossings(from: start, to: end, latitude: schedule.latitude, longitude: schedule.longitude)
                .map { Toggle(date: $0.date, on: $0.isSunrise) }
        case .fixed:
            var raw: [Toggle] = []
            if schedule.fixedDayStart != schedule.fixedEveningStart {
                raw += Self.occurrences(ofMinute: schedule.fixedDayStart, from: start, to: end, calendar: calendar)
                    .map { Toggle(date: $0, on: true) }
                raw += Self.occurrences(ofMinute: schedule.fixedEveningStart, from: start, to: end, calendar: calendar)
                    .map { Toggle(date: $0, on: false) }
            }
            (sunInitial, sun) = Self.normalised(raw, start: start, end: end, fallbackInitial: true)
        }

        var raw: [Toggle] = []
        if schedule.bedtimeEnabled, schedule.bedtimeLeadMinutes > 0 {
            let lead = TimeInterval(min(schedule.bedtimeLeadMinutes, 23 * 60) * 60)
            for wake in Self.occurrences(ofMinute: schedule.wakeMinutes, from: start, to: end, calendar: calendar) {
                raw.append(Toggle(date: wake.addingTimeInterval(-lead), on: true))
                raw.append(Toggle(date: wake, on: false))
            }
        }
        (bedInitial, bed) = Self.normalised(raw, start: start, end: end, fallbackInitial: false)
    }

    /// Every moment the local clock reads `minute` (minutes after midnight),
    /// from two days before `start` to two days after `end`.
    static func occurrences(ofMinute minute: Int, from start: Date, to end: Date, calendar: Calendar) -> [Date] {
        let m = ((minute % 1440) + 1440) % 1440
        var result: [Date] = []
        var day = calendar.startOfDay(for: start.addingTimeInterval(-2 * 86400))
        let limit = end.addingTimeInterval(2 * 86400)
        while day <= limit {
            if let date = calendar.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: day) {
                result.append(date)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = calendar.startOfDay(for: next)
        }
        return result
    }

    /// Sorts, works out the state at `start`, keeps what falls inside the window
    /// and drops toggles that would not change anything.
    static func normalised(_ raw: [Toggle], start: Date, end: Date, fallbackInitial: Bool) -> (Bool, [Toggle]) {
        let sorted = raw.enumerated().sorted {
            $0.element.date != $1.element.date ? $0.element.date < $1.element.date : $0.offset < $1.offset
        }.map(\.element)
        var initial = fallbackInitial
        if let last = sorted.last(where: { $0.date <= start }) {
            initial = last.on
        } else if let first = sorted.first {
            initial = !first.on
        }
        var state = initial
        var kept: [Toggle] = []
        for toggle in sorted where toggle.date > start && toggle.date <= end && toggle.on != state {
            kept.append(toggle)
            state = toggle.on
        }
        return (initial, kept)
    }

    /// True when the timeline can answer questions about `date` and a day beyond it.
    func covers(_ date: Date) -> Bool {
        date >= start.addingTimeInterval(2 * 3600) && date <= end.addingTimeInterval(-26 * 3600)
    }

    /// 0...1 weight of a toggled state at `date`, each toggle eased over `duration` centred on it.
    static func weight(_ toggles: [Toggle], initial: Bool, at date: Date, duration: TimeInterval) -> Double {
        let half = max(0, duration / 2)
        var w = initial ? 1.0 : 0.0
        for toggle in toggles {
            let offset = date.timeIntervalSince(toggle.date)
            if offset < -half { break }
            let progress = half > 0 ? TintMath.smoothstep((offset + half) / (2 * half)) : 1
            w += toggle.on ? progress : -progress
        }
        return TintMath.clamp01(w)
    }

    /// 1 = full daytime colour, 0 = full sunset colour.
    func dayWeight(at date: Date) -> Double {
        if let duration = schedule.sunRampDuration {
            return Self.weight(sun, initial: sunInitial, at: date, duration: duration)
        }
        let elevation = Solar.elevation(at: date, latitude: schedule.latitude, longitude: schedule.longitude)
        return TintMath.clamp01((elevation - Solar.horizon + 6) / 12)
    }

    func bedtimeWeight(at date: Date) -> Double {
        Self.weight(bed, initial: bedInitial, at: date, duration: schedule.bedtimeRampDuration)
    }

    func kelvin(at date: Date) -> Double {
        let awake = TintMath.lerp(schedule.sunsetKelvin, schedule.dayKelvin, dayWeight(at: date))
        return TintMath.lerp(awake, schedule.bedtimeKelvin, bedtimeWeight(at: date))
    }

    /// Bedtime wins over everything; otherwise the sun decides.
    func phase(at date: Date) -> TintPhase {
        if bedtimeWeight(at: date) >= 0.5 { return .bedtime }
        return dayWeight(at: date) >= 0.5 ? .day : .sunset
    }

    /// The next moment the phase becomes something else, and what it becomes.
    func nextChange(after date: Date) -> (date: Date, phase: TintPhase)? {
        let current = phase(at: date)
        let candidates = (sun + bed).map(\.date).filter { $0 > date }.sorted()
        for candidate in candidates {
            let after = phase(at: candidate.addingTimeInterval(1))
            if after != current { return (candidate, after) }
        }
        return nil
    }

    /// The next time daytime begins: sunrise, or the fixed day start.
    func nextDayStart(after date: Date) -> Date? {
        sun.first { $0.on && $0.date > date }?.date
    }

    func nextWake(after date: Date) -> Date? {
        bed.first { !$0.on && $0.date > date }?.date
    }

    /// Day/evening switches inside `range`, for labels and chart markers.
    func sunEvents(in range: ClosedRange<Date>) -> [Toggle] { sun.filter { range.contains($0.date) } }
    func bedEvents(in range: ClosedRange<Date>) -> [Toggle] { bed.filter { range.contains($0.date) } }

    /// The largest colour change over the next `interval`, used to decide how often to redraw.
    func slope(at date: Date, over interval: TimeInterval = 1) -> Double {
        abs(kelvin(at: date.addingTimeInterval(interval)) - kelvin(at: date))
    }
}

/// A critically damped spring: follows a moving target without overshoot or
/// velocity jumps, so manual changes glide instead of stepping.
struct TintSpring: Equatable {
    var value: Double
    var velocity = 0.0

    mutating func step(toward target: Double, dt: Double, omega: Double) {
        guard dt > 0 else { return }
        let c1 = value - target
        let c2 = velocity + omega * c1
        let decay = exp(-omega * dt)
        value = target + (c1 + c2 * dt) * decay
        velocity = (c2 - omega * (c1 + c2 * dt)) * decay
    }

    func isSettled(at target: Double) -> Bool {
        abs(value - target) < 0.5 && abs(velocity) < 2
    }
}

/// Why the tint is switched off right now, if it is.
enum TintSuppression: Equatable {
    case paused(until: Date?)      // nil = until turned back on
    case app(name: String)

    /// `pausedUntil == .distantFuture` means "until I turn it back on".
    static func evaluate(now: Date, pausedUntil: Date?, frontmostBundleID: String?, frontmostName: String?,
                         excludedBundleIDs: Set<String>) -> TintSuppression? {
        if let until = pausedUntil, until > now {
            return .paused(until: until == .distantFuture ? nil : until)
        }
        if let id = frontmostBundleID, excludedBundleIDs.contains(id.lowercased()) {
            return .app(name: frontmostName ?? id)
        }
        return nil
    }
}

enum TintLevel {
    /// The Kelvin one display should show.
    /// - Parameters:
    ///   - scheduled: what the schedule asks for
    ///   - strength: 0 = no tint, 1 = full
    ///   - offset: per-display correction in Kelvin (negative = warmer)
    ///   - active: false while paused, excluded by app, or the display is excluded
    static func kelvin(scheduled: Double, strength: Double, offset: Double, active: Bool) -> Double {
        guard active else { return ColorTemperature.neutral }
        let base = TintMath.lerp(ColorTemperature.neutral, scheduled, TintMath.clamp01(strength))
        return min(ColorTemperature.neutral, max(1000, base + offset))
    }
}
