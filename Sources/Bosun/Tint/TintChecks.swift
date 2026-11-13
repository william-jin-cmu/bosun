import ColorSync
import CoreGraphics
import Foundation

/// Headless checks for the colour maths, the schedule and the gamma plumbing.
/// Nothing here writes a gamma table unless `BOSUN_TINT_LIVE=1` is set: a
/// process that has written one makes the system reset *every* display's table
/// when it exits, which would flash the screen on each `--selftest`.
enum TintChecks {
    private static func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, _ s: Int = 0, zone: String = "Asia/Shanghai") -> Date {
        calendar(zone).date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private static func minutesIntoDay(_ date: Date, zone: String = "Asia/Shanghai") -> Double {
        date.timeIntervalSince(calendar(zone).startOfDay(for: date)) / 60
    }

    /// The user's f.lux setup: 3400 / 3100 / 3100, wake 08:30, Shanghai.
    private static var shanghai: TintSchedule {
        var s = TintSchedule()
        s.dayKelvin = 3400; s.sunsetKelvin = 3100; s.bedtimeKelvin = 2300
        s.latitude = 31.2; s.longitude = 121.4
        s.wakeMinutes = 510; s.bedtimeLeadMinutes = 540
        s.ramp = .fast
        return s
    }

    private static func timeline(_ schedule: TintSchedule, around: Date, zone: String = "Asia/Shanghai") -> TintTimeline {
        TintTimeline(schedule: schedule, around: around, calendar: calendar(zone))
    }

    static let all: [SelfTest.Check] = [
        ("tint: 6500 K is neutral and warmer removes blue first", {
            for primaries in [DisplayPrimaries.sRGB, .displayP3] {
                let neutral = ColorTemperature.multipliers(kelvin: 6500, primaries: primaries)
                guard neutral == (1, 1, 1) else { return "6500K -> \(neutral)" }
                let warm = ColorTemperature.multipliers(kelvin: 3400, primaries: primaries)
                guard warm.r == 1, warm.g < 1, warm.b < warm.g, warm.b > 0.3, warm.b < 0.7 else { return "3400K -> \(warm)" }
                let warmer = ColorTemperature.multipliers(kelvin: 2700, primaries: primaries)
                guard warmer.b < warm.b, warmer.g < warm.g else { return "2700K -> \(warmer)" }
            }
            return nil
        }),
        ("tint: color is continuous and monotonic from 1200 K to 6500 K", {
            for primaries in [DisplayPrimaries.sRGB, .displayP3] {
                var previous = ColorTemperature.multipliers(kelvin: 1200, primaries: primaries)
                for kelvin in stride(from: 1210.0, through: 6500, by: 10) {
                    let m = ColorTemperature.multipliers(kelvin: kelvin, primaries: primaries)
                    guard m.r == 1 else { return "red \(m.r) at \(kelvin)" }
                    guard m.g >= previous.g - 1e-9, m.b >= previous.b - 1e-9 else { return "not monotonic at \(kelvin): \(previous) -> \(m)" }
                    guard m.g - previous.g < 0.008, m.b - previous.b < 0.05 else { return "jump at \(kelvin): \(previous) -> \(m)" }
                    previous = m
                }
            }
            return nil
        }),
        ("tint: 3400 K on a P3 display matches what f.lux writes", {
            // Read from the gamma tables on this Mac while f.lux was showing 3400 K: g 0.8022877, b 0.5752859.
            let m = ColorTemperature.multipliers(kelvin: 3400, primaries: .displayP3)
            guard abs(m.g - 0.8023) < 0.004, abs(m.b - 0.5753) < 0.004 else { return "\(m)" }
            return nil
        }),
        ("tint: display primaries are read from a color space", {
            guard let p3 = CGColorSpace(name: CGColorSpace.displayP3), let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let fromP3 = DisplayPrimaries(colorSpace: p3), let fromSRGB = DisplayPrimaries(colorSpace: srgb) else { return "no primaries" }
            func distance(_ a: DisplayPrimaries, _ b: DisplayPrimaries) -> Double {
                zip(a.xyzToRGB, b.xyzToRGB).map { abs($0 - $1) }.max() ?? 9
            }
            guard distance(fromP3, .displayP3) < 0.02 else { return "P3 off by \(distance(fromP3, .displayP3))" }
            guard distance(fromSRGB, .sRGB) < 0.02 else { return "sRGB off by \(distance(fromSRGB, .sRGB))" }
            guard let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2), DisplayPrimaries(colorSpace: gray) == nil else { return "gray accepted" }
            return nil
        }),
        ("tint: sun elevation matches known values for Shanghai", {
            // Summer solstice 2026, local solar noon is about 03:56 UTC: 90 - 31.2 + 23.44 = 82.2 degrees.
            let noon = Date(timeIntervalSince1970: 1_782_014_160)
            let high = Solar.elevation(at: noon, latitude: 31.2, longitude: 121.4)
            guard abs(high - 82.2) < 0.5 else { return "noon elevation \(high)" }
            let midnight = Solar.elevation(at: noon.addingTimeInterval(12 * 3600), latitude: 31.2, longitude: 121.4)
            guard midnight < -30 else { return "midnight elevation \(midnight)" }
            return nil
        }),
        ("tint: sunrise and sunset on 2026-11-13 in Shanghai are about 06:18 and 16:57", {
            let dayStart = date(2026, 11, 13, 0, 0)
            guard dayStart.timeIntervalSince1970 == 1_794_499_200 else { return "calendar maths is off: \(dayStart.timeIntervalSince1970)" }
            let events = Solar.crossings(from: dayStart, to: dayStart.addingTimeInterval(86400), latitude: 31.2, longitude: 121.4)
            guard events.count == 2, events[0].isSunrise, !events[1].isSunrise else { return "events \(events)" }
            let rise = minutesIntoDay(events[0].date), set = minutesIntoDay(events[1].date)
            guard abs(rise - (6 * 60 + 18)) < 5 else { return "sunrise at minute \(rise)" }
            guard abs(set - (16 * 60 + 57)) < 5 else { return "sunset at minute \(set)" }
            guard let next = Solar.nextHorizonCrossing(after: dayStart.addingTimeInterval(12 * 3600), latitude: 31.2, longitude: 121.4),
                  !next.isSunrise, next.date == events[1].date || abs(next.date.timeIntervalSince(events[1].date)) < 5 else { return "next crossing differs" }
            return nil
        }),
        ("tint: other latitudes — London midsummer, the equator, polar day and night", {
            // London 2026-06-21: sunrise 04:43, sunset 21:21 BST.
            let london = date(2026, 6, 21, 0, 0, zone: "Europe/London")
            let events = Solar.crossings(from: london, to: london.addingTimeInterval(86400), latitude: 51.5074, longitude: -0.1278)
            guard events.count == 2, events[0].isSunrise else { return "london \(events)" }
            let rise = minutesIntoDay(events[0].date, zone: "Europe/London"), set = minutesIntoDay(events[1].date, zone: "Europe/London")
            guard abs(rise - (4 * 60 + 43)) < 5, abs(set - (21 * 60 + 21)) < 5 else { return "london rise \(rise) set \(set)" }
            // Quito at the equinox: twelve hours of day, give or take refraction.
            let quito = date(2026, 3, 20, 0, 0, zone: "America/Guayaquil")
            let q = Solar.crossings(from: quito, to: quito.addingTimeInterval(86400), latitude: -0.18, longitude: -78.47)
            guard q.count == 2, abs(q[1].date.timeIntervalSince(q[0].date) / 3600 - 12.1) < 0.15 else { return "quito \(q)" }
            // Tromsø: no sunset in June, no sunrise in December.
            let june = date(2026, 6, 21, 0, 0, zone: "Europe/Oslo"), december = date(2026, 12, 21, 0, 0, zone: "Europe/Oslo")
            guard Solar.crossings(from: june, to: june.addingTimeInterval(86400), latitude: 69.65, longitude: 18.96).isEmpty,
                  Solar.isUp(at: june, latitude: 69.65, longitude: 18.96) else { return "midnight sun missing" }
            guard Solar.crossings(from: december, to: december.addingTimeInterval(86400), latitude: 69.65, longitude: 18.96).isEmpty,
                  !Solar.isUp(at: december.addingTimeInterval(12 * 3600), latitude: 69.65, longitude: 18.96) else { return "polar night missing" }
            var polar = shanghai
            polar.latitude = 69.65; polar.longitude = 18.96; polar.bedtimeEnabled = false
            let line = timeline(polar, around: june.addingTimeInterval(12 * 3600), zone: "Europe/Oslo")
            guard line.phase(at: june.addingTimeInterval(2 * 3600)) == .day, line.nextChange(after: june) == nil else { return "polar day schedule" }
            return nil
        }),
        ("tint: schedule blends through twilight", {
            let values = [10.0, 6, 0, -6, -20].map { ColorTemperature.target(day: 6500, night: 3500, sunElevation: $0) }
            guard values == [6500, 6500, 5000, 3500, 3500] else { return "\(values)" }
            // The natural ramp: full day colour 6° above the horizon, full sunset colour 6° below, monotonic between.
            var s = shanghai
            s.ramp = .natural; s.bedtimeEnabled = false; s.dayKelvin = 6500; s.sunsetKelvin = 3400
            let line = timeline(s, around: date(2026, 11, 13, 12, 0))
            var previous = line.kelvin(at: date(2026, 11, 13, 15, 0))
            guard previous == 6500 else { return "15:00 is \(previous)" }
            for minute in stride(from: 15 * 60, through: 18 * 60 + 30, by: 1) {
                let at = date(2026, 11, 13, minute / 60, minute % 60)
                let k = line.kelvin(at: at)
                let elevation = Solar.elevation(at: at, latitude: 31.2, longitude: 121.4) - Solar.horizon
                guard k <= previous + 1e-6, previous - k < 60 else { return "step at \(minute): \(previous) -> \(k)" }
                if elevation > 6.01, k != 6500 { return "\(k) at elevation \(elevation)" }
                if elevation < -6.01, k != 3400 { return "\(k) at elevation \(elevation)" }
                previous = k
            }
            return previous == 3400 ? nil : "18:30 is \(previous)"
        }),
        ("tint: three phases through a Shanghai day, with the next change", {
            let line = timeline(shanghai, around: date(2026, 11, 13, 12, 0))
            let expectations: [(Date, TintPhase, Double)] = [
                (date(2026, 11, 13, 3, 0), .bedtime, 2300),
                (date(2026, 11, 13, 7, 0), .bedtime, 2300),      // sun is up but the wake time has not come
                (date(2026, 11, 13, 8, 29), .bedtime, 2300),
                (date(2026, 11, 13, 8, 31), .day, 3400),
                (date(2026, 11, 13, 12, 0), .day, 3400),
                (date(2026, 11, 13, 16, 30), .day, 3400),
                (date(2026, 11, 13, 17, 30), .sunset, 3100),
                (date(2026, 11, 13, 23, 29), .sunset, 3100),
                (date(2026, 11, 13, 23, 31), .bedtime, 2300),
                (date(2026, 11, 14, 0, 0), .bedtime, 2300),       // across midnight
                (date(2026, 11, 14, 8, 31), .day, 3400),
            ]
            for (at, phase, kelvin) in expectations {
                guard line.phase(at: at) == phase else { return "phase at \(at) is \(line.phase(at: at))" }
                guard abs(line.kelvin(at: at) - kelvin) < 0.01 else { return "kelvin at \(at) is \(line.kelvin(at: at))" }
            }
            guard let afternoon = line.nextChange(after: date(2026, 11, 13, 12, 0)), afternoon.phase == .sunset,
                  abs(minutesIntoDay(afternoon.date) - (16 * 60 + 57)) < 5 else { return "next after noon" }
            guard let evening = line.nextChange(after: date(2026, 11, 13, 20, 0)), evening.phase == .bedtime,
                  evening.date == date(2026, 11, 13, 23, 30) else { return "next after 20:00" }
            guard let night = line.nextChange(after: date(2026, 11, 14, 2, 0)), night.phase == .day,
                  night.date == date(2026, 11, 14, 8, 30) else { return "next after 02:00" }
            guard let rise = line.nextDayStart(after: date(2026, 11, 13, 20, 0)),
                  abs(minutesIntoDay(rise) - (6 * 60 + 19)) < 5, rise > date(2026, 11, 14, 0, 0) else { return "until sunrise" }
            guard line.nextWake(after: date(2026, 11, 13, 20, 0)) == date(2026, 11, 14, 8, 30) else { return "next wake" }
            return nil
        }),
        ("tint: wake-time edge cases", {
            guard shanghai.bedtimeStartMinutes == 23 * 60 + 30 else { return "bedtime start \(shanghai.bedtimeStartMinutes)" }
            // Waking before sunrise: awake in the dark gets the sunset colour until the sun is up.
            var early = shanghai
            early.wakeMinutes = 5 * 60
            guard early.bedtimeStartMinutes == 20 * 60 else { return "early bedtime start \(early.bedtimeStartMinutes)" }
            var line = timeline(early, around: date(2026, 11, 13, 12, 0))
            guard line.phase(at: date(2026, 11, 13, 4, 59)) == .bedtime, line.phase(at: date(2026, 11, 13, 5, 30)) == .sunset,
                  line.phase(at: date(2026, 11, 13, 7, 0)) == .day else { return "early wake phases" }
            guard let next = line.nextChange(after: date(2026, 11, 13, 5, 30)), next.phase == .day,
                  abs(minutesIntoDay(next.date) - (6 * 60 + 18)) < 5 else { return "early wake next change" }
            // Bedtime that starts before sunset skips the sunset phase altogether.
            var veryEarly = shanghai
            veryEarly.wakeMinutes = 30
            guard veryEarly.bedtimeStartMinutes == 15 * 60 + 30 else { return "wrap \(veryEarly.bedtimeStartMinutes)" }
            line = timeline(veryEarly, around: date(2026, 11, 13, 12, 0))
            guard line.phase(at: date(2026, 11, 13, 15, 0)) == .day, line.phase(at: date(2026, 11, 13, 16, 0)) == .bedtime,
                  line.phase(at: date(2026, 11, 13, 20, 0)) == .bedtime, line.phase(at: date(2026, 11, 14, 0, 29)) == .bedtime,
                  line.phase(at: date(2026, 11, 14, 0, 31)) == .sunset else { return "very early wake phases" }
            guard let skip = line.nextChange(after: date(2026, 11, 13, 15, 0)), skip.phase == .bedtime else { return "skip sunset" }
            // Midnight wake time and the longest lead.
            var midnight = shanghai
            midnight.wakeMinutes = 0; midnight.bedtimeLeadMinutes = 840
            guard midnight.bedtimeStartMinutes == 10 * 60 else { return "midnight wrap" }
            line = timeline(midnight, around: date(2026, 11, 13, 12, 0))
            guard line.phase(at: date(2026, 11, 13, 9, 59)) == .day, line.phase(at: date(2026, 11, 13, 10, 1)) == .bedtime,
                  line.phase(at: date(2026, 11, 13, 23, 59)) == .bedtime, line.phase(at: date(2026, 11, 14, 0, 1)) == .sunset else { return "midnight wake phases" }
            // No bedtime at all.
            var none = shanghai
            none.bedtimeEnabled = false
            line = timeline(none, around: date(2026, 11, 13, 12, 0))
            guard line.phase(at: date(2026, 11, 13, 3, 0)) == .sunset, line.bed.isEmpty,
                  line.nextChange(after: date(2026, 11, 13, 20, 0))?.phase == .day else { return "bedtime off" }
            return nil
        }),
        ("tint: fixed-times mode ignores the sun", {
            var fixed = shanghai
            fixed.mode = .fixed; fixed.fixedDayStart = 7 * 60; fixed.fixedEveningStart = 19 * 60; fixed.wakeMinutes = 6 * 60
            var line = timeline(fixed, around: date(2026, 11, 13, 12, 0))
            guard line.phase(at: date(2026, 11, 13, 6, 30)) == .sunset, line.phase(at: date(2026, 11, 13, 7, 1)) == .day,
                  line.phase(at: date(2026, 11, 13, 18, 59)) == .day, line.phase(at: date(2026, 11, 13, 19, 1)) == .sunset,
                  line.phase(at: date(2026, 11, 13, 21, 1)) == .bedtime else { return "fixed phases" }
            guard line.nextChange(after: date(2026, 11, 13, 12, 0))?.date == date(2026, 11, 13, 19, 0),
                  line.nextDayStart(after: date(2026, 11, 13, 12, 0)) == date(2026, 11, 14, 7, 0) else { return "fixed next change" }
            var elsewhere = fixed
            elsewhere.latitude = 69.65; elsewhere.longitude = 18.96
            let other = timeline(elsewhere, around: date(2026, 11, 13, 12, 0))
            guard other.sun == line.sun, other.kelvin(at: date(2026, 11, 13, 18, 0)) == line.kelvin(at: date(2026, 11, 13, 18, 0)) else { return "location leaked into fixed mode" }
            // Night-shift worker: "day" runs from 20:00 to 08:00.
            fixed.fixedDayStart = 20 * 60; fixed.fixedEveningStart = 8 * 60; fixed.bedtimeEnabled = false
            line = timeline(fixed, around: date(2026, 11, 13, 12, 0))
            guard line.phase(at: date(2026, 11, 13, 12, 0)) == .sunset, line.phase(at: date(2026, 11, 13, 22, 0)) == .day,
                  line.phase(at: date(2026, 11, 14, 3, 0)) == .day, line.phase(at: date(2026, 11, 14, 9, 0)) == .sunset else { return "inverted fixed phases" }
            // Same start and end: nothing to switch, stays in the day colour.
            fixed.fixedEveningStart = fixed.fixedDayStart
            line = timeline(fixed, around: date(2026, 11, 13, 12, 0))
            guard line.sun.isEmpty, line.phase(at: date(2026, 11, 13, 12, 0)) == .day else { return "degenerate fixed times" }
            // "Follow the twilight" has no meaning here and falls back to an hour.
            fixed.ramp = .natural
            guard fixed.sunRampDuration == 3600, shanghai.sunRampDuration == 20 else { return "ramp fallback" }
            var natural = shanghai
            natural.ramp = .natural
            guard natural.sunRampDuration == nil, natural.bedtimeRampDuration == 3600 else { return "natural ramp" }
            return nil
        }),
        ("tint: ramps are centered, eased and never step", {
            for ramp in TintRamp.allCases {
                guard let duration = ramp.duration else { continue }
                var s = shanghai
                s.ramp = ramp; s.dayKelvin = 6500; s.sunsetKelvin = 3400; s.bedtimeKelvin = 1900
                let line = timeline(s, around: date(2026, 11, 13, 12, 0))
                guard let sunset = line.sun.first(where: { !$0.on && $0.date > date(2026, 11, 13, 12, 0) })?.date else { return "no sunset" }
                guard line.kelvin(at: sunset.addingTimeInterval(-duration / 2)) == 6500,
                      line.kelvin(at: sunset.addingTimeInterval(duration / 2)) == 3400,
                      abs(line.kelvin(at: sunset) - 4950) < 0.01 else { return "\(ramp) not centered on sunset" }
                let bedtime = date(2026, 11, 13, 23, 30)
                guard abs(line.kelvin(at: bedtime) - 2650) < 0.01, line.kelvin(at: bedtime.addingTimeInterval(duration / 2 + 1)) == 1900 else { return "\(ramp) bedtime ramp" }
                // Walk a whole day in small steps: the colour may never move faster than the ease allows.
                let step = max(0.05, duration / 400)
                let limit = 4600 * 1.5 * step / duration + 0.001
                var t = sunset.addingTimeInterval(-duration)
                var previous = line.kelvin(at: t)
                for window in [sunset, bedtime, date(2026, 11, 14, 8, 30)] {
                    t = window.addingTimeInterval(-duration)
                    previous = line.kelvin(at: t)
                    while t < window.addingTimeInterval(duration) {
                        t = t.addingTimeInterval(step)
                        let k = line.kelvin(at: t)
                        guard abs(k - previous) <= limit else { return "\(ramp) steps \(abs(k - previous)) K at \(t)" }
                        guard k >= 1900 - 1e-6, k <= 6500 + 1e-6 else { return "\(ramp) out of range \(k)" }
                        previous = k
                    }
                }
            }
            // Overlapping ramps (bedtime 20 minutes after sunset, hour-long ramps) still stay continuous.
            var tight = shanghai
            tight.ramp = .verySlow; tight.dayKelvin = 6500; tight.sunsetKelvin = 3400; tight.bedtimeKelvin = 1900
            tight.wakeMinutes = 2 * 60 + 15     // bedtime 17:15
            let line = timeline(tight, around: date(2026, 11, 13, 12, 0))
            var previous = line.kelvin(at: date(2026, 11, 13, 15, 0))
            for second in stride(from: 0, through: 4 * 3600, by: 5) {
                let k = line.kelvin(at: date(2026, 11, 13, 15, 0).addingTimeInterval(Double(second)))
                guard abs(k - previous) < 15, k <= previous + 1e-6 else { return "overlap steps \(previous) -> \(k)" }
                previous = k
            }
            return previous == 1900 ? nil : "overlap ends at \(previous)"
        }),
        ("tint: daylight-saving changes keep the timeline ordered", {
            // 2026-03-08 02:00 PST jumps to 03:00 PDT; a 02:30 wake time does not exist that day.
            var s = shanghai
            s.mode = .fixed; s.wakeMinutes = 2 * 60 + 30; s.bedtimeLeadMinutes = 480
            for around in [date(2026, 3, 8, 12, 0, zone: "America/Los_Angeles"), date(2026, 11, 1, 12, 0, zone: "America/Los_Angeles")] {
                let line = timeline(s, around: around, zone: "America/Los_Angeles")
                for toggles in [line.sun, line.bed] {
                    guard toggles.count >= 6 else { return "too few toggles: \(toggles.count)" }
                    for (a, b) in zip(toggles, toggles.dropFirst()) {
                        guard a.date < b.date, a.on != b.on else { return "disordered toggles around \(a.date)" }
                    }
                }
                guard line.covers(around), line.covers(around.addingTimeInterval(24 * 3600)), !line.covers(around.addingTimeInterval(40 * 3600)) else { return "coverage" }
            }
            let spring = timeline(s, around: date(2026, 3, 8, 12, 0, zone: "America/Los_Angeles"), zone: "America/Los_Angeles")
            guard spring.bed.contains(where: { !$0.on && $0.date == date(2026, 3, 8, 3, 0, zone: "America/Los_Angeles") })
                    || spring.bed.contains(where: { !$0.on && $0.date == date(2026, 3, 8, 3, 30, zone: "America/Los_Angeles") }) else {
                return "skipped-hour wake time lost"
            }
            // Fixed day start keeps its wall-clock time on both sides of the change.
            guard spring.sun.contains(Toggle(date: date(2026, 3, 7, 7, 0, zone: "America/Los_Angeles"), on: true)),
                  spring.sun.contains(Toggle(date: date(2026, 3, 9, 7, 0, zone: "America/Los_Angeles"), on: true)) else { return "fixed start drifted" }
            return nil
        }),
        ("tint: colour-only edits keep the timeline; timing edits do not", {
            var edited = shanghai
            edited.bedtimeKelvin = 1900; edited.dayKelvin = 5000
            guard shanghai.hasSameTiming(as: edited) else { return "colour edit changed timing" }
            for change in [{ (s: inout TintSchedule) in s.wakeMinutes += 1 }, { $0.latitude += 1 }, { $0.mode = .fixed },
                           { $0.ramp = .slow }, { $0.bedtimeEnabled = false }, { $0.bedtimeLeadMinutes -= 30 }, { $0.fixedDayStart += 1 }] {
                var other = shanghai
                change(&other)
                guard !shanghai.hasSameTiming(as: other) else { return "timing edit not noticed" }
            }
            var s = shanghai
            s.setKelvin(2000, for: .sunset)
            guard s.kelvin(for: .sunset) == 2000, s.kelvin(for: .day) == 3400, s.kelvin(for: .bedtime) == 2300 else { return "per-phase accessors" }
            return TintSchedule.clockString(1410) == "23:30" && TintSchedule.clockString(-30) == "23:30" ? nil : "clock string"
        }),
        ("tint: manual changes glide (spring) without overshoot or a velocity jump", {
            var spring = TintSpring(value: 6500)
            var previous = spring.value
            for _ in 0..<180 {
                spring.step(toward: 3100, dt: 1.0 / 60, omega: 4.5)
                guard spring.value <= previous + 1e-9, spring.value >= 3100 - 1e-6 else { return "overshoot at \(spring.value)" }
                // Peak speed is distance × omega / e: about 94 K per frame here, 1.3% of the blue channel.
                guard previous - spring.value < 100 else { return "step of \(previous - spring.value) K in one frame" }
                previous = spring.value
            }
            guard abs(spring.value - 3100) < 0.5 else { return "not settled after 3 s: \(spring.value)" }
            guard spring.isSettled(at: 3100), !TintSpring(value: 3200).isSettled(at: 3100) else { return "settle test" }
            // Retargeting mid-flight keeps the velocity (no kink), and one long step equals many short ones.
            var a = TintSpring(value: 6500), b = TintSpring(value: 6500)
            for _ in 0..<30 { a.step(toward: 3100, dt: 1.0 / 60, omega: 11) }
            b.step(toward: 3100, dt: 0.5, omega: 11)
            guard abs(a.value - b.value) < 0.01, abs(a.velocity - b.velocity) < 0.01 else { return "step size changes the path: \(a) vs \(b)" }
            let velocity = a.velocity
            a.step(toward: 6500, dt: 1e-6, omega: 11)
            guard abs(a.velocity - velocity) < 1 else { return "velocity jumped on retarget" }
            a.step(toward: 6500, dt: 30, omega: 11)
            return abs(a.value - 6500) < 1e-6 && a.value.isFinite ? nil : "long step unstable: \(a)"
        }),
        ("tint: pause and per-app exclusion decide when the tint is off", {
            let now = Date(timeIntervalSince1970: 1_794_540_000)
            let excluded: Set<String> = ["com.adobe.photoshop", "com.apple.finalcut"]
            func evaluate(_ until: Date?, _ app: String?) -> TintSuppression? {
                TintSuppression.evaluate(now: now, pausedUntil: until, frontmostBundleID: app, frontmostName: app.map { _ in "App" }, excludedBundleIDs: excluded)
            }
            guard evaluate(nil, nil) == nil, evaluate(nil, "com.apple.Safari") == nil else { return "suppressed with no reason" }
            guard evaluate(nil, "com.adobe.Photoshop") == .app(name: "App") else { return "excluded app (case-insensitive) not honoured" }
            guard evaluate(nil, "com.adobe.photoshop.helper") == nil else { return "prefix matched" }
            let later = now.addingTimeInterval(3600)
            guard evaluate(later, nil) == .paused(until: later), evaluate(later, "com.adobe.Photoshop") == .paused(until: later) else { return "pause" }
            guard evaluate(now, nil) == nil, evaluate(now.addingTimeInterval(-1), "com.apple.FinalCut") == .app(name: "App") else { return "expired pause" }
            guard evaluate(.distantFuture, nil) == .paused(until: nil) else { return "indefinite pause" }
            return nil
        }),
        ("tint: strength, per-display offset and exclusion", {
            func level(_ scheduled: Double, _ strength: Double, _ offset: Double, _ active: Bool = true) -> Double {
                TintLevel.kelvin(scheduled: scheduled, strength: strength, offset: offset, active: active)
            }
            guard level(3100, 1, 0) == 3100, level(3100, 0, 0) == 6500, level(3100, 0.5, 0) == 4800 else { return "strength" }
            guard level(3100, 1, -300) == 2800, level(3100, 1, 400) == 3500 else { return "offset" }
            guard level(6500, 1, 500) == 6500, level(6300, 1, 500) == 6500, level(1200, 1, -1500) == 1000 else { return "clamping" }
            guard level(3100, 1, -300, false) == 6500, level(1200, 2, 0) == 1200, level(3100, -1, 0) == 6500 else { return "inactive / bad strength" }
            return nil
        }),
        ("tint: profile gamma (vcgt) parsing gives the untinted baseline", {
            // The built-in display's real tag: formula type, gamma 1, 0...1 on every channel.
            var formula = Data("vcgt".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 1])
            for _ in 0..<3 { formula += Data([0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0]) }
            guard let parsed = VCGT(tag: formula), case .formula = parsed else { return "formula tag rejected" }
            let flat = GammaController.baseline(vcgt: parsed, count: 1024)
            guard flat.isClose(to: .identity(count: 1024), tolerance: 1e-6) else { return "identity formula is not identity" }
            // A calibration table: 256 16-bit entries per channel, blue pulled down to 90%.
            var table = Data("vcgt".utf8) + Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 1, 0, 0, 2])
            for scale in [1.0, 1.0, 0.9] {
                for i in 0..<256 {
                    let value = UInt16((pow(Double(i) / 255, 1.1) * scale * 65535).rounded())
                    table += Data([UInt8(value >> 8), UInt8(value & 0xff)])
                }
            }
            guard let calibrated = VCGT(tag: table), case .table = calibrated else { return "table tag rejected" }
            let curve = GammaController.baseline(vcgt: calibrated, count: 1024)
            guard curve.r.count == 1024, abs(curve.r[1023] - 1) < 1e-4, abs(curve.b[1023] - 0.9) < 1e-4,
                  abs(Double(curve.g[512]) - pow(512.0 / 1023, 1.1)) < 0.002, curve.r[0] == 0 else { return "table resampled wrongly" }
            for i in 1..<1024 where curve.b[i] < curve.b[i - 1] { return "baseline not monotonic at \(i)" }
            // A tint is the baseline scaled, so calibration survives underneath it.
            let tinted = GammaController.scaled(curve, by: (1, 0.8, 0.5))
            guard abs(tinted.b[1023] - 0.45) < 1e-4, tinted.r[1023] == curve.r[1023] else { return "scaling" }
            guard VCGT(tag: Data("vcgt".utf8)) == nil, VCGT(tag: table.prefix(200)) == nil, VCGT(tag: Data(count: 64)) == nil else { return "malformed tag accepted" }
            guard GammaController.baseline(vcgt: nil, count: 256) == .identity(count: 256) else { return "no tag" }
            // Round trip through ColorSync: put the table into a real profile and read it back out.
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData(),
                  let source = ColorSyncProfileCreate(srgb, nil)?.takeRetainedValue(),
                  let mutable = ColorSyncProfileCreateMutableCopy(source)?.takeRetainedValue() else { return "cannot build a test profile" }
            guard GammaController.vcgt(of: source) == nil else { return "sRGB has a vcgt?" }
            ColorSyncProfileSetTag(mutable, "vcgt" as CFString, table as CFData)
            guard GammaController.vcgt(of: mutable) == calibrated else { return "profile round trip" }
            return nil
        }),
        ("tint: every display has a readable table, a sane baseline and primaries (read-only)", {
            let displays = GammaController.onlineDisplays()
            guard !displays.isEmpty else { return nil }   // headless session
            let controller = GammaController()
            for display in displays {
                let baseline = GammaController.profileBaseline(display)
                guard baseline.r.count == GammaController.tableSize(display), baseline.r.count >= 2 else { return "baseline size for \(display)" }
                guard abs(baseline.r.last! - baseline.g.last!) < 0.2, baseline.r.last! > 0.7 else { return "baseline of \(display) looks tinted" }
                guard let live = GammaController.readTable(display), live.r.count == baseline.r.count else { return "cannot read \(display)" }
                let m = ColorTemperature.multipliers(kelvin: 3400, primaries: GammaController.primaries(display))
                guard m.r == 1, m.g > 0.6, m.g < 0.9, m.b > 0.35, m.b < 0.7 else { return "primaries of \(display) give \(m)" }
                // Whatever is on screen now (f.lux's tint, say) is never mistaken for ours, and never adopted.
                let finding = controller.inspect(display)
                guard finding == .baseline || finding == .foreign else { return "fresh controller says \(finding) for \(display)" }
                guard !controller.owns(display), controller.appliedKelvin(display) == nil else { return "owns without writing" }
            }
            return nil
        }),
        ("tint: preferences migrate from the old keys and import f.lux", {
            let suite = "bosun.selftest.tint.\(ProcessInfo.processInfo.processIdentifier)"
            guard let defaults = UserDefaults(suiteName: suite) else { return "no scratch defaults" }
            defer { defaults.removePersistentDomain(forName: suite) }
            let flux: [String: Any] = ["dayColorTemp": 3400, "nightColorTemp": 3100, "lateColorTemp": 2300, "wakeTime": 510,
                                       "location": "31.200000,121.400000", "steptime": 34]
            // Fresh install next to f.lux.
            var s = TintPreferences.loadSchedule(defaults: defaults, flux: flux)
            guard s.dayKelvin == 3400, s.sunsetKelvin == 3100, s.bedtimeKelvin == 2300, s.wakeMinutes == 510,
                  s.latitude == 31.2, s.longitude == 121.4, s.mode == .sun, s.bedtimeLeadMinutes == 540 else { return "f.lux import: \(s)" }
            // No f.lux, nothing stored.
            guard TintPreferences.loadSchedule(defaults: defaults, flux: nil) == TintSchedule() else { return "defaults" }
            // An earlier Bosun: tint.day / tint.night win over f.lux and feed both evening phases.
            defaults.set(5000.0, forKey: "tint.day")
            defaults.set(2700.0, forKey: "tint.night")
            defaults.set(48.85, forKey: "tint.latitude")
            defaults.set(2.35, forKey: "tint.longitude")
            s = TintPreferences.loadSchedule(defaults: defaults, flux: flux)
            guard s.dayKelvin == 5000, s.sunsetKelvin == 2700, s.bedtimeKelvin == 2700, s.latitude == 48.85, s.longitude == 2.35,
                  s.wakeMinutes == 510 else { return "legacy migration: \(s)" }
            // Saving writes the new keys and retires the old one.
            s.bedtimeKelvin = 1900; s.mode = .fixed; s.ramp = .slow; s.wakeMinutes = 400; s.bedtimeEnabled = false
            s.fixedDayStart = 421; s.fixedEveningStart = 1111; s.bedtimeLeadMinutes = 600
            TintPreferences.save(s, to: defaults)
            guard defaults.object(forKey: "tint.night") == nil, defaults.double(forKey: "tint.sunset") == 2700 else { return "old key not retired" }
            guard TintPreferences.loadSchedule(defaults: defaults, flux: flux) == s else { return "round trip" }
            // Out-of-range values are clamped, not trusted.
            defaults.set(90000.0, forKey: "tint.day"); defaults.set(200.0, forKey: "tint.sunset")
            defaults.set(123.0, forKey: "tint.latitude"); defaults.set(-2.0, forKey: "tint.wake"); defaults.set("nonsense", forKey: "tint.mode")
            s = TintPreferences.loadSchedule(defaults: defaults, flux: nil)
            guard s.dayKelvin == 6500, s.sunsetKelvin == 1200, s.latitude == 90, s.wakeMinutes == 1438, s.mode == .sun else { return "clamping: \(s)" }
            // Lists.
            let apps = [TintApp(id: "com.adobe.Photoshop", name: "Photoshop"), TintApp(id: "com.apple.FinalCut", name: "Final Cut Pro")]
            TintPreferences.save(apps, to: defaults)
            guard TintPreferences.loadApps(defaults: defaults) == apps else { return "apps round trip" }
            let prefs = ["A1EA": TintDisplayPref(excluded: true, offset: 0), "37D8": TintDisplayPref(excluded: false, offset: -300)]
            TintPreferences.save(prefs, to: defaults)
            guard TintPreferences.loadDisplays(defaults: defaults) == prefs else { return "displays round trip" }
            return nil
        }),
        ("tint: chart samples, preset names and Night Shift status decoding", {
            let line = timeline(shanghai, around: date(2026, 11, 13, 12, 0))
            let range = TintChart.dayRange(around: date(2026, 11, 13, 12, 0), calendar: calendar("Asia/Shanghai"))
            guard range.lowerBound == date(2026, 11, 13, 0, 0), range.upperBound == date(2026, 11, 14, 0, 0) else { return "day range" }
            let samples = TintChart.samples(line, strength: 1, range: range, count: 25)
            guard samples.count == 25, samples[0] == 2300, samples[12] == 3400, samples[20] == 3100, samples[24] == 2300 else { return "samples \(samples)" }
            guard TintChart.samples(line, strength: 0, range: range, count: 5) == [6500, 6500, 6500, 6500, 6500] else { return "strength in chart" }
            guard ColorTemperature.name(for: 3400) == "Halogen", ColorTemperature.name(for: 3100) == "3100 K",
                  ColorTemperature.presets.map(\.kelvin) == ColorTemperature.presets.map(\.kelvin).sorted(),
                  ColorTemperature.presets.allSatisfy({ ColorTemperature.range.contains($0.kelvin) }) else { return "presets" }
            guard NightShift.parse(enabled: 0, mode: 1) == NightShift.Status(isOn: false, mode: 1),
                  NightShift.parse(enabled: 1, mode: 0).summary == "Night Shift is on",
                  NightShift.parse(enabled: 0, mode: 0).summary == nil, NightShift.parse(enabled: 0, mode: 77).mode == 0 else { return "night shift" }
            return nil
        }),
        ("tint: live gamma write, read-back, reset detection and restore (only with BOSUN_TINT_LIVE=1)", {
            guard ProcessInfo.processInfo.environment["BOSUN_TINT_LIVE"] != nil else { return nil }
            let display = CGMainDisplayID()
            guard let before = GammaController.readTable(display) else { return "cannot read gamma table" }
            let controller = GammaController()
            let startedForeign = controller.inspect(display) == .foreign
            defer {
                controller.restore()
                // Put back whatever was there (another app's tint included) rather than leave the screen neutral.
                GammaController.writeTable(display, before)
            }
            // 6300 K is a barely visible tint, and it is on screen for a few milliseconds.
            guard controller.apply(kelvin: 6300, to: display), controller.owns(display) else { return "write failed" }
            guard controller.inspect(display) == .ours else { return "read-back differs from what was written" }
            let baseline = GammaController.profileBaseline(display)
            let m = ColorTemperature.multipliers(kelvin: 6300, primaries: GammaController.primaries(display))
            guard let live = GammaController.readTable(display),
                  abs(Double(live.b.last!) - Double(baseline.b.last!) * m.b) < 0.0005 else { return "blue maximum is not baseline × multiplier" }
            // Tinting twice must not compound: the second write starts from the profile, not from the screen.
            guard controller.apply(kelvin: 6300, to: display, force: true), GammaController.readTable(display) == live else { return "tint compounded" }
            // The system taking the table back shows up as .baseline …
            CGDisplayRestoreColorSyncSettings()
            let afterRestore = controller.inspect(display)
            guard afterRestore == .baseline else { return "after a system restore the table reads \(afterRestore)" }
            // … and someone else's table as .foreign.
            GammaController.writeTable(display, GammaController.scaled(baseline, by: (1, 0.97, 0.9)))
            guard controller.inspect(display) == .foreign else { return "foreign table not recognised" }
            controller.release(display)
            guard !controller.owns(display), GammaController.readTable(display)?.isClose(to: baseline) == true else { return "release did not untint" }
            Log.info("live check ok; screen was \(startedForeign ? "tinted by another app" : "untinted") before", "tint")
            return nil
        }),
    ]

    private typealias Toggle = TintTimeline.Toggle
}
