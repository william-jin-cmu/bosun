import CoreGraphics
import Foundation

/// Headless checks for `Bosun --selftest`.
enum DisplaysChecks {
    static let all: [SelfTest.Check] = [
        (name: "displays: DDC packet format", run: packetFormat),
        (name: "displays: enumerate", run: enumerate),
        (name: "displays: built-in brightness read", run: builtInBrightness),
        (name: "displays: DDC brightness write, read back, restore", run: ddcRoundTrip),
    ]

    /// Known-good bytes: the requests MonitorControl puts on the wire, and a
    /// reply as captured from a real display.
    private static func packetFormat() -> String? {
        let get = DDC.packet(for: [0x10])
        if get != [0x82, 0x01, 0x10, 0xFD] { return "get packet is \(hex(get))" }
        let set = DDC.packet(for: [0x10, 0x00, 0x32])
        if set != [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A] { return "set packet is \(hex(set))" }

        var reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x4B, 0x00]
        reply[10] = reply[0..<10].reduce(0x50, ^)
        guard let parsed = DDC.parseReply(reply, vcp: 0x10), parsed.current == 75, parsed.max == 100 else {
            return "valid reply did not parse to 75/100"
        }
        if DDC.parseReply(reply, vcp: 0x62) != nil { return "reply for another feature was accepted" }
        var unsupported = reply
        unsupported[3] = 0x01
        unsupported[10] = unsupported[0..<10].reduce(0x50, ^)
        if DDC.parseReply(unsupported, vcp: 0x10) != nil { return "unsupported-feature reply was accepted" }
        var corrupt = reply
        corrupt[9] ^= 0xFF
        if DDC.parseReply(corrupt, vcp: 0x10) != nil { return "reply with a bad checksum was accepted" }
        return nil
    }

    private static func enumerate() -> String? {
        let ids = DisplaysModule.activeDisplayIDs()
        // No displays at all is legitimate (headless session); nothing to check.
        let external = ids.filter { CGDisplayIsBuiltin($0) == 0 }
        let services = DDC.externalServices()
        let matched = DDC.match(displays: external, services: services)
        for id in ids {
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let name = DisplaysModule.fallbackName(id, builtIn: builtIn)
            Log.info("display \(id): \(name)\(builtIn ? " (built-in)" : matched[id] != nil ? " (DDC channel found)" : " (no DDC channel)")", "displays")
        }
        if Set(matched.values.map { ObjectIdentifier($0) }).count != matched.count {
            return "one DDC channel was matched to two displays"
        }
        // A display that enumerates as external but has no channel is reported,
        // not failed: virtual, AirPlay and Sidecar displays never have one.
        return nil
    }

    private static func builtInBrightness() -> String? {
        guard let id = DisplaysModule.activeDisplayIDs().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
            Log.info("no built-in display, skipped", "displays")
            return nil
        }
        guard NativeBrightness.isAvailable else { return "DisplayServices symbols not found" }
        guard let value = NativeBrightness.get(id) else { return "DisplayServicesGetBrightness failed for display \(id)" }
        Log.info("built-in brightness \(Int((value * 100).rounded()))%", "displays")
        return nil
    }

    private static func ddcRoundTrip() -> String? {
        let external = DisplaysModule.activeDisplayIDs().filter { CGDisplayIsBuiltin($0) == 0 }
        let matched = DDC.match(displays: external, services: DDC.externalServices())
        var tested = 0
        var failures: [String] = []
        for id in external.sorted() {
            guard let service = matched[id], let original = DDC.read(service, vcp: DDC.VCP.brightness), original.max > 0 else {
                continue    // not DDC-capable: shown as "No DDC control" in the panel
            }
            tested += 1
            let name = DisplaysModule.fallbackName(id, builtIn: false)
            let target = original.current >= 5 ? original.current - 5 : original.current + 5

            var failure: String?
            if !DDC.write(service, vcp: DDC.VCP.brightness, value: target) {
                failure = "write of \(target) failed"
            } else if let seen = readBack(service, expecting: target) {
                if seen != target { failure = "wrote \(target), read back \(seen)" }
            } else {
                failure = "read back after writing \(target) failed"
            }

            // Always restore, whatever happened above.
            var restored = false
            for _ in 0..<3 where !restored {
                restored = DDC.write(service, vcp: DDC.VCP.brightness, value: original.current)
                    && readBack(service, expecting: original.current) == original.current
            }
            if !restored {
                failure = (failure.map { $0 + "; " } ?? "") + "COULD NOT RESTORE brightness to \(original.current)"
            }

            Log.info("\(name): brightness \(original.current)/\(original.max), wrote \(target), \(failure ?? "read back matched, restored")", "displays")
            if let failure { failures.append("\(name): \(failure)") }
        }
        if tested == 0 { Log.info("no DDC-capable external display, skipped", "displays") }
        return failures.isEmpty ? nil : failures.joined(separator: " | ")
    }

    /// Displays can take a moment to apply a value; poll briefly for it.
    private static func readBack(_ service: DDC.Service, expecting value: UInt16) -> UInt16? {
        var last: UInt16?
        for _ in 0..<4 {
            usleep(50_000)
            last = DDC.read(service, vcp: DDC.VCP.brightness)?.current ?? last
            if last == value { return last }
        }
        return last
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
