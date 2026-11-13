import CBridge
import CoreGraphics
import Foundation
import IOKit

/// DDC/CI over the Apple Silicon `IOAVService` I2C channel.
///
/// Packet format, checksums, retry counts and sleep timings follow
/// MonitorControl's Arm64DDC.swift (MIT). Everything here blocks for tens of
/// milliseconds per call, so callers must stay off the main thread.
enum DDC {
    enum VCP {
        static let brightness: UInt8 = 0x10
        static let contrast: UInt8 = 0x12
        static let inputSource: UInt8 = 0x60
        static let volume: UInt8 = 0x62
        static let mute: UInt8 = 0x8D
    }

    /// Values of VCP 0x8D.
    enum Mute {
        static let on: UInt16 = 1
        static let off: UInt16 = 2
    }

    /// An open I2C channel to one external display.
    final class Service: @unchecked Sendable {
        let av: CFTypeRef
        let edidUUID: String
        let productName: String
        let serialNumber: Int64
        /// IOService-plane path of the framebuffer that owns this channel.
        let framebufferPath: String

        init(av: CFTypeRef, edidUUID: String, productName: String, serialNumber: Int64, framebufferPath: String) {
            self.av = av
            self.edidUUID = edidUUID
            self.productName = productName
            self.serialNumber = serialNumber
            self.framebufferPath = framebufferPath
        }
    }

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51
    private static let writeSleep: UInt32 = 10_000
    private static let readSleep: UInt32 = 50_000
    private static let retrySleep: UInt32 = 20_000
    private static let writeCycles = 2
    private static let attempts = 5

    // MARK: Packets

    /// The bytes handed to `IOAVServiceWriteI2C` for a VCP request. A one-byte
    /// payload is a "get", three bytes a "set".
    static func packet(for payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [UInt8(0x80 | (payload.count + 1)), UInt8(payload.count)] + payload
        // Same seeds as MonitorControl: reads omit the 0x51 source byte.
        let seed: UInt8 = payload.count == 1 ? 0x6E : 0x6E ^ 0x51
        packet.append(packet.reduce(seed, ^))
        return packet
    }

    /// Parses an 11-byte "VCP feature reply". Nil when the checksum is wrong,
    /// the reply is for a different feature (another DDC client may be talking
    /// to the display at the same time) or the display reports the feature as
    /// unsupported.
    static func parseReply(_ reply: [UInt8], vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        guard reply.count == 11 else { return nil }
        guard reply[0..<10].reduce(0x50, ^) == reply[10] else { return nil }
        guard reply[2] == 0x02, reply[3] == 0x00, reply[4] == vcp else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return (current, max)
    }

    // MARK: Read / write

    static func read(_ service: Service, vcp: UInt8) -> (current: UInt16, max: UInt16)? {
        var request = packet(for: [vcp])
        for _ in 0..<attempts {
            for _ in 0..<writeCycles {
                usleep(writeSleep)
                _ = IOAVServiceWriteI2C(service.av, chipAddress, dataAddress, &request, UInt32(request.count))
            }
            usleep(readSleep)
            var reply = [UInt8](repeating: 0, count: 11)
            if IOAVServiceReadI2C(service.av, chipAddress, 0, &reply, UInt32(reply.count)) == KERN_SUCCESS,
               let values = parseReply(reply, vcp: vcp) {
                return values
            }
            usleep(retrySleep)
        }
        return nil
    }

