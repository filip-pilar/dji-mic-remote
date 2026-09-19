import AppKit
import ApplicationServices

extension Remote {
    func suspendForReceiverChange() {
        if local.recordingID != nil || local.activeID != nil || local.pastePending {
            local.interrupt("Receiver connection changed. Recording saved in History.")
        }
        receiverSettling = true
        eventGeneration += 1; buttonPress.reset(); emitter.release()
        pendingTest?.cancel(); pendingTest = nil; testButton.title = "Test in 3 seconds"
        updateStatusIcon()
    }

    func receiverChanged() {
        receiverSettling = false
        if !receiver.connected {
            mapping.disconnected()
        } else if mapping.needsCleanup && !clearMapping() {
            // A changed service set must not inherit ownership from the old device.
            enabled = false; removeTap()
            return
        }
        refresh()
    }

    func refresh() {
        refreshFlow()
        guard !receiverSettling else { refreshControls(); return }
        if enabled && receiver.connected && !mapped {
            do { try mapping.install() }
            catch {
                enabled = false; removeTap()
                var message = error.localizedDescription
                // A failed read-back may still follow a successful write. Attempt
                // rollback, with the same ownership checks as a normal disable.
                do { try mapping.clear() }
                catch { message += " " + error.localizedDescription }
                startupIssue = message
                diagnosticLabel.stringValue = message
                refreshControls()
                return
            }
        }
        refreshControls()
    }

    @discardableResult
    func clearMapping() -> Bool {
        do { try mapping.clear(); updateStatusIcon(); return true }
        catch {
            diagnosticLabel.stringValue = error.localizedDescription
            startupIssue = error.localizedDescription
            refreshControls()
            return false
        }
    }

    func installTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let remote = Unmanaged<Remote>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                remote.eventGeneration += 1
                remote.buttonPress.reset(waitForRelease: true)
                remote.emitter.release()
                remote.local.interrupt("Button listener interrupted. Recording saved in History.")
                if let tap = remote.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if remote.mapping.needsCleanup && event.getIntegerValueField(.keyboardEventKeycode) == Int64(ReceiverIdentity.sentinelKey) {
                // Continue swallowing the sentinel while topology changes settle,
                // but do not turn those events into shortcuts.
                guard remote.enabled && remote.mapped else { return nil }
                let accepted = remote.buttonPress.handle(isDown: type == .keyDown,
                    isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                    time: Double(event.timestamp) / 1_000_000_000)
                if accepted {
                    let generation = remote.eventGeneration
                    DispatchQueue.main.async {
                        guard remote.enabled, remote.mapped, generation == remote.eventGeneration else { return }
                        remote.buttonPresses += 1
                        remote.handleReceiverPress()
                    }
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
    }

    func handleReceiverPress() {
        guard receiverAction == nil else { return }
        let actionID = UUID(); receiverActionID = actionID
        let token = eventGeneration
        let restoring = popover.isShown
        if restoring { closePopover(restoringFocus: true) }
        receiverAction = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.receiverActionID == actionID { self.receiverAction = nil; self.receiverActionID = nil } }
            // Activation is asynchronous. Let our menu relinquish focus before
            // capturing the editor or completing dictation into its saved target.
            if restoring {
                for _ in 0..<6 {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    guard !Task.isCancelled else { return }
                }
            }
            guard !Task.isCancelled, self.enabled, self.mapped, token == self.eventGeneration else { return }
            if self.engine == .local { self.local.press() } else { self.sendShortcut() }
        }
    }
}
