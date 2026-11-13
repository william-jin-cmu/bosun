import SwiftUI

@MainActor
final class TintModule: ObservableObject, BosunModule {
    let id = "tint"
    let title = "Color Temperature"
    let symbol = "sun.max"
    // Off until asked for: two apps tinting the screen at once fight each other.
    let enabledByDefault = false

    @Published var dayKelvin: Double { didSet { save("tint.day", dayKelvin); refresh() } }
    @Published var nightKelvin: Double { didSet { save("tint.night", nightKelvin); refresh() } }
    @Published var latitude: Double { didSet { save("tint.latitude", latitude); refresh() } }
    @Published var longitude: Double { didSet { save("tint.longitude", longitude); refresh() } }
    @Published private(set) var pausedUntil: Date?
    @Published private(set) var currentKelvin: Double = ColorTemperature.neutral
    @Published private(set) var nextEvent: (date: Date, isSunrise: Bool)?
    @Published private(set) var otherTintApp: String?

    private let gamma = GammaController()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var running = false

    init() {
        let defaults = UserDefaults.standard
        // First run: carry over f.lux's settings if it has been used on this Mac.
        let flux = UserDefaults(suiteName: "org.herf.Flux")
        func stored(_ key: String) -> Double? { defaults.object(forKey: key) as? Double }
        func fluxNumber(_ key: String) -> Double? { (flux?.object(forKey: key) as? NSNumber)?.doubleValue }
        var fluxLocation: (Double, Double)?
        if let text = flux?.string(forKey: "location") {
            let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 { fluxLocation = (parts[0], parts[1]) }
        }
        dayKelvin = stored("tint.day") ?? fluxNumber("dayColorTemp") ?? 6500
        nightKelvin = stored("tint.night") ?? fluxNumber("nightColorTemp") ?? 3400
        latitude = stored("tint.latitude") ?? fluxLocation?.0 ?? 31.2
        longitude = stored("tint.longitude") ?? fluxLocation?.1 ?? 121.4
    }

    private func save(_ key: String, _ value: Double) { UserDefaults.standard.set(value, forKey: key) }

    func start() {
        guard !running else { return }
        running = true
        gamma.resetBaselines()
        refresh()
        // The system resets gamma tables behind our back (wake, display changes,
        // some full-screen transitions), so re-assert on a slow timer as well.
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        })
    }

    func stop() {
        guard running else { return }
        running = false
        timer?.invalidate()
        timer = nil
        observers.forEach {
            NotificationCenter.default.removeObserver($0)
            NSWorkspace.shared.notificationCenter.removeObserver($0)
        }
        observers.removeAll()
        pausedUntil = nil
        gamma.restore()
        currentKelvin = ColorTemperature.neutral
    }

    func panelVisibilityChanged(_ visible: Bool) {
        if visible { refresh() }
    }

    func pause(for interval: TimeInterval) {
        pausedUntil = Date().addingTimeInterval(interval)
        refresh()
    }

    func resume() {
        pausedUntil = nil
        refresh()
    }

    private func displaysChanged() {
        guard running else { return }
        gamma.resetBaselines()
        refresh()
    }

    private func refresh() {
        guard running else { return }
        let now = Date()
        if let until = pausedUntil, until <= now { pausedUntil = nil }
        let elevation = Solar.elevation(at: now, latitude: latitude, longitude: longitude)
        let target = pausedUntil == nil
            ? ColorTemperature.target(day: dayKelvin, night: nightKelvin, sunElevation: elevation)
            : ColorTemperature.neutral
        currentKelvin = target
        gamma.apply(kelvin: target)
        nextEvent = Solar.nextHorizonCrossing(after: now, latitude: latitude, longitude: longitude)
        otherTintApp = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == "org.herf.Flux" }?.localizedName
    }
}

