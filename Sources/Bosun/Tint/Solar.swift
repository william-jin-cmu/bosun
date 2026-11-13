import Foundation

enum Solar {
    /// Sun elevation above the horizon in degrees (low-precision almanac formula, good to ~0.1°).
    static func elevation(at date: Date, latitude: Double, longitude: Double) -> Double {
        let rad = Double.pi / 180
        let n = date.timeIntervalSince1970 / 86400 + 2440587.5 - 2451545.0   // days since J2000
        let meanLongitude = 280.460 + 0.9856474 * n
        let anomaly = (357.528 + 0.9856003 * n) * rad
        let eclipticLongitude = (meanLongitude + 1.915 * sin(anomaly) + 0.020 * sin(2 * anomaly)) * rad
        let obliquity = (23.439 - 0.0000004 * n) * rad
        let declination = asin(sin(obliquity) * sin(eclipticLongitude))
        let rightAscension = atan2(cos(obliquity) * sin(eclipticLongitude), cos(eclipticLongitude))
        let siderealDegrees = (18.697374558 + 24.06570982441908 * n) * 15 + longitude
        let hourAngle = siderealDegrees * rad - rightAscension
        let lat = latitude * rad
        return asin(sin(lat) * sin(declination) + cos(lat) * cos(declination) * cos(hourAngle)) / rad
    }

    /// The next sunrise or sunset after `date` (nil during polar day/night).
    static func nextHorizonCrossing(after date: Date, latitude: Double, longitude: Double) -> (date: Date, isSunrise: Bool)? {
        let horizon = -0.833   // refraction + solar radius
        func above(_ d: Date) -> Bool { elevation(at: d, latitude: latitude, longitude: longitude) > horizon }
        let start = above(date)
        var low = date
        for step in 1...(24 * 12) {
            let probe = date.addingTimeInterval(Double(step) * 300)
            if above(probe) != start {
                var high = probe
                while high.timeIntervalSince(low) > 30 {
                    let mid = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
                    if above(mid) == start { low = mid } else { high = mid }
                }
                return (high, !start)
            }
            low = probe
        }
        return nil
    }
}

enum ColorTemperature {
    static let neutral = 6500.0

    /// Channel multipliers (0...1) that turn a 6500 K white into `kelvin`.
    /// Tanner Helland's black-body fit, normalised so 6500 K is exactly (1, 1, 1).
    static func multipliers(kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let raw = blackBody(min(max(kelvin, 1000), neutral))
        let white = blackBody(neutral)
        return (min(1, raw.r / white.r), min(1, raw.g / white.g), min(1, raw.b / white.b))
    }

    private static func blackBody(_ kelvin: Double) -> (r: Double, g: Double, b: Double) {
        let t = kelvin / 100
        func clamp(_ v: Double) -> Double { min(255, max(0, v)) }
        let r = t <= 66 ? 255 : clamp(329.698727446 * pow(t - 60, -0.1332047592))
        let g = t <= 66 ? clamp(99.4708025861 * log(t) - 161.1195681661) : clamp(288.1221695283 * pow(t - 60, -0.0755148492))
        let b = t >= 66 ? 255 : (t <= 19 ? 0 : clamp(138.5177312231 * log(t - 10) - 305.0447927307))
        return (r, g, b)
    }

    /// Day colour while the sun is well up, night colour once it is well down,
    /// blended linearly through civil twilight (±6° of elevation).
    static func target(day: Double, night: Double, sunElevation: Double) -> Double {
        let mix = min(1, max(0, (sunElevation + 6) / 12))
        return night + (day - night) * mix
    }
}
