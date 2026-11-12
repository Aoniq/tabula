// Renders the Tabula app icon into an .iconset and converts it with iconutil.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = NSTemporaryDirectory() + "Tabula.iconset"
try? FileManager.default.removeItem(atPath: iconset)
try! FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    // macOS squircle-ish body with margin
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.cgContext.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSGradient(colors: [NSColor(red: 0.16, green: 0.36, blue: 0.92, alpha: 1), NSColor(red: 0.42, green: 0.22, blue: 0.86, alpha: 1)])!.draw(in: path, angle: -60)
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    // grid "sheet"
    let sheet = NSRect(x: 230 * s, y: 250 * s, width: 564 * s, height: 470 * s)
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: sheet, xRadius: 48 * s, yRadius: 48 * s).fill()
    // header band
    let header = NSBezierPath(roundedRect: NSRect(x: sheet.minX, y: sheet.maxY - 120 * s, width: sheet.width, height: 120 * s), xRadius: 48 * s, yRadius: 48 * s)
    header.append(NSBezierPath(rect: NSRect(x: sheet.minX, y: sheet.maxY - 120 * s, width: sheet.width, height: 60 * s)))
    NSColor(red: 0.24, green: 0.80, blue: 0.62, alpha: 1).setFill()
    header.fill()
    // grid lines
    NSColor(red: 0.16, green: 0.36, blue: 0.92, alpha: 0.30).setFill()
    for i in 1...2 {
        NSRect(x: sheet.minX + CGFloat(i) * sheet.width / 3 - 5 * s, y: sheet.minY + 30 * s, width: 10 * s, height: sheet.height - 150 * s).fill()
    }
    for j in 1...2 {
        NSRect(x: sheet.minX + 30 * s, y: sheet.minY + CGFloat(j) * (sheet.height - 120 * s) / 3 - 4 * s, width: sheet.width - 60 * s, height: 8 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    let data = render(CGFloat(px)).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", out]
try! p.run(); p.waitUntilExit()
print("wrote \(out)")
