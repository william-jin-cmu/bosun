import Foundation

/// `Bosun --selftest` prints one line per check and exits non-zero on failure.
/// Each module registers its own checks in an extension-free, explicit list.
enum SelfTest {
    typealias Check = (name: String, run: () -> String?)   // returns nil on pass, else failure text

    static func runAndExit() -> Never {
        let checks: [Check] = MonitorChecks.all + SensorsChecks.all + TintChecks.all
            + DisplaysChecks.all + KeyboardChecks.all + AudioChecks.all
        var failed = 0
        for check in checks {
            if let failure = check.run() {
                failed += 1
                print("FAIL \(check.name): \(failure)")
            } else {
                print("ok   \(check.name)")
            }
        }
        print(failed == 0 ? "all \(checks.count) checks passed" : "\(failed) of \(checks.count) checks failed")
        exit(failed == 0 ? 0 : 1)
    }
}
