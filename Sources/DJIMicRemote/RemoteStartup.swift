import AppKit
import AVFoundation

extension Remote {
    @objc func primaryAction() {
        if configuringFlow { return }
        if startupStage == .local || startupStage == .flow || startupStage == .microphoneRequest {
            cancelStartup()
            return
        }
        if startupStage == .accessibility {
            resumeStartup()
            if startupStage == .accessibility {
                if accessibilityRecovery { revealAppForAccessibility() }
                else { requestPermission() }
            }
            return
        }
        if startupStage == .microphone {
            resumeStartup()
            if startupStage == .microphone { microphonePermission() }
            return
        }
        if engine == .local, local.pastePending {
            local.cancelPaste()
            refreshControls()
            return
        }
        if engine == .local, local.recordingID != nil {
            local.finish(insert: false)
            return
        }
        if engine == .local, local.working {
            local.interrupt(local.activeID == nil ? "Setup cancelled." : "Transcription cancelled. Recording saved in History.")
            refreshControls()
            return
        }
        if engine == .local, local.hasUnsavedHistory {
            showHistory()
            return
        }
        if enabled {
            stopRemote()
            startupIssue = nil
            refresh()
            return
        }
        startRemote()
    }

    @objc func cancelStartup() {
        stopRemote()
        startupIssue = nil
        refresh()
    }

