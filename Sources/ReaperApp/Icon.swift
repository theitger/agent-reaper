import AppKit

/// The menu bar glyph: two slanted eye slits, angled down toward the nose.
/// 24 pt wide so the eyes stand as tall as the Wi-Fi glyph next to them;
/// cy puts the shape (cy - 0.5h ... cy + 0.6h) at the canvas center.
/// Template image, so macOS tints it like every other menu bar icon.
enum Icon {
    static let slits: NSImage = {
        let image = NSImage(size: NSSize(width: 24, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let (cx, cy, w, h, gap): (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat) = (12, 8.55, 9.6, 8.6, 2.0)
            let p = NSBezierPath()
            for side: CGFloat in [-1, 1] {
                let inner = cx + side * gap / 2
                p.move(to: NSPoint(x: inner + side * w, y: cy + h * 0.6))
                p.line(to: NSPoint(x: inner, y: cy))
                p.line(to: NSPoint(x: inner, y: cy - h * 0.5))
                p.line(to: NSPoint(x: inner + side * w * 0.8, y: cy - h * 0.1))
                p.close()
            }
            p.fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
