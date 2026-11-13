import AppKit
import CoreAudio
import Darwin

/// One Core Audio process object (a client of the audio server).
struct AudioProcess: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let isRunningOutput: Bool
}

/// All audio processes that belong to one user-facing app. Browsers and
/// Electron apps play from helper processes, so an app is usually several.
struct AudioApp: Identifiable, Equatable {
    /// Stable key, also used for persistence: the owning app's bundle ID, or
    /// `proc.<name>` for things that have none.
    let id: String
    let name: String
    /// PID of the owning app, or of the first process when there is no app.
    let ownerPID: pid_t
    var processObjects: [AudioObjectID]
    var isPlaying: Bool
}

enum AudioProcesses {
    static func list() -> [AudioProcess] {
        let own = getpid()
        return CA.objectIDs(CA.system, CA.address(kAudioHardwarePropertyProcessObjectList)).compactMap { object in
            guard let pid = CA.value(object, CA.address(kAudioProcessPropertyPID), initial: pid_t(0)),
                  pid > 0, pid != own else { return nil }
            let running = CA.value(object, CA.address(kAudioProcessPropertyIsRunningOutput), initial: UInt32(0)) ?? 0
            let bundleID = CA.string(object, CA.address(kAudioProcessPropertyBundleID)) ?? ""
            return AudioProcess(objectID: object, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    /// Groups processes under the app responsible for them. Order is stable
    /// (by name) so rows do not jump around.
    static func group(_ processes: [AudioProcess]) -> [AudioApp] {
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy != .prohibited {
            apps[app.processIdentifier] = app
        }
        var groups: [String: AudioApp] = [:]
        for process in processes {
            let owner = owner(of: process, apps: apps)
            var group = groups[owner.id]
                ?? AudioApp(id: owner.id, name: owner.name, ownerPID: owner.pid, processObjects: [], isPlaying: false)
            group.processObjects.append(process.objectID)
            group.isPlaying = group.isPlaying || process.isRunningOutput
            groups[owner.id] = group
        }
        return groups.values
            .map { var g = $0; g.processObjects.sort(); return g }
            .sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
    }

    private static func owner(
        of process: AudioProcess, apps: [pid_t: NSRunningApplication]
    ) -> (id: String, name: String, pid: pid_t) {
        func describe(_ app: NSRunningApplication) -> (id: String, name: String, pid: pid_t) {
            let name = app.localizedName ?? processName(app.processIdentifier) ?? "Unknown"
            return (app.bundleIdentifier ?? "proc.\(name)", name, app.processIdentifier)
        }
        // System alert sounds are played by a shared daemon that the system
        // attributes to whichever app happened to launch it; never group it.
        let ownName = processName(process.pid) ?? ""
        if ownName == "systemsoundserverd" || process.bundleID == "systemsoundserverd" {
            return ("proc.systemsoundserverd", "System Sounds", process.pid)
        }
        // 1. The process the system holds responsible (covers XPC services such
        //    as WebKit's GPU process, whose parent is launchd).
        if let responsible = responsiblePID(process.pid), let app = apps[responsible] { return describe(app) }
        // 2. The process itself, then its ancestors.
        var pid = process.pid
        for _ in 0..<8 {
            if let app = apps[pid] { return describe(app) }
            guard let parent = parentPID(pid), parent > 1, parent != pid else { break }
            pid = parent
        }
        // 3. A helper whose bundle ID extends a running app's ("com.x.app.helper").
        if !process.bundleID.isEmpty {
            let match = apps.values
                .filter { app in
                    guard let id = app.bundleIdentifier else { return false }
                    return process.bundleID.hasPrefix(id + ".")
                }
                .max { ($0.bundleIdentifier ?? "").count < ($1.bundleIdentifier ?? "").count }
            if let match { return describe(match) }
        }
        // 4. A background process with no app: its own entry.
        let name = ownName.isEmpty ? process.bundleID : ownName
        if !process.bundleID.isEmpty {
            return (process.bundleID, name.isEmpty ? process.bundleID : name, process.pid)
        }
        return ("proc.\(name.isEmpty ? String(process.pid) : name)", name.isEmpty ? "PID \(process.pid)" : name, process.pid)
    }

    static func icon(for app: AudioApp) -> NSImage? {
        NSRunningApplication(processIdentifier: app.ownerPID)?.icon
    }

    // MARK: Process tree

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleFn: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    static func responsiblePID(_ pid: pid_t) -> pid_t? {
        guard let responsibleFn else { return nil }
        let result = responsibleFn(pid)
        return result > 0 ? result : nil
    }

    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
