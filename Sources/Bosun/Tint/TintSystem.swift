import AppKit
@preconcurrency import CoreLocation

/// Read-only view of Night Shift, through the private CoreBrightness client.
/// Night Shift is applied below the gamma table (it never shows up in a table
/// read), so it stacks with Bosun's tint rather than fighting it.
enum NightShift {
    struct Status: Equatable {
        /// Warming the screen right now.
        var isOn: Bool
        /// 0 = no schedule, 1 = sunset to sunrise, 2 = custom times.
        var mode: Int

        var summary: String? {
            if isOn { return "Night Shift is on" }
            switch mode {
            case 1: return "Night Shift is scheduled from sunset to sunrise"
            case 2: return "Night Shift is scheduled"
            default: return nil
            }
        }
    }

    private static let client: NSObject? = {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil,
              let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return type.init()
    }()

    static func status() -> Status? {
        let selector = NSSelectorFromString("getBlueLightStatus:")
        guard let client, client.responds(to: selector), let implementation = client.method(for: selector) else { return nil }
        typealias Function = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
        let function = unsafeBitCast(implementation, to: Function.self)
        // { BOOL active; BOOL enabled; BOOL sunSchedulePermitted; int mode; schedule…; flags… } — oversized on purpose.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 256)
        guard function(client, selector, buffer) else { return nil }
        return parse(enabled: buffer.load(fromByteOffset: 1, as: UInt8.self), mode: buffer.load(fromByteOffset: 4, as: Int32.self))
    }

    static func parse(enabled: UInt8, mode: Int32) -> Status {
        Status(isOn: enabled != 0, mode: (0...2).contains(Int(mode)) ? Int(mode) : 0)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One-shot "where am I" for the schedule. Nothing is requested until the user asks.
@MainActor
final class TintLocation: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        case requesting
        case found(Date)
        case denied
        case restricted
        case failed(String)

        var message: String? {
            switch self {
            case .idle: nil
            case .requesting: "Asking macOS for your location…"
            case .found(let date): "Updated from Location Services at \(date.formatted(date: .omitted, time: .shortened))."
            case .denied: "Bosun is not allowed to use your location (or Location Services are off). Allow it in System Settings › Privacy & Security › Location Services, or type the coordinates."
            case .restricted: "Location Services are restricted on this Mac. Type the coordinates instead."
            case .failed(let reason): "Could not get a location (\(reason)). The coordinates were left as they are."
            }
        }

        var isProblem: Bool {
            switch self {
            case .denied, .restricted, .failed: true
            default: false
            }
        }
    }

    @Published private(set) var state: State = .idle
    var onFix: ((Double, Double) -> Void)?

    private var manager: CLLocationManager?
    private var timeout: Timer?

    func request() {
        guard state != .requesting else { return }
        let manager = self.manager ?? {
            let created = CLLocationManager()
            created.delegate = self
            created.desiredAccuracy = kCLLocationAccuracyKilometer
            self.manager = created
            return created
        }()
        state = .requesting
        timeout?.invalidate()
        timeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.state == .requesting else { return }
                self.manager?.stopUpdatingLocation()
                self.state = Self.state(for: manager.authorizationStatus) ?? .failed("no answer from Location Services")
            }
        }
        proceed(manager)
    }

    /// The terminal state an authorization status implies, or nil when a fix may still arrive.
    nonisolated static func state(for status: CLAuthorizationStatus) -> State? {
        switch status {
        case .denied: .denied
        case .restricted: .restricted
        default: nil
        }
    }

    private func proceed(_ manager: CLLocationManager) {
        guard state == .requesting else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            // Shows the system prompt; the answer arrives in locationManagerDidChangeAuthorization.
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish(Self.state(for: manager.authorizationStatus) ?? .denied)
        default:
            manager.requestLocation()
        }
    }

    private func finish(_ newState: State) {
        timeout?.invalidate()
        timeout = nil
        state = newState
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard self.state == .requesting, manager.authorizationStatus != .notDetermined else { return }
            self.proceed(manager)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate, CLLocationCoordinate2DIsValid(coordinate) else { return }
        MainActor.assumeIsolated {
            guard self.state == .requesting else { return }
            // Two decimals (about a kilometre) is plenty for sunrise times.
            self.onFix?((coordinate.latitude * 100).rounded() / 100, (coordinate.longitude * 100).rounded() / 100)
            self.finish(.found(Date()))
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let code = (error as? CLError)?.code
        let text = error.localizedDescription
        MainActor.assumeIsolated {
            guard self.state == .requesting else { return }
            switch code {
            case .denied?:
                self.finish(.denied)
            case .locationUnknown?:
                break   // CoreLocation keeps trying; the timeout ends it
            default:
                self.finish(.failed(text))
            }
        }
    }
}
