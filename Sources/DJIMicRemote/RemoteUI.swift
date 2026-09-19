import AppKit

extension Remote {
    private func text(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let label = ResizingLabel(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.onChange = { [weak self] in self?.scheduleLayout() }
        return label
    }

    private func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 12
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }

    private func separator() -> NSBox {
        let line = NSBox(); line.boxType = .separator; return line
    }

    func scheduleLayout() {
        guard !layoutScheduled else { return }
        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutScheduled = false
            self.fitPanels()
        }
    }

    func fitPanels() {
        guard let detailsContent, let helpPanel, let popoverContent else { return }
        helpPanel.contentView?.layoutSubtreeIfNeeded()
        let size = NSSize(width: 440, height: ceil(detailsContent.fittingSize.height) + 40)
        var frame = helpPanel.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        // Keep the title bar in place when switching modes or wrapping messages.
        frame.origin = NSPoint(x: helpPanel.frame.minX, y: helpPanel.frame.maxY - frame.height)
        if abs(frame.height - helpPanel.frame.height) > 0.5 { helpPanel.setFrame(frame, display: true) }
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
        popover.contentSize = NSSize(width: 360, height: ceil(popoverContent.fittingSize.height) + 36)
    }

    private func install(_ stack: NSStackView, in window: NSWindow) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
    }

    func buildPanel() {
        popover = NSPopover(); popover.behavior = .transient; popover.delegate = self
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 245))
        popover.contentViewController = controller
        let title = text("DJI Mic Remote", size: 17); title.font = .systemFont(ofSize: 17, weight: .semibold)
        engineControl = NSSegmentedControl(labels: ["Wispr Flow", "Local"], trackingMode: .selectOne, target: self, action: #selector(changeEngine))
        engineControl.selectedSegment = engine == .flow ? 0 : 1
        engineControl.setAccessibilityLabel("Dictation engine")
        stateTitle = text("Remote paused", size: 15); stateTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        statusLabel = text("", size: 12, secondary: true)
        progress = NSProgressIndicator(); progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        primaryButton = NSButton(title: "Start remote", target: self, action: #selector(primaryAction))
        primaryButton.bezelStyle = .rounded; primaryButton.controlSize = .large
        primaryButton.font = .systemFont(ofSize: 14, weight: .semibold)
        primaryButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        cancelSetupButton = NSButton(title: "Cancel setup", target: self, action: #selector(cancelStartup))
        cancelSetupButton.isHidden = true
        revealAppButton = NSButton(title: "Already enabled or missing?", target: self, action: #selector(accessibilityHelp))
        revealAppButton.isHidden = true
        for button in [revealAppButton!, cancelSetupButton!] {
            button.isBordered = false; button.font = .systemFont(ofSize: 12)
        }
        permissionActions = row([revealAppButton, spacer(), cancelSetupButton])
        permissionActions.isHidden = true
        inputPicker = NSPopUpButton(); inputPicker.target = self; inputPicker.action = #selector(changeInput)
        inputPicker.setAccessibilityLabel("Recording microphone")
        inputPicker.toolTip = "Pause the remote to change microphones."
        autoSendToggle = NSButton(checkboxWithTitle: "Auto-send", target: self, action: #selector(changeAutoSend))
        autoSendToggle.toolTip = "Press Return after paste is consumed and focus is rechecked. Return may send a message or add a new line. History pastes never auto-send."
        localControls = column([
            column([text("Microphone", size: 11, secondary: true), inputPicker], spacing: 4),
            column([autoSendToggle, text("Press Return after new dictation is inserted.", size: 11, secondary: true)], spacing: 4)
        ], spacing: 12)
        aboutButton = NSPopUpButton(frame: .zero, pullsDown: true)
        aboutButton.addItem(withTitle: "About")
        aboutButton.addItem(withTitle: "About DJI Mic Remote…")
        aboutButton.lastItem?.target = self; aboutButton.lastItem?.action = #selector(showAbout)
        aboutButton.addItem(withTitle: "Licenses…")
        aboutButton.lastItem?.target = self; aboutButton.lastItem?.action = #selector(showLicenses)
        aboutButton.controlSize = .small; aboutButton.bezelStyle = .rounded
        historyButton = NSButton(title: "History…", target: self, action: #selector(showHistory))
        let content = column([title, engineControl, localControls, separator(),
            column([row([stateTitle, spacer(), progress]), statusLabel], spacing: 5),
            primaryButton, permissionActions, separator(),
            row([historyButton, spacer(), aboutButton, NSButton(title: "Quit", target: self, action: #selector(quit))])], spacing: 14)
        popoverContent = content
        content.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: controller.view.topAnchor, constant: 18),
            content.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor, constant: -18)
        ])

        helpPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        helpPanel.title = "Flow Shortcut Settings"; helpPanel.titlebarAppearsTransparent = true
        helpPanel.isReleasedWhenClosed = false; helpPanel.delegate = self; helpPanel.center()
        automaticToggle = NSButton(checkboxWithTitle: "Follow Flow’s shortcut automatically", target: self, action: #selector(changeFlowMode))
        automaticToggle.state = automaticFlow ? .on : .off
        shortcutLabel = text("", size: 18)
        shortcutLabel.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        shortcutButton = NSButton(title: "Change…", target: self, action: #selector(recordShortcut))
        shortcutButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        testButton = NSButton(title: "Test in 3 seconds", target: self, action: #selector(testShortcut))
        resetButton = NSButton(title: "Reset custom shortcut", target: self, action: #selector(resetShortcut))
        manualControls = row([shortcutButton, resetButton, spacer()])
        modeHint = text("", size: 12, secondary: true)
        testButton.toolTip = "Sends the shortcut after a 3-second delay. Focus a blank text field first. Click again to cancel."
        shortcutLabel.setAccessibilityLabel("Hands-free shortcut")
        diagnosticLabel = text("No button events received this session.", size: 12, secondary: true)
        detailsContent = column([
            column([automaticToggle, modeHint], spacing: 6),
            row([shortcutLabel, spacer(), testButton]), manualControls,
            separator(),
            column([text("Activity", size: 12, secondary: true), diagnosticLabel], spacing: 6),
            separator(),
            text("Audio input and transcription are managed in Flow. Select your DJI microphone there.", size: 12, secondary: true),
            row([NSButton(title: "Open Flow", target: self, action: #selector(openFlow)), spacer(),
                 NSButton(title: "Accessibility…", target: self, action: #selector(requestPermission))])
        ], spacing: 14)
        install(detailsContent, in: helpPanel)
        refreshFlow()
    }

    @objc func showSettings() {
        if popover.isShown { popover.performClose(nil); return }
        local.refreshInputs()
        resumeStartup(); refresh()
        guard let button = status?.button else { return }
        menuTarget = TextDelivery.capture()
        menuFocus.opened()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func closePopover(restoringFocus: Bool) {
        guard popover?.isShown == true else { return }
        restoreFocusOnClose = restoringFocus
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        menuFocus.closed(restore: restoreFocusOnClose)
        restoreFocusOnClose = true
    }

    var statusPresentation: (badge: MenuBarBadge.State, description: String) {
        let ready = enabled && mapped && (engine == .flow || local.input != nil)
        let waitingForPermission = startupRequested && [.accessibility, .microphone, .microphoneRequest].contains(startupStage)
        if engine == .local && local.recordingID != nil { return (.recording, local.message) }
        if configuringFlow || startupStage == .flow { return (.working, "Starting Wispr Flow") }
        if engine == .local && local.working { return (.working, local.message) }
        if waitingForPermission { return (.attention, "Waiting for permission") }
        if let startupIssue { return (.attention, startupIssue) }
        if enabled && !ready { return (.attention, mapped ? "Microphone disconnected" : "Waiting for receiver") }
        if engine == .local {
            if local.hasUnsavedHistory || local.history == nil { return (.attention, local.message) }
            if savedFeedbackTimer != nil { return (.saved, "Transcript saved on this Mac") }
        }
        return ready ? (.ready, "Ready to dictate") : (.paused, "Remote paused")
    }

    func showSavedFeedback() {
        guard engine == .local, !local.busy else { return }
        clearSavedFeedback()
        let timer = Timer(timeInterval: savedFeedbackDuration, repeats: false) { [weak self] _ in
            self?.clearSavedFeedback(); self?.updateStatusIcon()
        }
        savedFeedbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        updateStatusIcon()
    }

    func clearSavedFeedback() { savedFeedbackTimer?.invalidate(); savedFeedbackTimer = nil }

    func updateStatusIcon() {
        if local.busy || engine != .local || startupRequested { clearSavedFeedback() }
        guard let button = status?.button else { return }
        let presentation = statusPresentation
        status.length = MenuBarIcon.itemWidth
        MenuBarIcon.apply(to: button, badge: statusBadge, state: presentation.badge)
        button.toolTip = "DJI Mic Remote — \(presentation.description)"
        button.setAccessibilityLabel("DJI Mic Remote")
        button.setAccessibilityValue(presentation.description)
    }

    /// Refresh the panel and its menu-bar icon together.
    func refreshControls() {
        guard localControls != nil else { return }
        let isLocal = engine == .local
        localControls.isHidden = !isLocal
        historyButton.title = isLocal ? "History…" : "Shortcut settings…"
        historyButton.action = isLocal ? #selector(showHistory) : #selector(showHelp)
        engineControl.isEnabled = !configuringFlow && startupStage != .local && startupStage != .flow && startupStage != .microphoneRequest
        autoSendToggle.state = local.autoSend ? .on : .off
        autoSendToggle.isEnabled = !local.busy
        if displayedInputs != local.inputs {
            displayedInputs = local.inputs
            inputPicker.removeAllItems(); inputPicker.addItem(withTitle: "Choose microphone…")
            for input in local.inputs { inputPicker.addItem(withTitle: input.name); inputPicker.lastItem?.representedObject = input.uid }
        }
        let inputIndex = local.inputs.firstIndex(where: { $0.uid == local.inputUID }).map { $0 + 1 } ?? 0
        if inputPicker.indexOfSelectedItem != inputIndex { inputPicker.selectItem(at: inputIndex) }
        inputPicker.isEnabled = !local.busy && !enabled
        primaryButton.isEnabled = !configuringFlow
        cancelSetupButton.isHidden = startupStage != .accessibility && startupStage != .microphone
        revealAppButton.isHidden = startupStage != .accessibility
        revealAppButton.title = accessibilityRecovery ? "Open Settings" : "Already enabled or missing?"
        permissionActions.isHidden = cancelSetupButton.isHidden
        var title = "Remote paused"
        var detail = isLocal ? "Private dictation on this Mac. Start the remote to begin." : "Use your mic button to dictate with Wispr Flow."
        var action = "Start remote"
        var spinning = false
        if configuringFlow { title = "Setting up Flow…"; detail = "Adding a shortcut and restarting Flow."; action = "Setting up…"; spinning = true }
        else if startupStage == .local { title = "Starting local dictation…"; detail = local.message; action = "Cancel setup"; spinning = true }
        else if startupStage == .flow { title = "Opening Flow…"; detail = "The remote will start automatically."; action = "Cancel setup"; spinning = true }
        else if startupStage == .microphone { title = "Waiting for microphone access"; detail = "Allow DJI Mic Remote in System Settings. Setup continues automatically when macOS grants access."; action = "Open Microphone Settings" }
        else if startupStage == .microphoneRequest { title = "Allow microphone access"; detail = "Choose Allow in the macOS prompt to record your microphone."; action = "Cancel setup" }
        else if startupStage == .accessibility {
            if accessibilityRecovery {
                title = "Restore Accessibility access"
                detail = "If the switch is already on, macOS may still be using an older build’s permission.\n\nIn Accessibility, select DJI Mic Remote and click −. Then click + and add the app shown in Finder. Turn it on.\n\nIf it’s missing, just add it. Setup continues automatically once access works."
                action = "Show this app in Finder"
            } else {
                title = "Waiting for Accessibility"
                detail = "Turn on DJI Mic Remote in Accessibility. Setup continues automatically when macOS grants access."
                action = "Open Accessibility Settings"
            }
        }
        else if isLocal && local.recordingID != nil { title = "Recording…"; detail = local.message; action = "Finish & save" }
        else if isLocal && local.cancelling { title = "Stopping…"; detail = "Finishing the current operation. Nothing will be typed."; action = "Stopping…"; primaryButton.isEnabled = false; spinning = true }
        else if isLocal && (local.pastePending || local.delivering) { title = "Pasting…"; detail = local.message; action = "Cancel paste"; spinning = true }
        else if isLocal && local.working && local.activeID == nil { title = "Starting local dictation…"; detail = local.message; action = "Cancel setup"; spinning = true }
        else if isLocal && local.working { title = "Transcribing…"; detail = "Your recording is saved. Transcribing on this Mac."; action = "Cancel transcription"; spinning = true }
        else if isLocal && local.hasUnsavedHistory { title = "Save transcript to continue"; detail = "Open History to copy your transcript or retry saving."; action = "Open History…" }
        else if isLocal && local.history == nil { title = "History unavailable"; detail = local.message; action = "Start remote"; primaryButton.isEnabled = false }
        else if let issue = startupIssue { title = isLocal && local.input == nil ? "Choose a microphone" : "Needs attention"; detail = issue; action = isLocal && local.input == nil ? "Choose microphone…" : "Try again" }
        else if enabled {
            title = mapped ? "Ready to dictate" : "Waiting for receiver"
            detail = mapped ? "Press the mic button to start. Press again to finish." : "Connect your DJI receiver. The remote will connect automatically."
            action = "Pause remote"
            if isLocal && local.input == nil { title = "Microphone disconnected"; detail = "Pause the remote and choose a connected microphone above." }
        } else if !isLocal && automaticFlow && activeShortcut == nil {
            title = "Connect Wispr Flow"; detail = flowProblem ?? "Open Flow to finish setting up its hands-free shortcut."
            action = canConfigureFlow ? "Set up Flow & start" : flowActionTitle
        } else if isLocal && local.input == nil {
            title = "Choose a microphone"; detail = "Select an input to start private dictation on this Mac."; action = "Choose microphone…"
        } else if isLocal && local.ready { detail = "Local dictation is ready. Start the remote to use your mic button." }
        if receiverSettling && enabled { title = "Checking receiver…" }
        stateTitle.stringValue = title; statusLabel.stringValue = detail; primaryButton.title = action
        stateTitle.textColor = local.recordingID != nil && isLocal ? .systemRed : .labelColor
        if spinning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        updateStatusIcon()
        scheduleLayout()
    }

    @objc func changeAutoSend() { local.setAutoSend(autoSendToggle.state == .on); refreshControls() }

    @objc func changeInput() {
        local.selectInput(inputPicker.selectedItem?.representedObject as? String)
        startupIssue = nil
        if startupRequested { startRemote() } else { refreshControls() }
    }

    @objc func showHistory() {
        closePopover(restoringFocus: false)
        if historyWindow == nil { historyWindow = HistoryWindow(local: local) }
        historyWindow?.pasteTarget = TextDelivery.capture() ?? menuTarget
        historyWindow?.show()
    }

    @objc func showLicenses() {
        closePopover(restoringFocus: false)
        NSWorkspace.shared.open(AppResources.root.appendingPathComponent("Licenses"))
    }

    @objc func showAbout() {
        closePopover(restoringFocus: false)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DJI Mic Remote"])
    }
}

private final class ResizingLabel: NSTextField {
    var onChange: (() -> Void)?
    override var stringValue: String {
        didSet { if oldValue != stringValue { onChange?() } }
    }
}
