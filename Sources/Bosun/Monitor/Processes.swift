import AppKit
import Darwin

struct ProcessLoad: Identifiable {
    let pid: Int32
    var name: String
    var cpu: Double            // percent of one core
    var memory: UInt64         // bytes: physical footprint (Activity Monitor's "Memory"), or resident size for other users' processes
    var icon: NSImage?         // the enclosing app's icon, if the process lives inside an app bundle
    var id: Int32 { pid }
}

/// Top processes without shelling out for the common case.
///
/// The current user's processes come from libproc (`proc_pid_rusage`): CPU time deltas
/// and physical footprint, about 2 ms for ~480 processes on an M1 Pro. The kernel refuses
/// that call for other users' processes (root daemons, WindowServer, kernel_task), and the
/// only unprivileged way to see those is the setuid `ps`, so `ps` still runs, but only
/// for them and only every few sweeps (`foreignInterval`), instead of on every tick.
/// Touch from one queue only.
final class ProcessSampler {
    static let foreignInterval: TimeInterval = 6

    private struct Meta { var start: UInt64; var name: String; var appPath: String? }
    private struct Foreign { var cpu: Double; var memory: UInt64; var name: String }

    private var previous: [pid_t: (cpuTime: UInt64, start: UInt64)] = [:]
    private var previousAt: UInt64 = 0
    private var foreign: [pid_t: Foreign] = [:]
    private var foreignAt: TimeInterval = -.infinity
    private var meta: [pid_t: Meta] = [:]
    private var icons: [String: NSImage] = [:]
    private var pids = [pid_t](repeating: 0, count: 2048)

    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    var hasBaseline: Bool { previousAt != 0 }

    /// Forget the CPU baselines (call when sampling stops, so the next first sweep does not
    /// average over the whole pause).
    func reset() {
        previous = [:]
        previousAt = 0
    }

    /// Returns nil on a sweep that only established the CPU baseline.
    func sample(limit: Int) -> (byCPU: [ProcessLoad], byMemory: [ProcessLoad])? {
        var count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        if count >= pids.count {
            pids = [pid_t](repeating: 0, count: count * 2)
            count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride)))
        }
        guard count > 0 else { return nil }
        let nowAbs = mach_absolute_time()
        let elapsed = previousAt == 0 ? 0 : (nowAbs - previousAt)
        let hasBaseline = previousAt != 0 && elapsed > 0

        var rows: [(pid: pid_t, cpu: Double, memory: UInt64)] = []
        rows.reserveCapacity(count)
        var current: [pid_t: (cpuTime: UInt64, start: UInt64)] = [:]
        current.reserveCapacity(count)
        var unreadable: Set<pid_t> = []
        for pid in pids.prefix(count) {
            var usage = rusage_info_v2()
            let result = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard result == 0 else {
                unreadable.insert(pid)
                continue
            }
            // Both are in mach time units, as is `elapsed`, so the ratio needs no conversion.
            let cpuTime = usage.ri_user_time &+ usage.ri_system_time
            current[pid] = (cpuTime, usage.ri_proc_start_abstime)
            var cpu = 0.0
            if hasBaseline, let before = previous[pid], before.start == usage.ri_proc_start_abstime, cpuTime >= before.cpuTime {
                cpu = Double(cpuTime - before.cpuTime) / Double(elapsed) * 100
            }
            rows.append((pid, cpu, usage.ri_phys_footprint))
        }
        previous = current
        previousAt = nowAbs

        let now = ProcessInfo.processInfo.systemUptime
        if now - foreignAt >= Self.foreignInterval {
            foreignAt = now
            foreign = [:]
            if let output = Self.runPS() {
                for row in Self.parsePS(output) where unreadable.contains(row.pid) {
                    foreign[row.pid] = Foreign(cpu: row.cpu, memory: row.rssKB * 1024, name: row.name)
                }
            }
        }
        for (pid, info) in foreign where unreadable.contains(pid) { rows.append((pid, info.cpu, info.memory)) }

        if meta.count > count * 2 {
            let alive = Set(pids.prefix(count))
            meta = meta.filter { alive.contains($0.key) }
        }
        guard hasBaseline else { return nil }
        // After a long pause the delta would be an average over the pause, not "now".
        if Double(elapsed) * Double(Self.timebase.numer) / Double(Self.timebase.denom) > 15e9 { return nil }

        func build(_ slice: ArraySlice<(pid: pid_t, cpu: Double, memory: UInt64)>) -> [ProcessLoad] {
            slice.map { row in
                let info = describe(row.pid, start: current[row.pid]?.start ?? 0)
                return ProcessLoad(pid: row.pid, name: info.name, cpu: row.cpu, memory: row.memory,
                                   icon: info.appPath.flatMap(icon(for:)))
            }
        }
        let byCPU = rows.sorted { $0.cpu > $1.cpu }.prefix(limit)
        let byMemory = rows.sorted { $0.memory > $1.memory }.prefix(limit)
        return (build(byCPU), build(byMemory))
    }

    private func describe(_ pid: pid_t, start: UInt64) -> Meta {
        if let cached = meta[pid], cached.start == start { return cached }
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var info = Meta(start: start, name: foreign[pid]?.name ?? "", appPath: nil)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            info.name = Self.displayName(path: path)
            info.appPath = Self.appBundlePath(path)
        } else if info.name.isEmpty {
            var name = [CChar](repeating: 0, count: 64)
            proc_name(pid, &name, UInt32(name.count))
            info.name = String(cString: name)
            if info.name.isEmpty { info.name = pid == 0 ? "kernel_task" : "pid \(pid)" }
        }
        meta[pid] = info
        return info
    }

    private func icon(for appPath: String) -> NSImage? {
        if let cached = icons[appPath] { return cached }
        if icons.count > 200 { icons.removeAll() }
        let image = NSWorkspace.shared.icon(forFile: appPath)
        image.size = NSSize(width: 16, height: 16)
        icons[appPath] = image
        return image
    }

    static func displayName(path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// The outermost `.app` bundle containing `path`, so helpers get their parent app's icon.
    static func appBundlePath(_ path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: ps, for processes libproc may not read

    struct PSRow: Equatable { var pid: pid_t; var cpu: Double; var rssKB: UInt64; var name: String }

    /// Parses `ps -Aceo pid=,pcpu=,rss=,comm=` output.
    static func parsePS(_ output: String) -> [PSRow] {
        var rows: [PSRow] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = pid_t(parts[0]), let cpu = Double(parts[1]), let rss = UInt64(parts[2]) else { continue }
            rows.append(PSRow(pid: pid, cpu: cpu, rssKB: rss, name: String(parts[3])))
        }
        return rows
    }

    /// posix_spawn + pipe + waitpid: no Foundation `Process`, so nothing here ever spins a run loop.
    static func runPS() -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        let arguments = ["/bin/ps", "-Aceo", "pid=,pcpu=,rss=,comm="]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/ps", &actions, &attributes, &argv, nil)
        close(fds[1])
        defer { close(fds[0]) }
        guard status == 0 else { return nil }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fds[0], &chunk, chunk.count)
            if n > 0 { data.append(chunk, count: n) } else if n == 0 || errno != EINTR { break }
        }
        var exit: Int32 = 0
        while waitpid(pid, &exit, 0) == -1 && errno == EINTR {}
        return String(decoding: data, as: UTF8.self)
    }
}
