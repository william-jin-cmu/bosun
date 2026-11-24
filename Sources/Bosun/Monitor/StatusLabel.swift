import SwiftUI
import AppKit

// The menu bar item. A MenuBarExtra label only reliably renders an Image and a Text
// (no custom drawing, frames or stacks of mixed fonts), so every widget is drawn into
// one template NSImage: the system then tints it for a light or dark menu bar, and
// the item's width is exactly the image's width.

/// One drawable element of the menu bar item. Values are pre-formatted and quantised,
/// so two equal pieces draw identically and an unchanged item is not redrawn.
enum StatusPiece: Equatable {
    case icon
    /// A number, optionally under a small caption. `widest` is the widest text the value can ever be.
    case value(caption: String?, text: String, widest: String)
    /// Two short lines (network up over down).
    case stack(top: String, bottom: String, widest: String)
    /// Area graph; levels are 0...StatusLayout.graphLevels, oldest first, `capacity` slots wide.
    case graph(levels: [UInt8], capacity: Int)
    /// One vertical bar per entry, levels 0...StatusLayout.graphLevels.
    case bars(levels: [UInt8])
    case battery(percent: Int, charging: Bool)
}

enum StatusComposer {
    static let graphSlots = 30

    /// Pure: what the menu bar item shows for these preferences and readings.
    static func pieces(prefs: MonitorPrefs, snapshot: MonitorSnapshot, enabled: Bool = true) -> [StatusPiece] {
        guard enabled else { return [.icon] }
        var pieces: [StatusPiece] = prefs.effectiveShowIcon ? [.icon] : []
        let labels = prefs.widgetLabels
        func value(_ widget: StatusWidget, _ text: String, widest: String) -> StatusPiece {
            .value(caption: labels ? widget.caption : nil, text: text, widest: widest)
        }
        for widget in prefs.widgets {
            switch widget {
            case .cpu:
                pieces.append(value(widget, Format.percent(snapshot.cpu.total), widest: "100%"))
            case .cpuGraph:
                pieces.append(.graph(levels: snapshot.cpuHistory.suffix(graphSlots).map(StatusLayout.level), capacity: graphSlots))
            case .cpuBars:
                let order = CPUTopology.current.clusters.flatMap(\.indices)
                let cores = snapshot.cpu.cores
                let ordered = order.count == cores.count ? order.map { cores[$0] } : cores
                pieces.append(.bars(levels: ordered.map(StatusLayout.level)))
            case .gpu:
                pieces.append(value(widget, snapshot.gpu.map { Format.percent($0.utilization) } ?? "–", widest: "100%"))
            case .memory:
                pieces.append(value(widget, Format.percent(snapshot.memory.fraction), widest: "100%"))
            case .network:
                pieces.append(.stack(top: Format.rate(snapshot.network.up) + " ↑",
                                     bottom: Format.rate(snapshot.network.down) + " ↓", widest: "999 M ↓"))
            case .disk:
                pieces.append(value(widget, snapshot.disk.boot.map { Format.percent($0.usedFraction) } ?? "–", widest: "100%"))
            case .temperature:
                let text = snapshot.sensors.cpuTemperature.map { Format.degrees($0, fahrenheit: prefs.fahrenheit) } ?? "–"
                pieces.append(value(widget, text, widest: prefs.fahrenheit ? "222°" : "100°"))
            case .battery:
                if let battery = snapshot.battery {
                    pieces.append(.battery(percent: battery.percent, charging: battery.isCharging))
                }
            }
        }
        return pieces.isEmpty ? [.icon] : pieces
    }

    /// Spoken description of the item.
    static func description(_ pieces: [StatusPiece]) -> String {
        var parts = ["Bosun"]
        for piece in pieces {
            switch piece {
            case .icon, .graph, .bars: break
            case let .value(caption, text, _): parts.append([caption, text].compactMap { $0 }.joined(separator: " "))
            case let .stack(top, bottom, _): parts.append("up \(top.dropLast(2)), down \(bottom.dropLast(2))")
            case let .battery(percent, charging): parts.append("battery \(percent)%\(charging ? ", charging" : "")")
            }
        }
        return parts.joined(separator: ", ")
    }
}

enum StatusLayout {
    static let height: CGFloat = 22
    static let spacing: CGFloat = 6
    static let iconSize: CGFloat = 18
    static let graphLevels = 16
    static let graphHeight: CGFloat = 16
    static let barWidth: CGFloat = 3
    static let barGap: CGFloat = 1
    static let batteryBody = CGSize(width: 21, height: 10.5)

