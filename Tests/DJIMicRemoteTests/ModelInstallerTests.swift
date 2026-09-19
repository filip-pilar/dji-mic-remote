import XCTest
@testable import DJIMicRemote

final class ModelInstallerTests: XCTestCase {
    var directory: URL!
    var manifest: ModelManifest!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("reference")
        try Data("verified weights".utf8).write(to: file)
        manifest = ModelManifest(repository: "fixture/model", revision: String(repeating: "a", count: 40),
                                 files: [.init(path: "encoder/weights.bin", bytes: 16, sha256: try ModelManifest.digest(file))])
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func downloaded(_ url: URL, text: String = "verified weights", code: Int = 200) throws -> (URL, URLResponse) {
        let file = directory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: file)
        return (file, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
    func testPinnedDownloadAndVerifiedReuse() async throws {
        var requests = 0
        try await ModelInstaller.install(manifest, in: directory, allowDownload: true, progress: { _ in }) { url, _, _ in
            requests += 1
            XCTAssertEqual(url.path, "/fixture/model/resolve/" + String(repeating: "a", count: 40) + "/encoder/weights.bin")
            return try self.downloaded(url)
        }
        XCTAssertEqual(requests, 1)
        try await ModelInstaller.install(manifest, in: directory, allowDownload: true, progress: { _ in }) { _, _, _ in
            XCTFail("Verified assets must be reused without network")
            throw LocalFailure.message("Unexpected download")
        }
    }
    func testCorruptionAndHTTPFailureNeverInstall() async throws {
        for badStatus in [false, true] {
            do {
                try await ModelInstaller.install(manifest, in: directory, allowDownload: true, progress: { _ in }) { url, _, _ in
                    try self.downloaded(url, text: badStatus ? "verified weights" : "tampered weights", code: badStatus ? 500 : 200)
                }
                XCTFail("Invalid response must fail")
            } catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("encoder/weights.bin").path))
        }
    }
    func testDamagedBundledAssetsNeverDownload() async throws {
        do {
            try await ModelInstaller.install(manifest, in: directory, allowDownload: false, progress: { _ in }) { _, _, _ in
                XCTFail("Bundled model must fail closed")
                throw LocalFailure.message("Unexpected network")
            }
            XCTFail("Missing bundled model must fail")
        } catch {}
    }
    func testCancelledDownloadDoesNotInstall() async throws {
        let task = Task {
            try await ModelInstaller.install(manifest, in: directory, allowDownload: true, progress: { _ in }) { url, _, _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return try self.downloaded(url)
            }
        }
        do { try await task.value; XCTFail("Cancellation must propagate") } catch is CancellationError {} catch { XCTFail("\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("encoder/weights.bin").path))
    }
}
