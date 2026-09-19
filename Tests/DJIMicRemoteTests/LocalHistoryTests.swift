import XCTest
@testable import DJIMicRemote

final class LocalHistoryTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testCrashRecoveryRetentionAndDeletion() throws {
        let history = try LocalHistory(directory: directory)
        let old = Transcript(id: UUID(), created: Date().addingTimeInterval(-8 * 86_400))
        try history.save(old); try Data([1, 2]).write(to: history.audioURL(old.id))
        let recovered = try LocalHistory(directory: directory)
        XCTAssertEqual(recovered.entries.first?.state, .interrupted)
        try recovered.expireAudio()
        XCTAssertFalse(recovered.hasAudio(old.id)); XCTAssertEqual(recovered.entries.count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o700)
        try recovered.delete(old.id); XCTAssertTrue(recovered.entries.isEmpty)
    }

    func testRetentionKeepsRecentAudioAndAllTranscriptMetadata() throws {
        let history = try LocalHistory(directory: directory)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let ages: [TimeInterval] = [0, 7 * 86_400, 7 * 86_400 + 1]
        for age in ages {
            var entry = Transcript(id: UUID(), created: now.addingTimeInterval(-age))
            entry.state = .ready; entry.text = "Keep this transcript"
            try history.save(entry); try Data([1]).write(to: history.audioURL(entry.id))
        }
        try history.expireAudio(now: now)
        XCTAssertEqual(history.entries.count, 3)
        for entry in history.entries {
            XCTAssertEqual(history.hasAudio(entry.id), now.timeIntervalSince(entry.created) <= 7 * 86_400)
            XCTAssertEqual(try LocalHistory(directory: directory).entry(entry.id)?.text, "Keep this transcript")
        }
    }

    func testHistoryRetainsDiagnosticsAndReadsOlderRecordsWithoutThem() throws {
        let history = try LocalHistory(directory: directory)
        var entry = Transcript(id: UUID(), created: Date())
        entry.state = .ready; entry.text = "Current text"; entry.previousTexts = ["Original text"]
        entry.targetName = "Fixture editor"; entry.modelRevision = "pinned-fixture-revision"
        entry.pasteState = .autoSendSkipped; entry.needsInsertionRecovery = true
        entry.message = "Paste sent, Return skipped"
        try history.save(entry)
        let reopened = try LocalHistory(directory: directory)
        let saved = try XCTUnwrap(reopened.entry(entry.id))
        XCTAssertEqual(saved, entry)
        try reopened.save(saved)
        XCTAssertEqual(try LocalHistory(directory: directory).entry(entry.id), entry)

        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for field in ["targetName", "modelRevision", "pasteState", "needsInsertionRecovery"] { older.removeValue(forKey: field) }
        try JSONSerialization.data(withJSONObject: older).write(to: directory.appendingPathComponent(entry.id.uuidString + ".json"))
        let compatible = try XCTUnwrap(LocalHistory(directory: directory).entry(entry.id))
        XCTAssertEqual(compatible.text, entry.text); XCTAssertEqual(compatible.previousTexts, entry.previousTexts)
        XCTAssertNil(compatible.pasteState); XCTAssertNil(compatible.modelRevision)
    }
}
