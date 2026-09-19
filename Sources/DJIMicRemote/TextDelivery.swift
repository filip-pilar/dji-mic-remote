import AppKit
import ApplicationServices
import os
import Carbon.HIToolbox

struct TextTarget {
    let pid: pid_t
    let name: String
    let element: AXUIElement
    let selection: CFTypeRef?
    var window: AXUIElement? = nil
    var opaque = false
}

struct TextTargetCapture {
    enum Failure { case permission, ownApp, unavailable, secure, notEditable }
    var target: TextTarget?
    var appPID: pid_t?
    var failure: Failure?
    var appName: String?
    var window: AXUIElement?

    enum Focus {
        case ready(TextTarget)
        case unavailable(String)
        case changed(String)
    }

    /// A missing AX response is not evidence of a changed destination. Keep
    /// app/window observations even when the field cannot currently be read.
    func focus(matching expected: TextTarget, includingSelection: Bool = false) -> Focus {
        if let pid = appPID ?? target?.pid, pid != expected.pid { return .changed("the active app changed") }
        switch failure {
        case .permission: return .changed("Accessibility access is unavailable")
        case .secure: return .changed("the field is protected")
        case .notEditable: return .changed("the focused control is not editable")
        case .ownApp: return .changed("the active app changed")
        default: break
        }
        if let expectedWindow = expected.window {
            guard let actualWindow = window ?? target?.window else { return .unavailable("the app did not expose its active window") }
            guard CFEqual(expectedWindow, actualWindow) else { return .changed("the active window changed") }
        }
        guard let target else { return .unavailable("the app did not expose its text field") }
        guard CFEqual(expected.element, target.element) else {
            // During a redraw, AX can temporarily return the app/web wrapper
            // instead of its editor. Wait for the captured editor to reappear.
            if target.opaque || expected.opaque { return .unavailable("the app did not expose the original text field") }
            return .changed("the text field changed")
        }
        if includingSelection, let expectedSelection = expected.selection {
            guard let actualSelection = target.selection else { return .unavailable("the app did not expose the text cursor") }
            guard CFEqual(expectedSelection, actualSelection) else { return .changed("the text cursor moved") }
        }
        return .ready(target)
    }
    var recoveryMessage: String {
        switch failure {
        case .permission: return "Saved · Accessibility access is missing. Grant access, then paste from History."
        case .ownApp: return "Saved · the DJI app had focus when recording started. Focus your text field, then paste from History."
        case .secure: return "Saved · password fields cannot receive dictation. Paste into a regular text field from History."
        case .notEditable: return "Saved · no writable text field was focused in \(appName ?? "the app"). Focus your text field, then paste from History."
        default: return "Saved · \(appName ?? "the app") did not expose its text field. Focus the field, then paste from History."
        }
    }
}

struct TextDeliveryResult {
    let message: String
    var needsRecovery = false
    var pasteState: Transcript.PasteState?
    init(_ message: String, needsRecovery: Bool = false, pasteState: Transcript.PasteState? = nil) {
        self.message = message; self.needsRecovery = needsRecovery; self.pasteState = pasteState
    }
}

