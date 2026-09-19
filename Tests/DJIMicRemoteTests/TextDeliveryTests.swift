import XCTest
import AppKit
import ApplicationServices
@testable import DJIMicRemote

final class TextDeliveryTests: XCTestCase {
    let editor = AXUIElementCreateApplication(123)
    var target: TextTarget { .init(pid: 123, name: "Fixture editor", element: editor, selection: nil) }

    func testWebEditorCanDeclareEditabilityWithoutSelectedTextRange() {
        let result = TextDelivery.resolve(editor, pid: 123, name: "Chat fixture", read: { _, key in
            switch key {
            case kAXRoleAttribute: return kAXGroupRole as CFString
            case "AXEditable": return kCFBooleanTrue
            default: return nil
            }
        }, owner: { _ in 123 })
        XCTAssertNotNil(result.target)
        XCTAssertNil(result.target?.selection)
    }
    func testOpaqueEditorUsesNormalPasteWithoutReadingItsContents() {
        let result = TextDelivery.resolve(editor, pid: 123, name: "Opaque editor", read: { _, key in
            key == kAXRoleAttribute ? kAXGroupRole as CFString : nil
        }, owner: { _ in 123 })
        XCTAssertTrue(result.target?.opaque == true)
        XCTAssertNil(result.target?.selection)
        XCTAssertNil(result.target.flatMap(AutoSend.snapshot))
        let window = AXUIElementCreateApplication(789)
        let otherWindow = AXUIElementCreateApplication(790)
        var before = target; before.window = window
        var after = before; after.window = otherWindow
        XCTAssertFalse(TextDelivery.matchesFocus(before, current: after))
        XCTAssertTrue(TextDelivery.matchesFocus(before, current: before))
    }
    func testFollowsOnlyExplicitFocusedElementInsideWrapper() {
        let wrapper = AXUIElementCreateApplication(456)
        let result = TextDelivery.resolve(wrapper, pid: 123, name: "Fixture", read: { element, key in
            if CFEqual(element, wrapper) {
                if key == kAXRoleAttribute { return kAXGroupRole as CFString }
                if key == kAXFocusedUIElementAttribute { return self.editor }
            } else if key == kAXRoleAttribute { return kAXTextAreaRole as CFString }
            return nil
        }, owner: { _ in 123 })
        XCTAssertTrue(result.target.map { CFEqual($0.element, editor) } ?? false)
    }
    func testForeignSystemFocusProxyFallsBackToAppFocusButSecureFieldDoesNot() {
        let proxy = AXUIElementCreateApplication(456)
        let result = TextDelivery.resolveFocused([proxy, editor], pid: 123, name: "Fixture", read: { _, key in
            key == kAXRoleAttribute ? kAXTextAreaRole as CFString : nil
        }, owner: { CFEqual($0, self.editor) ? 123 : 456 })
        XCTAssertNotNil(result.target)
        let secure = TextDelivery.resolveFocused([proxy, editor], pid: 123, name: "Fixture", read: { element, key in
            if CFEqual(element, proxy), key == kAXSubroleAttribute { return kAXSecureTextFieldSubrole as CFString }
            if key == kAXRoleAttribute { return kAXTextAreaRole as CFString }
            return nil
        }, owner: { _ in 123 })
        XCTAssertNil(secure.target); XCTAssertEqual(secure.failure, .secure)
    }
    func testReadOnlySelectionSecureAndForeignElementsAreRejected() {
        for (role, subrole, editable, expected) in [
            (kAXStaticTextRole, "", true, TextTargetCapture.Failure.notEditable),
            (kAXTextAreaRole, "", false, .notEditable),
            (kAXTextFieldRole, kAXSecureTextFieldSubrole, true, .secure)
        ] {
            let capture = TextDelivery.resolve(editor, pid: 123, name: "Fixture", read: { _, key in
                switch key {
                case kAXRoleAttribute: return role as CFString
                case kAXSubroleAttribute: return subrole as CFString
                case "AXEditable": return editable ? kCFBooleanTrue : kCFBooleanFalse
                case kAXSelectedTextRangeAttribute: return "selected read-only text" as CFString
                default: return nil
                }
            }, owner: { _ in 123 })
            XCTAssertNil(capture.target); XCTAssertEqual(capture.failure, expected)
        }
        let foreign = TextDelivery.resolve(editor, pid: 456, name: "Other", read: { _, _ in XCTFail("Must reject foreign process before reading"); return nil }, owner: { _ in 123 })
        XCTAssertNil(foreign.target)
    }
    @MainActor private func fixtureDelivery() -> (TextDelivery, NSPasteboard) {
        let board = NSPasteboard.withUniqueName()
        let delivery = TextDelivery()
        var time: TimeInterval = 0
        delivery.current = { .init(target: self.target) }; delivery.heldModifiers = { [] }
        delivery.read = { _ in nil }; delivery.pause = { time += Double($0) / 1_000_000_000 }
        delivery.now = { time }
        delivery.publish = { ClipboardPaste(text: $0, board: board, now: { time }) }
        delivery.postPaste = { XCTFail("Unexpected keyboard delivery"); return false }
        delivery.postReturn = { XCTFail("Unexpected Return"); return false }
        return (delivery, board)
    }
    @MainActor func testOpaqueEditorAutoSendsAfterConsumptionWithoutClaimingVerifiedInsertion() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        var pastes = 0; var returns = 0
        delivery.postPaste = { pastes += 1; XCTAssertEqual(board.string(forType: .string), "Fixture dictation"); return true }
        delivery.postReturn = {
            returns += 1
            XCTAssertEqual(board.string(forType: .string), "original clipboard")
            XCTAssertGreaterThanOrEqual(delivery.now(), 0.63)
            return true
        }
        let result = await delivery.insert("Fixture dictation", into: target, autoSend: true)
        XCTAssertEqual(pastes, 1); XCTAssertEqual(returns, 1); XCTAssertFalse(result.needsRecovery)
        XCTAssertTrue(result.message.contains("Paste and Return sent")); XCTAssertFalse(result.message.contains("inserted"))
        XCTAssertEqual(result.pasteState, .sent)
    }
    @MainActor func testNoConsumptionOrReceiptBeforePasteCannotAutoSend() async {
        for earlyRead in [false, true] {
            let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
            board.setString("original clipboard", forType: .string)
            if earlyRead {
                delivery.publish = { text in
                    let transaction = ClipboardPaste(text: text, board: board, now: delivery.now)
                    XCTAssertEqual(board.string(forType: .string), text)
                    return transaction
                }
            }
            delivery.postPaste = { true }
            let result = await delivery.insert("Hello", into: target, autoSend: true)
            XCTAssertEqual(result.pasteState, .autoSendSkipped); XCTAssertTrue(result.needsRecovery)
            XCTAssertEqual(board.string(forType: .string), "original clipboard")
        }
    }
    @MainActor func testSyntheticPasteModifiersDoNotBlockAutoSendButHardwareModifiersDo() async {
        for physical: CGEventFlags in [[], .maskCommand, .maskControl, .maskAlternate, .maskShift] {
            let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
            board.setString("original clipboard", forType: .string)
            var sessionFlags: CGEventFlags = []
            var hardwareFlags: CGEventFlags = []
            var returns = 0
            delivery.heldModifiers = {
                PasteKeystroke.physicalModifiers(read: { state in
                    state == .hidSystemState ? hardwareFlags : sessionFlags
                })
            }
            delivery.postPaste = {
                // Model the session state left by our actual event pair, without
                // posting any events into the user's session.
                let sent = await PasteKeystroke(keyCode: { 9 }, post: { event in
                    sessionFlags = event.flags
                }, pause: {}).send()
                XCTAssertTrue(sessionFlags.contains(.maskCommand))
                XCTAssertEqual(board.string(forType: .string), "dictation")
                hardwareFlags = physical
                return sent
            }
            delivery.postReturn = { returns += 1; return true }
            let result = await delivery.insert("dictation", into: target, autoSend: true)
            XCTAssertEqual(returns, physical.isEmpty ? 1 : 0)
            XCTAssertEqual(result.pasteState, physical.isEmpty ? .sent : .autoSendSkipped)
            XCTAssertEqual(board.string(forType: .string), "original clipboard")
            if !physical.isEmpty { XCTAssertTrue(result.message.contains("keyboard modifiers are held")) }
        }
    }
    @MainActor func testOrdinaryPasteDoesNotRequireEditorReadbackAndRestoresClipboard() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        delivery.postPaste = { XCTAssertEqual(board.string(forType: .string), "dictation"); return true }
        let result = await delivery.insert("dictation", into: target)
        XCTAssertEqual(result.pasteState, .sent)
        XCTAssertFalse(result.needsRecovery)
        XCTAssertEqual(result.message, "Paste sent to Fixture editor. Transcript saved in History.")
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }
    @MainActor func testMissingFieldAfterPasteWaitsForClipboardReadAndFocusRecovery() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        var posted = false; var consumed = false; var pastes = 0; var returns = 0
        let advance = delivery.pause
        delivery.pause = { delay in
            try await advance(delay)
            if posted && !consumed && delivery.now() >= 0.4 {
                // Previously the first failed AX read restored the clipboard
                // before this consumer could read the transcript.
                XCTAssertEqual(board.string(forType: .string), "dictation")
                consumed = true
            }
        }
        delivery.current = {
            posted && delivery.now() < 0.85
                ? .init(appPID: 123, failure: .unavailable) : .init(target: self.target)
        }
        delivery.postPaste = { posted = true; pastes += 1; return true }
        delivery.postReturn = { returns += 1; return true }
        let result = await delivery.insert("dictation", into: target, autoSend: true)
        XCTAssertTrue(consumed); XCTAssertEqual(pastes, 1); XCTAssertEqual(returns, 1)
        XCTAssertEqual(result.pasteState, .sent); XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }
    @MainActor func testKnownAppChangeAfterPasteStillStopsAutoSend() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        var posted = false
        delivery.current = { posted ? .init(appPID: 456, failure: .unavailable) : .init(target: self.target) }
        delivery.postPaste = { posted = true; _ = board.string(forType: .string); return true }
        let result = await delivery.insert("dictation", into: target, autoSend: true)
        XCTAssertEqual(result.pasteState, .autoSendSkipped)
        XCTAssertTrue(result.message.contains("active app changed"))
    }
    func testFocusCheckSeparatesUnavailableFromKnownChangedOrProtectedTargets() {
        var captured = target; captured.window = AXUIElementCreateApplication(456)
        let wrapper = TextTarget(pid: 123, name: "Wrapper",
            element: AXUIElementCreateApplication(789), selection: nil, window: captured.window, opaque: true)
        let unavailable: [TextTargetCapture] = [
            .init(appPID: 123, failure: .unavailable, window: captured.window),
            .init(target: target), // Same field, temporarily missing window.
            .init(target: wrapper)
        ]
        for observation in unavailable {
            guard case .unavailable = observation.focus(matching: captured) else { return XCTFail("Missing AX data is not a switch") }
        }
        var otherWindow = captured; otherWindow.window = AXUIElementCreateApplication(999)
        let changed: [TextTargetCapture] = [
            .init(appPID: 456, failure: .unavailable), .init(target: otherWindow),
            .init(appPID: 123, failure: .secure), .init(appPID: 123, failure: .notEditable),
            .init(failure: .permission), .init(failure: .ownApp)
        ]
        for observation in changed {
            guard case .changed = observation.focus(matching: captured) else { return XCTFail("Known change must stop delivery") }
        }
        let missingRole = TextDelivery.resolve(editor, pid: 123, name: "Fixture", read: { _, _ in nil }, owner: { _ in 123 })
        XCTAssertEqual(missingRole.failure, .unavailable)
    }
    @MainActor func testDelayedEditorReadbackContinuesAfterClipboardRestoration() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        var time: TimeInterval = 0; var pasted = false; var restoredBeforeReadback = false
        delivery.now = { time }
        delivery.publish = { ClipboardPaste(text: $0, board: board, now: { time }) }
        delivery.pause = { delay in
            time += Double(delay) / 1_000_000_000
            if time > 0.6 && time < 0.8 { restoredBeforeReadback = board.string(forType: .string) == "original clipboard" }
        }
        delivery.read = { _ in
            let arrived = pasted && time >= 0.9
            return .init(text: arrived ? "Hello" : "", selection: CFRange(location: arrived ? 5 : 0, length: 0))
        }
        delivery.postPaste = { pasted = true; XCTAssertEqual(board.string(forType: .string), "Hello"); return true }
        let result = await delivery.insert("Hello", into: target)
        XCTAssertTrue(restoredBeforeReadback)
        XCTAssertEqual(result.pasteState, .verified)
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }
    @MainActor func testSlowClipboardConsumerStillGetsTranscriptBeforeRestore() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        board.setString("original clipboard", forType: .string)
        var time: TimeInterval = 0; var consumed = false
        delivery.now = { time }
        delivery.publish = { ClipboardPaste(text: $0, board: board, now: { time }) }
        delivery.pause = { delay in
            time += Double(delay) / 1_000_000_000
            if time >= 1.2 && !consumed { consumed = true; XCTAssertEqual(board.string(forType: .string), "Hello") }
        }
        delivery.postPaste = { true }
        _ = await delivery.insert("Hello", into: target)
        XCTAssertTrue(consumed); XCTAssertGreaterThan(time, 1.5)
        XCTAssertEqual(board.string(forType: .string), "original clipboard")
    }
    @MainActor func testNewUserCopyAndCancellationDuringPasteArePreserved() async {
        for cancelled in [false, true] {
            let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
            board.setString("old clipboard", forType: .string)
            delivery.postPaste = {
                XCTAssertEqual(board.string(forType: .string), "dictation")
                board.clearContents(); board.setString("new user copy", forType: .string)
                if cancelled { delivery.cancel() }
                return true
            }
            _ = await delivery.insert("dictation", into: target, autoSend: true)
            XCTAssertEqual(board.string(forType: .string), "new user copy")
        }
    }
    @MainActor func testOnlyExactReadbackReportsVerifiedInsertion() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        var posted = false
        delivery.read = { _ in .init(text: posted ? "Hello world" : "Hello ", selection: CFRange(location: posted ? 11 : 6, length: 0)) }
        delivery.postPaste = { posted = true; return true }
        let result = await delivery.insert("world", into: target)
        XCTAssertTrue(result.message.contains("verified")); XCTAssertFalse(result.needsRecovery)
    }
    @MainActor func testVerifiedPasteAutoSendsOnceOnlyAfterReadback() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        var posted = false; var returns = 0
        delivery.read = { _ in .init(text: posted ? "Hello" : "", selection: CFRange(location: posted ? 5 : 0, length: 0)) }
        delivery.postPaste = { posted = true; return true }
        delivery.postReturn = { XCTAssertTrue(posted); returns += 1; return true }
        let result = await delivery.insert("Hello", into: target, autoSend: true)
        XCTAssertEqual(returns, 1); XCTAssertFalse(result.needsRecovery); XCTAssertTrue(result.message.contains("Return sent"))
    }
    @MainActor func testNilOrChangedTargetsNeverPublishOrPaste() async {
        let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
        delivery.current = { .init(failure: .unavailable) }
        delivery.publish = { _ in XCTFail("Unexpected clipboard mutation"); return nil }
        let missing = await delivery.insert("Fixture", into: nil)
        XCTAssertTrue(missing.needsRecovery)
        let changed = await delivery.insert("Fixture", into: target)
        XCTAssertTrue(changed.needsRecovery)
    }
    @MainActor func testFocusModifiersClipboardAndCancellationRecheckedBeforePaste() async {
        for scenario in 0..<4 {
            let (delivery, board) = fixtureDelivery(); defer { board.releaseGlobally() }
            board.setString("original", forType: .string)
            delivery.pause = { _ in
                switch scenario {
                case 0: delivery.current = { .init(failure: .unavailable) }
                case 1: delivery.heldModifiers = { .maskShift }
                case 2: board.clearContents(); board.setString("new user copy", forType: .string)
                default: delivery.cancel()
                }
            }
            let result = await delivery.insert("Fixture", into: target)
            XCTAssertTrue(result.needsRecovery)
            XCTAssertEqual(board.string(forType: .string), scenario == 2 ? "new user copy" : "original")
        }
    }
    func testClipboardPreservesEveryRepresentationAndRespectsNewerCopy() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let item = NSPasteboardItem(); let custom = NSPasteboard.PasteboardType("test.binary")
        item.setString("original", forType: .string); item.setData(Data([0, 1, 2]), forType: custom)
        board.writeObjects([item])
        let paste = try XCTUnwrap(ClipboardPaste(text: "transcript", board: board))
        XCTAssertNil(paste.readAt); XCTAssertTrue(paste.ownsClipboard)
        XCTAssertEqual(board.string(forType: .string), "transcript"); XCTAssertNotNil(paste.readAt)
        paste.finish()
        XCTAssertEqual(board.string(forType: .string), "original"); XCTAssertEqual(board.data(forType: custom), Data([0, 1, 2]))
        let next = try XCTUnwrap(ClipboardPaste(text: "next", board: board))
        board.clearContents(); board.setString("newer", forType: .string); next.finish()
        XCTAssertEqual(board.string(forType: .string), "newer")
    }
    @MainActor func testPasteKeystrokeAllocatesCompletePairAndPostsSessionCommandFlags() async {
        var events: [CGEvent] = []
        let chord = PasteKeystroke(keyCode: { 31 }, post: { events.append($0) }, pause: {})
        let sent = await chord.send()
        XCTAssertTrue(sent); XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
        XCTAssertTrue(events.allSatisfy { $0.flags.contains(.maskCommand) && $0.getIntegerValueField(.keyboardEventKeycode) == 31 })
        let incomplete = await PasteKeystroke(keyCode: { 9 }, makeEvent: { _, _ in nil }, post: { _ in XCTFail("Partial chord") }, pause: {}).send()
        XCTAssertFalse(incomplete)
        let unresolved = await PasteKeystroke(keyCode: { nil }, post: { _ in XCTFail("Guessed paste shortcut") }, pause: {}).send()
        XCTAssertFalse(unresolved)
        events = []
        let interrupted = await PasteKeystroke(keyCode: { 9 }, post: { events.append($0) }, pause: { throw CancellationError() }).send()
        XCTAssertFalse(interrupted); XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
    }
    func testClipboardRoundTripPreservesMultipleItemsAndAllFormatsExactly() throws {
        let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
        let first = NSPasteboardItem(); let second = NSPasteboardItem()
        let html = Data("<b>original</b>".utf8)
        let binary = Data([0, 255, 42, 0, 1])
        first.setString("original", forType: .string); first.setData(html, forType: .html)
        second.setData(binary, forType: .tiff); second.setString("file:///tmp/fixture.png", forType: .fileURL)
        XCTAssertTrue(board.writeObjects([first, second]))
        let transaction = try XCTUnwrap(ClipboardPaste(text: "new transcript", board: board))
        XCTAssertEqual(board.string(forType: .string), "new transcript")
        transaction.finish(); transaction.finish()
        let items = try XCTUnwrap(board.pasteboardItems)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "original")
        XCTAssertEqual(items[0].data(forType: .html), html)
        XCTAssertEqual(items[1].data(forType: .tiff), binary)
        XCTAssertEqual(items[1].string(forType: .fileURL), "file:///tmp/fixture.png")
        board.clearContents()
        let empty = try XCTUnwrap(ClipboardPaste(text: "temporary", board: board))
        empty.finish(); XCTAssertTrue(board.pasteboardItems?.isEmpty ?? true)
    }
    @MainActor func testRecoveryRestoresOnlyRememberedEditorAndRejectsChangedField() async {
        var front: pid_t = 10; var activations: [pid_t] = []
        var restore = EditorReturn(ownPID: 10, frontPID: { front }, activate: { activations.append($0); front = $0; return true }, current: { self.target }, pause: {})
        let result = await restore.restore(target); XCTAssertTrue(result); XCTAssertEqual(activations, [123])
        front = 456
        let other = await restore.restore(target); XCTAssertFalse(other); XCTAssertEqual(activations, [123])
        front = 123; restore.current = { nil }
        let stale = await restore.restore(target); XCTAssertFalse(stale)
    }
    func testMenuReturnsFocusOnlyWhenItDisplacedTheApp() {
        let focus = MenuFocus(); focus.ownPID = 10
        var current: pid_t = 20; var activations: [pid_t] = []
        focus.currentPID = { current }; focus.activate = { activations.append($0) }
        focus.opened(); current = 10; focus.closed(restore: true)
        XCTAssertEqual(activations, [20]); XCTAssertNil(focus.returnPID)
        current = 20; focus.opened(); current = 30; focus.closed(restore: true)
        XCTAssertEqual(activations, [20]) // User chose another app.
        current = 20; focus.opened(); current = 10; focus.closed(restore: false)
        XCTAssertEqual(activations, [20]) // Opening History/Settings.
        focus.opened(); focus.closed(restore: true)
        XCTAssertEqual(activations, [20]) // No stale previous-app reuse.
    }
}
