// Renders the disk image window background (Resources/dmg-background.png and @2x): a title, an
// arrow from the app to Applications, and the one-line instructions. Icons sit at x=165 and x=495,
// y=210 (from the top) in a 660×400 window; scripts/dmg-settings.py places them there.
// Usage: swiftc scripts/make-dmg-background.swift -o /tmp/make-dmg-bg && /tmp/make-dmg-bg <repo root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")

func render(scale: CGFloat) -> Data {
    let w = 660 * scale, h = 400 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let u = scale
    // Top-left coordinates, like Finder's.
    func y(_ fromTop: CGFloat) -> CGFloat { h - fromTop * u }

    NSGradient(colors: [NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1), NSColor(red: 0.89, green: 0.93, blue: 1.0, alpha: 1)])!
        .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

    func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * u, weight: weight), .foregroundColor: color, .paragraphStyle: style,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let height = str.size().height
        str.draw(in: NSRect(x: 0, y: y(top) - height, width: w, height: height))
    }
    text("Install OpenNotch", size: 26, weight: .semibold, color: NSColor(white: 0.1, alpha: 1), top: 42)

    // Arrow from the app icon to the Applications folder.
    let accent = NSColor(red: 0.16, green: 0.40, blue: 0.95, alpha: 1)
    let start = NSPoint(x: 250 * u, y: y(206)), end = NSPoint(x: 410 * u, y: y(206))
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: NSPoint(x: end.x - 14 * u, y: end.y))
    shaft.lineWidth = 6 * u
    shaft.lineCapStyle = .round
    accent.withAlphaComponent(0.85).setStroke()
    shaft.stroke()
    let head = NSBezierPath()
    head.move(to: NSPoint(x: end.x + 4 * u, y: end.y))
    head.line(to: NSPoint(x: end.x - 20 * u, y: end.y + 16 * u))
    head.line(to: NSPoint(x: end.x - 20 * u, y: end.y - 16 * u))
    head.close()
    accent.withAlphaComponent(0.85).setFill()
    head.fill()

    text("Drag OpenNotch to Applications", size: 15, weight: .medium, color: NSColor(white: 0.2, alpha: 1), top: 318)
    text("or just double-click it, and it installs itself.", size: 13, weight: .regular, color: NSColor(white: 0.42, alpha: 1), top: 342)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [.compressionFactor: 1.0])!
}

try! render(scale: 1).write(to: root.appendingPathComponent("Resources/dmg-background.png"))
try! render(scale: 2).write(to: root.appendingPathComponent("Resources/dmg-background@2x.png"))
print("✓ Resources/dmg-background.png (+ @2x)")
