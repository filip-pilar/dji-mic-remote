import CoreGraphics
import XCTest
@testable import DJIMicRemote

final class ShortcutEmitterTests: XCTestCase {
    func testModifierOnlySequencePreservesHeldModifiersAndReleasesOnce() {
        var events: [CGEvent] = []
        let emitter = ShortcutEmitter(post: { events.append($0) })
        XCTAssertEqual(emitter.send(.defaultShortcut, heldFlags: [.maskControl, .maskShift]), .sent)
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [58, 55])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .flagsChanged])
        emitter.release()
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) }, [58, 55, 55, 58])
        XCTAssertEqual(events.last?.flags, [.maskControl, .maskShift])
        emitter.release()
        XCTAssertEqual(events.count, 4)
    }

    func testRegularKeyReleasesBeforeInjectedModifiers() {
        var events: [CGEvent] = []
        let emitter = ShortcutEmitter(post: { events.append($0) })
        let shortcut = Shortcut(key: 36, flags: CGEventFlags.maskCommand.rawValue, label: "Command–Return")
        XCTAssertEqual(emitter.send(shortcut, heldFlags: .maskAlternate), .sent)
        emitter.release()
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged])
        XCTAssertEqual(events[1].flags, [.maskCommand, .maskAlternate])
        XCTAssertEqual(events.last?.flags, .maskAlternate)
    }

    func testFullyHeldModifierShortcutPostsNothing() {
        var count = 0
        let emitter = ShortcutEmitter(post: { _ in count += 1 })
        XCTAssertEqual(emitter.send(.defaultShortcut, heldFlags: [.maskControl, .maskAlternate, .maskCommand]), .alreadyHeld)
        emitter.release()
        XCTAssertEqual(count, 0)
    }

    func testAllocationFailureAtAnyStepPostsNoPartialChord() {
        let shortcut = Shortcut(key: 36, flags: Shortcut.defaultShortcut.flags, label: "test")
        // Three modifier pairs plus the regular key pair, including every release.
        for failedIndex in 0..<8 {
            var index = 0, posted = 0
            let emitter = ShortcutEmitter(makeEvent: { key, down in
                defer { index += 1 }
                return index == failedIndex ? nil : CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)
            }, post: { _ in posted += 1 })
            XCTAssertEqual(emitter.send(shortcut, heldFlags: []), .allocationFailed)
            emitter.release()
            XCTAssertEqual(posted, 0, "Failed allocation \(failedIndex) must not strand any keys")
        }
    }

    func testNewShortcutReleasesPreviousOneFirst() {
        var events: [CGEvent] = []
        let emitter = ShortcutEmitter(post: { events.append($0) })
        let shortcut = Shortcut(key: 36, flags: CGEventFlags.maskCommand.rawValue, label: "test")
        _ = emitter.send(shortcut, heldFlags: [])
        _ = emitter.send(shortcut, heldFlags: [])
        XCTAssertEqual(events.map(\.type), [.flagsChanged, .keyDown, .keyUp, .flagsChanged, .flagsChanged, .keyDown])
        emitter.release()
        XCTAssertEqual(events.count, 8)
    }

    func testHeldStateIsSampledAfterPreviousShortcutRelease() {
        var events: [CGEvent] = []
        let emitter = ShortcutEmitter(post: { events.append($0) })
        let shortcut = Shortcut(key: 36, flags: CGEventFlags.maskCommand.rawValue, label: "test")
        _ = emitter.send(shortcut, heldFlags: [])
        func readHeldFlags() -> CGEventFlags {
            XCTAssertEqual(events.count, 4, "Prior chord must be fully released before reading held keys")
            return []
        }
        _ = emitter.send(shortcut, heldFlags: readHeldFlags())
        emitter.release()
        XCTAssertEqual(events.count, 8)
    }

    func testDelayedReleaseAndCancellationDoNotReleaseNewerShortcut() {
        var events: [CGEvent] = [], scheduled: [DispatchWorkItem] = []
        let emitter = ShortcutEmitter(post: { events.append($0) }, scheduleRelease: { scheduled.append($0) })
        let shortcut = Shortcut(key: 36, flags: CGEventFlags.maskCommand.rawValue, label: "test")
        _ = emitter.send(shortcut, heldFlags: [])
        _ = emitter.send(shortcut, heldFlags: [])
        XCTAssertTrue(scheduled[0].isCancelled)
        scheduled[0].perform()
        XCTAssertEqual(events.count, 6)
        scheduled[1].perform()
        XCTAssertEqual(events.count, 8)
        emitter.release()
        XCTAssertEqual(events.count, 8)
    }

    func testSavedShortcutCompatibilityAndRoundTrip() throws {
        let legacy = Data(#"{"key":90,"flags":786432,"label":"legacy","directHIDUsage":30064771183}"#.utf8)
        XCTAssertNotNil(try JSONDecoder().decode(Shortcut.self, from: legacy).directHIDUsage)
        let old = Data(#"{"key":90,"flags":786432,"label":"legacy"}"#.utf8)
        let decoded = try JSONDecoder().decode(Shortcut.self, from: old)
        XCTAssertEqual(decoded.key, 90)
        XCTAssertNil(decoded.directHIDUsage)
        let current = try JSONDecoder().decode(Shortcut.self, from: JSONEncoder().encode(Shortcut.defaultShortcut))
        XCTAssertNil(current.key)
        XCTAssertEqual(current.flags, Shortcut.defaultShortcut.flags)
    }
}