    @discardableResult
    static func write(_ service: Service, vcp: UInt8, value: UInt16) -> Bool {
        var request = packet(for: [vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
        for _ in 0..<attempts {
            var ok = false
            for _ in 0..<writeCycles {
                usleep(writeSleep)
                ok = IOAVServiceWriteI2C(service.av, chipAddress, dataAddress, &request, UInt32(request.count)) == KERN_SUCCESS
            }
            if ok { return true }
            usleep(retrySleep)
        }
        return false
    }

    // MARK: Discovery

    /// Every `DCPAVServiceProxy` with `Location == External`, paired with the
    /// identity of the framebuffer (`AppleCLCD2`) that drives the same display.
    ///
    /// The proxy is not a registry descendant of its framebuffer: the
    /// framebuffer sits at `…/dispext0@…/AppleCLCD2` while the proxy sits under
    /// the coprocessor at `…/dcpext0@…/…/dispext0:dcpav-service-epic:0/`. The
    /// shared `dispext0` device name links the two. When that naming is absent
    /// we fall back to MonitorControl's rule: the framebuffer most recently
    /// seen in a recursive walk of the IOService plane.
    static func externalServices() -> [Service] {
        struct Framebuffer {
            var device = ""          // "dispext0"
            var edidUUID = ""
            var productName = ""
            var serial: Int64 = 0
            var path = ""
        }
        var iterator = io_iterator_t()
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var framebuffers: [Framebuffer] = []
        var proxies: [(av: CFTypeRef, device: String, preceding: Int?)] = []
        var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
            let entryName = String(cString: name)
            if entryName == "AppleCLCD2" || entryName == "IOMobileFramebufferShim" {
                var framebuffer = Framebuffer()
                framebuffer.device = parentName(of: entry).components(separatedBy: "@")[0]
                framebuffer.edidUUID = property(entry, "EDID UUID") as? String ?? ""
                if let attributes = property(entry, "DisplayAttributes") as? NSDictionary,
                   let product = attributes["ProductAttributes"] as? NSDictionary {
                    framebuffer.productName = product["ProductName"] as? String ?? ""
                    framebuffer.serial = (product["SerialNumber"] as? NSNumber)?.int64Value ?? 0
                }
                framebuffer.path = registryPath(entry)
                framebuffers.append(framebuffer)
            } else if entryName == "DCPAVServiceProxy" {
                guard let location = property(entry, "Location") as? String, location == "External",
                      let av = IOAVServiceCreateWithService(kCFAllocatorDefault, entry) else { continue }
                let device = parentName(of: entry).components(separatedBy: ":")[0]
                proxies.append((av, device, framebuffers.indices.last))
            }
        }

        return proxies.map { proxy in
            let index = framebuffers.firstIndex { !$0.device.isEmpty && $0.device == proxy.device } ?? proxy.preceding
            let framebuffer = index.map { framebuffers[$0] } ?? Framebuffer()
            return Service(av: proxy.av, edidUUID: framebuffer.edidUUID, productName: framebuffer.productName,
                           serialNumber: framebuffer.serial, framebufferPath: framebuffer.path)
        }
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func registryPath(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: MemoryLayout<io_string_t>.size)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private static func parentName(of entry: io_registry_entry_t) -> String {
        var parent = io_registry_entry_t()
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return "" }
        defer { IOObjectRelease(parent) }
        var name = [CChar](repeating: 0, count: MemoryLayout<io_name_t>.size)
        guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { return "" }
        return String(cString: name)
    }

    // MARK: Matching services to displays

    /// What CoreGraphics / CoreDisplay know about a display, for matching.
    struct DisplayIdentity {
        var vendor: Int64 = 0
        var product: Int64 = 0
        var week: Int64 = 0
        var year: Int64 = 0
        var horizontalSize: Int64 = 0
        var verticalSize: Int64 = 0
        var serial: Int64 = 0
        var name = ""
        var location = ""
    }

    private typealias InfoDictionaryFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private static let infoDictionaryFn: InfoDictionaryFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let symbol = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(symbol, to: InfoDictionaryFn.self)
    }()

    static func identity(of displayID: CGDirectDisplayID) -> DisplayIdentity {
        var identity = DisplayIdentity()
        identity.vendor = Int64(CGDisplayVendorNumber(displayID))
        identity.product = Int64(CGDisplayModelNumber(displayID))
        identity.serial = Int64(CGDisplaySerialNumber(displayID))
        guard let info = infoDictionaryFn?(displayID)?.takeRetainedValue() as NSDictionary? else { return identity }
        func int(_ key: String) -> Int64? { (info[key] as? NSNumber)?.int64Value }
        identity.vendor = int("DisplayVendorID") ?? identity.vendor
        identity.product = int("DisplayProductID") ?? identity.product
        identity.serial = int("DisplaySerialNumber") ?? identity.serial
        identity.week = int("DisplayWeekManufacture") ?? 0
        identity.year = int("DisplayYearManufacture") ?? 0
        identity.horizontalSize = int("DisplayHorizImageSize") ?? 0
        identity.verticalSize = int("DisplayVertImageSize") ?? 0
        identity.location = info["IODisplayLocation"] as? String ?? ""
        if let names = info["DisplayProductName"] as? [String: String] {
            identity.name = names["en_US"] ?? names.first?.value ?? ""
        }
        return identity
    }

