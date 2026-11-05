// Draws the app icon. Usage: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <AppIcon.iconset>
import AppKit

func draw(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let inset = s * 0.1
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(red: 0.42, green: 0.25, blue: 0.95, alpha: 1),
               ending: NSColor(red: 0.08, green: 0.62, blue: 0.86, alpha: 1))!.draw(in: shape, angle: -70)

    // Three faders at different levels: one volume per app.
    for (index, level) in [0.72, 0.34, 0.56].enumerated() {
        let x = s * (0.3 + 0.2 * CGFloat(index))
        let bottom = s * 0.24, height = s * 0.52, width = s * 0.035
        NSColor.white.withAlphaComponent(0.3).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - width / 2, y: bottom, width: width, height: height),
                     xRadius: width / 2, yRadius: width / 2).fill()
        let filled = height * CGFloat(level)
        NSColor.white.withAlphaComponent(0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - width / 2, y: bottom, width: width, height: filled),
                     xRadius: width / 2, yRadius: width / 2).fill()
        let knob = s * 0.11
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - knob / 2, y: bottom + filled - knob / 2, width: knob, height: knob)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let folder = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        let data = draw(size: base * scale).representation(using: .png, properties: [:])!
        try data.write(to: URL(fileURLWithPath: "\(folder)/icon_\(base)x\(base)\(suffix).png"))
    }
}