    static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
    static let smallValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    static let captionFont = NSFont.systemFont(ofSize: 7, weight: .semibold)
    static let stackFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)

    /// 0...1 -> 0...graphLevels, so tiny load changes do not force a redraw.
    static func level(_ fraction: Double) -> UInt8 {
        UInt8((min(max(fraction, 0), 1) * Double(graphLevels)).rounded())
    }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Width of a piece. Depends only on what kind of piece it is and on its `widest`
    /// template, never on the current value, so the item does not jitter as numbers change.
    static func width(_ piece: StatusPiece) -> CGFloat {
        switch piece {
        case .icon: return iconSize
        case let .value(caption, _, widest):
            guard let caption else { return textWidth(widest, valueFont) }
            return max(textWidth(widest, smallValueFont), textWidth(caption, captionFont))
        case let .stack(_, _, widest): return textWidth(widest, stackFont)
        case let .graph(_, capacity): return CGFloat(capacity) + 2
        case let .bars(levels): return CGFloat(levels.count) * (barWidth + barGap) - barGap
        case .battery: return batteryBody.width + 2 + 3 + textWidth("100%", valueFont)
        }
    }

    static func totalWidth(_ pieces: [StatusPiece]) -> CGFloat {
        pieces.map(width).reduce(0, +) + spacing * CGFloat(max(pieces.count - 1, 0))
    }
}

