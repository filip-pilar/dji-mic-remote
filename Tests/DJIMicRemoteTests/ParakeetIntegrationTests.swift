import XCTest
import AVFoundation
@testable import DJIMicRemote

final class ParakeetIntegrationTests: XCTestCase {
    func testRealModelWithExplicitAudioFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let models = environment["DJI_MODEL_SMOKE_DIR"], let audio = environment["DJI_MODEL_SMOKE_AUDIO"] else {
            throw XCTSkip("Set DJI_MODEL_SMOKE_DIR and DJI_MODEL_SMOKE_AUDIO for the explicit local inference check.")
        }
        // Feed the supplied speech through the actual capture-buffer writer first.
        // This validates the recorder's CAF output with Parakeet, without a mic.
        let recorded = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: recorded) }
        let writer = CapturedAudioFile(url: recorded) { XCTFail($0) }
        let source = try AVAudioFile(forReading: URL(fileURLWithPath: audio))
        while source.framePosition < source.length {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: 4096))
            try source.read(into: pcm)
            guard pcm.frameLength > 0 else { break }
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(pcm.format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
                makeDataReadyCallback: nil, refcon: nil, formatDescription: pcm.format.formatDescription,
                sampleCount: Int(pcm.frameLength), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample), noErr)
            let buffer = try XCTUnwrap(sample)
            XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(buffer, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
            XCTAssertEqual(CMSampleBufferSetDataReady(buffer), noErr)
            writer.receive(buffer)
        }
        XCTAssertGreaterThan(writer.close(), 0)
        let engine = ParakeetEngine(bundledDirectory: URL(fileURLWithPath: models))
        let start = Date()
        try await engine.prepare { _ in }
        let loaded = Date()
        let text = try await engine.transcribe(recorded)
        print("Model fixture: load \(loaded.timeIntervalSince(start))s; recognition \(Date().timeIntervalSince(loaded))s; text: \(text)")
        XCTAssertTrue(text.lowercased().contains("microphone"))
        XCTAssertTrue(text.lowercased().contains("recording"))
    }
}
