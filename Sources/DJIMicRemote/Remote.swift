import AppKit
import ApplicationServices
import AVFoundation

final class Remote: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    // MARK: - Engines

    enum Engine: String { case flow, local }
    var engine = Engine(rawValue: UserDefaults.standard.string(forKey: "dictationEngine") ?? "flow") ?? .flow
    let local: LocalDictation
    init(local: LocalDictation = LocalDictation()) {
        self.local = local
        super.init()
    }

    // MARK: - Panels and focus

    var historyWindow: HistoryWindow?
    var status: NSStatusItem!
    let statusBadge = MenuBarBadge(frame: .zero)
    var savedFeedbackTimer: Timer?
    var savedFeedbackDuration: TimeInterval = 1.4
    var popover: NSPopover!
    var popoverContent: NSStackView!
    var helpPanel: NSPanel!
    var detailsContent: NSStackView!
    var layoutScheduled = false
    var engineControl: NSSegmentedControl!
    var localControls: NSStackView!
    var inputPicker: NSPopUpButton!
    var displayedInputs: [AudioInput]?
    var autoSendToggle: NSButton!
    var aboutButton: NSPopUpButton!
    var historyButton: NSButton!
    var stateTitle: NSTextField!
    var statusLabel: NSTextField!
    var progress: NSProgressIndicator!
    var primaryButton: NSButton!
    var cancelSetupButton: NSButton!
    var revealAppButton: NSButton!
    var permissionActions: NSStackView!
    var modeHint: NSTextField!
    var manualControls: NSStackView!
    var shortcutLabel: NSTextField!
    var shortcutButton: NSButton!
    var testButton: NSButton!
    var diagnosticLabel: NSTextField!
    var automaticToggle: NSButton!
    var resetButton: NSButton!
    let menuFocus = MenuFocus()
    var menuTarget: TextTarget?
    var restoreFocusOnClose = true
    var focusObserver: NSObjectProtocol?
    var prepareTextTarget: () -> Void = TextDelivery.prepareFocusedApplication

    // MARK: - Startup and permissions

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
    var installListener: (() -> Bool)?
    var openAccessibilitySettings: (() -> Void)?
    var openMicrophoneSettings: (() -> Void)?
    var dismissPermissionWindows: (() -> Void)?
    var revealApplication: ((URL) -> Void)?
    var activationObserver: NSObjectProtocol?

    // MARK: - Flow shortcuts

    var flowActionTitle = "Open Flow"
    var flowObservers: [NSObjectProtocol] = []
    var flowShortcut: Shortcut?
    var flowProblem: String?
    var canConfigureFlow = false
    var configuringFlow = false
    var automaticFlow = UserDefaults.standard.object(forKey: "automaticFlow") as? Bool ?? true
    var activeShortcut: Shortcut? { automaticFlow ? flowShortcut : shortcut }
    var pendingTest: DispatchWorkItem?
    let emitter = ShortcutEmitter()
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

    // MARK: - Receiver

    let receiver = ReceiverMonitor()
    let mapping = ReceiverMapping()
    var buttonPress = ButtonPress()
    var buttonPresses = 0
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var eventGeneration = 0
    var receiverSettling = false
    var enabled = false
    var mapped: Bool { mapping.isVerified && !receiverSettling }
    var receiverAction: Task<Void, Never>?
    var receiverActionID: UUID?

    // MARK: - Application lifecycle

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
        local.onChange = { [weak self] in
            self?.refreshControls()
            self?.historyWindow?.refresh(showActivity: true)
        }
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

    @objc func changeEngine() {
        guard !configuringFlow, stopRemote() else { engineControl.selectedSegment = engine == .flow ? 0 : 1; return }
        startupIssue = nil
        finishRecording(); helpPanel.orderOut(nil)
        engine = engineControl.selectedSegment == 0 ? .flow : .local
        UserDefaults.standard.set(engine.rawValue, forKey: "dictationEngine")
        local.refreshInputs(); refresh()
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

    deinit { permissionTimer?.invalidate(); savedFeedbackTimer?.invalidate() }
}
