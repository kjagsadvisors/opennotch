// Renders the disk image window background (Resources/dmg-background.png and @2x): a title and the
// one-line instruction above a single app icon at x=330, y=190 (from the top) in a 660×400 window;
// scripts/dmg-settings.py places it there. There's deliberately no Applications folder to drag onto:
// macOS never opens an app after a drag, but double-clicking installs it and opens it (Installer.swift).
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
    // Everything important sits in the top two-thirds: on macOS 26, Finder draws its toolbar and
    // path bar inside disk image windows, which covers the bottom of the picture.
    text("Install OpenNotch", size: 24, weight: .semibold, color: NSColor(white: 0.1, alpha: 1), top: 46)
    text("Double-click OpenNotch to install it.", size: 14, weight: .regular,
         color: NSColor(white: 0.35, alpha: 1), top: 80)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [.compressionFactor: 1.0])!
}

try! render(scale: 1).write(to: root.appendingPathComponent("Resources/dmg-background.png"))
try! render(scale: 2).write(to: root.appendingPathComponent("Resources/dmg-background@2x.png"))
print("✓ Resources/dmg-background.png (+ @2x)")
