import AppKit
import ApplicationServices

struct FieldSnapshot {
    let text: String
    let selection: CFRange
}

/// Optional full-value and caret read-back. Only this evidence can label an
/// insertion verified; ordinary cross-app paste does not depend on it.
struct InsertionProof {
    let text: String
    let caret: Int
    init?(before: FieldSnapshot?, inserted: String) {
        guard let before, !inserted.isEmpty else { return nil }
        let value = before.text as NSString
        let range = before.selection
        guard range.location >= 0, range.length >= 0, range.location <= value.length,
              range.length <= value.length - range.location else { return nil }
        let expected = value.replacingCharacters(in: NSRange(location: range.location, length: range.length), with: inserted)
        guard expected != before.text else { return nil }
        text = expected; caret = range.location + (inserted as NSString).length
    }
    func matches(_ snapshot: FieldSnapshot?) -> Bool {
        guard let snapshot else { return false }
        return snapshot.text == text && snapshot.selection.location == caret && snapshot.selection.length == 0
    }
}

struct AutoSend {
    var current: () -> TextTargetCapture = TextDelivery.inspect
    var read: (TextTarget) -> FieldSnapshot? = snapshot
    var held: () -> CGEventFlags = { PasteKeystroke.physicalModifiers() }
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 200_000_000) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var pressReturn: () -> Bool

    static func snapshot(_ target: TextTarget) -> FieldSnapshot? {
        guard !target.opaque else { return nil }
        guard let text = TextDelivery.attribute(target.element, kAXValueAttribute) as? String,
              let value = TextDelivery.attribute(target.element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return FieldSnapshot(text: text, selection: range)
    }
    @MainActor func finish(target: TextTarget, proof: InsertionProof?, clipboardConsumed: Bool = false,
                           isCurrent: () -> Bool) async -> TextDeliveryResult {
        func skipped(_ reason: String) -> TextDeliveryResult {
            .init("Paste sent · Auto-send skipped: \(reason). Transcript saved in History.",
                  needsRecovery: true, pasteState: .autoSendSkipped)
        }
        guard proof != nil || clipboardConsumed else { return skipped("the paste was not consumed") }
        let deadline = now() + 3
        var pendingReason = "the paste was not consumed or verified"
        var anchor: TextTarget?
        var anchorSnapshot: FieldSnapshot?
        attempts: for _ in 0..<15 {
            do { try await pause(); try Task.checkCancellation() }
            catch { return skipped("cancelled") }
            guard isCurrent() else { return skipped("cancelled") }
            if now() > deadline { break }
            let focused: TextTarget
            switch current().focus(matching: anchor ?? target, includingSelection: anchor != nil) {
            case .ready(let value): focused = value; pendingReason = "the paste was not consumed or verified"
            case .unavailable(let reason): pendingReason = reason; continue
            case .changed(let reason): return skipped(reason)
            }
            guard held().intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
                return skipped("keyboard modifiers are held")
            }
            let snapshot = read(focused)
            let verified = proof?.matches(snapshot) == true
            if verified || clipboardConsumed {
                // Keep the first observed post-paste caret/text across retries.
                // A temporary AX failure must not reset the baseline and hide a
                // real edit or cursor move that occurred while waiting.
                if let anchorSnapshot, let snapshot, !Self.same(anchorSnapshot, snapshot) {
                    return skipped("the text or cursor changed")
                }
                if anchor == nil { anchor = focused; anchorSnapshot = snapshot }
                // Revalidate immediately before posting, after the potentially blocking AX read.
                guard isCurrent(), !Task.isCancelled else { return skipped("cancelled") }
                let final: TextTarget
                switch current().focus(matching: focused, includingSelection: true) {
                case .ready(let value): final = value
                case .unavailable(let reason): pendingReason = reason; continue attempts
                case .changed(let reason): return skipped(reason)
                }
                let finalSnapshot = read(final)
                if let snapshot, let finalSnapshot, !Self.same(snapshot, finalSnapshot) {
                    return skipped("the text or cursor changed")
                }
                // The final AX read can also block. Do not send after switching
                // apps/windows or moving the exposed caret while it was running.
                guard isCurrent(), !Task.isCancelled else { return skipped("cancelled") }
                switch current().focus(matching: final, includingSelection: true) {
                case .ready: break
                case .unavailable(let reason): pendingReason = reason; continue attempts
                case .changed(let reason): return skipped(reason)
                }
                guard isCurrent(), !Task.isCancelled else { return skipped("cancelled") }
                guard held().intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else {
                    return skipped("keyboard modifiers are held")
                }
                guard pressReturn() else { return skipped("Return could not be sent") }
                let finalVerified = proof?.matches(finalSnapshot) == true
                return .init(finalVerified ? "Text inserted · Return sent to \(target.name)."
                    : "Paste and Return sent to \(target.name) · saved in History.",
                    pasteState: finalVerified ? .verified : .sent)
            }
        }
        return skipped(pendingReason)
    }
    private static func same(_ lhs: FieldSnapshot, _ rhs: FieldSnapshot) -> Bool {
        lhs.text == rhs.text && lhs.selection.location == rhs.selection.location && lhs.selection.length == rhs.selection.length
    }
}
