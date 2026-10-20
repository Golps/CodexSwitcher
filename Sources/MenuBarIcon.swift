import AppKit

/// The menu-bar glyph: two swap arrows around a terminal prompt, drawn as a
/// template image so macOS tints it for light and dark menu bars.
/// Same shape as assets/menubar-icon.svg (a 24-unit grid, y pointing down).
enum MenuBarIcon {
    static let image: NSImage = {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let path = NSBezierPath()
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            let center = NSPoint(x: 12, y: 12), radius: CGFloat = 8.2
            func point(_ degrees: CGFloat) -> NSPoint {
                let t = degrees * .pi / 180
                return NSPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
            }
            func arrow(from start: CGFloat, to end: CGFloat) {
                path.move(to: point(start))
                path.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
                // Arrowhead at the end, pointing along the direction of travel.
                let t = end * .pi / 180
                let tip = point(end)
                let back = atan2(-cos(t), sin(t))
                for side: CGFloat in [1, -1] {
                    let a = back + side * 42 * .pi / 180
                    path.move(to: tip)
                    path.line(to: NSPoint(x: tip.x + 3 * cos(a), y: tip.y + 3 * sin(a)))
                }
            }
            arrow(from: 205, to: 335)
            arrow(from: 25, to: 155)

            // ">_" prompt in the middle.
            path.move(to: NSPoint(x: 8.6, y: 9.4))
            path.line(to: NSPoint(x: 11.2, y: 12))
            path.line(to: NSPoint(x: 8.6, y: 14.6))
            path.move(to: NSPoint(x: 12.6, y: 14.6))
            path.line(to: NSPoint(x: 15.6, y: 14.6))

            path.transform(using: AffineTransform(scale: size / 24))
            path.lineWidth = 2 * size / 24
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
