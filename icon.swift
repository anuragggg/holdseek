// Renders AppIcon.icns, extension/icon.png, and assets/icon.png (README). Run from the repo root: swift icon.swift
import AppKit

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func shadow(y: CGFloat = 0, blur: CGFloat, _ color: NSColor, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowOffset = NSSize(width: 0, height: y); s.shadowBlurRadius = blur; s.shadowColor = color; s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// Rounded rect with continuous ("squircle") corners and straight sides, like Apple's icon shape.
// Each corner is one cubic curve that eases in over `extent` points along both edges.
func smoothRect(_ r: NSRect, extent d: CGFloat) -> NSBezierPath {
    let k: CGFloat = 0.2  // control points this fraction of `extent` from the corner; lower is squarer
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX + d, y: r.maxY))
    p.line(to: NSPoint(x: r.maxX - d, y: r.maxY))
    p.curve(to: NSPoint(x: r.maxX, y: r.maxY - d), controlPoint1: NSPoint(x: r.maxX - d * k, y: r.maxY), controlPoint2: NSPoint(x: r.maxX, y: r.maxY - d * k))
    p.line(to: NSPoint(x: r.maxX, y: r.minY + d))
    p.curve(to: NSPoint(x: r.maxX - d, y: r.minY), controlPoint1: NSPoint(x: r.maxX, y: r.minY + d * k), controlPoint2: NSPoint(x: r.maxX - d * k, y: r.minY))
    p.line(to: NSPoint(x: r.minX + d, y: r.minY))
    p.curve(to: NSPoint(x: r.minX, y: r.minY + d), controlPoint1: NSPoint(x: r.minX + d * k, y: r.minY), controlPoint2: NSPoint(x: r.minX, y: r.minY + d * k))
    p.line(to: NSPoint(x: r.minX, y: r.maxY - d))
    p.curve(to: NSPoint(x: r.minX + d, y: r.maxY), controlPoint1: NSPoint(x: r.minX, y: r.maxY - d * k), controlPoint2: NSPoint(x: r.minX + d * k, y: r.maxY))
    p.close()
    return p
}

// A thin crescent of light along the top or bottom inside edge of a shape, fading out toward the sides.
func edge(_ shape: NSBezierPath, _ thickness: CGFloat, top: Bool, _ color: NSColor) {
    let shifted = shape.copy() as! NSBezierPath
    shifted.transform(using: AffineTransform(translationByX: 0, byY: top ? -thickness : thickness))
    let crescent = shape.copy() as! NSBezierPath
    crescent.append(shifted); crescent.windingRule = .evenOdd
    NSGraphicsContext.saveGraphicsState()
    shape.addClip(); crescent.addClip()
    NSGradient(colors: [color.withAlphaComponent(0), color, color.withAlphaComponent(0)])!.draw(in: shape.bounds, angle: 0)
    NSGraphicsContext.restoreGraphicsState()
}

let amber = hex(0xFF9F0A)

let image = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
    // Tile: graphite lit from above, on Apple's macOS icon grid (824pt body in a 1024 canvas).
    let tile = smoothRect(NSRect(x: 100, y: 100, width: 824, height: 824), extent: 262)
    shadow(y: -10, blur: 22, hex(0, 0.35)) { hex(0).setFill(); tile.fill() }
    NSGradient(starting: hex(0x34343A), ending: hex(0x0C0C0E))!.draw(in: tile, angle: -90)

    // Warm backlight spilling out from under the key onto the tile.
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    let spill = NSAffineTransform(); spill.translateX(by: 512, yBy: 268); spill.scaleX(by: 1, yBy: 0.42); spill.concat()
    NSGradient(colors: [amber.withAlphaComponent(0.62), amber.withAlphaComponent(0.16), amber.withAlphaComponent(0)],
               atLocations: [0, 0.45, 1], colorSpace: .sRGB)!
        .draw(fromCenter: .zero, radius: 0, toCenter: .zero, radius: 430, options: [])
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState(); tile.addClip(); hex(0xFFFFFF, 0.09).setStroke(); tile.lineWidth = 4; tile.stroke()  // rim, so it holds up on a dark Dock
    NSGraphicsContext.restoreGraphicsState()
    edge(tile, 3, top: true, hex(0xFFFFFF, 0.26))

    // Keycap: matte black, the face set in from the sides and lifted off the bottom to suggest height.
    let base = smoothRect(NSRect(x: 252, y: 276, width: 520, height: 500), extent: 180)
    shadow(blur: 60, amber.withAlphaComponent(0.24)) { hex(0x050506).setFill(); base.fill() }  // light leaking around it
    NSGradient(starting: hex(0x1B1B1E), ending: hex(0x060607))!.draw(in: base, angle: -90)
    edge(base, 4, top: false, amber.withAlphaComponent(0.55))  // backlight catching the bottom lip

    let face = smoothRect(NSRect(x: 270, y: 324, width: 484, height: 436), extent: 160)
    NSGradient(starting: hex(0x38383E), ending: hex(0x1C1C1F))!.draw(in: face, angle: -90)
    NSGradient(colors: [hex(0, 0.22), hex(0, 0)])!.draw(in: face, relativeCenterPosition: NSPoint(x: 0, y: -0.15))  // shallow dish
    edge(face, 3, top: true, hex(0xFFFFFF, 0.4))

    // Legend: the fast-forward glyph from Mac F9 keys, backlit in amber with a hot core.
    let config = NSImage.SymbolConfiguration(pointSize: 190, weight: .semibold).applying(.init(paletteColors: [.white]))
    let glyph = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let lit = NSImage(size: glyph.size, flipped: false) { r in
        glyph.draw(in: r)
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSGradient(starting: hex(0xFFEBC9), ending: hex(0xFFA21A))!.draw(in: r, angle: -90)
        return true
    }
    let legend = NSRect(x: 508 - glyph.size.width / 2, y: 544 - glyph.size.height / 2, width: glyph.size.width, height: glyph.size.height)
    shadow(blur: 70, amber.withAlphaComponent(0.65)) { lit.draw(in: legend) }
    shadow(blur: 16, amber.withAlphaComponent(0.9)) { lit.draw(in: legend) }
    return true
}

func png(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try! png(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let iconutil = try! Process.run(URL(fileURLWithPath: "/usr/bin/iconutil"), arguments: ["-c", "icns", iconset.path, "-o", "AppIcon.icns"])
iconutil.waitUntilExit()
try! png(128).write(to: URL(fileURLWithPath: "extension/icon.png"))
try? FileManager.default.createDirectory(atPath: "assets", withIntermediateDirectories: true)
try! png(512).write(to: URL(fileURLWithPath: "assets/icon.png"))
print("wrote AppIcon.icns, extension/icon.png, and assets/icon.png")
