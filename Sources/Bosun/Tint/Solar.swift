import CoreGraphics
import Foundation

enum Solar {
    /// Elevation of the sun's centre at which its upper limb touches the horizon
    /// (atmospheric refraction + solar radius).
    static let horizon = -0.833

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

    static func isUp(at date: Date, latitude: Double, longitude: Double) -> Bool {
        elevation(at: date, latitude: latitude, longitude: longitude) > horizon
    }

    /// Every sunrise and sunset in `start...end`, in order (empty during polar day/night).
    static func crossings(from start: Date, to end: Date, latitude: Double, longitude: Double) -> [(date: Date, isSunrise: Bool)] {
        var result: [(date: Date, isSunrise: Bool)] = []
        var low = start
        var state = isUp(at: start, latitude: latitude, longitude: longitude)
        while low < end {
            let probe = min(end, low.addingTimeInterval(300))
            if isUp(at: probe, latitude: latitude, longitude: longitude) != state {
                var a = low, b = probe
                while b.timeIntervalSince(a) > 1 {
                    let mid = a.addingTimeInterval(b.timeIntervalSince(a) / 2)
                    if isUp(at: mid, latitude: latitude, longitude: longitude) == state { a = mid } else { b = mid }
                }
                state.toggle()
                result.append((b, state))
            }
            low = probe
        }
        return result
    }

    /// The next sunrise or sunset after `date` (nil during polar day/night).
    static func nextHorizonCrossing(after date: Date, latitude: Double, longitude: Double) -> (date: Date, isSunrise: Bool)? {
        crossings(from: date, to: date.addingTimeInterval(24 * 3600), latitude: latitude, longitude: longitude).first
    }
}

/// The chromaticities a display can show, as the matrix that takes CIE XYZ
/// (ICC profile connection space, D50) to the display's linear RGB.
struct DisplayPrimaries: Equatable {
    /// Row-major 3×3.
    var xyzToRGB: [Double]

    /// From the XYZ (D50) of full red, green and blue.
    init?(red: [Double], green: [Double], blue: [Double]) {
        guard red.count == 3, green.count == 3, blue.count == 3 else { return nil }
        let m = [red[0], green[0], blue[0], red[1], green[1], blue[1], red[2], green[2], blue[2]]
        let det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
        guard det.isFinite, abs(det) > 1e-6 else { return nil }
        let inverse = [
            m[4] * m[8] - m[5] * m[7], m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
            m[5] * m[6] - m[3] * m[8], m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
            m[3] * m[7] - m[4] * m[6], m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
        ].map { $0 / det }
        guard inverse.allSatisfy(\.isFinite) else { return nil }
        xyzToRGB = inverse
    }

    static let sRGB = DisplayPrimaries(red: [0.4360747, 0.2225045, 0.0139322],
                                       green: [0.3850649, 0.7168786, 0.0971045],
                                       blue: [0.1430804, 0.0606169, 0.7141733])!
    static let displayP3 = DisplayPrimaries(red: [0.5151, 0.2412, -0.0011],
                                            green: [0.2920, 0.6922, 0.0419],
                                            blue: [0.1571, 0.0666, 0.7841])!

    /// Reads the primaries out of a display's colour space by converting its
    /// pure red, green and blue to XYZ. Nil for anything that is not a sane RGB space.
    init?(colorSpace: CGColorSpace) {
        guard colorSpace.model == .rgb, let xyz = CGColorSpace(name: CGColorSpace.genericXYZ) else { return nil }
        func convert(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> [Double]? {
            guard let color = CGColor(colorSpace: colorSpace, components: [r, g, b, 1]),
                  let out = color.converted(to: xyz, intent: .relativeColorimetric, options: nil),
                  let c = out.components, c.count >= 3 else { return nil }
            return [Double(c[0]), Double(c[1]), Double(c[2])]
        }
        guard let red = convert(1, 0, 0), let green = convert(0, 1, 0), let blue = convert(0, 0, 1),
              let white = convert(1, 1, 1) else { return nil }
        // A usable profile maps its white to (roughly) the D50 connection-space white.
        guard abs(white[0] - 0.9642) < 0.05, abs(white[1] - 1) < 0.05, abs(white[2] - 0.8249) < 0.05 else { return nil }
        self.init(red: red, green: green, blue: blue)
    }
}

enum ColorTemperature {
    static let neutral = 6500.0
    static let range = 1200.0...6500.0

    struct Preset: Identifiable, Equatable {
        let name: String
        let kelvin: Double
        var id: Double { kelvin }
    }

