import AppKit
import ApplicationServices
import IOKit.hid

// DJI Mic Series Mobile Receiver. Match the receiver, never all keyboards.
let receiverMatch = "{\"VendorID\":11427,\"ProductID\":16401}"
let volumeUp: UInt64 = 0xC000000E9
let sentinel: UInt64 = 0x70000006D // F18
let sentinelKey: CGKeyCode = 79

struct Shortcut: Codable {
    var key: UInt16?
    var flags: UInt64
    var label: String
    var directHIDUsage: UInt64? = nil
    static let defaultShortcut = Shortcut(key: nil, flags: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue, label: "⌃⌥⌘")
}

final class Remote: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var status: NSStatusItem!
    var panel: NSPanel!
    var statusLabel: NSTextField!
    var shortcutButton: NSButton!
    var toggle: NSButton!
    var testButton: NSButton!
    var diagnosticLabel: NSTextField!
    var pendingTest: DispatchWorkItem?
    var buttonPresses = 0
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    var timer: Timer?
    var manager: IOHIDManager!
    var connected = false
    var enabled = false
    var mapped = false
    var recordingShortcut = false
    var recordedModifiers: NSEvent.ModifierFlags = []
    var monitor: Any?
    var lastPress = Date.distantPast
    var pendingRelease: DispatchWorkItem?
    var pressedShortcut: Shortcut?
    let eventSource = CGEventSource(stateID: .privateState)
    var injectedModifiers: [(CGKeyCode, CGEventFlags)] = []
    var baseFlags: CGEventFlags = []
    var shortcut: Shortcut? {
        didSet {
            if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: "shortcut")
            }
            shortcutButton?.title = "Change shortcut: \(shortcut?.label ?? Shortcut.defaultShortcut.label)…"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let data = UserDefaults.standard.data(forKey: "shortcut") {
            shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
        }
        if shortcut == nil || shortcut?.directHIDUsage != nil {
            shortcut = .defaultShortcut
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "DJI Mic Remote")
        let menu = NSMenu()
        menu.addItem(withTitle: "DJI Mic Remote…", action: #selector(showSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
        status.menu = menu
        buildPanel()
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 11427, kIOHIDProductIDKey: 16401] as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
        showSettings()
    }

    func buildPanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 490), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "DJI Mic Remote"
        panel.delegate = self
        panel.center()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 26), stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -26), stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: 26)])
        let title = NSTextField(labelWithString: "Your mic. One button.")
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        stack.addArrangedSubview(title)
        let description = NSTextField(wrappingLabelWithString: "Default: Control–Option–Command. Choose a shortcut that isn’t used by your other apps, and set the same shortcut in Wispr Flow’s Hands-free mode.")
        stack.addArrangedSubview(description)
        shortcutButton = NSButton(title: "Change shortcut: \(shortcut?.label ?? Shortcut.defaultShortcut.label)…", target: self, action: #selector(recordShortcut))
        stack.addArrangedSubview(shortcutButton)
        stack.addArrangedSubview(NSButton(title: "Reset to default", target: self, action: #selector(resetShortcut)))
        toggle = NSButton(checkboxWithTitle: "Enable mic remote", target: self, action: #selector(toggleEnabled))
        stack.addArrangedSubview(toggle)
        testButton = NSButton(title: "Test shortcut in 3 seconds", target: self, action: #selector(testShortcut))
        stack.addArrangedSubview(testButton)
        diagnosticLabel = NSTextField(wrappingLabelWithString: "No button events received this session.")
        diagnosticLabel.font = .systemFont(ofSize: 11)
        stack.addArrangedSubview(diagnosticLabel)
        statusLabel = NSTextField(wrappingLabelWithString: "Looking for receiver…")
        statusLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)
        let permission = NSButton(title: "Allow Accessibility…", target: self, action: #selector(requestPermission))
        stack.addArrangedSubview(permission)
        let hint = NSTextField(wrappingLabelWithString: "Select the DJI microphone in Flow. This app only sends the shortcut; Flow handles your audio and text.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(hint)
    }

    @objc func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    @objc func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
    func stopRemote() {
        enabled = false
        toggle.state = .off
        pendingTest?.cancel(); pendingTest = nil
        releaseShortcut()
        clearMapping()
        removeTap()
    }
    @objc func resetShortcut() {
        stopRemote()
        guard !mapped else { return }
        finishRecording()
        shortcut = .defaultShortcut
        diagnosticLabel.stringValue = "Default restored. Press Control–Option–Command in Flow’s shortcut recorder."
        refresh()
    }
    @objc func recordShortcut() {
        guard !recordingShortcut else { return }
        stopRemote()
        guard !mapped else { return }
        recordingShortcut = true
        recordedModifiers = []
        shortcutButton.title = "Press and release shortcut (Esc cancels)…"
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
            guard event.keyCode != sentinelKey, !flags.isEmpty else {
                self.shortcutButton.title = "Include Command, Option, Control or Shift…"
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
        guard shortcut != nil else { statusLabel.stringValue = "Record your Flow shortcut first."; return }
        guard AXIsProcessTrusted() else { statusLabel.stringValue = "Allow Accessibility before testing."; return }
        finishRecording()
        pendingTest?.cancel()
        diagnosticLabel.stringValue = "Switch to a blank text document. Sending in 3 seconds…"
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingTest = nil
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
        shortcutButton.title = "Change shortcut: \(shortcut?.label ?? Shortcut.defaultShortcut.label)…"
    }
    @objc func toggleEnabled() {
        if toggle.state == .on {
            guard shortcut != nil else { toggle.state = .off; statusLabel.stringValue = "Record your Flow shortcut first."; return }
            do {
                guard AXIsProcessTrusted() else { toggle.state = .off; requestPermission(); statusLabel.stringValue = "Allow Accessibility, then enable the remote."; return }
                guard installTap() else { toggle.state = .off; statusLabel.stringValue = "Could not listen for the button. Check Accessibility permission."; return }
            }
            enabled = true
        } else {
            stopRemote()
        }
        refresh()
    }
    func refresh() {
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        connected = !devices.isEmpty
        if !connected { mapped = false; releaseShortcut() }
        if enabled && connected && !mapped {
            // Never overwrite an existing user mapping we do not own.
            let current = hidutil(["--get", "UserKeyMapping"])
            guard current.0 == 0 else {
                statusLabel.stringValue = "Could not read receiver mappings: \(current.1)"
                return
            }
            guard let empty = receiverMappingsAreEmpty(current.1) else {
                statusLabel.stringValue = "Could not find receiver mapping values. Reconnect the receiver."
                return
            }
            if !empty {
                statusLabel.stringValue = "Receiver already has a key mapping. Disable it before enabling this remote."
                return
            }
            let destination = sentinel
            let result = hidutil(["--set", "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(volumeUp),\"HIDKeyboardModifierMappingDst\":\(destination)}]}"])
            if result.0 != 0 { statusLabel.stringValue = "Could not map the receiver: \(result.1)"; return }
            mapped = true
        }
        testButton.isEnabled = true
        statusLabel.stringValue = !connected ? "Connect your DJI Mic Series Mobile Receiver." : (enabled ? "Ready. Press the mic button to send your Flow shortcut." : "Receiver connected. Remote is off.")
        status.button?.image = NSImage(systemSymbolName: enabled && mapped ? "mic.fill" : "mic", accessibilityDescription: "DJI Mic Remote")
    }
    func hidutil(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--matching", receiverMatch] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch { return (-1, error.localizedDescription) }
    }
    func clearMapping() {
        if mapped {
            let result = hidutil(["--set", "{\"UserKeyMapping\":[]}"])
            guard result.0 == 0 else {
                diagnosticLabel.stringValue = "Mapping cleanup failed. Reconnect the receiver before using it normally."
                return
            }
        }
        mapped = false
    }
    func installTap() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: CGEventMask(mask), callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let remote = Unmanaged<Remote>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = remote.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if remote.enabled && remote.mapped && event.getIntegerValueField(.keyboardEventKeycode) == Int64(sentinelKey) {
                if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    DispatchQueue.main.async {
                        guard remote.enabled && remote.mapped else { return }
                        remote.buttonPresses += 1
                        remote.diagnosticLabel.stringValue = "Button events received: \(remote.buttonPresses)"
                        remote.trigger()
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
    func trigger() {
        guard enabled, mapped, !recordingShortcut, Date().timeIntervalSince(lastPress) > 0.35 else { return }
        lastPress = Date()
        sendShortcut()
    }
    func sendShortcut() {
        guard !recordingShortcut, AXIsProcessTrusted(), let shortcut else { return }
        releaseShortcut()
        baseFlags = CGEventSource.flagsState(.combinedSessionState).intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        let requested = CGEventFlags(rawValue: shortcut.flags)
        let modifiers: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand)]
        let needed = modifiers.filter { requested.contains($0.1) && !baseFlags.contains($0.1) }
        // Allocate the whole sequence before posting, so allocation failure cannot strand modifiers.
        let down: CGEvent?
        if let key = shortcut.key {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true) else { return }
            down = event
        } else {
            down = nil
            guard !needed.isEmpty else {
                diagnosticLabel.stringValue = "Release the shortcut modifiers before pressing the mic button."
                return
            }
        }
        var flags = baseFlags
        var modifierEvents: [CGEvent] = []
        for (key, modifier) in needed {
            guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: true) else { return }
            flags.insert(modifier)
            event.type = .flagsChanged
            event.flags = flags
            modifierEvents.append(event)
        }
        injectedModifiers = needed
        for event in modifierEvents { event.post(tap: .cghidEventTap) }
        down?.flags = baseFlags.union(requested)
        down?.post(tap: .cghidEventTap)
        pressedShortcut = shortcut
        diagnosticLabel.stringValue = "Button events: \(buttonPresses). Sent \(shortcut.label) at \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))."
        let work = DispatchWorkItem { [weak self] in self?.releaseShortcut() }
        pendingRelease = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }
    func releaseShortcut() {
        pendingRelease?.cancel(); pendingRelease = nil
        if let shortcut = pressedShortcut {
            if let key = shortcut.key, let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false) {
                event.flags = baseFlags.union(CGEventFlags(rawValue: shortcut.flags))
                event.post(tap: .cghidEventTap)
            }
            var flags = baseFlags.union(CGEventFlags(rawValue: shortcut.flags))
            for (key, modifier) in injectedModifiers.reversed() {
                flags.remove(modifier)
                if let event = CGEvent(keyboardEventSource: eventSource, virtualKey: key, keyDown: false) {
                    event.type = .flagsChanged
                    event.flags = flags
                    event.post(tap: .cghidEventTap)
                }
            }
        }
        injectedModifiers = []
        baseFlags = []
        pressedShortcut = nil
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        pendingTest?.cancel(); timer?.invalidate(); finishRecording(); releaseShortcut(); clearMapping(); removeTap()
    }
}
let app = NSApplication.shared
let delegate = Remote()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