/// Delivery is best effort. Never mark an event post as confirmed insertion.
final class TextDelivery {
    private static let logger = Logger(subsystem: "com.phil.dji-mic-remote", category: "TextDelivery")
    private let emitter = ShortcutEmitter()
    private var generation = 0
    private var clipboard: ClipboardPaste?
    var current: () -> TextTargetCapture = inspect
    var heldModifiers: () -> CGEventFlags = { PasteKeystroke.physicalModifiers() }
    var read: (TextTarget) -> FieldSnapshot? = AutoSend.snapshot
    var publish: (String) -> ClipboardPaste? = { ClipboardPaste(text: $0) }
    var postPaste: () async -> Bool = { await PasteKeystroke().send() }
    var postReturn: (() -> Bool)?
    var pause: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.3)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    static func isEditable(role: String?, subrole: String?, explicitlyEditable: Bool? = nil) -> Bool {
        guard subrole != kAXSecureTextFieldSubrole else { return false }
        if explicitlyEditable == false { return false }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role ?? "")
            || (explicitlyEditable == true && [kAXGroupRole, "AXWebArea"].contains(role ?? ""))
    }
    static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func prepareFocusedApplication() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        // Electron's documented assistive-technology opt-in. Unsupported apps
        // ignore it. Do not toggle AXEnhancedUserInterface/VoiceOver mode.
        if attribute(application, "AXManualAccessibility") as? Bool != true {
            AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        _ = attribute(application, kAXRoleAttribute)
    }
    static func capture() -> TextTarget? { inspect().target }
    static func inspect() -> TextTargetCapture {
        guard AXIsProcessTrusted() else { return .init(failure: .permission) }
        guard !IsSecureEventInputEnabled() else { return .init(failure: .secure) }
        guard let app = NSWorkspace.shared.frontmostApplication else { return .init(failure: .unavailable) }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else { return .init(appPID: pid, failure: .ownApp) }
        let application = AXUIElementCreateApplication(pid)
        let focused = [element(attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)),
                       element(attribute(application, kAXFocusedUIElementAttribute))].compactMap { $0 }
        let name = app.localizedName ?? "the app"
        var result = resolveFocused(focused, pid: pid, name: name)
        let window = element(attribute(application, kAXFocusedWindowAttribute))
        // Normal Command-V does not require the application to expose its text
        // contents through AX. Keep opaque editors scoped to the same app and
        // window; do not turn known secure/read-only controls into targets.
        if focused.isEmpty, let window {
            result = .init(target: TextTarget(pid: pid, name: name, element: application,
                selection: nil, window: window, opaque: true), appPID: pid)
        } else { result.target?.window = window }
        result.appName = name; result.window = window
        let finalPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard finalPID == pid else { return .init(appPID: finalPID, failure: .unavailable) }
        return result
    }
    static func resolveFocused(_ focused: [AXUIElement], pid: pid_t, name: String,
                               read: (AXUIElement, String) -> CFTypeRef? = attribute,
                               owner: (AXUIElement) -> pid_t? = { value in var pid: pid_t = 0; return AXUIElementGetPid(value, &pid) == .success ? pid : nil }) -> TextTargetCapture {
        for candidate in focused {
            let attempt = resolve(candidate, pid: pid, name: name, read: read, owner: owner)
            // A system-wide AX proxy can belong to a different process. Try the
            // foreground application's own explicit focus before declaring loss.
            if attempt.target != nil || attempt.failure != .unavailable { return attempt }
        }
        return .init(appPID: pid, failure: .unavailable, appName: name)
    }
    static func resolve(_ focused: AXUIElement, pid: pid_t, name: String,
                        read: (AXUIElement, String) -> CFTypeRef? = attribute,
                        owner: (AXUIElement) -> pid_t? = { value in var pid: pid_t = 0; return AXUIElementGetPid(value, &pid) == .success ? pid : nil }) -> TextTargetCapture {
        var candidate = focused
        // Follow explicit focus links only. Searching arbitrary descendants could
        // choose a different composer or the selected text of a read-only message.
        for _ in 0..<4 {
            guard owner(candidate) == pid else { return .init(appPID: pid, failure: .unavailable) }
            let subrole = read(candidate, kAXSubroleAttribute) as? String
            if subrole == kAXSecureTextFieldSubrole || read(candidate, "AXProtectedContent") as? Bool == true {
                return .init(appPID: pid, failure: .secure)
            }
            let selection = read(candidate, kAXSelectedTextRangeAttribute)
            let role = read(candidate, kAXRoleAttribute) as? String
            let editable = read(candidate, "AXEditable") as? Bool
            let enabled = read(candidate, kAXEnabledAttribute) as? Bool
            if enabled != false, isEditable(role: role, subrole: subrole, explicitlyEditable: editable) {
                return .init(target: TextTarget(pid: pid, name: name, element: candidate, selection: selection), appPID: pid)
            }
            guard let next = element(read(candidate, kAXFocusedUIElementAttribute)), !CFEqual(next, candidate) else {
                guard let role else { return .init(appPID: pid, failure: .unavailable) }
                if [kAXGroupRole, "AXWebArea"].contains(role), editable != false, enabled != false {
                    return .init(target: TextTarget(pid: pid, name: name, element: candidate,
                        selection: nil, opaque: true), appPID: pid)
                }
                // Diagnostic metadata only: never log field values or transcripts.
                logger.info("No editable target in \(name, privacy: .public): role=\(role, privacy: .public), editable=\(String(describing: editable), privacy: .public), enabled=\(String(describing: enabled), privacy: .public)")
                return .init(appPID: pid, failure: .notEditable)
            }
            candidate = next
        }
        return .init(appPID: pid, failure: .unavailable)
    }
    static func matches(_ target: TextTarget, current: TextTarget?) -> Bool {
        guard matchesFocus(target, current: current), let current else { return false }
        if let selection = target.selection {
            guard let now = current.selection, CFEqual(selection, now) else { return false }
        }
        return true
    }
    static func matchesFocus(_ target: TextTarget, current: TextTarget?) -> Bool {
        guard let current, target.pid == current.pid, CFEqual(target.element, current.element) else { return false }
        if let window = target.window {
            guard let currentWindow = current.window, CFEqual(window, currentWindow) else { return false }
        }
        return true
    }
    @MainActor func insert(_ text: String, into target: TextTarget?, autoSend: Bool = false) async -> TextDeliveryResult {
        cancel()
        let token = generation
        guard !text.isEmpty else { return .init("No speech recognized. Replay or retry the recording.") }
        guard let target else { return .init("Saved · choose a text field, then use Copy in History.", needsRecovery: true) }
        func canPaste() -> Bool {
            generation == token && !Task.isCancelled && Self.matches(target, current: current().target)
                && heldModifiers().intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty
        }
        guard canPaste() else { return .init("Saved · the destination or keyboard modifiers changed. Use Copy in History.", needsRecovery: true) }
        let proof = InsertionProof(before: read(target), inserted: text)
        guard let transaction = publish(text) else { return .init("Saved · clipboard unavailable. Use Copy in History.", needsRecovery: true) }
        clipboard = transaction
        defer {
            transaction.finish()
            if generation == token { clipboard = nil }
        }
        do { try await pause(80_000_000) } catch { return .init("Paste cancelled · transcript saved.", needsRecovery: true) }
        // Clipboard publication and AX queries can yield. Recheck immediately
        // before the event pair, and never overwrite a newer user clipboard.
        guard canPaste(), transaction.ownsClipboard else {
            return .init("Saved · destination or clipboard changed before paste. Use Copy in History.", needsRecovery: true)
        }
        let postedAt = now()
        guard await postPaste() else { return .init("Saved · paste could not be sent. Use Copy in History.", needsRecovery: true) }
        var confirmed = false
        var consumed = false
        var restored = false
        var focusFailure: String?
        // Clipboard restoration and editor verification have different clocks.
        // A consumer can read the pasteboard before updating its accessible text.
        // Restore promptly after consumption, but keep checking the editor for
        // the full verification window. Never paste a second time automatically.
        let deadline = postedAt + 3
        for _ in 0..<60 {
            do { try await pause(50_000_000) } catch { break }
            guard generation == token, !Task.isCancelled else { break }
            switch current().focus(matching: target) {
            case .ready(let focused): confirmed = proof?.matches(read(focused)) == true
            case .unavailable: confirmed = false // Retry within the existing paste wait.
            case .changed(let reason): focusFailure = reason
            }
            let readSettled = transaction.readAt.map { $0 >= postedAt && now() - $0 >= 0.35 } ?? false
            consumed = consumed || readSettled
            if !restored && (readSettled || (confirmed && now() - postedAt >= 0.15) || now() >= deadline) {
                transaction.finish(); restored = true
                if generation == token { clipboard = nil }
            }
            if focusFailure != nil || now() >= deadline || (confirmed && restored) { break }
            if !restored && !transaction.ownsClipboard { break }
            if autoSend && consumed && restored { break }
            if proof == nil && restored { break }
        }
        guard generation == token, !Task.isCancelled else { return .init("Paste cancelled · transcript saved.", needsRecovery: true) }
        if autoSend, focusFailure == nil, confirmed || consumed {
            return await finishAutoSend(target, proof: proof, clipboardConsumed: consumed, token: token)
        }
        guard confirmed else {
            let reason = focusFailure ?? "the paste was not consumed or verified"
            Self.logger.notice("Paste posted: target=\(target.name, privacy: .public), readBack=\(reason, privacy: .public), clipboardRead=\(transaction.readAt != nil, privacy: .public)")
            return .init("Paste sent to \(target.name). " + (autoSend ? "Auto-send skipped: \(reason). " : "") + "Transcript saved in History.",
                         needsRecovery: autoSend || focusFailure != nil, pasteState: autoSend ? .autoSendSkipped : .sent)
        }
        if autoSend { return .init("Paste sent · Auto-send skipped: \(focusFailure ?? "the destination could not be checked"). Transcript saved in History.", needsRecovery: true, pasteState: .autoSendSkipped) }
        return .init("Inserted in \(target.name) · verified and saved.", pasteState: .verified)
    }
    @MainActor private func finishAutoSend(_ target: TextTarget, proof: InsertionProof?, clipboardConsumed: Bool, token: Int) async -> TextDeliveryResult {
        let verifier = AutoSend(current: current, read: read, held: heldModifiers, pause: { try await self.pause(200_000_000) }, now: now, pressReturn: { [weak self] in
            guard let self else { return false }
            guard self.heldModifiers().intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty else { return false }
            if let postReturn = self.postReturn { return postReturn() }
            let result = self.emitter.send(Shortcut(key: 36, flags: 0, label: "Return"),
                                           heldFlags: [])
            if case .sent = result { return true }; return false
        })
        let result = await verifier.finish(target: target, proof: proof, clipboardConsumed: clipboardConsumed,
                                           isCurrent: { self.generation == token })
        Self.logger.notice("Auto-send: target=\(target.name, privacy: .public), outcome=\(result.message, privacy: .public)")
        return result
    }
    func cancel() { generation += 1; emitter.release(); clipboard?.finish(); clipboard = nil }
}

/// Explicit recovery returns to the editor captured before our UI opened.
/// It never searches for another field or resets the user's selection.
struct EditorReturn {
    var ownPID = ProcessInfo.processInfo.processIdentifier
    var frontPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var activate: (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activate(options: []) ?? false }
    var current: () -> TextTarget? = TextDelivery.capture
    var pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 50_000_000) }
    @MainActor func restore(_ target: TextTarget) async -> Bool {
        guard !Task.isCancelled else { return false }
        let front = frontPID()
        guard front == ownPID || front == target.pid else { return false }
        if front != target.pid, !activate(target.pid) { return false }
        for _ in 0..<10 {
            do { try await pause() } catch { return false }
            guard !Task.isCancelled else { return false }
            let front = frontPID()
            guard front == ownPID || front == target.pid else { return false }
            if front == target.pid, TextDelivery.matches(target, current: current()) { return true }
        }
        return false
    }
}