    /// The light sources f.lux names, warmest first.
    static let presets: [Preset] = [
        Preset(name: "Ember", kelvin: 1200),
        Preset(name: "Candle", kelvin: 1900),
        Preset(name: "Dim Incandescent", kelvin: 2300),
        Preset(name: "Incandescent", kelvin: 2700),
        Preset(name: "Halogen", kelvin: 3400),
        Preset(name: "Fluorescent", kelvin: 4200),
        Preset(name: "Sunlight", kelvin: 5500),
        Preset(name: "Daylight", kelvin: 6500),
    ]

    static func preset(for kelvin: Double) -> Preset? {
        presets.first { abs($0.kelvin - kelvin) < 1 }
    }

    /// "Halogen" for an exact preset, otherwise "3100 K".
    static func name(for kelvin: Double) -> String {
        preset(for: kelvin)?.name ?? "\(Int(kelvin.rounded())) K"
    }

    /// CIE 1931 xy of a black body (Krystek's fit, 1000–15000 K).
    static func planckian(_ t: Double) -> (x: Double, y: Double) {
        let u = (0.860117757 + 1.54118254e-4 * t + 1.28641212e-7 * t * t) / (1 + 8.42420235e-4 * t + 7.08145163e-7 * t * t)
        let v = (0.317398726 + 4.22806245e-5 * t + 4.20481691e-8 * t * t) / (1 - 2.89741816e-5 * t + 1.61456053e-7 * t * t)
        let d = 2 * u - 8 * v + 4
        return (3 * u / d, 2 * v / d)
    }

    /// Linear-light RGB of a `kelvin` black body on a display whose white is D65, brightest channel = 1.
    private static func linear(_ kelvin: Double, _ primaries: DisplayPrimaries) -> (r: Double, g: Double, b: Double) {
        let (x, y) = planckian(kelvin)
        let X = x / y, Y = 1.0, Z = (1 - x - y) / y
        // Bradford D65 → D50, the same adaptation display profiles are built with.
        let px = 1.0478112 * X + 0.0228866 * Y - 0.0501270 * Z
        let py = 0.0295424 * X + 0.9904844 * Y - 0.0170491 * Z
        let pz = -0.0092345 * X + 0.0150436 * Y + 0.7521316 * Z
        let m = primaries.xyzToRGB
        let r = max(0, m[0] * px + m[1] * py + m[2] * pz)
        let g = max(0, m[3] * px + m[4] * py + m[5] * pz)
        let b = max(0, m[6] * px + m[7] * py + m[8] * pz)
        let top = max(r, g, b, 1e-9)
        return (r / top, g / top, b / top)
    }

    /// Gamma-table multipliers (0...1) that turn the display's white into `kelvin`.
    ///
    /// The black-body colour is expressed in the display's own primaries and
    /// encoded with a 2.2 gamma — the same construction f.lux uses, so a Kelvin
    /// value here looks like the same value there (3400 K on a P3 panel is
    /// (1, 0.802, 0.575) in both). A 6500 K black body is slightly off the D65
    /// white displays are built around, so that residue is divided out towards
    /// the top of the range: 6500 K is exactly (1, 1, 1), and nothing below
    /// 5000 K is affected.
    static func multipliers(kelvin: Double, primaries: DisplayPrimaries = .sRGB) -> (r: Double, g: Double, b: Double) {
        let t = min(max(kelvin, 1000), neutral)
        if t >= neutral { return (1, 1, 1) }
        let raw = linear(t, primaries)
        let white = linear(neutral, primaries)
        let w = TintMath.smoothstep((t - 5000) / (neutral - 5000))
        func channel(_ value: Double, _ whiteValue: Double) -> Double {
            let corrected = value / pow(max(whiteValue, 1e-6), w)
            return pow(min(1, max(0, corrected)), 1 / 2.2)
        }
        return (channel(raw.r, white.r), channel(raw.g, white.g), channel(raw.b, white.b))
    }

    /// Day colour while the sun is well up, night colour once it is well down,
    /// blended linearly through civil twilight (±6° of elevation).
    static func target(day: Double, night: Double, sunElevation: Double) -> Double {
        let mix = min(1, max(0, (sunElevation + 6) / 12))
        return night + (day - night) * mix
    }
}

enum TintMath {
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    static func smoothstep(_ x: Double) -> Double {
        let t = clamp01(x)
        return t * t * (3 - 2 * t)
    }
    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }
}