enum StatusRenderer {
    /// A template image of all pieces in a row.
    ///
    /// Drawn once into a bitmap rather than left as a drawing handler: AppKit snapshots a
    /// status item several times per change (once per display and menu bar style), and each
    /// snapshot would otherwise run the whole drawing again.
    static func image(_ pieces: [StatusPiece], scale: CGFloat = 2) -> NSImage {
        if pieces == [.icon] { return MainActor.assumeIsolated { MenuBarIcon.shared.image } }
        let size = NSSize(width: max(1, ceil(StatusLayout.totalWidth(pieces))), height: StatusLayout.height)
        let image = NSImage(size: size)
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let context = NSGraphicsContext(bitmapImageRep: rep) {
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // A bitmap context draws in pixels; scale so the pieces are laid out in points.
            context.cgContext.scaleBy(x: scale, y: scale)
            var x: CGFloat = 0
            for piece in pieces {
                let width = StatusLayout.width(piece)
                draw(piece, in: CGRect(x: x, y: 0, width: width, height: size.height))
                x += width + StatusLayout.spacing
            }
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        image.accessibilityDescription = StatusComposer.description(pieces)
        return image
    }

    private static func draw(_ piece: StatusPiece, in rect: CGRect) {
        let ink = NSColor.black
        switch piece {
        case .icon:
            let side = StatusLayout.iconSize
            MainActor.assumeIsolated {
                MenuBarIcon.shared.draw(in: CGRect(x: rect.minX, y: rect.midY - side / 2, width: side, height: side))
            }
        case let .value(caption, text, _):
            if let caption {
                drawText(caption, StatusLayout.captionFont, ink.withAlphaComponent(0.7), in: rect, alignment: .center, baseline: 13.5)
                drawText(text, StatusLayout.smallValueFont, ink, in: rect, alignment: .center, baseline: 3.5)
            } else {
                drawText(text, StatusLayout.valueFont, ink, in: rect, alignment: .right, baseline: 6.5)
            }
        case let .stack(top, bottom, _):
            drawText(top, StatusLayout.stackFont, ink, in: rect, alignment: .right, baseline: 12.5)
            drawText(bottom, StatusLayout.stackFont, ink, in: rect, alignment: .right, baseline: 3)
        case let .graph(levels, capacity):
            let box = CGRect(x: rect.minX, y: rect.midY - StatusLayout.graphHeight / 2, width: rect.width, height: StatusLayout.graphHeight)
            ink.withAlphaComponent(0.18).setFill()
            NSBezierPath(roundedRect: box, xRadius: 2.5, yRadius: 2.5).fill()
            let plot = box.insetBy(dx: 1, dy: 1)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: plot, xRadius: 1.5, yRadius: 1.5).addClip()
            ink.setFill()
            let slot = plot.width / CGFloat(max(capacity, 1))
            let offset = CGFloat(capacity - levels.count) * slot
            for (index, level) in levels.enumerated() {
                let height = max(1, plot.height * CGFloat(level) / CGFloat(StatusLayout.graphLevels))
                CGRect(x: plot.minX + offset + CGFloat(index) * slot, y: plot.minY, width: slot, height: height).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        case let .bars(levels):
            let bottom = rect.midY - StatusLayout.graphHeight / 2
            for (index, level) in levels.enumerated() {
                let x = rect.minX + CGFloat(index) * (StatusLayout.barWidth + StatusLayout.barGap)
                let track = CGRect(x: x, y: bottom, width: StatusLayout.barWidth, height: StatusLayout.graphHeight)
                ink.withAlphaComponent(0.2).setFill()
                NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()
                let height = max(1.5, track.height * CGFloat(level) / CGFloat(StatusLayout.graphLevels))
                ink.setFill()
                NSBezierPath(roundedRect: CGRect(x: x, y: bottom, width: StatusLayout.barWidth, height: height), xRadius: 1, yRadius: 1).fill()
            }
        case let .battery(percent, charging):
            let body = CGRect(x: rect.minX + 0.5, y: rect.midY - StatusLayout.batteryBody.height / 2,
                              width: StatusLayout.batteryBody.width, height: StatusLayout.batteryBody.height)
            let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1
            ink.withAlphaComponent(0.55).setStroke()
            outline.stroke()
            ink.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: CGRect(x: body.maxX + 1, y: body.midY - 2, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
            let inner = body.insetBy(dx: 2, dy: 2)
            let fill = CGRect(x: inner.minX, y: inner.minY, width: max(1.5, inner.width * CGFloat(min(max(percent, 0), 100)) / 100), height: inner.height)
            ink.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.2, yRadius: 1.2).fill()
            if charging, let context = NSGraphicsContext.current?.cgContext {
                // Punch a lightning bolt out of the body so it reads on any fill level.
                let bolt = NSBezierPath()
                let c = CGPoint(x: body.midX, y: body.midY)
                bolt.move(to: CGPoint(x: c.x + 1.5, y: c.y + 4.5))
                bolt.line(to: CGPoint(x: c.x - 3.5, y: c.y - 0.6))
                bolt.line(to: CGPoint(x: c.x - 0.3, y: c.y - 0.6))
                bolt.line(to: CGPoint(x: c.x - 1.5, y: c.y - 4.5))
                bolt.line(to: CGPoint(x: c.x + 3.5, y: c.y + 0.6))
                bolt.line(to: CGPoint(x: c.x + 0.3, y: c.y + 0.6))
                bolt.close()
                context.saveGState()
                context.setBlendMode(.clear)
                bolt.lineWidth = 2
                bolt.stroke()
                bolt.fill()
                context.setBlendMode(.normal)
                context.restoreGState()
                ink.setFill()
                bolt.fill()
            }
            // Left-aligned so the number stays next to the glyph; the reserved width is still that of "100%".
            let textRect = CGRect(x: body.maxX + 5, y: rect.minY, width: rect.maxX - body.maxX - 5, height: rect.height)
            drawText("\(percent)%", StatusLayout.valueFont, ink, in: textRect, alignment: .left, baseline: 6.5)
        }
    }

    /// Draws one line with its baseline `baseline` points above the bottom of `rect`.
    private static func drawText(_ text: String, _ font: NSFont, _ color: NSColor, in rect: CGRect,
                                 alignment: NSTextAlignment, baseline: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (text as NSString).size(withAttributes: attributes).width
        let x: CGFloat
        switch alignment {
        case .right: x = rect.maxX - width
        case .center: x = rect.midX - width / 2
        default: x = rect.minX
        }
        (text as NSString).draw(at: CGPoint(x: x, y: rect.minY + baseline + font.descender), withAttributes: attributes)
    }

    /// The template image tinted and composited onto a bar-coloured background, for
    /// previews and for checking the drawing without a menu bar.
    static func preview(_ pieces: [StatusPiece], dark: Bool, scale: CGFloat = 2, padding: CGFloat = 10) -> NSBitmapImageRep? {
        let image = image(pieces)
        let size = NSSize(width: image.size.width + padding * 2, height: 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        (dark ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        CGRect(origin: .zero, size: size).fill()
        let target = CGRect(x: padding, y: (size.height - image.size.height) / 2, width: image.size.width, height: image.size.height)
        context.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(in: target)
        (dark ? NSColor.white : NSColor.black).setFill()
        target.fill(using: .sourceIn)
        context.cgContext.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}

/// Holds the rendered menu bar image. Separate from MonitorModule so that readings
/// published for the panel do not invalidate the menu bar label, and vice versa.
@MainActor
final class StatusModel: ObservableObject {
    @Published private(set) var image: NSImage = MenuBarIcon.shared.image
    private(set) var pieces: [StatusPiece] = [.icon]

    func show(_ pieces: [StatusPiece]) {
        guard pieces != self.pieces else { return }
        self.pieces = pieces
        render()
    }

    /// Redraws with the current pieces, e.g. after the user picked another icon.
    func render() {
        image = StatusRenderer.image(pieces, scale: NSScreen.screens.map(\.backingScaleFactor).max() ?? 2)
    }
}

/// The MenuBarExtra label.
struct StatusLabel: View {
    let monitor: MonitorModule
    let monitorEnabled: Bool

    var body: some View {
        StatusImage(model: monitor.status, enabled: monitorEnabled)
    }
}

private struct StatusImage: View {
    @ObservedObject var model: StatusModel
    @ObservedObject var icon = MenuBarIcon.shared
    let enabled: Bool

    var body: some View {
        Image(nsImage: enabled ? model.image : icon.image)
            .onChange(of: icon.image) { model.render() }
    }
}