struct TintSection: View {
    @ObservedObject var module: TintModule
    @State private var showLocation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(Int(module.currentKelvin.rounded())) K").font(.title3.weight(.semibold)).monospacedDigit()
                Spacer()
                if let event = module.nextEvent {
                    Text("\(event.isSunrise ? "Sunrise" : "Sunset") at \(event.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let other = module.otherTintApp {
                Label("\(other) is also running and will fight over the screen color. Quit one of them.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            KelvinSlider(label: "Day", symbol: "sun.max", value: $module.dayKelvin)
            KelvinSlider(label: "Night", symbol: "moon", value: $module.nightKelvin)
            HStack {
                if let until = module.pausedUntil {
                    Text("Paused until \(until.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { module.resume() }
                } else {
                    Button("Pause for an hour") { module.pause(for: 3600) }
                    Spacer()
                }
                Button(showLocation ? "Hide location" : "Location") { showLocation.toggle() }
            }
            .controlSize(.small)
            if showLocation {
                HStack {
                    CoordinateField(label: "Latitude", value: $module.latitude, range: -90...90)
                    CoordinateField(label: "Longitude", value: $module.longitude, range: -180...180)
                }
            }
        }
    }
}

private struct KelvinSlider: View {
    let label: String
    let symbol: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Label(label, systemImage: symbol).labelStyle(.iconOnly).frame(width: 16)
            Text(label).font(.callout).frame(width: 38, alignment: .leading)
            Slider(value: $value, in: 1900...6500, step: 100).accessibilityLabel("\(label) color temperature")
            Text("\(Int(value)) K").font(.callout).monospacedDigit().frame(width: 54, alignment: .trailing)
        }
    }
}

private struct CoordinateField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: Binding(
                get: { value },
                set: { value = min(max($0, range.lowerBound), range.upperBound) }
            ), format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder).controlSize(.small)
        }
    }
}

enum TintChecks {
    static let all: [SelfTest.Check] = [
        ("tint: 6500 K is neutral and warmer removes blue first", {
            let neutral = ColorTemperature.multipliers(kelvin: 6500)
            guard neutral == (1, 1, 1) else { return "6500K -> \(neutral)" }
            let warm = ColorTemperature.multipliers(kelvin: 3400)
            guard warm.r == 1, warm.g < 1, warm.b < warm.g, warm.b > 0.3, warm.b < 0.7 else { return "3400K -> \(warm)" }
            let warmer = ColorTemperature.multipliers(kelvin: 2700)
            guard warmer.b < warm.b, warmer.g < warm.g else { return "2700K -> \(warmer)" }
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
        ("tint: sunset on 2026-11-13 in Shanghai is about 16:57 local", {
            // 2026-11-13 00:00 +08:00
            let dayStart = Date(timeIntervalSince1970: 1_794_499_200)
            guard let event = Solar.nextHorizonCrossing(after: dayStart.addingTimeInterval(12 * 3600), latitude: 31.2, longitude: 121.4),
                  !event.isSunrise else { return "no sunset found" }
            let minutes = event.date.timeIntervalSince(dayStart) / 60
            return abs(minutes - (16 * 60 + 57)) < 6 ? nil : "sunset at minute \(minutes)"
        }),
        ("tint: schedule blends through twilight", {
            let values = [10.0, 6, 0, -6, -20].map { ColorTemperature.target(day: 6500, night: 3500, sunElevation: $0) }
            return values == [6500, 6500, 5000, 3500, 3500] ? nil : "\(values)"
        }),
        ("tint: gamma table write reads back and restores", {
            let display = CGMainDisplayID()
            guard let original = GammaController.readTable(display) else { return "cannot read gamma table" }
            defer { GammaController.writeTable(display, original) }
            let m = ColorTemperature.multipliers(kelvin: 3400)
            guard GammaController.writeTable(display, GammaController.scaled(original, by: m)) else { return "write failed" }
            guard let tinted = GammaController.readTable(display) else { return "cannot read back" }
            let expected = Double(original.b.last!) * m.b
            guard abs(Double(tinted.b.last!) - expected) < 0.01 else { return "blue max \(tinted.b.last!) expected \(expected)" }
            GammaController.writeTable(display, original)
            guard let restored = GammaController.readTable(display), abs(restored.b.last! - original.b.last!) < 0.005 else { return "restore mismatch" }
            return nil
        }),
    ]
}
