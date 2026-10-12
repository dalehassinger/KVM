// Renders the KVM Dashboard app icon (keyboard + mouse) to a 1024×1024 PNG.
// Usage: swiftc tools/make-icon.swift -o build/make-icon && build/make-icon build/icon_1024.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: a)
}

func symbol(_ name: String, pointSize: CGFloat, colors: [NSColor]) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: colors))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { fatalError("missing symbol \(name)") }
    return image
}

/// Draws an image scaled to fit `width`, with its bottom-left at `origin`.
func draw(_ image: NSImage, width: CGFloat, at origin: CGPoint) -> CGRect {
    let h = width * image.size.height / image.size.width
    let rect = CGRect(x: origin.x, y: origin.y, width: width, height: h)
    image.draw(in: rect)
    return rect
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: 824pt tile inset 100pt, continuous-corner radius ≈ 185pt.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

// Drop shadow under the tile.
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
hex(0x17242b).setFill()
tilePath.fill()
NSGraphicsContext.restoreGraphicsState()

// Clarity dark gradient background with a thin highlight border.
NSGradient(starting: hex(0x2a4250), ending: hex(0x0f171c))!.draw(in: tilePath, angle: -90)
hex(0x49afd9, 0.35).setStroke()
tilePath.lineWidth = 6
tilePath.stroke()

// Soft glow behind the devices.
NSGraphicsContext.saveGraphicsState()
tilePath.addClip()
NSGradient(starting: hex(0x49afd9, 0.28), ending: hex(0x49afd9, 0))!
    .draw(fromCenter: CGPoint(x: 512, y: 470), radius: 0, toCenter: CGPoint(x: 512, y: 470), radius: 420, options: [])
NSGraphicsContext.restoreGraphicsState()

let blue = hex(0x49afd9)
let light = hex(0xe9ecef)

// Keyboard (left/centre) and mouse (right), sitting on a common baseline.
let keyboard = symbol("keyboard", pointSize: 400, colors: [blue])
let mouse = symbol("computermouse", pointSize: 400, colors: [light])
let kbRect = draw(keyboard, width: 520, at: CGPoint(x: 153, y: 420))
_ = draw(mouse, width: 175, at: CGPoint(x: kbRect.maxX + 22, y: kbRect.minY - 6))

// "KVM" wordmark under the devices.
let font = NSFont.systemFont(ofSize: 132, weight: .heavy)
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: light, .kern: 10]
let text = NSAttributedString(string: "KVM", attributes: attrs)
let ts = text.size()
text.draw(at: CGPoint(x: (size - ts.width) / 2, y: 235))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
