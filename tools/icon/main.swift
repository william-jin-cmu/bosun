// Renders Resources/AppIcon.icns and a menu bar glyph preview.
// Run via tools/make-icon.sh.
import AppKit

func png(_ size: Int, _ draw: (CGRect) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func appIcon(_ canvas: CGRect) {
    let s = canvas.width / 1024
    let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let shape = NSBezierPath(roundedRect: plate, xRadius: 186 * s, yRadius: 186 * s)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
    drop.shadowBlurRadius = 24 * s
    drop.shadowOffset = NSSize(width: 0, height: -10 * s)
    drop.set()
    NSColor(srgbRed: 0.07, green: 0.13, blue: 0.24, alpha: 1).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    // Deep sea: lighter teal-navy at the top falling to near-black blue.
    NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.30, blue: 0.44, alpha: 1),
                        NSColor(srgbRed: 0.06, green: 0.14, blue: 0.27, alpha: 1),
                        NSColor(srgbRed: 0.03, green: 0.07, blue: 0.15, alpha: 1)])!
        .draw(in: plate, angle: -90)
    // Soft glow behind the wheel.
    NSGradient(colors: [NSColor(srgbRed: 0.45, green: 0.75, blue: 0.85, alpha: 0.20),
                        NSColor(srgbRed: 0.45, green: 0.75, blue: 0.85, alpha: 0.06),
                        NSColor(srgbRed: 0.45, green: 0.75, blue: 0.85, alpha: 0)])!
        .draw(in: NSBezierPath(ovalIn: plate.insetBy(dx: -60 * s, dy: -60 * s)), relativeCenterPosition: .zero)

    let wheelRect = plate.insetBy(dx: 128 * s, dy: 128 * s)
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.45)
    lift.shadowBlurRadius = 18 * s
    lift.shadowOffset = NSSize(width: 0, height: -8 * s)
    lift.set()
    // One transparency layer so the shadow is cast by the whole wheel, not each stroke.
    let cg = NSGraphicsContext.current!.cgContext
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    WheelGlyph.draw(in: wheelRect, color: NSColor(srgbRed: 0.96, green: 0.90, blue: 0.76, alpha: 1))
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    // Thin top highlight on the plate edge.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 184 * s, yRadius: 184 * s)
    edge.lineWidth = 4 * s
    NSColor.white.withAlphaComponent(0.10).setStroke()
    edge.stroke()
    NSGraphicsContext.restoreGraphicsState()
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = out.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(base, appIcon).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(base * 2, appIcon).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
// Preview: the menu bar glyph at 2x, shown large on light and dark bars.
try png(288) { rect in
    NSColor(white: 0.93, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: 144, height: 288).fill()
    NSColor(white: 0.12, alpha: 1).setFill(); CGRect(x: 144, y: 0, width: 144, height: 288).fill()
    WheelGlyph.draw(in: CGRect(x: 18, y: 162, width: 108, height: 108), color: .black)
    WheelGlyph.draw(in: CGRect(x: 162, y: 162, width: 108, height: 108), color: .white)
    WheelGlyph.draw(in: CGRect(x: 54, y: 60, width: 36, height: 36), color: .black)
    WheelGlyph.draw(in: CGRect(x: 198, y: 60, width: 36, height: 36), color: .white)
}.write(to: out.appendingPathComponent("glyph-preview.png"))
