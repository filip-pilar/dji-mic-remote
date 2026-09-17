import AppKit
import ApplicationServices

final class Remote: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var status: NSStatusItem!
    var popover: NSPopover!
    var popoverContent: NSStackView!
    var statusLabel: NSTextField!
    var helpPanel: NSPanel!
    var detailsContent: NSStackView!
    var modeHint: NSTextField!
    var manualControls: NSStackView!
    var layoutScheduled = false
    var shortcutLabel: NSTextField!
    var shortcutButton: NSButton!
    var toggle: NSButton!
    var testButton: NSButton!
    var diagnosticLabel: NSTextField!
    var flowLabel: NSTextField!
    var flowAction: NSButton!
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
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        status.button?.target = self
        status.button?.action = #selector(showSettings)
        buildPanel()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            flowObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == FlowSettings.bundleID, !self.configuringFlow else { return }
                if name == NSWorkspace.didTerminateApplicationNotification && self.automaticFlow { self.stopRemote() }
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
        popover = NSPopover(); popover.behavior = .transient
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 245))
        popover.contentViewController = controller
        let title = text("DJI Mic Remote", size: 17); title.font = .systemFont(ofSize: 17, weight: .semibold)
        toggle = NSButton(checkboxWithTitle: "Enable remote", target: self, action: #selector(toggleEnabled))
        toggle.font = .systemFont(ofSize: 14, weight: .medium)
        statusLabel = text("Looking for receiver…", size: 12, secondary: true)
        flowLabel = text("Checking Wispr Flow…", size: 12, secondary: true)
        flowAction = NSButton(title: "Set up Flow automatically", target: self, action: #selector(resolveFlow))
        let content = column([title, text("One press to start dictation. One to finish.", size: 12, secondary: true),
            toggle, statusLabel, flowLabel, flowAction, separator(),
            row([NSButton(title: "Details…", target: self, action: #selector(showHelp)), spacer(),
                 NSButton(title: "Quit", target: self, action: #selector(quit))])], spacing: 12)
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
        helpPanel.title = "DJI Mic Remote Details"; helpPanel.titlebarAppearsTransparent = true
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
        popover.performClose(nil)
        refreshFlow(); fitPanels()
        NSApp.activate(ignoringOtherApps: true); helpPanel.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings() {
        if popover.isShown { popover.performClose(nil); return }
        refresh()
        guard let button = status.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    var flowIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: FlowSettings.bundleID).contains { !$0.isTerminated }
    }
    func refreshFlow() {
        guard !configuringFlow else { return }
        let previous = flowShortcut
        canConfigureFlow = false
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: FlowSettings.bundleID) == nil {
            flowShortcut = nil; flowProblem = "Install Wispr Flow to connect your remote."
            flowAction.title = "Get Wispr Flow"
        } else {
            do {
                flowShortcut = try FlowSettings.shortcut(in: FlowSettings.read())
                flowProblem = nil
            } catch {
                flowShortcut = nil; flowProblem = error.localizedDescription
                if case FlowSettings.Failure.noShortcut = error { canConfigureFlow = true }
            }
            flowAction.title = canConfigureFlow ? "Set up Flow (restarts Flow)" : "Open Flow"
        }
        if automaticFlow && enabled && !FlowSettings.sameBinding(previous, flowShortcut) {
            stopRemote()
            diagnosticLabel.stringValue = "Flow’s shortcut changed. Enable the remote again to use the new binding."
        }
        flowLabel.stringValue = automaticFlow
            ? (flowProblem ?? (flowIsRunning ? "Flow’s shortcut is detected automatically." : "Wispr Flow will open when you enable the remote."))
            : "Using your custom shortcut. Match it in Flow."
        flowAction.isHidden = !automaticFlow || flowShortcut != nil
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
    @objc func resolveFlow() {
        guard canConfigureFlow else { openFlow(); return }
        guard !configuringFlow, stopRemote() else { return }
        configuringFlow = true
        toggle.isEnabled = false; flowAction.isEnabled = false
        automaticToggle.isEnabled = false; testButton.isEnabled = false
        flowLabel.stringValue = "Setting up Flow…"
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
                    ? "Flow’s existing shortcut is ready. Enable the remote."
                    : "Added a hands-free binding and restarted Flow. Existing settings were backed up. Enable the remote."
            } catch { problem = error.localizedDescription }
            if reopen { self.launchFlow { _ in } }
            self.configuringFlow = false
            self.toggle.isEnabled = true; self.flowAction.isEnabled = true
            self.automaticToggle.isEnabled = true; self.testButton.isEnabled = true
            self.refresh()
            if let problem { self.statusLabel.stringValue = problem; self.diagnosticLabel.stringValue = problem }
        }
    }
    @objc func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @discardableResult
    func stopRemote() -> Bool {
        enabled = false
        toggle.state = .off
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
        diagnosticLabel.stringValue = "Shortcut saved. Match it in Flow, then enable the remote."
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
    @objc func toggleEnabled() {
        guard !configuringFlow else { return }
        if toggle.state == .on {
            refreshFlow()
            guard activeShortcut != nil else { toggle.state = .off; statusLabel.stringValue = flowProblem ?? "Record a custom shortcut in Details."; return }
            if automaticFlow && !flowIsRunning {
                let generation = eventGeneration
                statusLabel.stringValue = "Opening Wispr Flow…"
                launchFlow { [weak self] error in
                    guard let self, self.eventGeneration == generation, self.toggle.state == .on else { return }
                    if let error { self.toggle.state = .off; self.statusLabel.stringValue = error.localizedDescription }
                    else if self.flowIsRunning { self.toggleEnabled() }
                    else { self.toggle.state = .off; self.statusLabel.stringValue = "Open Flow and try again." }
                }
                return
            }
            guard AXIsProcessTrusted() else { toggle.state = .off; requestPermission(); statusLabel.stringValue = "Allow Accessibility, then enable the remote."; return }
            if mapping.needsCleanup && !clearMapping() { toggle.state = .off; return }
            guard installTap() else { toggle.state = .off; statusLabel.stringValue = "Could not listen for the button. Check Accessibility permission."; return }
            eventGeneration += 1; buttonPress.reset()
            enabled = true
        } else {
            guard stopRemote() else { return }
        }
        refresh()
    }
    func suspendForReceiverChange() {
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
            enabled = false; toggle.state = .off; removeTap()
            return
        }
        refresh()
    }
    func refresh() {
        refreshFlow()
        guard !receiverSettling else { statusLabel.stringValue = "Receiver connection changed. Checking…"; return }
        if enabled && receiver.connected && !mapped {
            do { try mapping.install() }
            catch {
                enabled = false; toggle.state = .off; removeTap()
                var message = error.localizedDescription
                // A failed read-back may still follow a successful write. Attempt
                // rollback, with the same ownership checks as a normal disable.
                do { try mapping.clear() }
                catch { message += " " + error.localizedDescription }
                statusLabel.stringValue = message
                diagnosticLabel.stringValue = message
                updateStatusIcon()
                return
            }
        }
        statusLabel.stringValue = !receiver.connected ? "Connect your DJI Mic Series Mobile Receiver." : (mapped && enabled ? "Ready. Press the receiver button to dictate." : "Receiver connected. Remote is off.")
        updateStatusIcon()
    }
    func updateStatusIcon() {
        guard let button = status.button else { return }
        let ready = enabled && mapped
        let state = ready ? "Ready" : (enabled ? "Waiting for receiver" : "Off")
        button.image = ready ? MenuBarIcon.ready : MenuBarIcon.inactive
        button.toolTip = "DJI Mic Remote — \(state)"
        button.setAccessibilityLabel("DJI Mic Remote")
        button.setAccessibilityValue(state)
    }
    @discardableResult
    func clearMapping() -> Bool {
        do { try mapping.clear(); updateStatusIcon(); return true }
        catch {
            diagnosticLabel.stringValue = error.localizedDescription
            statusLabel.stringValue = error.localizedDescription
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
                        remote.sendShortcut()
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
    func sendShortcut() {
        if automaticFlow {
            let previous = flowShortcut
            refreshFlow()
            guard flowIsRunning, FlowSettings.sameBinding(previous, flowShortcut) else {
                diagnosticLabel.stringValue = "Flow or its shortcut changed. Check the connection and enable the remote again."
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
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
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
