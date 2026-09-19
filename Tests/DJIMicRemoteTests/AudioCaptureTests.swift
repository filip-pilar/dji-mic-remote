import XCTest
import AVFoundation
import CoreMedia
@testable import DJIMicRemote

final class AudioCaptureTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private var url: URL { directory.appendingPathComponent("fixture.caf") }

    /// Actual Core Media PCM buffers exercise the same copy/file path as the mic,
    /// without opening any device. Different channels carry different values.
    private func sample(rate: Double = 16_000, channels: AVAudioChannelCount = 1,
                        interleaved: Bool = true, frames: AVAudioFrameCount = 160) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        let data = try XCTUnwrap(pcm.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[interleaved ? 0 : channel][interleaved ? frame * Int(channels) + channel : frame] = Float(channel + 1) / 4
            }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format.formatDescription,
            sampleCount: Int(frames), sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result), noErr)
        let sample = try XCTUnwrap(result)
        XCTAssertEqual(CMSampleBufferSetDataBufferFromAudioBufferList(sample, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: pcm.audioBufferList), noErr)
        XCTAssertEqual(CMSampleBufferSetDataReady(sample), noErr)
        return sample
    }

    func testActualPCMIsSavedAndFinalizedWithPrivatePermissions() throws {
        for interleaved in [true, false] {
            let fileURL = directory.appendingPathComponent("\(interleaved).caf")
            var errors: [String] = []
            let writer = CapturedAudioFile(url: fileURL) { errors.append($0) }
            // The first buffer can have the device's negotiated format.
            writer.receive(try sample(rate: 48_000, channels: 2, interleaved: interleaved, frames: 480))
            writer.receive(try sample(rate: 48_000, channels: 2, interleaved: interleaved, frames: 480))
            XCTAssertEqual(writer.close(), 0.02, accuracy: 0.00001)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
            let file = try AVAudioFile(forReading: fileURL)
            XCTAssertEqual(file.length, 960); XCTAssertEqual(file.processingFormat.channelCount, 2)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 960))
            try file.read(into: buffer)
            XCTAssertEqual(buffer.floatChannelData?[0][0], 0.25)
            XCTAssertEqual(buffer.floatChannelData?[1][959], 0.5)
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }
    func testMonoDictationFormatProducesReadableAudio() throws {
        let writer = CapturedAudioFile(url: url) { XCTFail($0) }
        writer.receive(try sample())
        XCTAssertEqual(writer.close(), 0.01, accuracy: 0.00001)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
    }
    func testFormatChangePreservesEarlierAudioAndFailsOnce() throws {
        var errors: [String] = []
        let writer = CapturedAudioFile(url: url) { errors.append($0) }
        writer.receive(try sample())
        writer.receive(try sample(rate: 48_000))
        writer.receive(try sample())
        XCTAssertEqual(writer.close(), 0.01, accuracy: 0.00001)
        XCTAssertEqual(errors.count, 1); XCTAssertTrue(errors.first?.contains("format changed") == true)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
    }
    func testLateSamplesCannotReopenClosedFileOrReachNextRecording() throws {
        let old = CapturedAudioFile(url: url) { XCTFail($0) }
        old.receive(try sample()); old.close()
        let nextURL = directory.appendingPathComponent("next.caf")
        let next = CapturedAudioFile(url: nextURL) { XCTFail($0) }
        old.receive(try sample()); next.receive(try sample(frames: 320))
        XCTAssertEqual(old.close(), 0.01, accuracy: 0.00001)
        XCTAssertEqual(next.close(), 0.02, accuracy: 0.00001)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 160)
        XCTAssertEqual(try AVAudioFile(forReading: nextURL).length, 320)
    }
    func testInvalidSampleFailsOnceWithoutCreatingAudio() throws {
        var errors: [String] = []
        let writer = CapturedAudioFile(url: url) { errors.append($0) }
        let invalid = try sample()
        XCTAssertEqual(CMSampleBufferInvalidate(invalid), noErr)
        writer.receive(invalid); writer.receive(invalid)
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(writer.close(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testFileCreationFailureIsReportedOnce() throws {
        var errors: [String] = []
        let writer = CapturedAudioFile(url: directory.appendingPathComponent("missing/fixture.caf")) { errors.append($0) }
        writer.receive(try sample()); writer.receive(try sample())
        XCTAssertEqual(errors.count, 1); XCTAssertEqual(writer.close(), 0)
    }
    func testNoBuffersDoesNotClaimRecoverableAudio() {
        let writer = CapturedAudioFile(url: url) { XCTFail($0) }
        XCTAssertEqual(writer.close(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    @MainActor func testQueuedInterruptionsCannotStopNextRecording() async {
        var errors: [String] = []
        let old = CaptureCallbacks { errors.append($0) }
        old.post("Old device removal"); old.post("Old write error"); old.stop()
        let next = CaptureCallbacks { errors.append($0) }
        let drained = expectation(description: "Callbacks drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 1)
        XCTAssertTrue(errors.isEmpty)
        next.interrupt("Current interruption"); next.interrupt("Duplicate")
        XCTAssertEqual(errors, ["Current interruption"])
    }
}
