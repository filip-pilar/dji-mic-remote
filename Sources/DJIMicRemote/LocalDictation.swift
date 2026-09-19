import Foundation

final class LocalDictation {
    var onChange: (() -> Void)?
    /// Durable, nonempty transcript completion, never an assertion of insertion.
    var onTranscriptSaved: (() -> Void)?
    var listInputs: () -> [AudioInput]
    let history: LocalHistory?
    let recognizer: LocalRecognizing
    let recorder: AudioRecording
    var captureTarget: () -> TextTargetCapture = TextDelivery.inspect
    var prepareTarget: () -> Void = TextDelivery.prepareFocusedApplication
    var restoreTarget: (TextTarget) async -> Bool = { await EditorReturn().restore($0) }
    var deliver: (String, TextTarget?, Bool) async -> TextDeliveryResult
    private(set) var autoSend: Bool
    private let delivery = TextDelivery()
    private(set) var ready = false
    private(set) var working = false
    private(set) var cancelling = false
    private(set) var delivering = false
    private(set) var recordingID: UUID?
    private(set) var activeID: UUID?
    private(set) var message = "Start the remote to begin local dictation."
    private(set) var inputs: [AudioInput] = []
    var inputUID = UserDefaults.standard.string(forKey: "localInputUID")
    private var target: TextTarget?
    private var targetCapture = TextTargetCapture()
    private var captureTask: Task<Void, Never>?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var unsaved: Transcript?
    private var maintenanceTimer: Timer?
    private var recordingTimer: Timer?
    private var recordingStarted: Date?
    private(set) var pastePending = false
    var hasUnsavedHistory: Bool { unsaved != nil }
    var busy: Bool { working || recordingID != nil || pastePending }
    var input: AudioInput? { inputs.first { $0.uid == inputUID } }
    var entries: [Transcript] { history?.entries ?? [] }

