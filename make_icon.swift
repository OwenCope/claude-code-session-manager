import AppKit
import CoreGraphics

func drawIcon(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    defer { img.unlockFocus() }
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpaceCreateDeviceRGB()

    // Squircle background
    let inset = size * 0.04
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Warm Claude-inspired gradient (peach → coral → plum)
    let bgColors = [
        CGColor(srgbRed: 0.99, green: 0.74, blue: 0.49, alpha: 1.0),
        CGColor(srgbRed: 0.93, green: 0.45, blue: 0.40, alpha: 1.0),
        CGColor(srgbRed: 0.55, green: 0.32, blue: 0.62, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: space, colors: bgColors, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(bgGrad,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])

    // Soft top highlight
    ctx.setBlendMode(.softLight)
    let hi = CGGradient(colorsSpace: space,
                        colors: [CGColor(gray: 1, alpha: 0.7), CGColor(gray: 1, alpha: 0)] as CFArray,
                        locations: [0, 1])!
    ctx.drawRadialGradient(hi,
                           startCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.95),
                           startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.maxY * 0.95),
                           endRadius: rect.width * 0.7,
                           options: [])
    ctx.setBlendMode(.normal)
    ctx.restoreGState()

    // Inner stroke for crispness
    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.08))
    ctx.setLineWidth(size * 0.005)
    ctx.strokePath()
    ctx.restoreGState()

    // ===== Glyph: terminal-prompt style chat caret =====
    // A rounded chat bubble silhouette with a ">_" inside, evoking
    // "Claude Code session". Centered, scales with size.
    ctx.saveGState()

    let bubbleW = rect.width * 0.62
    let bubbleH = rect.height * 0.50
    let bubbleX = rect.midX - bubbleW / 2
    let bubbleY = rect.midY - bubbleH / 2 + rect.height * 0.04
    let bubbleR = bubbleW * 0.22
    let bubble = CGMutablePath()
    bubble.addRoundedRect(in: CGRect(x: bubbleX, y: bubbleY, width: bubbleW, height: bubbleH),
                          cornerWidth: bubbleR, cornerHeight: bubbleR)
    // Tail
    let tailX = bubbleX + bubbleW * 0.20
    let tailTop = bubbleY + bubbleH * 0.18
    bubble.move(to: CGPoint(x: tailX, y: bubbleY + bubbleH * 0.05))
    bubble.addLine(to: CGPoint(x: tailX - bubbleW * 0.16, y: bubbleY - bubbleH * 0.22))
    bubble.addLine(to: CGPoint(x: tailX + bubbleW * 0.10, y: tailTop))
    bubble.closeSubpath()

    // Bubble shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012),
                  blur: size * 0.04,
                  color: CGColor(gray: 0, alpha: 0.18))
    ctx.addPath(bubble)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // Glyph inside bubble: ">_"
    let glyphColor = CGColor(srgbRed: 0.32, green: 0.20, blue: 0.45, alpha: 1.0)
    let lineW = size * 0.04
    let pad = bubbleW * 0.18
    let cx = bubbleX + pad
    let cy = bubbleY + bubbleH / 2 + size * 0.02

    // Caret ">"
    let caret = CGMutablePath()
    let caretSize = bubbleH * 0.30
    caret.move(to: CGPoint(x: cx, y: cy + caretSize))
    caret.addLine(to: CGPoint(x: cx + caretSize, y: cy))
    caret.addLine(to: CGPoint(x: cx, y: cy - caretSize))
    ctx.addPath(caret)
    ctx.setLineWidth(lineW)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(glyphColor)
    ctx.strokePath()

    // Underscore "_"
    let underX = cx + caretSize * 1.6
    let underY = cy - caretSize
    ctx.move(to: CGPoint(x: underX, y: underY))
    ctx.addLine(to: CGPoint(x: underX + bubbleW * 0.30, y: underY))
    ctx.setLineWidth(lineW)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(glyphColor)
    ctx.strokePath()

    ctx.restoreGState()

    // Sparkle (top-right) — decorative
    ctx.saveGState()
    let sx = rect.maxX - rect.width * 0.18
    let sy = rect.maxY - rect.height * 0.18
    let sr = rect.width * 0.045
    let sparkle = CGMutablePath()
    sparkle.move(to: CGPoint(x: sx, y: sy + sr * 1.8))
    sparkle.addQuadCurve(to: CGPoint(x: sx + sr * 1.8, y: sy),
                         control: CGPoint(x: sx + sr * 0.4, y: sy + sr * 0.4))
    sparkle.addQuadCurve(to: CGPoint(x: sx, y: sy - sr * 1.8),
                         control: CGPoint(x: sx + sr * 0.4, y: sy - sr * 0.4))
    sparkle.addQuadCurve(to: CGPoint(x: sx - sr * 1.8, y: sy),
                         control: CGPoint(x: sx - sr * 0.4, y: sy - sr * 0.4))
    sparkle.addQuadCurve(to: CGPoint(x: sx, y: sy + sr * 1.8),
                         control: CGPoint(x: sx - sr * 0.4, y: sy + sr * 0.4))
    ctx.addPath(sparkle)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.fillPath()
    ctx.restoreGState()

    return img
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
               from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let entries: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for entry in entries {
    let img = drawIcon(size: CGFloat(entry.px))
    savePNG(img, to: outDir.appendingPathComponent(entry.name), pixelSize: entry.px)
    print("wrote \(entry.name)")
}
