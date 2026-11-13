import AppKit

/// Bosun's mark: a ship's wheel. Drawn in code so the menu bar glyph and the
/// app icon stay the same shape at every size.
enum WheelGlyph {
    /// Draws the wheel centred in `rect`, sized to fill it, in the current graphics context.
    static func draw(in rect: CGRect, color: NSColor, spokes: Int = 8) {
        let unit = min(rect.width, rect.height) / 2          // 1.0 = tip of a handle
        let center = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius * unit, y: center.y + sin(angle) * radius * unit)
        }
        color.setStroke()
        color.setFill()

        let rim = NSBezierPath(ovalIn: CGRect(x: center.x - 0.66 * unit, y: center.y - 0.66 * unit,
                                              width: 1.32 * unit, height: 1.32 * unit))
        rim.lineWidth = 0.17 * unit
        rim.stroke()

        for index in 0..<spokes {
            let angle = CGFloat(index) / CGFloat(spokes) * 2 * .pi + .pi / 2
            let spoke = NSBezierPath()
            spoke.move(to: point(0.2, angle))
            spoke.line(to: point(0.6, angle))
            spoke.lineWidth = 0.1 * unit
            spoke.stroke()
            let handle = NSBezierPath()
            handle.move(to: point(0.72, angle))
            handle.line(to: point(0.92, angle))
            handle.lineWidth = 0.16 * unit
            handle.lineCapStyle = .round
            handle.stroke()
        }

        let hub = NSBezierPath(ovalIn: CGRect(x: center.x - 0.24 * unit, y: center.y - 0.24 * unit,
                                              width: 0.48 * unit, height: 0.48 * unit))
        hub.lineWidth = 0.13 * unit
        hub.stroke()
    }

    /// Template image for the menu bar.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            draw(in: rect.insetBy(dx: 0.5, dy: 0.5), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Bosun"
        return image
    }()
}
