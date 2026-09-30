// Renders Resources/AppIcon.icns: a MacBook-style notch hanging from the top of a blue gradient
// "screen", with the waveform living inside it, on Apple's macOS icon grid.
// Usage: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <repo root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Apple's grid: an 824pt body inside a 1024pt canvas, ~185pt corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
    shadow.shadowBlurRadius = s * 18 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 8 / 1024)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [
        NSColor(red: 0.10, green: 0.16, blue: 0.52, alpha: 1),
        NSColor(red: 0.16, green: 0.40, blue: 0.95, alpha: 1),
        NSColor(red: 0.38, green: 0.78, blue: 1.00, alpha: 1),
    ])!.draw(in: path, angle: 60)

    // Soft top highlight, like light hitting glass.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: path, angle: -90)

    // The notch: flat top flush with the screen's top edge, soft concave shoulders where it meets
    // the bezel, and round bottom corners, the way it looks on a MacBook.
    let u = s / 1024
    let notchW = 440 * u, notchH = 300 * u, corner = 112 * u, shoulder = 30 * u
    let top = body.maxY, bottom = top - notchH
    let x0 = body.midX - notchW / 2, x1 = body.midX + notchW / 2
    let notch = NSBezierPath()
    notch.move(to: NSPoint(x: x0 - shoulder, y: top + 1))
    notch.curve(to: NSPoint(x: x0, y: top - shoulder), controlPoint1: NSPoint(x: x0, y: top), controlPoint2: NSPoint(x: x0, y: top))
    notch.line(to: NSPoint(x: x0, y: bottom + corner))
    notch.appendArc(withCenter: NSPoint(x: x0 + corner, y: bottom + corner), radius: corner, startAngle: 180, endAngle: 270)
    notch.line(to: NSPoint(x: x1 - corner, y: bottom))
    notch.appendArc(withCenter: NSPoint(x: x1 - corner, y: bottom + corner), radius: corner, startAngle: 270, endAngle: 360)
    notch.line(to: NSPoint(x: x1, y: top - shoulder))
    notch.curve(to: NSPoint(x: x1 + shoulder, y: top + 1), controlPoint1: NSPoint(x: x1, y: top), controlPoint2: NSPoint(x: x1, y: top))
    notch.close()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    // The screen lights up under the notch while it listens.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.30), NSColor.white.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: body.midX, y: bottom), radius: 0,
              toCenter: NSPoint(x: body.midX, y: bottom), radius: 380 * u, options: [])
    let lift = NSShadow()
    lift.shadowColor = NSColor.black.withAlphaComponent(0.35)
    lift.shadowBlurRadius = 24 * u
    lift.shadowOffset = NSSize(width: 0, height: -8 * u)
    NSGraphicsContext.saveGraphicsState()
    lift.set()
    NSColor.black.setFill()
    notch.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(white: 0.02, alpha: 1), NSColor(white: 0.10, alpha: 1)])!.draw(in: notch, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let config = NSImage.SymbolConfiguration(pointSize: 178 * u, weight: .bold)
        .applying(.init(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let center = NSPoint(x: body.midX, y: bottom + notchH * 0.46)
        symbol.draw(in: NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ Resources/AppIcon.icns" : "iconutil failed")
