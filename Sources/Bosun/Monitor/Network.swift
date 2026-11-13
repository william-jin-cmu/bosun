import Foundation
import Darwin
import SystemConfiguration

struct InterfaceReading: Identifiable, Equatable {
    var name: String               // BSD name, "en0"
    var displayName: String = ""   // "Wi-Fi"; empty until details are read
    var address: String = ""       // local IPv4 (or IPv6 if that is all there is); never a public lookup
    var down: Double = 0           // bytes per second
    var up: Double = 0
    var totalDown: UInt64 = 0      // since Bosun started
    var totalUp: UInt64 = 0
    var isUp = false
    var id: String { name }
    var title: String { displayName.isEmpty ? name : "\(displayName) (\(name))" }
}

struct NetworkReading {
    var down: Double = 0           // bytes per second over the counted interfaces
    var up: Double = 0
    var totalDown: UInt64 = 0      // since Bosun started
    var totalUp: UInt64 = 0
    var interfaces: [InterfaceReading] = []
}

/// Per-interface byte counters from the routing sysctl (64-bit; getifaddrs only has 32-bit ones).
final class NetworkSampler {
    struct Counters: Equatable { var rx: UInt64; var tx: UInt64; var up: Bool }

    private var previous: [String: Counters] = [:]
    private var previousAt: TimeInterval = 0
    private var totals: [String: (down: UInt64, up: UInt64)] = [:]
    private var names: [UInt16: String] = [:]
    private var details: [String: (displayName: String, address: String)] = [:]
    private var detailsAt: TimeInterval = -.infinity

    /// `counted` picks the interface whose traffic is the headline number; empty means
    /// every physical interface (en*), which avoids counting VPN tunnels twice.
    /// `withDetails` also resolves display names and local addresses (refreshed every 10 s).
    func sample(counted: String = "", withDetails: Bool = false) -> NetworkReading {
        let now = ProcessInfo.processInfo.systemUptime
        let current = Self.counters(names: &names)
        let dt = now - previousAt
        var reading = NetworkReading()
        if withDetails, now - detailsAt > 10 {
            detailsAt = now
            details = Self.readDetails()
        }
        for (name, counters) in current {
            var item = InterfaceReading(name: name, isUp: counters.up)
            // A counter that went backwards means the interface was recreated: skip one sample.
            if let before = previous[name], dt > 0, counters.rx >= before.rx, counters.tx >= before.tx {
                let rx = counters.rx - before.rx, tx = counters.tx - before.tx
                item.down = Double(rx) / dt
                item.up = Double(tx) / dt
                let sum = totals[name] ?? (0, 0)
                totals[name] = (sum.down + rx, sum.up + tx)
            }
            item.totalDown = totals[name]?.down ?? 0
            item.totalUp = totals[name]?.up ?? 0
            if let detail = details[name] {
                item.displayName = detail.displayName
                item.address = detail.address
            }
            if Self.isCounted(name, selection: counted) {
                reading.down += item.down
                reading.up += item.up
                reading.totalDown += item.totalDown
                reading.totalUp += item.totalUp
            }
            reading.interfaces.append(item)
        }
        reading.interfaces = Self.listed(reading.interfaces)
        previous = current
        previousAt = now
        return reading
    }

    static func isCounted(_ name: String, selection: String) -> Bool {
        selection.isEmpty ? name.hasPrefix("en") : name == selection
    }

    /// Interfaces worth a row: up, and either addressed or having moved data since launch.
    /// Loopback and the Apple-internal link-local plumbing (awdl, llw, anpi, ap, gif, stf) are dropped.
    static func listed(_ all: [InterfaceReading]) -> [InterfaceReading] {
        let hidden = ["lo", "awdl", "llw", "anpi", "ap", "gif", "stf", "pktap", "XHC"]
        return all.filter { item in
            guard item.isUp, !hidden.contains(where: { item.name.hasPrefix($0) }) else { return false }
            return !item.address.isEmpty || item.totalDown + item.totalUp > 0
        }
        .sorted { a, b in
            let aPhysical = a.name.hasPrefix("en"), bPhysical = b.name.hasPrefix("en")
            if aPhysical != bPhysical { return aPhysical }
            if a.address.isEmpty != b.address.isEmpty { return !a.address.isEmpty }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Sum over physical interfaces; kept for the self-test.
    static func totals() -> (rx: UInt64, tx: UInt64) {
        var names: [UInt16: String] = [:]
        return counters(names: &names).filter { $0.key.hasPrefix("en") }
            .reduce((0, 0)) { ($0.0 + $1.value.rx, $0.1 + $1.value.tx) }
    }

    static func counters(names: inout [UInt16: String]) -> [String: Counters] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return [:] }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else { return [:] }
        var result: [String: Counters] = [:]
        var seen: Set<UInt16> = []
        var offset = 0
        buffer.withUnsafeBytes { raw in
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                guard header.ifm_msglen > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let info = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    seen.insert(info.ifm_index)
                    var name = names[info.ifm_index]
                    if name == nil {
                        var chars = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                        if if_indextoname(UInt32(info.ifm_index), &chars) != nil {
                            name = String(cString: chars)
                            names[info.ifm_index] = name
                        }
                    }
                    if let name {
                        let flags = info.ifm_flags
                        result[name] = Counters(rx: info.ifm_data.ifi_ibytes, tx: info.ifm_data.ifi_obytes,
                                                up: flags & IFF_UP != 0 && flags & IFF_RUNNING != 0)
                    }
                }
                offset += Int(header.ifm_msglen)
            }
        }
        // Indices are reused when interfaces come and go (VPN tunnels): forget the stale names.
        if names.count != seen.count { names = names.filter { seen.contains($0.key) } }
        return result
    }

    /// Display names from SystemConfiguration, local addresses from getifaddrs.
    static func readDetails() -> [String: (displayName: String, address: String)] {
        var result: [String: (displayName: String, address: String)] = [:]
        for interface in (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? [] {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String? else { continue }
            result[bsd] = ((SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?) ?? "", "")
        }
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }
        var v6: [String: String] = [:]
        var cursor = list
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if family == AF_INET {
                if result[name]?.address.isEmpty ?? true { result[name] = (result[name]?.displayName ?? "", text) }
            } else if !text.hasPrefix("fe80"), v6[name] == nil {
                v6[name] = text
            }
        }
        for (name, address) in v6 where result[name]?.address.isEmpty ?? true {
            result[name] = (result[name]?.displayName ?? "", address)
        }
        for name in result.keys where result[name]!.displayName.isEmpty {
            if name.hasPrefix("utun") || name.hasPrefix("ipsec") || name.hasPrefix("ppp") { result[name]!.displayName = "VPN" }
            else if name.hasPrefix("bridge") { result[name]!.displayName = "Bridge" }
        }
        return result
    }
}
