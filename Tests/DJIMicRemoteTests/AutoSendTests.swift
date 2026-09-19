import XCTest
import ApplicationServices
@testable import DJIMicRemote

final class AutoSendTests: XCTestCase {
    let target = TextTarget(pid: 123, name: "Fixture", element: AXUIElementCreateApplication(123), selection: nil)
    var before: FieldSnapshot { .init(text: "Hello ", selection: CFRange(location: 6, length: 0)) }
    var after: FieldSnapshot { .init(text: "Hello world", selection: CFRange(location: 11, length: 0)) }
    func testProofUsesUTF16AndReplacesSelectedText() throws {
        let proof = try XCTUnwrap(InsertionProof(before: .init(text: "🎙 old!", selection: CFRange(location: 3, length: 3)), inserted: "new"))
        XCTAssertTrue(proof.matches(.init(text: "🎙 new!", selection: CFRange(location: 6, length: 0))))
        XCTAssertFalse(proof.matches(.init(text: "🎙 new!", selection: CFRange(location: 0, length: 0))))
        XCTAssertNil(InsertionProof(before: .init(text: "x", selection: CFRange(location: 2, length: 0)), inserted: "a"))
        XCTAssertNil(InsertionProof(before: .init(text: "same", selection: CFRange(location: 0, length: 4)), inserted: "same"))
    }
    @MainActor func testVerifiedInsertionPostsReturnExactlyOnce() async {
        var sent = 0
        let verifier = AutoSend(current: { .init(target: self.target) }, read: { _ in self.after }, held: { [] }, pause: {}, pressReturn: { sent += 1; return true })
        let result = await verifier.finish(target: target, proof: InsertionProof(before: before, inserted: "world"), isCurrent: { true })
        XCTAssertEqual(sent, 1); XCTAssertTrue(result.message.contains("Return sent"))
    }
    @MainActor func testUnconsumedUnverifiedPasteNeverSends() async {
        var sent = 0
        let verifier = AutoSend(current: { .init(target: self.target) }, read: { _ in self.before }, held: { [] }, pause: {}, pressReturn: { sent += 1; return true })
        _ = await verifier.finish(target: target, proof: nil, isCurrent: { true })
        _ = await verifier.finish(target: target, proof: InsertionProof(before: before, inserted: "world"), isCurrent: { true })
        XCTAssertEqual(sent, 0)
    }
    @MainActor func testFocusModifiersAndCancellationPreventReturn() async {
        var sent = 0
        let proof = InsertionProof(before: before, inserted: "world")
        var verifier = AutoSend(current: { .init(failure: .unavailable) }, read: { _ in self.after }, held: { [] }, pause: {}, pressReturn: { sent += 1; return true })
        _ = await verifier.finish(target: target, proof: proof, isCurrent: { true })
        verifier.current = { .init(target: self.target) }; verifier.held = { .maskShift }
        _ = await verifier.finish(target: target, proof: proof, isCurrent: { true })
        verifier.held = { [] }
        _ = await verifier.finish(target: target, proof: proof, isCurrent: { false })
        verifier.pause = { throw CancellationError() }
        _ = await verifier.finish(target: target, proof: proof, isCurrent: { true })
        XCTAssertEqual(sent, 0)
    }
    @MainActor func testWaitsForPasteButRejectsEditsBeforeReturn() async {
        var reads = 0; var sent = 0
        var verifier = AutoSend(current: { .init(target: self.target) }, read: { _ in
            reads += 1; return reads < 3 ? self.before : self.after
        }, held: { [] }, pause: {}, pressReturn: { sent += 1; return true })
        _ = await verifier.finish(target: target, proof: InsertionProof(before: before, inserted: "world"), isCurrent: { true })
        XCTAssertEqual(sent, 1)
        reads = 0; sent = 0
        verifier.read = { _ in reads += 1; return reads == 1 ? self.after : self.before }
        _ = await verifier.finish(target: target, proof: InsertionProof(before: before, inserted: "world"), isCurrent: { true })
        XCTAssertEqual(sent, 0)
    }
    @MainActor func testSwitchingWindowsInSameAppPreventsReturn() async {
        var captured = target; captured.window = AXUIElementCreateApplication(456)
        var current = captured; current.window = AXUIElementCreateApplication(789)
        let verifier = AutoSend(current: { .init(target: current) }, read: { _ in self.after }, held: { [] }, pause: {},
            pressReturn: { XCTFail("Must not submit in another window"); return true })
        let result = await verifier.finish(target: captured, proof: InsertionProof(before: before, inserted: "world"), isCurrent: { true })
        XCTAssertTrue(result.message.contains("active window changed"))
    }
    @MainActor func testConsumedPasteCanAutoSendWithMissingOrStaleAXContents() async {
        for readable in [false, true] {
            var sent = 0
            let verifier = AutoSend(current: { .init(target: self.target) }, read: { _ in readable ? self.before : nil }, held: { [] },
                pause: {}, pressReturn: { sent += 1; return true })
            let result = await verifier.finish(target: target, proof: InsertionProof(before: before, inserted: "world"),
                                               clipboardConsumed: true, isCurrent: { true })
            XCTAssertEqual(sent, 1); XCTAssertEqual(result.pasteState, .sent)
            XCTAssertFalse(result.needsRecovery); XCTAssertTrue(result.message.contains("Paste and Return sent"))
        }
    }
    @MainActor func testConsumedPasteStillRechecksFocusModifiersCancellationAndEdits() async {
        for scenario in 0..<5 {
            var currentReads = 0; var textReads = 0
            let verifier = AutoSend(current: {
                currentReads += 1
                return .init(target: scenario == 0 && currentReads > 1 ? nil : self.target)
            }, read: { _ in
                textReads += 1
                return scenario == 4 && textReads > 1 ? self.after : self.before
            }, held: { scenario == 1 ? .maskCommand : [] },
                pause: { if scenario == 2 { throw CancellationError() } },
                pressReturn: { XCTFail("Unexpected Return for scenario \(scenario)"); return true })
            let result = await verifier.finish(target: target, proof: nil, clipboardConsumed: true,
                                               isCurrent: { scenario != 3 })
            XCTAssertEqual(result.pasteState, .autoSendSkipped); XCTAssertTrue(result.needsRecovery)
        }
    }
    @MainActor func testTemporaryMissingFieldAtEveryReturnCheckRecoversWithoutDuplicateReturn() async {
        for missingRead in 1...3 {
            var reads = 0; var sent = 0
            let verifier = AutoSend(current: {
                reads += 1
                return reads == missingRead ? .init(appPID: 123, failure: .unavailable) : .init(target: self.target)
            }, read: { _ in nil }, held: { [] }, pause: {}, pressReturn: { sent += 1; return true })
            let result = await verifier.finish(target: target, proof: nil, clipboardConsumed: true, isCurrent: { true })
            XCTAssertEqual(sent, 1, "Missing read \(missingRead)")
            XCTAssertEqual(result.pasteState, .sent)
        }
    }
    @MainActor func testTemporaryMissingWindowRecoversButPersistentMissingFieldTimesOutHonestly() async {
        var captured = target; captured.window = AXUIElementCreateApplication(456)
        var missingWindow = captured; missingWindow.window = nil
        var reads = 0; var sent = 0; var time: TimeInterval = 0
        var verifier = AutoSend(current: {
            reads += 1; return .init(target: reads == 1 ? missingWindow : captured)
        }, read: { _ in nil }, held: { [] }, pause: { time += 0.2 }, now: { time }, pressReturn: { sent += 1; return true })
        let recovered = await verifier.finish(target: captured, proof: nil, clipboardConsumed: true, isCurrent: { true })
        XCTAssertEqual(sent, 1); XCTAssertEqual(recovered.pasteState, .sent)
        sent = 0; time = 0
        verifier.current = { .init(appPID: 123, failure: .unavailable, window: captured.window) }
        let missing = await verifier.finish(target: captured, proof: nil, clipboardConsumed: true, isCurrent: { true })
        XCTAssertEqual(sent, 0); XCTAssertEqual(missing.pasteState, .autoSendSkipped)
        XCTAssertTrue(missing.message.contains("did not expose its text field"))
        XCTAssertFalse(missing.message.contains("changed")); XCTAssertLessThanOrEqual(time, 3.1)
    }
    @MainActor func testRealChangeWhileWaitingIsTerminalEvenIfOriginalAppWouldReturn() async {
        var reads = 0
        let verifier = AutoSend(current: {
            reads += 1
            if reads == 1 { return .init(appPID: 123, failure: .unavailable) }
            if reads == 2 { return .init(appPID: 456, failure: .unavailable) }
            return .init(target: self.target)
        }, read: { _ in nil }, held: { [] }, pause: {}, pressReturn: { XCTFail("Must not send after an app switch"); return true })
        let result = await verifier.finish(target: target, proof: nil, clipboardConsumed: true, isCurrent: { true })
        XCTAssertEqual(reads, 2); XCTAssertTrue(result.message.contains("active app changed"))
    }
    @MainActor func testMissingFinalReadDoesNotHideCursorMoveOrEditDuringRetry() async {
        for movedCaret in [false, true] {
            var range = CFRange(location: 11, length: 0)
            var stable = target
            stable = TextTarget(pid: stable.pid, name: stable.name, element: stable.element,
                                selection: AXValueCreate(.cfRange, &range))
            range.location = 12
            let moved = TextTarget(pid: stable.pid, name: stable.name, element: stable.element,
                                   selection: AXValueCreate(.cfRange, &range))
            var captures = 0; var reads = 0
            let verifier = AutoSend(current: {
                captures += 1
                if captures == 2 { return .init(appPID: 123, failure: .unavailable) }
                return .init(target: captures > 2 && movedCaret ? moved : stable)
            }, read: { _ in
                reads += 1; return reads == 1 ? self.after : self.before
            }, held: { [] }, pause: {}, pressReturn: { XCTFail("Must preserve the pre-retry baseline"); return true })
            let result = await verifier.finish(target: stable, proof: nil, clipboardConsumed: true, isCurrent: { true })
            XCTAssertEqual(result.pasteState, .autoSendSkipped)
            XCTAssertTrue(result.message.contains(movedCaret ? "cursor moved" : "text or cursor changed"))
        }
    }
    @MainActor func testCancellationDuringMissingFieldWaitNeverPostsReturn() async {
        var active = true
        let verifier = AutoSend(current: { .init(appPID: 123, failure: .unavailable) }, read: { _ in nil }, held: { [] },
            pause: { active = false }, pressReturn: { XCTFail("Cancelled send"); return true })
        let result = await verifier.finish(target: target, proof: nil, clipboardConsumed: true, isCurrent: { active })
        XCTAssertTrue(result.message.contains("cancelled"))
    }
    @MainActor func testCancellationDuringFinalFocusReadNeverPostsReturn() async {
        var active = true; var reads = 0
        let verifier = AutoSend(current: {
            reads += 1
            if reads == 3 { active = false }
            return .init(target: self.target)
        }, read: { _ in nil }, held: { [] }, pause: {}, pressReturn: { XCTFail("Cancelled during AX read"); return true })
        let result = await verifier.finish(target: target, proof: nil, clipboardConsumed: true, isCurrent: { active })
        XCTAssertTrue(result.message.contains("cancelled"))
    }
}