    /// MonitorControl's scoring: registry location is decisive (10), EDID
    /// fragments, product name and serial number add one point each.
    static func matchScore(_ identity: DisplayIdentity, _ service: Service) -> Int {
        var score = 0
        func hex(_ value: Int64, bytes: Int) -> String {
            let limit: Int64 = bytes == 1 ? 0xFF : 0xFFFF
            return String(format: bytes == 1 ? "%02X" : "%04X", Int(Swift.max(0, Swift.min(value, limit))))
        }
        let product = Swift.max(0, Swift.min(identity.product, 0xFFFF))
        let fragments: [(key: String, offset: Int)] = [
            (hex(identity.vendor, bytes: 2), 0),
            (hex(product & 0xFF, bytes: 1) + hex(product >> 8, bytes: 1), 4),
            (hex(identity.week, bytes: 1) + hex(identity.year - 1990, bytes: 1), 19),
            (hex(identity.horizontalSize / 10, bytes: 1) + hex(identity.verticalSize / 10, bytes: 1), 30),
        ]
        for fragment in fragments where fragment.key != "0000" {
            if service.edidUUID.prefix(fragment.offset + 4).suffix(4) == fragment.key { score += 1 }
        }
        if !service.framebufferPath.isEmpty, service.framebufferPath == identity.location { score += 10 }
        if !service.productName.isEmpty, service.productName.lowercased() == identity.name.lowercased() { score += 1 }
        if service.serialNumber != 0, service.serialNumber == identity.serial { score += 1 }
        return score
    }

    /// Assigns each external display at most one service, best scores first.
    static func match(displays: [CGDirectDisplayID], services: [Service]) -> [CGDirectDisplayID: Service] {
        var candidates: [(display: CGDirectDisplayID, index: Int, score: Int)] = []
        for display in displays {
            let identity = identity(of: display)
            for (index, service) in services.enumerated() {
                let score = matchScore(identity, service)
                if score > 0 { candidates.append((display, index, score)) }
            }
        }
        var result: [CGDirectDisplayID: Service] = [:]
        var taken = Set<Int>()
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard result[candidate.display] == nil, !taken.contains(candidate.index) else { continue }
            result[candidate.display] = services[candidate.index]
            taken.insert(candidate.index)
        }
        // One display and one channel left over can only belong together.
        let unmatchedDisplays = displays.filter { result[$0] == nil }
        let unmatchedServices = services.indices.filter { !taken.contains($0) }
        if unmatchedDisplays.count == 1, unmatchedServices.count == 1 {
            result[unmatchedDisplays[0]] = services[unmatchedServices[0]]
        }
        return result
    }
}

/// Brightness of Apple-controlled panels (the built-in display, Apple external
/// displays) through the private DisplayServices framework, resolved at run
/// time so the package needs no private-framework linker flags.
enum NativeBrightness {
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let functions: (get: GetFn, set: SetFn)? = {
        let path = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
        guard let handle = dlopen(path, RTLD_LAZY),
              let get = dlsym(handle, "DisplayServicesGetBrightness"),
              let set = dlsym(handle, "DisplayServicesSetBrightness") else { return nil }
        return (unsafeBitCast(get, to: GetFn.self), unsafeBitCast(set, to: SetFn.self))
    }()

    static var isAvailable: Bool { functions != nil }

    /// 0...1, or nil when the display is not controllable this way.
    static func get(_ displayID: CGDirectDisplayID) -> Double? {
        guard let functions else { return nil }
        var value: Float = 0
        guard functions.get(displayID, &value) == 0, value.isFinite else { return nil }
        return Double(Swift.min(Swift.max(value, 0), 1))
    }

    @discardableResult
    static func set(_ displayID: CGDirectDisplayID, _ value: Double) -> Bool {
        guard let functions else { return false }
        return functions.set(displayID, Float(Swift.min(Swift.max(value, 0), 1))) == 0
    }
}