    func startRemote() {
        guard !configuringFlow, !enabled, startupStage == .idle else { return }
        startupRequested = true; startupIssue = nil
        if engine == .local {
            local.refreshInputs()
            guard local.input != nil else {
                startupIssue = "Choose the microphone you want to use above."
                refreshControls(); return
            }
            guard checkAccessibility() else { return }
            if microphoneAuthorization() == .notDetermined {
                startupStage = .microphoneRequest; refreshControls()
                let token = startupGeneration
                microphoneTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    let allowed = await self.requestMicrophoneAccess()
                    guard self.startupRequested, self.startupGeneration == token, self.engine == .local else { return }
                    self.microphoneTask = nil
                    if allowed && self.microphoneAuthorization() == .authorized {
                        self.startupStage = .idle; self.startRemote()
                    } else {
                        // A denied prompt should leave one clear next action, not
                        // immediately open another window behind the system alert.
                        self.startupStage = .microphone; self.refreshControls()
                    }
                }
                return
            }
            if microphoneAuthorization() == .denied || microphoneAuthorization() == .restricted {
                startupStage = .microphone; refreshControls(); microphonePermission(); return
            }
            if !local.ready {
                startupStage = .local
                let token = startupGeneration
                refreshControls()
                local.prepare { [weak self] success in
                    guard let self, self.startupRequested, self.startupGeneration == token, self.engine == .local else { return }
                    self.startupStage = .idle
                    if success { self.finishStartup() }
                    else if self.microphoneAuthorization() == .denied || self.microphoneAuthorization() == .restricted {
                        self.startupStage = .microphone; self.refreshControls()
                    } else { self.startupRequested = false; self.startupIssue = self.local.message; self.refreshControls() }
                }
                return
            }
        } else {
            refreshFlow()
            if activeShortcut == nil {
                startupRequested = false
                if canConfigureFlow { resolveFlow() }
                else { openFlow(); startupIssue = flowProblem ?? "Finish Flow setup, then start the remote."; refreshControls() }
                return
            }
            guard checkAccessibility() else { return }
            if automaticFlow && !flowIsRunning {
                startupStage = .flow; let token = startupGeneration; refreshControls()
                launchFlow { [weak self] error in
                    guard let self, self.startupRequested, self.startupGeneration == token else { return }
                    self.startupStage = .idle
                    if let error { self.startupRequested = false; self.startupIssue = error.localizedDescription; self.refreshControls() }
                    else if self.flowIsRunning { self.finishStartup() }
                    else { self.startupRequested = false; self.startupIssue = "Flow did not open. Open it and try again."; self.refreshControls() }
                }
                return
            }
        }
        finishStartup()
    }

    func finishStartup() {
        guard startupRequested else { return }
        if engine == .local {
            guard microphoneAuthorization() == .authorized else {
                startupStage = .microphone; refreshControls(); return
            }
            local.refreshInputs()
            guard local.input != nil else {
                startupStage = .idle
                startupIssue = "Your microphone disconnected. Choose a connected microphone above."
                refreshControls(); return
            }
        }
        guard checkAccessibility() else { return }
        if mapping.needsCleanup && !clearMapping() { startupRequested = false; refreshControls(); return }
        guard installListener?() ?? installTap() else {
            startupRequested = false; startupStage = .idle
            startupIssue = "Could not listen for the mic button. Check Accessibility access and try again."
            refreshControls(); return
        }
        startupRequested = false; startupStage = .idle
        eventGeneration += 1; buttonPress.reset(); enabled = true
        if engine == .local { prepareTextTarget() }
        refresh()
    }

    func resumeStartup() {
        guard startupRequested else { return }
        if startupStage == .accessibility && accessibilityAllowed() {
            startupStage = .idle; startRemote()
        } else if startupStage == .microphone && microphoneAuthorization() == .authorized {
            startupStage = .idle; startRemote()
        } else if startupStage == .idle && engine == .local && !local.working {
            local.refreshInputs()
            if local.input != nil { startRemote() }
        }
    }

    @discardableResult
    func stopRemote() -> Bool {
        clearSavedFeedback()
        startupGeneration += 1; startupRequested = false; startupStage = .idle
        microphoneTask?.cancel(); microphoneTask = nil
        receiverAction?.cancel(); receiverAction = nil; receiverActionID = nil
        local.interrupt("Remote stopped. Recording saved in History.")
        enabled = false
        pendingTest?.cancel(); pendingTest = nil
        testButton?.title = "Test in 3 seconds"
        emitter.release()
        eventGeneration += 1; buttonPress.reset()
        let cleaned = clearMapping()
        removeTap()
        return cleaned
    }

    @discardableResult func checkAccessibility() -> Bool {
        guard accessibilityAllowed() else {
            let entering = startupStage != .accessibility
            startupStage = .accessibility; refreshControls()
            // No AX prompt: macOS can leave it behind Settings, and a removed
            // entry is not reliably re-registered. The missing-entry action is
            // always available; passive rechecks never reopen windows.
            if entering { requestPermission() }
            return false
        }
        return true
    }

    func updatePermissionMonitoring() {
        permissionTimer?.invalidate(); permissionTimer = nil
        guard startupRequested, startupStage == .accessibility || startupStage == .microphone else { return }
        // A menu-bar app may never become active after the user grants access.
        // Poll only during this explicit start request, including while Settings
        // or a menu is active. Still-denied checks never reopen Settings;
        // a grant advances to the next step of the same start request.
        let timer = Timer(timeInterval: permissionCheckInterval, repeats: true) { [weak self] _ in
            self?.resumeStartup()
        }
        timer.tolerance = permissionCheckInterval / 5
        permissionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc func requestPermission() {
        dismissForPermission()
        if let openAccessibilitySettings { openAccessibilitySettings(); return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func dismissForPermission() {
        if let dismissPermissionWindows { dismissPermissionWindows(); return }
        closePopover(restoringFocus: false)
        helpPanel?.orderOut(nil)
    }

    func revealAppForAccessibility() {
        dismissForPermission()
        // Reveal exactly the running bundle, not another copy found by name.
        let url = Bundle.main.bundleURL
        if let revealApplication { revealApplication(url); return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc func accessibilityHelp() {
        guard startupStage == .accessibility else { return }
        if accessibilityRecovery { requestPermission() }
        else { accessibilityRecovery = true; refreshControls() }
    }

    @objc func microphonePermission() {
        dismissForPermission()
        if let openMicrophoneSettings { openMicrophoneSettings(); return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
