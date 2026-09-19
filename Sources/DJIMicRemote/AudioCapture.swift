import AVFoundation
import CoreAudio
import CoreMedia
import OSLog

struct AudioInput: Equatable {
    // Capture and saved selection use the persistent UID, not the transient
    // Core Audio object ID used only while enumerating devices below.
    let uid: String
    let name: String
    static func available() -> [Self] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
            func string(_ selector: AudioObjectPropertySelector) -> String? {
                var property = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
                var value: Unmanaged<CFString>?
                var length = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                guard AudioObjectGetPropertyData(id, &property, 0, nil, &length, &value) == noErr else { return nil }
                return value?.takeRetainedValue() as String?
            }
            guard let uid = string(kAudioDevicePropertyDeviceUID), let name = string(kAudioObjectPropertyName) else { return nil }
            return Self(uid: uid, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

protocol AudioRecording: AnyObject {
    var onInterruption: ((String) -> Void)? { get set }
    func start(to url: URL, input: AudioInput) throws
    func stop() -> Double
}

/// One recording's main-thread callbacks. Late events cannot interrupt its successor.
final class CaptureCallbacks {
    private var active = true
    private let onInterruption: (String) -> Void
    init(onInterruption: @escaping (String) -> Void) { self.onInterruption = onInterruption }
    func post(_ reason: String) {
        DispatchQueue.main.async { [weak self] in self?.interrupt(reason) }
    }
    func interrupt(_ reason: String) {
        guard active else { return }
        active = false; onInterruption(reason)
    }
    func stop() { active = false }
}

/// All sample delivery and file access are serialized on the sample queue.
/// The first actual buffer determines the format, not a device's startup format.
final class CapturedAudioFile: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let url: URL
    private let onFailure: (String) -> Void
    private var file: AVAudioFile?
    private var frames: AVAudioFramePosition = 0
    private var rate: Double = 1
    private var closed = false
    private var failed = false
    var duration: Double { Double(frames) / rate }

    init(url: URL, onFailure: @escaping (String) -> Void) {
        self.url = url; self.onFailure = onFailure
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        receive(sampleBuffer)
    }
    func receive(_ sample: CMSampleBuffer) {
        guard !closed, !failed else { return }
        do { try append(sample) }
        catch {
            failed = true
            onFailure(error.localizedDescription)
        }
    }
    private func append(_ sample: CMSampleBuffer) throws {
        let count = CMSampleBufferGetNumSamples(sample)
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample), count > 0, count <= Int(Int32.max),
              let description = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio,
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              stream.pointee.mFormatID == kAudioFormatLinearPCM,
              stream.pointee.mSampleRate > 0, stream.pointee.mChannelsPerFrame > 0 else {
            throw LocalFailure.message("Microphone returned invalid audio. Recording saved in History.")
        }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        guard format.commonFormat != .otherFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
            throw LocalFailure.message("Microphone returned invalid audio. Recording saved in History.")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else {
            throw LocalFailure.message("Microphone audio could not be read. Recording saved in History.")
        }
        if file == nil {
            do {
                let created = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                file = created; rate = format.sampleRate
            } catch { throw LocalFailure.message("Recording stopped: audio could not be saved. Check free disk space.") }
        }
        guard let file, file.processingFormat.isEqual(format) else {
            throw LocalFailure.message("Microphone audio format changed. Recording saved in History; start a new recording.")
        }
        do { try file.write(from: buffer) }
        catch { throw LocalFailure.message("Recording stopped: audio could not be saved. Check free disk space.") }
        frames += AVAudioFramePosition(buffer.frameLength)
    }
    @discardableResult func close() -> Double {
        closed = true; file = nil // Finalize before recognition reads the file.
        return duration
    }
}

final class AudioCapture: AudioRecording {
    var onInterruption: ((String) -> Void)?
    private let captureQueue = DispatchQueue(label: "com.phil.dji-mic-remote.capture", qos: .userInitiated)
    private let sampleQueue = DispatchQueue(label: "com.phil.dji-mic-remote.samples", qos: .userInitiated)
    private var capture: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var writer: CapturedAudioFile?
    private var observers: [NSObjectProtocol] = []
    private var callbacks: CaptureCallbacks?
    private var timer: Timer?
    private var firstAudioTimer: Timer?
    private static let logger = Logger(subsystem: "com.phil.dji-mic-remote", category: "AudioCapture")

