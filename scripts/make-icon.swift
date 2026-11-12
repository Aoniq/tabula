// Renders the Tabula app icon (minimal graphite tile + line-drawn table mark)
// into an .iconset and converts it with iconutil.
//   swift scripts/make-icon.swift Resources/AppIcon.icns [variant] [preview.png]
import AppKit

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "Resources/AppIcon.icns"
let variant = args.count > 2 ? args[2] : "b"
let preview = args.count > 3 ? args[3] : nil

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let cg = ctx.cgContext
    let s = size / 1024

    // Tile (macOS grid: 824pt body, 100pt margin)
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let tile = NSBezierPath(roundedRect: body, xRadius: 186 * s, yRadius: 186 * s)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8 * s), blur: 20 * s, color: NSColor.black.withAlphaComponent(0.30).cgColor)
    color(0x15171C).setFill()
    tile.fill()
    cg.restoreGState()
    cg.saveGState()
    tile.addClip()
    NSGradient(colors: [color(0x2A2E37), color(0x14161B)])!.draw(in: body, angle: -90)
    // hairline inner highlight
    color(0xFFFFFF, 0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2 * s, dy: 2 * s), xRadius: 184 * s, yRadius: 184 * s)
    rim.lineWidth = 3 * s
    rim.stroke()
    cg.restoreGState()

    // Mark: rounded table outline, header rule, one column rule
    let line = max(1, 34 * s)
    let mark = NSRect(x: 262 * s, y: 292 * s, width: 500 * s, height: 440 * s)
    let radius = 64 * s
    let headerY = mark.maxY - 128 * s
    let colX = mark.minX + 178 * s
    let ink = color(0xF2F3F5)
    let accent = color(0x5B8CFF)

    if variant == "b" {
        // filled accent header
        cg.saveGState()
        NSBezierPath(roundedRect: mark, xRadius: radius, yRadius: radius).addClip()
        accent.setFill()
        NSRect(x: mark.minX, y: headerY, width: mark.width, height: mark.maxY - headerY).fill()
        cg.restoreGState()
    }
    ink.setStroke()
    let outline = NSBezierPath(roundedRect: mark.insetBy(dx: line / 2, dy: line / 2), xRadius: radius - line / 2, yRadius: radius - line / 2)
    outline.lineWidth = line
    outline.stroke()

    let header = NSBezierPath()
    header.move(to: NSPoint(x: mark.minX + line / 2, y: headerY))
    header.line(to: NSPoint(x: mark.maxX - line / 2, y: headerY))
    header.lineWidth = line
    (variant == "a" ? accent : ink).setStroke()
    header.stroke()

    let col = NSBezierPath()
    col.move(to: NSPoint(x: colX, y: mark.minY + line / 2))
    col.line(to: NSPoint(x: colX, y: headerY))
    col.lineWidth = line
    (variant == "b" ? ink : ink.withAlphaComponent(0.55)).setStroke()
    col.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

if let preview {
    try! render(1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: preview))
}

let iconset = NSTemporaryDirectory() + "Tabula.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]
try! p.run(); p.waitUntilExit()
print("wrote \(out)")
