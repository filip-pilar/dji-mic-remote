import AppKit
import ApplicationServices
import AVFoundation

final class Remote: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    enum Engine: String { case flow, local }
    var engine = Engine(rawValue: UserDefaults.standard.string(forKey: "dictationEngine") ?? "flow") ?? .flow
    let local: LocalDictation
    init(local: LocalDictation = LocalDictation()) { self.local = local; super.init() }
    var historyWindow: HistoryWindow?
    var engineControl: NSSegmentedControl!
    var localControls: NSStackView!
    var inputPicker: NSPopUpButton!
    var autoSendToggle: NSButton!
    var aboutButton: NSPopUpButton!
    var historyButton: NSButton!
    var stateTitle: NSTextField!
    var progress: NSProgressIndicator!
    var cancelSetupButton: NSButton!
    var revealAppButton: NSButton!
    var permissionActions: NSStackView!
    var prepareTextTarget: () -> Void = TextDelivery.prepareFocusedApplication
    enum StartupStage { case idle, local, flow, microphone, microphoneRequest, accessibility }
    var startupStage: StartupStage = .idle {
        didSet {
            if startupStage != .accessibility { accessibilityRecovery = false }
            if oldValue != startupStage { updatePermissionMonitoring() }
        }
    }
    var startupRequested = false
    var startupGeneration = 0
    var startupIssue: String?
    var accessibilityAllowed: () -> Bool = AXIsProcessTrusted
    var accessibilityRecovery = false
    var permissionTimer: Timer?
    var permissionCheckInterval: TimeInterval = 0.5
    var microphoneAuthorization: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var requestMicrophoneAccess: () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    var microphoneTask: Task<Void, Never>?
    var displayedInputs: [AudioInput]?
    var installListener: (() -> Bool)?
    var openAccessibilitySettings: (() -> Void)?
    var openMicrophoneSettings: (() -> Void)?
    var dismissPermissionWindows: (() -> Void)?
    var revealApplication: ((URL) -> Void)?
    var activationObserver: NSObjectProtocol?
    deinit { permissionTimer?.invalidate(); savedFeedbackTimer?.invalidate() }
    var status: NSStatusItem!
    let statusBadge = MenuBarBadge(frame: .zero)
    var savedFeedbackTimer: Timer?
    var savedFeedbackDuration: TimeInterval = 1.4
    var popover: NSPopover!
    let menuFocus = MenuFocus()
    var menuTarget: TextTarget?
    var restoreFocusOnClose = true
    var receiverAction: Task<Void, Never>?
    var receiverActionID: UUID?
    var focusObserver: NSObjectProtocol?
    var popoverContent: NSStackView!
    var statusLabel: NSTextField!
    var helpPanel: NSPanel!
    var detailsContent: NSStackView!
    var modeHint: NSTextField!
    var manualControls: NSStackView!
    var layoutScheduled = false
    var shortcutLabel: NSTextField!
    var shortcutButton: NSButton!
    var primaryButton: NSButton!
    var testButton: NSButton!
    var diagnosticLabel: NSTextField!
    var flowActionTitle = "Open Flow"
    var automaticToggle: NSButton!
    var resetButton: NSButton!
    var flowObservers: [NSObjectProtocol] = []
    var flowShortcut: Shortcut?
    var flowProblem: String?
    var canConfigureFlow = false
    var configuringFlow = false
    var automaticFlow = UserDefaults.standard.object(forKey: "automaticFlow") as? Bool ?? true
    var activeShortcut: Shortcut? { automaticFlow ? flowShortcut : shortcut }
    var pendingTest: DispatchWorkItem?
    var buttonPresses = 0
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    let receiver = ReceiverMonitor()
    let mapping = ReceiverMapping()
    let emitter = ShortcutEmitter()
    var buttonPress = ButtonPress()
    var eventGeneration = 0
    var receiverSettling = false
    var enabled = false
    var mapped: Bool { mapping.isVerified && !receiverSettling }
    var recordingShortcut = false
    var recordedModifiers: NSEvent.ModifierFlags = []
    var monitor: Any?
    var shortcut: Shortcut? {
        didSet {
            if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: "shortcut")
            }
            shortcutButton?.title = "Change…"
            shortcutLabel?.stringValue = shortcut?.label ?? Shortcut.defaultShortcut.label
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "shortcut") {
            shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        if shortcut == nil || shortcut?.directHIDUsage != nil {
            shortcut = .defaultShortcut
        }
        status = NSStatusBar.system.statusItem(withLength: MenuBarIcon.itemWidth)
        statusBadge.autoresizingMask = [.minXMargin]
        status.button?.addSubview(statusBadge)
        updateStatusIcon()
        status.button?.target = self
        status.button?.action = #selector(showSettings)
        buildPanel()
        local.onChange = { [weak self] in self?.refreshControls(); self?.historyWindow?.refresh(showActivity: true); self?.updateStatusIcon() }
        local.onTranscriptSaved = { [weak self] in self?.showSavedFeedback() }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.resumeStartup() }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.engine == .local, self.enabled || self.local.pastePending else { return }
            self.prepareTextTarget()
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            flowObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == FlowSettings.bundleID, !self.configuringFlow else { return }
                if name == NSWorkspace.didTerminateApplicationNotification && self.engine == .flow && self.automaticFlow { self.stopRemote() }
                self.refresh()
            })
        }
        receiver.onWillChange = { [weak self] in self?.suspendForReceiverChange() }
        receiver.onChange = { [weak self] in self?.receiverChanged() }
        receiver.start()
        showSettings()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { showSettings() }
        return false
    }

    func text(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let label = ResizingLabel(wrappingLabelWithString: value)
        label.font = .systemFont(ofSize: size)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
        label.onChange = { [weak self] in self?.scheduleLayout() }
        return label
    }
    func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        return stack
    }
    func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = 12
        return stack
    }
    func spacer() -> NSView {
        let view = NSView(); view.setContentHuggingPriority(.defaultLow, for: .horizontal); return view
    }
    func separator() -> NSBox {
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
    func install(_ stack: NSStackView, in window: NSWindow) {
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
    @objc func showHelp() {
        if engine == .local { showHistory(); return }
        closePopover(restoringFocus: false)
        refreshFlow(); fitPanels()
        NSApp.activate(ignoringOtherApps: true); helpPanel.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if popover.isShown { popover.performClose(nil); return }
        local.refreshInputs()
        resumeStartup(); refresh()
        guard let button = status?.button else { return }
        menuTarget = TextDelivery.capture()
        menuFocus.opened()
        refreshControls()
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
    func finishRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recordingShortcut = false
        recordedModifiers = []
        shortcutButton.title = "Change…"
        shortcutLabel.stringValue = activeShortcut?.label ?? "Not connected"
        refreshDetails()
    }
    @objc func primaryAction() {
        if configuringFlow { return }
        if startupStage == .local || startupStage == .flow || startupStage == .microphoneRequest { cancelStartup(); return }
        if startupStage == .accessibility {
            resumeStartup()
            if startupStage == .accessibility {
                if accessibilityRecovery { revealAppForAccessibility() }
                else { requestPermission() }
            }
            return
        }
        if startupStage == .microphone { resumeStartup(); if startupStage == .microphone { microphonePermission() }; return }
        if engine == .local, local.pastePending { local.cancelPaste(); refreshControls(); return }
        if engine == .local, local.recordingID != nil { local.finish(insert: false); return }
        if engine == .local, local.working { local.interrupt(local.activeID == nil ? "Setup cancelled." : "Transcription cancelled. Recording saved in History."); refreshControls(); return }
        if engine == .local, local.hasUnsavedHistory { showHistory(); return }
        if enabled { stopRemote(); startupIssue = nil; refresh(); return }
        startRemote()
    }
    @objc func cancelStartup() { stopRemote(); startupIssue = nil; refresh() }
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
                updateStatusIcon()
                return
            }
        }
        refreshControls()
        updateStatusIcon()
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
    @discardableResult
    func clearMapping() -> Bool {
        do { try mapping.clear(); updateStatusIcon(); return true }
        catch {
            diagnosticLabel.stringValue = error.localizedDescription
            startupIssue = error.localizedDescription
            refreshControls()
            updateStatusIcon()
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
    @objc func changeEngine() {
        guard !configuringFlow, stopRemote() else { engineControl.selectedSegment = engine == .flow ? 0 : 1; return }
        startupIssue = nil
        finishRecording(); helpPanel.orderOut(nil)
        engine = engineControl.selectedSegment == 0 ? .flow : .local
        UserDefaults.standard.set(engine.rawValue, forKey: "dictationEngine")
        local.refreshInputs(); refresh()
    }
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
    @objc func microphonePermission() {
        dismissForPermission()
        if let openMicrophoneSettings { openMicrophoneSettings(); return }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
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
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard local.hasUnsavedHistory else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Some history could not be saved"
        alert.informativeText = "Keep the app open to copy the transcript or retry saving. Quitting may lose the unsaved text."
        alert.addButton(withTitle: "Keep open"); alert.addButton(withTitle: "Quit anyway")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        if let focusObserver { NSWorkspace.shared.notificationCenter.removeObserver(focusObserver) }
        flowObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        stopRemote(); receiver.stop(); finishRecording()
    }
}

private final class ResizingLabel: NSTextField {
    var onChange: (() -> Void)?
    override var stringValue: String {
        didSet { if oldValue != stringValue { onChange?() } }
    }
}

@main
struct DJIMicRemoteApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = Remote()
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