    init(history: LocalHistory? = nil, recognizer: LocalRecognizing = ParakeetEngine(), recorder: AudioRecording = AudioCapture(), inputs: @escaping () -> [AudioInput] = AudioInput.available, autoSend: Bool = UserDefaults.standard.bool(forKey: "localAutoSend")) {
        self.recognizer = recognizer; self.recorder = recorder; self.listInputs = inputs; self.autoSend = autoSend
        do { self.history = try history ?? LocalHistory() }
        catch { self.history = nil; message = "History could not be opened: \(error.localizedDescription)" }
        let delivery = self.delivery
        self.deliver = { await delivery.insert($0, into: $1, autoSend: $2) }
        self.recorder.onInterruption = { [weak self] reason in self?.interrupt(reason) }
        refreshInputs()
        do { try self.history?.expireAudio() }
        catch { message = "Old recordings could not be removed: \(error.localizedDescription)" }
        if let warning = self.history?.warning { message = warning }
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            guard let self, !self.busy else { return }
            do { try self.history?.expireAudio() }
            catch { self.message = "Audio cleanup failed: \(error.localizedDescription)"; self.onChange?() }
        }
    }
    func refreshInputs() {
        inputs = listInputs()
        if inputUID == nil, let dji = inputs.first(where: { $0.name.localizedCaseInsensitiveContains("Wireless Mic") || $0.name.localizedCaseInsensitiveContains("DJI") }) {
            inputUID = dji.uid
            UserDefaults.standard.set(dji.uid, forKey: "localInputUID")
        }
    }
    func setAutoSend(_ enabled: Bool) {
        guard !busy else { return }
        autoSend = enabled
        UserDefaults.standard.set(enabled, forKey: "localAutoSend")
        onChange?()
    }
    func selectInput(_ uid: String?) {
        interrupt("Microphone changed. Recording saved in History.")
        inputUID = uid; UserDefaults.standard.set(uid, forKey: "localInputUID")
        onChange?()
    }
    func prepare(completion: ((Bool) -> Void)? = nil) {
        #if !arch(arm64)
        message = "Local Parakeet requires Apple Silicon. Wispr Flow remains available."; onChange?(); completion?(false); return
        #endif
        guard !busy, history != nil else { completion?(false); return }
        guard !ready else { completion?(true); return }
        cancelling = false; working = true; message = "Preparing local dictation…"; onChange?()
        generation += 1; let token = generation
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var succeeded = false
            defer { self.working = false; self.cancelling = false; self.task = nil; self.onChange?(); completion?(succeeded && token == self.generation) }
            do {
                try await self.recognizer.prepare { [weak self] progress in
                    DispatchQueue.main.async {
                        guard let self, self.generation == token, self.working else { return }
                        self.message = progress; self.onChange?()
                    }
                }
                guard token == self.generation else { return }
                self.ready = true; succeeded = true; self.refreshInputs()
                self.message = "Parakeet is ready · English · audio stays on this Mac."
            } catch {
                guard token == self.generation else { return }
                self.message = "Setup failed: \(error.localizedDescription)"
            }
        }
    }
    func press() {
        if recordingID != nil { finish(); return }
        guard unsaved == nil else { message = "Open History and Retry saving before recording again."; onChange?(); return }
        guard ready, !busy, let history else { return }
        refreshInputs()
        guard let input else { message = "Choose a connected microphone first."; onChange?(); return }
        var entry = Transcript(id: UUID(), created: Date())
        prepareTarget()
        targetCapture = captureTarget(); target = targetCapture.target; entry.targetName = target?.name
        entry.modelRevision = (try? ModelManifest.bundled())?.revision
        do {
            try history.expireAudio()
            try history.save(entry)
            try recorder.start(to: history.audioURL(entry.id), input: input)
            recordingID = entry.id; recordingStarted = Date()
            updateRecordingMessage(seconds: 0)
            retryTargetCapture(for: entry.id)
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let start = self.recordingStarted else { return }
                let seconds = Int(Date().timeIntervalSince(start))
                self.updateRecordingMessage(seconds: seconds)
                self.onChange?()
            }
        } catch {
            _ = recorder.stop()
            entry.state = .failed; entry.message = error.localizedDescription
            persist(entry)
            message = "Could not record: \(error.localizedDescription)"
        }
        onChange?()
    }
    private func updateRecordingMessage(seconds: Int) {
        message = String(format: "Recording · %d:%02d", seconds / 60, seconds % 60)
            + (target == nil ? " · text field not detected; saved to History" : " · press again to finish")
    }
    private func retryTargetCapture(for id: UUID) {
        guard target == nil, let pid = targetCapture.appPID,
              targetCapture.failure == .unavailable || targetCapture.failure == .notEditable else { return }
        captureTask = Task { @MainActor [weak self] in
            // Some web editors expose their focused field shortly after AX is
            // enabled. Audio is already recording; never block or drop speech.
            for _ in 0..<6 {
                do { try await Task.sleep(nanoseconds: 150_000_000) } catch { return }
                guard let self, self.recordingID == id, !Task.isCancelled else { return }
                let capture = self.captureTarget()
                guard capture.appPID == pid else { return }
                self.targetCapture = capture
                if let target = capture.target {
                    self.target = target
                    if var entry = self.history?.entry(id) { entry.targetName = target.name; _ = self.persist(entry) }
                    self.updateRecordingMessage(seconds: Int(Date().timeIntervalSince(self.recordingStarted ?? Date())))
                    self.onChange?(); return
                }
                if capture.failure == .secure || capture.failure == .ownApp { return }
            }
        }
    }
    func finish(insert: Bool = true) {
        guard let id = recordingID, var entry = history?.entry(id) else { return }
        captureTask?.cancel(); captureTask = nil
        entry.duration = recorder.stop(); recordingID = nil; stopTimer()
        guard entry.duration > 0 else {
            entry.state = .failed; entry.message = "No audio reached the app. Check the selected microphone and try again."
            if persist(entry) { message = entry.message }
            target = nil; onChange?(); return
        }
        entry.state = .interrupted; entry.message = "Recording saved. Ready to transcribe."
        guard persist(entry) else { onChange?(); return }
        recognize(entry, insert: insert, target: target, captureIssue: target == nil ? targetCapture.recoveryMessage : nil)
    }
    private func stopTimer() { recordingTimer?.invalidate(); recordingTimer = nil; recordingStarted = nil }
    @discardableResult private func persist(_ entry: Transcript) -> Bool {
        do { try history?.save(entry); if unsaved?.id == entry.id { unsaved = nil }; return true }
        catch { unsaved = entry; message = "Could not save history. Free disk space, then Retry saving. Text remains available to copy."; return false }
    }
    func retry(_ id: UUID) {
        guard !busy, let history else { return }
        if let unsaved, unsaved.id == id {
            if persist(unsaved) { message = "History saved. You can copy, paste, or transcribe again." }
            onChange?(); return
        }
        guard unsaved == nil else { message = "Retry saving the unsaved entry first."; onChange?(); return }
        guard ready else {
            prepare { [weak self] success in if success { self?.retry(id) } }
            return
        }
        guard let entry = history.entry(id), history.hasAudio(id) else { return }
        recognize(entry, insert: false, target: nil)
    }
    func needsSaving(_ id: UUID) -> Bool { unsaved?.id == id }
    private func recognize(_ original: Transcript, insert: Bool, target: TextTarget?, captureIssue: String? = nil) {
        guard let history else { return }
        var entry = original; entry.state = .transcribing; entry.message = "Transcribing…"
        guard persist(entry) else { onChange?(); return }
        cancelling = false; working = true; activeID = entry.id; message = "Transcribing · recording saved"
        generation += 1; let token = generation; onChange?()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var completed = false
            defer {
                self.working = false; self.delivering = false; self.cancelling = false; self.activeID = nil; self.task = nil
                self.onChange?()
                if completed { self.onTranscriptSaved?() }
            }
            do {
                let result = try await self.recognizer.transcribe(history.audioURL(entry.id))
                guard self.generation == token else { return }
                if !entry.text.isEmpty && entry.text != result { entry.previousTexts.append(entry.text) }
                entry.text = result; entry.state = .ready
                // A retry produces new text without delivering it. Do not carry
                // a prior paste/Auto-send outcome onto the new transcript.
                entry.needsInsertionRecovery = false; entry.pasteState = nil
                entry.message = result.isEmpty ? "No speech recognized. Play the recording or try again." : "Saved · ready to copy or paste."
                guard self.persist(entry) else { return }
                // Durability precedes delivery. Retry never inserts automatically.
                if insert && !result.isEmpty {
                    let delivery: TextDeliveryResult
                    if let captureIssue { delivery = TextDeliveryResult(captureIssue, needsRecovery: true) }
                    else {
                        self.delivering = true; self.message = "Pasting to \(target?.name ?? "your editor")…"; self.onChange?()
                        delivery = await self.deliver(result, target, self.autoSend)
                    }
                    entry.message = delivery.message; entry.needsInsertionRecovery = delivery.needsRecovery
                    entry.pasteState = delivery.pasteState
                    guard self.generation == token else { return }
                    guard self.persist(entry) else { return }
                }
                self.message = entry.message
                completed = !entry.text.isEmpty && entry.needsInsertionRecovery != true
            } catch {
                guard self.generation == token else { return }
                entry.state = .failed; entry.message = "Transcription failed: \(error.localizedDescription)"
                if self.persist(entry) { self.message = "Transcription failed · recording saved in History." }
            }
        }
    }
    func interrupt(_ reason: String) {
        let wasPasting = pastePending
        generation += 1; task?.cancel(); cancelling = working; cancelPaste(); delivery.cancel()
        captureTask?.cancel(); captureTask = nil
        if !wasPasting, let id = recordingID ?? activeID, var entry = history?.entry(id) {
            if recordingID != nil { entry.duration = recorder.stop() }
            if entry.state == .ready {
                entry.message = "Delivery cancelled · transcript saved."; entry.needsInsertionRecovery = true
            } else { entry.state = .interrupted; entry.message = reason }
            if persist(entry) { message = reason }
        } else if working { message = "Stopping… You can retry when this operation finishes." }
        recordingID = nil; target = nil; stopTimer(); onChange?()
    }
    func pasteAgain(_ id: UUID, text: String? = nil, into destination: TextTarget?) {
        guard !busy, var entry = history?.entry(id), !entry.text.isEmpty else { return }
        guard let destination else {
            message = "Choose a text field before opening History, or use Copy."
            onChange?(); return
        }
        working = true; pastePending = true; activeID = id; cancelling = false
        generation += 1; let token = generation
        message = "Pasting to \(destination.name)…"; onChange?()
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var completed = false
            defer {
                self.working = false; self.pastePending = false; self.cancelling = false
                self.activeID = nil; self.task = nil; self.onChange?()
                if completed { self.onTranscriptSaved?() }
            }
            let restored = await self.restoreTarget(destination)
            guard self.generation == token, !Task.isCancelled else { return }
            let result: TextDeliveryResult
            if restored { result = await self.deliver(text ?? entry.text, destination, false) }
            else { result = .init("Saved · the previous editor is unavailable or changed. Use Copy.", needsRecovery: true) }
            guard self.generation == token, !Task.isCancelled else { return }
            entry.message = result.message; entry.needsInsertionRecovery = result.needsRecovery
            entry.pasteState = result.pasteState
            if self.persist(entry) { self.message = entry.message; completed = !result.needsRecovery }
        }
    }
    func cancelPaste() {
        guard pastePending else { return }
        generation += 1; task?.cancel(); delivery.cancel()
        message = "Paste cancelled · transcript saved."; onChange?()
    }
    deinit { maintenanceTimer?.invalidate(); recordingTimer?.invalidate(); task?.cancel(); captureTask?.cancel() }
    func delete(_ id: UUID) {
        guard id != recordingID, id != activeID else { return }
        do { try history?.delete(id); if unsaved?.id == id { unsaved = nil }; message = "Recording and transcript deleted." }
        catch { message = "Could not delete: \(error.localizedDescription)" }
        onChange?()
    }
}
