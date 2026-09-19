import AppKit
import ApplicationServices

extension Remote {
    var flowIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: FlowSettings.bundleID).contains { !$0.isTerminated }
    }

    func refreshFlow() {
        guard engine == .flow, !configuringFlow else { return }
        let previous = flowShortcut
        canConfigureFlow = false
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: FlowSettings.bundleID) == nil {
            flowShortcut = nil; flowProblem = "Install Wispr Flow to connect your remote."
            flowActionTitle = "Get Wispr Flow"
        } else {
            do {
                flowShortcut = try FlowSettings.shortcut(in: FlowSettings.read())
                flowProblem = nil
            } catch {
                flowShortcut = nil; flowProblem = error.localizedDescription
                if case FlowSettings.Failure.noShortcut = error { canConfigureFlow = true }
            }
            flowActionTitle = "Open Flow"
        }
        if automaticFlow && enabled && !FlowSettings.sameBinding(previous, flowShortcut) {
            stopRemote()
            diagnosticLabel.stringValue = "Flow’s shortcut changed. Start the remote again to use the new binding."
        }
        if !recordingShortcut { shortcutLabel.stringValue = activeShortcut?.label ?? "Not connected" }
        refreshDetails()
    }

    func refreshDetails() {
        manualControls.isHidden = automaticFlow
        shortcutButton.isEnabled = !configuringFlow
        resetButton.isEnabled = !configuringFlow && !recordingShortcut
        testButton.isEnabled = !configuringFlow && !recordingShortcut && activeShortcut != nil
        if !recordingShortcut {
            modeHint.stringValue = automaticFlow
                ? (flowProblem ?? "Using Flow’s existing hands-free shortcut.")
                : "Record a shortcut here, then set the same hands-free shortcut in Flow."
        }
        scheduleLayout()
    }

    @objc func showHelp() {
        if engine == .local { showHistory(); return }
        closePopover(restoringFocus: false)
        refreshFlow(); fitPanels()
        NSApp.activate(ignoringOtherApps: true); helpPanel.makeKeyAndOrderFront(nil)
    }

    @objc func changeFlowMode() {
        guard !configuringFlow else { return }
        guard stopRemote() else { automaticToggle.state = automaticFlow ? .on : .off; return }
        finishRecording()
        automaticFlow = automaticToggle.state == .on
        UserDefaults.standard.set(automaticFlow, forKey: "automaticFlow")
        refresh()
    }

    @objc func openFlow() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FlowSettings.bundleID) else {
            NSWorkspace.shared.open(URL(string: "https://wisprflow.ai/downloads")!); return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func launchFlow(completion: @escaping (Error?) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FlowSettings.bundleID) else {
            completion(FlowSettings.Failure.unreadable); return
        }
        let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            DispatchQueue.main.async { completion(error) }
        }
    }

    func resolveFlow() {
        guard canConfigureFlow else { openFlow(); return }
        guard !configuringFlow, stopRemote() else { return }
        configuringFlow = true
        primaryButton.isEnabled = false
        automaticToggle.isEnabled = false; testButton.isEnabled = false
        refreshControls()
        Task { @MainActor in
            var problem: String?
            var reopen = false
            do {
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: FlowSettings.bundleID) {
                    guard app.terminate() else { throw FlowSettings.Failure.running }
                    reopen = true
                }
                let deadline = Date().addingTimeInterval(10)
                while self.flowIsRunning && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
                let backups = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Application Support/DJI Mic Remote/Flow Backups")
                let backup = try FlowSettings.install(at: FlowSettings.configurationURL, backupDirectory: backups,
                                                      isRunning: { self.flowIsRunning })
                reopen = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    self.launchFlow { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                reopen = false
                _ = try FlowSettings.shortcut(in: FlowSettings.read())
                self.diagnosticLabel.stringValue = backup == nil
                    ? "Flow’s existing shortcut is ready."
                    : "Added a hands-free binding and restarted Flow. Existing settings were backed up."
            } catch { problem = error.localizedDescription }
            if reopen { self.launchFlow { _ in } }
            self.configuringFlow = false
            self.primaryButton.isEnabled = true
            self.automaticToggle.isEnabled = true; self.testButton.isEnabled = true
            self.refresh()
            if let problem { self.startupIssue = problem; self.diagnosticLabel.stringValue = problem; self.refreshControls() }
            else { self.startRemote() }
        }
    }

    @objc func resetShortcut() {
        guard stopRemote() else { return }
        finishRecording()
        shortcut = .defaultShortcut
        diagnosticLabel.stringValue = "Default restored. Press Control–Option–Command in Flow’s shortcut recorder."
        refresh()
    }

    @objc func recordShortcut() {
        guard !automaticFlow, !configuringFlow else { return }
        if recordingShortcut { finishRecording(); return }
        guard stopRemote() else { return }
        recordingShortcut = true
        recordedModifiers = []
        shortcutButton.title = "Cancel recording"
        shortcutLabel.stringValue = "…"
        modeHint.stringValue = "Press a shortcut, then release. Escape cancels."
        refreshDetails()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode == 53 { self.finishRecording(); return nil }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.type == .flagsChanged {
                if flags.isEmpty {
                    if !self.recordedModifiers.isEmpty {
                        self.saveRecordedShortcut(key: nil, flags: self.recordedModifiers, keyLabel: "")
                    }
                } else if flags.rawValue.nonzeroBitCount >= self.recordedModifiers.rawValue.nonzeroBitCount {
                    self.recordedModifiers = flags
                }
                return event
            }
            guard event.keyCode != ReceiverIdentity.sentinelKey, !flags.isEmpty else {
                self.modeHint.stringValue = "Include Control, Option, Shift or Command."
                return nil
            }
            let keyLabel = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers?.uppercased() ?? "Key \(event.keyCode)")
            self.saveRecordedShortcut(key: event.keyCode, flags: flags, keyLabel: keyLabel)
            return nil
        }
    }

    func saveRecordedShortcut(key: UInt16?, flags: NSEvent.ModifierFlags, keyLabel: String) {
        var name = ""
        if flags.contains(.control) { name += "⌃" }
        if flags.contains(.option) { name += "⌥" }
        if flags.contains(.shift) { name += "⇧" }
        if flags.contains(.command) { name += "⌘" }
        shortcut = Shortcut(key: key, flags: UInt64(flags.rawValue), label: name + keyLabel)
        finishRecording()
        diagnosticLabel.stringValue = "Shortcut saved. Match it in Flow, then start the remote."
    }

    func finishRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingShortcut = false
        recordedModifiers = []
        shortcutButton.title = "Change…"
        shortcutLabel.stringValue = activeShortcut?.label ?? "Not connected"
        refreshDetails()
    }

    func windowWillClose(_ notification: Notification) { finishRecording() }

    func windowDidResignKey(_ notification: Notification) {
        if recordingShortcut { finishRecording() }
    }

    @objc func testShortcut() {
        guard !configuringFlow else { return }
        if let pendingTest {
            pendingTest.cancel(); self.pendingTest = nil
            testButton.title = "Test in 3 seconds"
            diagnosticLabel.stringValue = "Test cancelled. No shortcut sent."
            return
        }
        refreshFlow()
        guard activeShortcut != nil else { diagnosticLabel.stringValue = flowProblem ?? "Record a custom shortcut first."; return }
        guard !automaticFlow || flowIsRunning else { diagnosticLabel.stringValue = "Open Flow before testing."; return }
        guard AXIsProcessTrusted() else { diagnosticLabel.stringValue = "Allow Accessibility before testing. Use the Accessibility button below."; return }
        finishRecording()
        pendingTest?.cancel()
        diagnosticLabel.stringValue = "Switch to a blank text document. Sending in 3 seconds…"
        testButton.title = "Cancel test"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTest = nil
            self.testButton.title = "Test in 3 seconds"
            self.sendShortcut()
        }
        pendingTest = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    func sendShortcut() {
        guard engine == .flow else { return }
        if automaticFlow {
            let previous = flowShortcut
            refreshFlow()
            guard flowIsRunning, FlowSettings.sameBinding(previous, flowShortcut) else {
                diagnosticLabel.stringValue = "Flow or its shortcut changed. Check the connection and start the remote again."
                stopRemote(); return
            }
        }
        guard !recordingShortcut, AXIsProcessTrusted(), let shortcut = activeShortcut else { return }
        switch emitter.send(shortcut, heldFlags: CGEventSource.flagsState(.combinedSessionState)) {
        case .sent:
            diagnosticLabel.stringValue = "Button events: \(buttonPresses). Sent \(shortcut.label) at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))."
        case .alreadyHeld:
            diagnosticLabel.stringValue = "Release the shortcut modifiers before pressing the mic button."
        case .allocationFailed:
            diagnosticLabel.stringValue = "Could not create shortcut events. No new keys were sent."
        }
    }
}
