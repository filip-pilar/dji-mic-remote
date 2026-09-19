import XCTest
import AppKit
import ApplicationServices
@testable import DJIMicRemote

/// Opt-in checks: no microphone access, receiver mapping, or keyboard injection.
final class LayoutTests: XCTestCase {
    @MainActor func testNativeLayoutSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["DJI_UI_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set DJI_UI_SNAPSHOT_DIR for offscreen AppKit layout checks.")
        }
        _ = NSApplication.shared
        NSApp.appearance = NSAppearance(named: .aqua)
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixtureDirectory = root.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let history = try LocalHistory(directory: fixtureDirectory)
        var entry = Transcript(id: UUID(), created: Date(timeIntervalSince1970: 1_790_000_000))
        entry.state = .ready; entry.duration = 8
        entry.text = "Testing the wireless microphone. This recording is saved locally, so I can recover the text if the destination changes."
        entry.message = "Saved · destination changed. Copy or paste again from History."
        entry.previousTexts = ["Testing the wireless mic."]
        try history.save(entry)
        let local = LocalDictation(history: history, recognizer: FakeRecognizer(), recorder: FakeRecorder(), inputs: { [AudioInput(uid: "fixture", name: "USB microphone")] })
        local.inputUID = "fixture"
        let remote = Remote(local: local)
        remote.configuringFlow = true // Never inspect or configure the user's Flow store.
        remote.buildPanel()
        remote.configuringFlow = false
        remote.engine = .local; remote.engineControl.selectedSegment = 1
        remote.refreshControls(); remote.fitPanels()
        let view = remote.popover.contentViewController!.view
        view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
        try snapshot(view, to: root.appendingPathComponent("local-menu.png"))
        XCTAssertLessThan(view.frame.height, 370)
        XCTAssertGreaterThan(view.frame.height, 260)
        XCTAssertFalse(remote.localControls.isHidden)
        XCTAssertEqual(remote.historyButton.title, "History…")
        XCTAssertEqual(remote.aboutButton.itemTitles, ["About", "About DJI Mic Remote…", "Licenses…"])
        let baseSize = view.frame.size
        let inputFrame = remote.inputPicker.convert(remote.inputPicker.bounds, to: view)
        let footerFrame = remote.historyButton.convert(remote.historyButton.bounds, to: view)
        entry.needsInsertionRecovery = true
        try history.save(entry); remote.refreshControls(); remote.fitPanels()
        view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
        try snapshot(view, to: root.appendingPathComponent("insertion-recovery.png"))
        XCTAssertEqual(remote.stateTitle.stringValue, "Remote paused")
        XCTAssertEqual(view.frame.size, baseSize)
        XCTAssertEqual(remote.statusPresentation.badge, .paused)
        XCTAssertEqual(remote.inputPicker.convert(remote.inputPicker.bounds, to: view), inputFrame)
        XCTAssertEqual(remote.historyButton.convert(remote.historyButton.bounds, to: view), footerFrame)
        entry.pasteState = .autoSendSkipped
        entry.message = "Paste sent to Editor. Auto-send skipped: the paste was not consumed or verified. Transcript saved in History."
        try history.save(entry); remote.refreshControls(); remote.fitPanels()
        view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
        try snapshot(view, to: root.appendingPathComponent("auto-send-skipped.png"))
        XCTAssertEqual(remote.stateTitle.stringValue, "Remote paused")
        XCTAssertEqual(view.frame.size, baseSize)
        XCTAssertEqual(remote.statusPresentation.badge, .paused)
        XCTAssertEqual(remote.inputPicker.convert(remote.inputPicker.bounds, to: view), inputFrame)
        XCTAssertEqual(remote.historyButton.convert(remote.historyButton.bounds, to: view), footerFrame)
        XCTAssertEqual(history.entry(entry.id)?.displayMessage, entry.message)
        remote.enabled = true; remote.refreshControls(); remote.fitPanels()
        view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
        try snapshot(view, to: root.appendingPathComponent("waiting-for-receiver.png"))
        XCTAssertEqual(remote.stateTitle.stringValue, "Waiting for receiver")
        XCTAssertEqual(remote.primaryButton.title, "Pause remote")
        XCTAssertFalse(remote.localControls.isHidden)
        XCTAssertFalse(remote.statusLabel.stringValue.contains("Auto-send skipped"))
        remote.enabled = false
        entry.needsInsertionRecovery = false; try history.save(entry); remote.refreshControls()
        remote.accessibilityAllowed = { false }
        remote.startupRequested = true; remote.startupStage = .accessibility
        remote.refreshControls(); remote.fitPanels()
        view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
        try snapshot(view, to: root.appendingPathComponent("permission.png"))
        XCTAssertEqual(remote.primaryButton.title, "Open Accessibility Settings")
        remote.accessibilityHelp(); remote.fitPanels()
        view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
        try snapshot(view, to: root.appendingPathComponent("permission-recovery.png"))
        XCTAssertLessThan(view.frame.height, 560)
        XCTAssertEqual(remote.primaryButton.title, "Show this app in Finder")
        for (stage, filename) in [(Remote.StartupStage.microphoneRequest, "microphone-permission.png"), (.local, "loading.png")] {
            remote.startupStage = stage; remote.refreshControls(); remote.fitPanels()
            view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
            try snapshot(view, to: root.appendingPathComponent(filename))
            XCTAssertLessThan(view.frame.height, 440)
            XCTAssertEqual(remote.primaryButton.title, "Cancel setup")
        }
        remote.startupRequested = false; remote.startupStage = .idle
        let historyUI = HistoryWindow(local: local)
        historyUI.pasteTarget = TextTarget(pid: 123, name: "ChatGPT", element: AXUIElementCreateApplication(123), selection: nil)
        historyUI.refresh()
        historyUI.window.contentView!.layoutSubtreeIfNeeded()
        try snapshot(historyUI.window.contentView!, to: root.appendingPathComponent("history.png"))
        XCTAssertEqual(historyUI.table.numberOfRows, 1)
        XCTAssertGreaterThan(historyUI.scroll.frame.height, 300)
        XCTAssertTrue(historyUI.scroll.hasVerticalScroller)
        XCTAssertFalse(historyUI.scroll.autohidesScrollers)
        for index in 1...6 {
            var item = Transcript(id: UUID(), created: entry.created.addingTimeInterval(Double(-index * 60)))
            item.text = index == 6 ? String(repeating: "This is a longer transcript that remains readable and expands in place. ", count: 16) : "A short local transcript, ready to copy."
            item.state = .ready; item.duration = 12; item.message = "Saved on this Mac"
            try history.save(item)
        }
        historyUI.refresh(); historyUI.window.contentView!.layoutSubtreeIfNeeded()
        try snapshot(historyUI.window.contentView!, to: root.appendingPathComponent("history-list.png"))
        XCTAssertEqual(historyUI.table.numberOfRows, 7)
        XCTAssertGreaterThan(historyUI.table.frame.height, historyUI.scroll.contentView.bounds.height)
        historyUI.window.setContentSize(NSSize(width: 540, height: 390)); historyUI.window.contentView!.layoutSubtreeIfNeeded()
        try snapshot(historyUI.window.contentView!, to: root.appendingPathComponent("history-compact.png"))
        remote.engine = .flow; remote.engineControl.selectedSegment = 0
        remote.flowShortcut = .defaultShortcut
        remote.refreshControls(); remote.fitPanels()
        view.setFrameSize(remote.popover.contentSize); view.layoutSubtreeIfNeeded()
        try snapshot(view, to: root.appendingPathComponent("flow-menu.png"))
        XCTAssertTrue(remote.localControls.isHidden)
        XCTAssertEqual(remote.historyButton.title, "Shortcut settings…")
        XCTAssertEqual(remote.historyButton.action, #selector(Remote.showHelp))
        let iconStrip = NSView(frame: NSRect(x: 0, y: 0, width: MenuBarIcon.itemWidth * CGFloat(MenuBarBadge.State.allCases.count), height: 24))
        for (index, state) in MenuBarBadge.State.allCases.enumerated() {
            let button = NSButton(frame: NSRect(x: CGFloat(index) * MenuBarIcon.itemWidth, y: 0, width: MenuBarIcon.itemWidth, height: 24))
            button.isBordered = false
            let badge = MenuBarBadge(frame: .zero)
            button.addSubview(badge)
            MenuBarIcon.apply(to: button, badge: badge, state: state)
            iconStrip.addSubview(button)
        }
        try snapshot(iconStrip, to: root.appendingPathComponent("menu-icons.png"))
        iconStrip.appearance = NSAppearance(named: .darkAqua)
        try snapshot(iconStrip, to: root.appendingPathComponent("menu-icons-dark.png"), background: .black)
    }
    @MainActor private func snapshot(_ view: NSView, to url: URL, background: NSColor = .white) throws {
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        let composite = NSImage(size: view.bounds.size)
        composite.lockFocus()
        background.setFill(); view.bounds.fill()
        let rendered = NSImage(size: view.bounds.size); rendered.addRepresentation(image)
        rendered.draw(in: view.bounds, from: .zero, operation: .sourceOver, fraction: 1)
        composite.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(composite.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }
}
