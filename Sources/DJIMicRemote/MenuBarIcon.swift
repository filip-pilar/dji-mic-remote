import AppKit

enum MenuBarIcon {
    static let ready = make(ready: true)
    static let inactive = make(ready: false)

    private static func make(ready: Bool) -> NSImage {
        // A vector template lets AppKit handle scale, appearance, and selection.
        let image = NSImage(size: NSSize(width: 26, height: 20), flipped: true) { _ in
            NSColor.black.set()

            let capsule = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 2, width: 6, height: 10),
                                       xRadius: 3, yRadius: 3)
            capsule.lineWidth = 1.6
            if ready { capsule.fill() }
            capsule.stroke()

            let outline = NSBezierPath()
            outline.lineWidth = 1.6
            outline.lineCapStyle = .round
            outline.lineJoinStyle = .round
            outline.move(to: NSPoint(x: 3, y: 9))
            outline.line(to: NSPoint(x: 3, y: 10.5))
            outline.curve(to: NSPoint(x: 8.5, y: 16),
                          controlPoint1: NSPoint(x: 3, y: 13.5),
                          controlPoint2: NSPoint(x: 5.5, y: 16))
            outline.curve(to: NSPoint(x: 14, y: 10.5),
                          controlPoint1: NSPoint(x: 11.5, y: 16),
                          controlPoint2: NSPoint(x: 14, y: 13.5))
            outline.line(to: NSPoint(x: 14, y: 9))
            outline.move(to: NSPoint(x: 8.5, y: 16))
            outline.line(to: NSPoint(x: 8.5, y: 18.5))

            // Two separated arcs keep the signal legible at menu bar size.
            outline.move(to: NSPoint(x: 17, y: 4))
            outline.curve(to: NSPoint(x: 17, y: 11),
                          controlPoint1: NSPoint(x: 20, y: 5.8),
                          controlPoint2: NSPoint(x: 20, y: 9.2))
            outline.move(to: NSPoint(x: 20, y: 1.5))
            outline.curve(to: NSPoint(x: 20, y: 13.5),
                          controlPoint1: NSPoint(x: 25, y: 4.6),
                          controlPoint2: NSPoint(x: 25, y: 10.4))
            outline.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
