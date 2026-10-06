// Renders the reaper app icon: the menu bar's two slanted eye slits, light
// ink on a warm near-black (Muxy's dark palette). Same macOS icon grid as
// Muxy's make-icon.swift.
// Usage: swift Scripts/make-icon.swift <iconset-dir>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let paper = 0x1C1A17
let ink = 0xD8D1C3

func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func render(px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // macOS icon grid: 824/1024 body, Apple's corner radius, ground shadow.
    let body = CGRect(x: s * 100 / 1024, y: s * 100 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: s * 185 / 1024, cornerHeight: s * 185 / 1024, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: rgb(0x000000, 0.25))
    ctx.addPath(bodyPath)
    ctx.setFillColor(rgb(paper))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.addPath(bodyPath)
    ctx.setLineWidth(max(1, s * 0.003))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
    ctx.strokePath()

    // The slits, same proportions as Icon.swift (24×18 pt canvas), scaled to
    // span 64% of the body's width and centered.
    let w: CGFloat = 9.6, h: CGFloat = 8.6, gap: CGFloat = 2.0
    let span = 2 * w + gap
    let u = body.width * 0.64 / span
    let cx = body.midX
    // Shape runs from cy - 0.5h to cy + 0.6h; center that on the body.
    let cy = body.midY - 0.05 * h * u
    let path = CGMutablePath()
    for side: CGFloat in [-1, 1] {
        let inner = cx + side * gap / 2 * u
        path.move(to: CGPoint(x: inner + side * w * u, y: cy + h * 0.6 * u))
        path.addLine(to: CGPoint(x: inner, y: cy))
        path.addLine(to: CGPoint(x: inner, y: cy - h * 0.5 * u))
        path.addLine(to: CGPoint(x: inner + side * w * 0.8 * u, y: cy - h * 0.1 * u))
        path.closeSubpath()
    }
    ctx.addPath(path)
    ctx.setFillColor(rgb(ink))
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    try! render(px: px).write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