    func start(to url: URL, input: AudioInput) throws {
        guard capture == nil else { throw LocalFailure.message("A recording is already active.") }
        let callbacks = CaptureCallbacks { [weak self] reason in
            Self.logger.error("Recording interrupted: \(reason, privacy: .public)")
            self?.onInterruption?(reason)
        }
        self.callbacks = callbacks
        do {
            try captureQueue.sync {
                // Resolve the saved UID directly. Never create a default-input engine
                // or mutate its I/O audio unit; that can activate unrelated devices.
                guard let device = AVCaptureDevice(uniqueID: input.uid), device.isConnected, device.hasMediaType(.audio) else {
                    throw LocalFailure.message("The selected microphone is disconnected. Reconnect it and choose it again.")
                }
                let source = try AVCaptureDeviceInput(device: device)
                let capture = AVCaptureSession()
                let output = AVCaptureAudioDataOutput()
                output.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false]
                let writer = CapturedAudioFile(url: url) { [weak callbacks] reason in callbacks?.post(reason) }
                self.capture = capture; self.output = output; self.writer = writer
                try configure(capture, source: source, output: output)
                output.setSampleBufferDelegate(writer, queue: sampleQueue)
                observe(AVCaptureSession.runtimeErrorNotification, object: capture, callbacks: callbacks,
                        reason: "Microphone capture failed. Recording saved in History; reconnect it and try again.")
                observe(AVCaptureSession.wasInterruptedNotification, object: capture, callbacks: callbacks,
                        reason: "Microphone capture was interrupted. Recording saved in History.")
                observe(AVCaptureSession.didStopRunningNotification, object: capture, callbacks: callbacks,
                        reason: "Microphone capture stopped. Recording saved in History.")
                observe(AVCaptureDevice.wasDisconnectedNotification, object: device, callbacks: callbacks,
                        reason: "Microphone disconnected. Recording saved in History.")
                capture.startRunning()
                guard capture.isRunning else { throw LocalFailure.message("Could not start the selected microphone. Check its connection and Microphone permission.") }
                Self.logger.info("Started recording from the explicitly selected microphone")
            }
        } catch { _ = stop(); throw error }
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: false) { [weak callbacks] _ in
            callbacks?.interrupt("Five-minute limit reached. Recording saved; transcribe it from History.")
        }
        firstAudioTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self, weak callbacks] _ in
            guard let self, self.sampleQueue.sync(execute: { (self.writer?.duration ?? 0) == 0 }) else { return }
            callbacks?.interrupt("No audio reached the app. Check the selected microphone and try again.")
        }
    }
    private func configure(_ capture: AVCaptureSession, source: AVCaptureDeviceInput, output: AVCaptureAudioDataOutput) throws {
        capture.beginConfiguration()
        defer { capture.commitConfiguration() }
        guard capture.canAddInput(source) else { throw LocalFailure.message("The selected microphone cannot be opened.") }
        capture.addInput(source)
        guard capture.canAddOutput(output) else { throw LocalFailure.message("Microphone recording could not be configured.") }
        capture.addOutput(output)
    }
    private func observe(_ name: Notification.Name, object: AnyObject, callbacks: CaptureCallbacks, reason: String) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak callbacks] _ in
            // Never tear down capture from a framework's notification callback.
            callbacks?.post(reason)
        })
    }
    @discardableResult func stop() -> Double {
        callbacks?.stop(); callbacks = nil
        timer?.invalidate(); timer = nil
        firstAudioTimer?.invalidate(); firstAudioTimer = nil
        return captureQueue.sync {
            observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
            output?.setSampleBufferDelegate(nil, queue: nil)
            capture?.stopRunning() // Synchronous: finish hardware shutdown before releasing it.
            let duration = sampleQueue.sync { writer?.close() ?? 0 }
            output = nil; writer = nil; capture = nil
            return duration
        }
    }
    deinit { stop() }
}
