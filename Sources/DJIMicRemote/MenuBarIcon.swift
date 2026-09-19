import AppKit
import QuartzCore

enum MenuBarIcon {
    static let itemWidth: CGFloat = 36
    static func badgeFrame(in button: NSButton) -> NSRect {
        NSRect(x: button.bounds.maxX - 9, y: button.isFlipped ? button.bounds.maxY - 9 : 1, width: 8, height: 8)
    }
    static let image = make()
    static func apply(to button: NSButton, badge: MenuBarBadge, state: MenuBarBadge.State) {
        button.image = image
        button.title = ""; button.imagePosition = .imageOnly
        button.contentTintColor = nil
        button.alphaValue = state == .paused ? 0.42 : 1
        badge.frame = badgeFrame(in: button)
        badge.state = state
    }

    private static func make() -> NSImage {
        // A vector template lets AppKit handle scale, appearance, and selection.
        let image = NSImage(size: NSSize(width: 26, height: 20), flipped: true) { _ in
            NSColor.black.set()

            let capsule = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 2, width: 6, height: 10),
                                       xRadius: 3, yRadius: 3)
            capsule.lineWidth = 1.6
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

/// A separate badge preserves native template contrast without tinting/filling
/// the microphone or resizing the menu-bar item. It never intercepts clicks.
final class MenuBarBadge: NSView {
    enum State: CaseIterable { case ready, recording, working, saved, paused, attention }
    let indicator = CAShapeLayer()
    var state: State = .paused {
        didSet {
            guard oldValue != state else { return }
            updateIndicator()
            refreshAnimation()
        }
    }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(indicator)
        updateIndicator()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(refreshAnimation),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() { super.layout(); updateIndicator() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); updateIndicator(); refreshAnimation()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateIndicator() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateIndicator() }

    @objc func refreshAnimation() {
        // AppKit owns the backing layer's geometry (its anchor can be zero).
        // Animate our own centered sublayer, never the view or the mic template.
        // Repeated status refreshes do not restart the animation.
        guard state == .working, window != nil, !reduceMotion() else {
            indicator.removeAnimation(forKey: "processing")
            return
        }
        guard indicator.animation(forKey: "processing") == nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0; spin.toValue = -2 * Double.pi
        spin.duration = 1.5; spin.repeatCount = .infinity
        spin.timingFunction = CAMediaTimingFunction(name: .linear)
        indicator.add(spin, forKey: "processing")
    }
    private func updateIndicator() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        indicator.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
        indicator.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        indicator.position = CGPoint(x: bounds.midX, y: bounds.midY)
        indicator.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        indicator.lineCap = .round; indicator.lineJoin = .round
        indicator.fillColor = nil; indicator.strokeColor = nil
        // Resolve dynamic colors in this view's appearance, including when the
        // menu bar changes between light and dark independently of the app.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let path = CGMutablePath()
            switch state {
            case .ready, .paused: break
            case .recording:
                indicator.fillColor = NSColor.systemRed.cgColor
                path.addEllipse(in: CGRect(x: 1.5, y: 1.5, width: 5, height: 5))
            case .working:
                indicator.strokeColor = NSColor.labelColor.cgColor; indicator.lineWidth = 1.3
                path.addArc(center: CGPoint(x: 4, y: 4), radius: 2.6,
                            startAngle: .pi * 40 / 180, endAngle: .pi * 320 / 180, clockwise: false)
            case .saved:
                indicator.strokeColor = NSColor.systemGreen.cgColor; indicator.lineWidth = 1.6
                path.move(to: CGPoint(x: 1, y: 4)); path.addLine(to: CGPoint(x: 3, y: 2))
                path.addLine(to: CGPoint(x: 7, y: 6))
            case .attention:
                indicator.strokeColor = NSColor.systemOrange.cgColor; indicator.lineWidth = 1.1
                path.move(to: CGPoint(x: 4, y: 7)); path.addLine(to: CGPoint(x: 0.7, y: 1))
                path.addLine(to: CGPoint(x: 7.3, y: 1)); path.closeSubpath()
                path.move(to: CGPoint(x: 4, y: 4.9)); path.addLine(to: CGPoint(x: 4, y: 3.7))
                path.move(to: CGPoint(x: 4, y: 2.4)); path.addLine(to: CGPoint(x: 4, y: 2.3))
            }
            indicator.path = path
        }
    }
}
