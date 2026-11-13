import SwiftUI

/// One feature area of Bosun. A module does nothing until `start()` and must
/// undo every system-level change it made in `stop()`.
@MainActor
protocol BosunModule: AnyObject {
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    /// Whether the module is on the first time Bosun runs.
    var enabledByDefault: Bool { get }
    func start()
    func stop()
    /// Called when the panel opens or closes, so modules can poll faster
    /// (or at all) only while someone is looking.
    func panelVisibilityChanged(_ visible: Bool)
}

extension BosunModule {
    var enabledByDefault: Bool { true }
    func panelVisibilityChanged(_ visible: Bool) {}
    var enabledKey: String { "module.\(id).enabled" }
}

enum Log {
    static func info(_ message: @autoclosure () -> String, _ tag: String = "bosun") {
        FileHandle.standardError.write(Data("[\(tag)] \(message())\n".utf8))
    }
}
