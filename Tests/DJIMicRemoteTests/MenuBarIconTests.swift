import XCTest
import AppKit
import QuartzCore
@testable import DJIMicRemote

final class MenuBarIconTests: XCTestCase {
    @MainActor func testAllStatesKeepTheSameTemplateSlotAndBadgeAnchor() throws {
        _ = NSApplication.shared
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 36, height: 24))
        let badge = MenuBarBadge(frame: .zero)
        button.addSubview(badge)
        var intrinsicSize: NSSize?
        // Include transitions back to ready; transient states must not leave a
        // faded image or a different-sized button behind.
        for state in MenuBarBadge.State.allCases + [.ready, .working, .recording, .ready] {
            MenuBarIcon.apply(to: button, badge: badge, state: state)
            XCTAssertEqual(button.frame.width, 36)
            XCTAssertEqual(badge.frame, MenuBarIcon.badgeFrame(in: button))
            XCTAssertEqual(badge.frame.maxY, button.bounds.maxY - 1)
            XCTAssertTrue(button.image === MenuBarIcon.image)
            XCTAssertTrue(try XCTUnwrap(button.image).isTemplate)
            XCTAssertTrue(button.title.isEmpty)
            XCTAssertEqual(button.alphaValue, state == .paused ? 0.42 : 1)
            if let intrinsicSize { XCTAssertEqual(button.intrinsicContentSize, intrinsicSize) }
            else { intrinsicSize = button.intrinsicContentSize }
        }
        XCTAssertNil(badge.hitTest(NSPoint(x: 4, y: 4)))
    }

    @MainActor func testProcessingRotatesOnlyCenteredBadgeAndStopsForReducedMotionOrDetach() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 36, height: 24),
                              styleMask: .borderless, backing: .buffered, defer: false)
        // Offscreen only: no app activation, receiver mapping, or key events.
        let button = NSButton(frame: window.contentView!.bounds)
        window.contentView!.addSubview(button)
        let badge = MenuBarBadge(frame: .zero)
        var reduced = false
        badge.reduceMotion = { reduced }
        button.addSubview(badge)
        MenuBarIcon.apply(to: button, badge: badge, state: .working)
        let layer = badge.indicator
        let spin = try XCTUnwrap(layer.animation(forKey: "processing") as? CABasicAnimation)
        XCTAssertEqual(spin.keyPath, "transform.rotation.z")
        XCTAssertEqual(layer.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(layer.position, CGPoint(x: badge.bounds.midX, y: badge.bounds.midY))
        XCTAssertEqual(layer.bounds.size, NSSize(width: 8, height: 8))
        XCTAssertTrue(button.layer?.animationKeys()?.isEmpty ?? true)
        reduced = true; badge.refreshAnimation()
        XCTAssertNil(layer.animation(forKey: "processing"))
        XCTAssertEqual(badge.state, .working)
        reduced = false; badge.refreshAnimation()
        XCTAssertNotNil(layer.animation(forKey: "processing"))
        badge.state = .recording
        XCTAssertNil(layer.animation(forKey: "processing"))
        badge.state = .working
        badge.removeFromSuperview()
        XCTAssertNil(layer.animation(forKey: "processing"))
    }
}
