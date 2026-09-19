import XCTest
@testable import DJIMicRemote

final class FakeRecorder: AudioRecording {
    var onInterruption: ((String) -> Void)?
    var stopped = 0
    var duration = 1.5
    func start(to url: URL, input: AudioInput) throws { try Data("fixture audio".utf8).write(to: url) }
    func stop() -> Double { stopped += 1; return duration }
}
final class FakeRecognizer: LocalRecognizing {
    var calls = 0
    var output = "Hello from the microphone."
    var failure: Error?
    var delayed = false
    var continuation: CheckedContinuation<String, Error>?
    @MainActor func prepare(progress: @escaping (String) -> Void) async throws { progress("Fixture ready") }
    @MainActor func transcribe(_ audio: URL) async throws -> String {
        calls += 1
        if delayed { return try await withCheckedThrowingContinuation { continuation = $0 } }
        if let failure { throw failure }
        return output
    }
}

extension XCTestCase {
    @MainActor func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for fixture operation", file: file, line: line)
    }
}
