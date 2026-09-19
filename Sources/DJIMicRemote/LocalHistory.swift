import Foundation

struct Transcript: Codable, Identifiable, Equatable {
    enum State: String, Codable { case recording, transcribing, ready, interrupted, failed }
    enum PasteState: String, Codable { case sent, verified, autoSendSkipped }
    let id: UUID
    let created: Date
    var duration: Double = 0
    var state: State = .recording
    var text = ""
    var previousTexts: [String] = []
    var message = "Recording…"
    // Durable diagnostics: preserve these fields across decoding/re-saving even
    // when the main panel does not display them. Older records may omit them.
    var targetName: String?
    var needsInsertionRecovery: Bool?
    var pasteState: PasteState?
    var modelRevision: String?
    var displayMessage: String {
        // Older builds treated AX setter success as insertion; do not repeat
        // that unverified claim when displaying existing history.
        message.hasPrefix("Inserted in") && !message.contains("verified") ? "Saved on this Mac" : message
    }
}

/// One atomic metadata file per recording. Audio is persisted before recognition begins.
final class LocalHistory {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/DJI Mic Remote/History", isDirectory: true)
    let directory: URL
    private(set) var entries: [Transcript] = []
    private(set) var warning: String?
    init(directory: URL = LocalHistory.root) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            do {
                var entry = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
                guard url.deletingPathExtension().lastPathComponent == entry.id.uuidString else { throw CocoaError(.fileReadCorruptFile) }
                if entry.state == .recording || entry.state == .transcribing {
                    entry.state = .interrupted
                    entry.message = "Interrupted. Retry transcription from the saved recording."
                    try write(entry)
                }
                entries.append(entry)
            } catch { warning = "Some history files could not be read. They were left on disk for recovery." }
        }
        entries.sort { $0.created > $1.created }
    }
    func audioURL(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".caf") }
    func hasAudio(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: audioURL(id).path) }
    func entry(_ id: UUID) -> Transcript? { entries.first { $0.id == id } }
    func save(_ entry: Transcript) throws {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
        else { entries.insert(entry, at: 0) }
        try write(entry)
    }
    private func write(_ entry: Transcript) throws {
        let url = directory.appendingPathComponent(entry.id.uuidString + ".json")
        try JSONEncoder().encode(entry).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func delete(_ id: UUID) throws {
        // Remove audio first. A failed delete must never silently orphan a private recording.
        let audio = audioURL(id)
        if hasAudio(id) { try FileManager.default.removeItem(at: audio) }
        let metadata = directory.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        entries.removeAll { $0.id == id }
    }
    // Called at launch, before recording, or while idle; never during capture.
    func expireAudio(now: Date = Date()) throws {
        for entry in entries where now.timeIntervalSince(entry.created) > 7 * 86_400 {
            if hasAudio(entry.id) { try FileManager.default.removeItem(at: audioURL(entry.id)) }
        }
    }
}

enum LocalFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}
