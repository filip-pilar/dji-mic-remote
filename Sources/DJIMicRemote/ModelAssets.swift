import Foundation
import CryptoKit
import CoreML
import FluidAudio

enum AppResources {
    static var root: URL {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("DJIMicRemote_DJIMicRemote.bundle/Resources")
        if let packaged, FileManager.default.fileExists(atPath: packaged.path) { return packaged }
        return Bundle.module.bundleURL.appendingPathComponent("Resources")
    }
}

struct ModelManifest: Codable {
    struct File: Codable { let path: String; let bytes: Int64; let sha256: String }
    let repository: String
    let revision: String
    let files: [File]
    static func bundled() throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: AppResources.root.appendingPathComponent("ModelManifest.json")))
    }
    static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func valid(_ file: File, in root: URL) throws -> Bool {
        guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else { return false }
        let url = root.appendingPathComponent(file.path)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == file.bytes else { return false }
        return try Self.digest(url) == file.sha256
    }
}

enum ModelInstaller {
    static func install(_ manifest: ModelManifest, in root: URL, allowDownload: Bool,
                        progress: @escaping (String) -> Void,
                        download: (URL, Int64, Int64) async throws -> (URL, URLResponse)) async throws {
        var completed: Int64 = 0
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.bytes }
        for (index, file) in manifest.files.enumerated() {
            guard !file.path.hasPrefix("/"), !file.path.split(separator: "/").contains("..") else {
                throw LocalFailure.message("Invalid model manifest path.")
            }
            defer { completed += file.bytes }
            try Task.checkCancellation()
            progress("Checking model · \(index + 1) of \(manifest.files.count)")
            if try manifest.valid(file, in: root) { continue }
            guard allowDownload else { throw LocalFailure.message("The bundled model is damaged. Reinstall the app or use an unbundled build.") }
            progress("Downloading model · \(index + 1) of \(manifest.files.count) · 614 MB total")
            let url = URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(file.path)")!
            let (temporary, response) = try await download(url, completed, total)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  try ModelManifest.digest(temporary) == file.sha256,
                  (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == file.bytes
            else { throw LocalFailure.message("Model verification failed. Retry the download; your recordings are safe.") }
            try Task.checkCancellation()
            let destination = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

private final class ModelDownloadProgress: NSObject, URLSessionDownloadDelegate {
    let completed: Int64
    let total: Int64
    let update: (String) -> Void
    private var lastPercent = -1
    init(completed: Int64, total: Int64, update: @escaping (String) -> Void) {
        self.completed = completed; self.total = total; self.update = update
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let percent = min(100, Int((completed + totalBytesWritten) * 100 / max(1, total)))
        guard percent != lastPercent else { return }
        lastPercent = percent; update("Downloading model · \(percent)% of 614 MB")
    }
}

protocol LocalRecognizing: AnyObject {
    func prepare(progress: @escaping (String) -> Void) async throws
    func transcribe(_ audio: URL) async throws -> String
}

/// The SDK never downloads assets: all inference loads a checksum-verified, pinned directory.
actor ParakeetEngine: LocalRecognizing {
    private var manager: UnifiedAsrManager?
    private let bundledDirectory: URL?
    init(bundledDirectory: URL? = Bundle.main.resourceURL?.appendingPathComponent("Parakeet")) {
        self.bundledDirectory = bundledDirectory
    }
    func prepare(progress: @escaping (String) -> Void) async throws {
        if manager != nil { return }
        let manifest = try ModelManifest.bundled()
        let bundled = bundledDirectory
        let cache = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DJI Mic Remote/Models/" + manifest.revision)
        let root = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? cache
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 1800
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        try await ModelInstaller.install(manifest, in: root, allowDownload: root == cache, progress: progress) { url, completed, total in
            let delegate = ModelDownloadProgress(completed: completed, total: total, update: progress)
            return try await session.download(from: url, delegate: delegate)
        }
        try Task.checkCancellation()
        progress("Loading Parakeet · once per app launch")
        let configurationML = MLModelConfiguration(); configurationML.computeUnits = .cpuAndNeuralEngine
        let loaded = UnifiedAsrManager(configuration: configurationML, encoderPrecision: .int8)
        try await loaded.loadModels(from: root)
        try Task.checkCancellation()
        manager = loaded
    }
    func transcribe(_ audio: URL) async throws -> String {
        guard let manager else { throw LocalFailure.message("Local dictation is not ready. Start the remote or retry transcription from History.") }
        try Task.checkCancellation()
        let samples = try AudioConverter().resampleAudioFile(audio)
        guard !samples.isEmpty, samples.count <= 16_000 * 301 else { throw LocalFailure.message("Recording is empty or exceeds the five-minute limit.") }
        let result = try await manager.transcribeWithTimings(samples)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
