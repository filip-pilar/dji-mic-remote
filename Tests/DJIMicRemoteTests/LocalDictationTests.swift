import XCTest
import ApplicationServices
@testable import DJIMicRemote

final class LocalDictationTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    @MainActor func configured(_ recognizer: FakeRecognizer = FakeRecognizer(), autoSend: Bool = false) async throws -> LocalDictation {
        let local = LocalDictation(history: try LocalHistory(directory: directory), recognizer: recognizer, recorder: FakeRecorder(), inputs: { [] }, autoSend: autoSend)
        local.listInputs = { [AudioInput(uid: "fixture", name: "Fixture microphone")] }
        local.inputUID = "fixture"; local.prepareTarget = {}
        local.captureTarget = { .init(target: TextTarget(pid: 123, name: "Fixture", element: AXUIElementCreateApplication(123), selection: nil), appPID: 123) }
        local.deliver = { _, _, _ in .init("Fixture delivery") }
        local.prepare(); try await waitUntil { !local.working }; XCTAssertTrue(local.ready)
        return local
    }
    @MainActor func testHistoryPasteReturnsToCapturedEditorWithoutCountdownOrAutoSend() async throws {
        let local = try await configured(autoSend: true)
        local.press(); local.finish(insert: false); try await waitUntil { !local.working }
        let entry = try XCTUnwrap(local.entries.first)
        let target = try XCTUnwrap(local.captureTarget().target)
        var restored = false; var deliveries = 0
        local.restoreTarget = { value in XCTAssertEqual(value.pid, target.pid); restored = true; return true }
        local.deliver = { text, value, autoSend in
            XCTAssertTrue(restored); XCTAssertFalse(autoSend); XCTAssertEqual(value?.pid, target.pid)
            XCTAssertEqual(text, "Selected previous version"); deliveries += 1
            return .init("Verified fixture")
        }
        local.pasteAgain(entry.id, text: "Selected previous version", into: target)
        XCTAssertTrue(local.pastePending)
        try await waitUntil { !local.working }
        XCTAssertEqual(deliveries, 1); XCTAssertFalse(local.pastePending)
        XCTAssertEqual(local.history?.entry(entry.id)?.state, .ready)
    }
    @MainActor func testRecoveryCannotDeliverAfterCancellationOrFailedFocusRestore() async throws {
        let local = try await configured()
        local.press(); local.finish(insert: false); try await waitUntil { !local.working }
        let entry = try XCTUnwrap(local.entries.first); let target = try XCTUnwrap(local.captureTarget().target)
        local.deliver = { _, _, _ in XCTFail("Unexpected recovery delivery"); return .init("Unexpected") }
        local.restoreTarget = { _ in false }
        local.pasteAgain(entry.id, into: target); try await waitUntil { !local.working }
        XCTAssertTrue(local.history?.entry(entry.id)?.needsInsertionRecovery == true)
        var resume: CheckedContinuation<Bool, Never>?
        local.restoreTarget = { _ in await withCheckedContinuation { resume = $0 } }
        local.pasteAgain(entry.id, into: target); try await waitUntil { resume != nil }
        local.interrupt("Paused")
        resume?.resume(returning: true); try await waitUntil { !local.working }
        XCTAssertEqual(local.history?.entry(entry.id)?.state, .ready)
        XCTAssertEqual(local.history?.entry(entry.id)?.text, entry.text)
    }
    @MainActor func testCancellingDeliveryKeepsReadyTextRecoverableAndRejectsLateSuccess() async throws {
        let local = try await configured()
        var completions = 0
        local.onTranscriptSaved = { completions += 1 }
        var resume: CheckedContinuation<TextDeliveryResult, Never>?
        local.deliver = { _, _, _ in await withCheckedContinuation { resume = $0 } }
        local.press(); local.finish(); try await waitUntil { resume != nil }
        XCTAssertTrue(local.delivering)
        local.interrupt("Paused")
        resume?.resume(returning: .init("Late success")); try await waitUntil { !local.working }
        XCTAssertFalse(local.delivering); XCTAssertEqual(local.entries.first?.needsInsertionRecovery, true)
        XCTAssertEqual(local.entries.first?.state, .ready)
        XCTAssertEqual(local.entries.first?.message, "Delivery cancelled · transcript saved.")
        XCTAssertEqual(completions, 0)
    }
    @MainActor func testSavedFeedbackRequiresDurableNonemptyCompletionWithoutRecovery() async throws {
        let recognizer = FakeRecognizer()
        let local = try await configured(recognizer)
        var completions = 0
        local.onTranscriptSaved = {
            XCTAssertFalse(local.busy)
            XCTAssertEqual(local.entries.first?.state, .ready)
            XCTAssertFalse(local.hasUnsavedHistory)
            completions += 1
        }
        local.press(); local.finish(insert: false); try await waitUntil { !local.working }
        XCTAssertEqual(completions, 1)
        local.deliver = { _, _, _ in .init("Paste sent, not confirmed", needsRecovery: true) }
        local.press(); local.finish(); try await waitUntil { !local.working }
        XCTAssertEqual(completions, 1)
        recognizer.output = ""
        local.press(); local.finish(insert: false); try await waitUntil { !local.working }
        XCTAssertEqual(completions, 1)
        recognizer.failure = NSError(domain: "Fixture", code: 1)
        local.press(); local.finish(); try await waitUntil { !local.working }
        XCTAssertEqual(completions, 1)
    }
    @MainActor func testHistoryRetryPreparesAutomaticallyWithoutInsertion() async throws {
        let history = try LocalHistory(directory: directory)
        var entry = Transcript(id: UUID(), created: Date()); entry.state = .interrupted
        try history.save(entry); try Data([1]).write(to: history.audioURL(entry.id))
        let recognizer = FakeRecognizer()
        let local = LocalDictation(history: history, recognizer: recognizer, recorder: FakeRecorder(), inputs: { [] }, autoSend: true)
        var deliveries = 0; local.deliver = { _, _, _ in deliveries += 1; return .init("Unexpected") }
        local.retry(entry.id)
        try await waitUntil { !local.working }
        XCTAssertTrue(local.ready); XCTAssertEqual(recognizer.calls, 1)
        XCTAssertEqual(deliveries, 0); XCTAssertEqual(local.entries.first?.text, recognizer.output)
    }
    @MainActor func testRetryClearsOldDeliveryOutcomeAndKeepsPriorText() async throws {
        let recognizer = FakeRecognizer(); let local = try await configured(recognizer, autoSend: true)
        local.deliver = { _, _, _ in .init("Paste sent · Auto-send skipped", needsRecovery: true, pasteState: .autoSendSkipped) }
        local.press(); local.finish(); try await waitUntil { !local.working }
        let original = try XCTUnwrap(local.entries.first)
        XCTAssertEqual(original.pasteState, .autoSendSkipped)
        recognizer.output = "Revised transcript"
        local.deliver = { _, _, _ in XCTFail("Retry must not deliver"); return .init("Unexpected") }
        local.retry(original.id); try await waitUntil { !local.working }
        let saved = try XCTUnwrap(LocalHistory(directory: directory).entry(original.id))
        XCTAssertEqual(saved.text, recognizer.output)
        XCTAssertEqual(saved.previousTexts, [original.text])
        XCTAssertEqual(saved.needsInsertionRecovery, false); XCTAssertNil(saved.pasteState)
        XCTAssertEqual(saved.targetName, original.targetName)
        XCTAssertTrue(local.history!.hasAudio(original.id))
    }
    @MainActor func testMissingTargetSavesAndExposesRecoveryWithoutDelivering() async throws {
        let local = try await configured()
        local.captureTarget = { .init(failure: .ownApp) }
        local.deliver = { _, _, _ in XCTFail("No target must never receive text"); return .init("Unexpected") }
        local.press()
        XCTAssertTrue(local.message.contains("text field not detected"))
        local.finish(); try await waitUntil { !local.working }
        let entry = try XCTUnwrap(local.entries.first)
        XCTAssertEqual(entry.needsInsertionRecovery, true)
        XCTAssertFalse(entry.text.isEmpty); XCTAssertTrue(entry.message.contains("DJI app had focus"))
        let saved = try LocalHistory(directory: directory)
        XCTAssertEqual(saved.entries.first?.needsInsertionRecovery, true)
    }
    @MainActor func testDelayedWebFieldBecomesTargetWhileAudioKeepsRecording() async throws {
        let local = try await configured(); var available = false
        local.captureTarget = { available
            ? .init(target: TextTarget(pid: 123, name: "Chat fixture", element: AXUIElementCreateApplication(123), selection: nil), appPID: 123)
            : .init(appPID: 123, failure: .unavailable) }
        local.press(); XCTAssertNotNil(local.recordingID)
        available = true
        try await waitUntil { local.entries.first?.targetName == "Chat fixture" }
        XCTAssertNotNil(local.recordingID)
        var delivered = 0
        local.deliver = { _, target, _ in delivered += 1; XCTAssertEqual(target?.pid, 123); return .init("Inserted fixture") }
        local.finish(); try await waitUntil { !local.working }
        XCTAssertEqual(delivered, 1); XCTAssertEqual(local.entries.first?.needsInsertionRecovery, false)
    }
    @MainActor func testDelayedCaptureCannotRetargetAnotherAppOrFinishLate() async throws {
        let local = try await configured(); var pid: pid_t = 123; var captures = 0
        local.captureTarget = {
            captures += 1
            return .init(target: pid == 456 ? TextTarget(pid: pid, name: "Other", element: AXUIElementCreateApplication(pid), selection: nil) : nil,
                         appPID: pid, failure: .unavailable)
        }
        local.press(); pid = 456
        try await waitUntil { captures >= 2 }
        XCTAssertNil(local.entries.first?.targetName)
        local.finish(); try await waitUntil { !local.working }
        XCTAssertEqual(local.entries.first?.needsInsertionRecovery, true)
    }
    @MainActor func testMenuFinishSavesWithoutInsertion() async throws {
        let local = try await configured(autoSend: true)
        var deliveries = 0; local.deliver = { _, _, _ in deliveries += 1; return .init("Unexpected") }
        local.press(); local.finish(insert: false)
        try await waitUntil { !local.working }
        XCTAssertEqual(deliveries, 0); XCTAssertFalse(local.entries.first!.text.isEmpty)
    }
    @MainActor func testEmptyRecordingDoesNotTranscribeOrDeliver() async throws {
        let recognizer = FakeRecognizer(); let local = try await configured(recognizer)
        let recorder = try XCTUnwrap(local.recorder as? FakeRecorder); recorder.duration = 0
        var deliveries = 0; local.deliver = { _, _, _ in deliveries += 1; return .init("Unexpected") }
        local.press(); local.press()
        XCTAssertNil(local.recordingID); XCTAssertFalse(local.working)
        XCTAssertEqual(recognizer.calls, 0); XCTAssertEqual(deliveries, 0)
        XCTAssertEqual(local.entries.first?.state, .failed)
        XCTAssertTrue(local.message.contains("No audio reached"))
    }
    @MainActor func testNewDictationSavesBeforeAutoSendAndRetryNeverDelivers() async throws {
        let recognizer = FakeRecognizer()
        let local = try await configured(recognizer, autoSend: true)
        var autoSendOptions: [Bool] = []
        local.deliver = { text, _, autoSend in
            autoSendOptions.append(autoSend)
            do {
                let recovered = try LocalHistory(directory: self.directory)
                XCTAssertEqual(recovered.entries.first?.text, text)
                XCTAssertEqual(recovered.entries.first?.state, .ready)
            } catch {
                XCTFail("Transcript must be durable before delivery: \(error)")
            }
            return .init("Fixture delivery")
        }
        local.press()
        let id = try XCTUnwrap(local.recordingID)
        local.press()
        try await waitUntil { !local.working }
        XCTAssertEqual(autoSendOptions, [true])
        XCTAssertTrue(local.history!.hasAudio(id))

        recognizer.output = "A revised transcript."
        local.retry(id)
        try await waitUntil { !local.working }
        XCTAssertEqual(autoSendOptions, [true])
        XCTAssertEqual(recognizer.calls, 2)
        XCTAssertEqual(local.entries.first?.previousTexts, ["Hello from the microphone."])
    }
    @MainActor func testCancelInferenceKeepsAudioAndRejectsLateDelivery() async throws {
        let recognizer = FakeRecognizer(); recognizer.delayed = true
        let local = try await configured(recognizer)
        var deliveries = 0; local.deliver = { _, _, _ in deliveries += 1; return .init("sent") }
        local.press(); let id = try XCTUnwrap(local.recordingID); local.press()
        try await waitUntil { recognizer.continuation != nil }
        local.interrupt("Disconnected")
        recognizer.continuation?.resume(returning: "Late transcript")
        try await waitUntil { !local.working }
        XCTAssertEqual(deliveries, 0); XCTAssertEqual(local.entries.first?.state, .interrupted)
        XCTAssertTrue(local.history!.hasAudio(id))
    }
    @MainActor func testRecorderInterruptionClosesFileWithoutInference() async throws {
        let recognizer = FakeRecognizer(); let local = try await configured(recognizer)
        local.press(); local.recorder.onInterruption?("Input unplugged")
        XCTAssertNil(local.recordingID); XCTAssertEqual(local.entries.first?.state, .interrupted)
        XCTAssertEqual(recognizer.calls, 0)
    }
    @MainActor func testRecognitionFailureKeepsExistingTextAndAudio() async throws {
        let recognizer = FakeRecognizer(); let local = try await configured(recognizer)
        local.press(); local.press(); try await waitUntil { !local.working }
        let id = try XCTUnwrap(local.entries.first?.id)
        recognizer.failure = LocalFailure.message("Fixture failure")
        local.retry(id); try await waitUntil { !local.working }
        XCTAssertEqual(local.entries.first?.text, "Hello from the microphone.")
        XCTAssertEqual(local.entries.first?.state, .failed); XCTAssertTrue(local.history!.hasAudio(id))
    }
    @MainActor func testSaveFailureNeverDeliversAndTextRemainsInMemory() async throws {
        let local = try await configured()
        var delivered = 0; local.deliver = { _, _, _ in delivered += 1; return .init("sent") }
        local.press()
        // Block metadata replacement while leaving the recording readable.
        let id = try XCTUnwrap(local.recordingID)
        let metadata = directory.appendingPathComponent(id.uuidString + ".json")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
        local.press()
        XCTAssertEqual(delivered, 0); XCTAssertTrue(local.needsSaving(id))
        XCTAssertTrue(local.history!.hasAudio(id))
        try FileManager.default.removeItem(at: metadata)
        local.retry(id)
        XCTAssertFalse(local.needsSaving(id)); XCTAssertEqual(delivered, 0)
    }
}
