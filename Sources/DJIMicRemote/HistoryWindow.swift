import AppKit
import AVFoundation

final class HistoryWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, AVAudioPlayerDelegate {
    let local: LocalDictation
    let window: NSWindow
    let table = NSTableView()
    let scroll = NSScrollView()
    let status = NSTextField(wrappingLabelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    var pasteTarget: TextTarget?
    private var player: AVAudioPlayer?
    private var playingID: UUID?
    private var expanded: Set<UUID> = []
    private var selectedVersions: [UUID: Int] = [:]
    private var displayedEntries: [Transcript] = []
    private var lastPresentation = ""

    init(local: LocalDictation) {
        self.local = local
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 510), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Transcripts"; window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 540, height: 340); window.isReleasedWhenClosed = false
        window.delegate = self; window.center()
        let column = NSTableColumn(identifier: .init("transcripts")); table.addTableColumn(column)
        column.width = 600; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil; table.delegate = self; table.dataSource = self
        table.style = .plain; table.selectionHighlightStyle = .none; table.intercellSpacing = NSSize(width: 0, height: 12)
        table.backgroundColor = .windowBackgroundColor
        table.setAccessibilityLabel("Saved transcripts")
        scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false; scroll.drawsBackground = true; scroll.backgroundColor = .windowBackgroundColor
        countLabel.font = .systemFont(ofSize: 12, weight: .medium); countLabel.textColor = .secondaryLabelColor
        status.font = .systemFont(ofSize: 11); status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        let content = NSStackView(views: [countLabel, scroll, status])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false; window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -14),
            scroll.widthAnchor.constraint(equalTo: content.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            status.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
    }
    func show() { refresh(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    func refresh(showActivity: Bool = false) {
        if local.recordingID != nil { player?.stop() }
        countLabel.stringValue = local.entries.isEmpty ? "No transcripts yet" : "\(local.entries.count) saved locally"
        status.stringValue = local.entries.isEmpty
            ? "Choose Local in the menu, start the remote, then press your mic button to dictate."
            : (pasteTarget == nil ? "Copy, then ⌘V in your app · audio kept for 7 days" : "Audio kept for 7 days · transcripts stay until deleted")
        if showActivity { status.stringValue = local.message }
        let presentation = "\(local.busy)-\(local.activeID?.uuidString ?? "")-\(player?.isPlaying ?? false)-\(pasteTarget?.pid ?? 0)"
        if displayedEntries != local.entries || lastPresentation != presentation {
            displayedEntries = local.entries; lastPresentation = presentation; table.reloadData()
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { displayedEntries.count }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let entry = displayedEntries[row]
        let text = value(entry)
        let width = max(240, tableView.bounds.width - 42)
        let measured = ceil((text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)]).height)
        return 106 + max(20, expanded.contains(entry.id) ? measured : min(104, measured)) + (entry.previousTexts.isEmpty ? 0 : 32) + (measured > 104 ? 26 : 0)
    }
    private func needsExpansion(_ text: String) -> Bool {
        (text as NSString).boundingRect(with: NSSize(width: max(240, table.bounds.width - 42), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: NSFont.systemFont(ofSize: 14)]).height > 104
    }
    private func value(_ entry: Transcript) -> String {
        let version = selectedVersions[entry.id] ?? 0
        if version > 0, version <= entry.previousTexts.count { return entry.previousTexts[entry.previousTexts.count - version] }
        return entry.text.isEmpty ? "No transcript yet. Retry transcription from the saved audio." : entry.text
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = displayedEntries[row]
        let card = TranscriptRow(entry: entry, text: value(entry), expanded: expanded.contains(entry.id), canExpand: needsExpansion(value(entry)), version: selectedVersions[entry.id] ?? 0, destination: pasteTarget?.name,
                                 busy: local.busy, audio: local.history?.hasAudio(entry.id) == true,
                                 playing: player?.isPlaying == true && playingID == entry.id,
                                 needsSaving: local.needsSaving(entry.id))
        card.onAction = { [weak self] card, action in self?.act(action, entry: entry, card: card) }
        return card
    }
    private func act(_ action: TranscriptRow.Action, entry: Transcript, card: TranscriptRow) {
        switch action {
        case .copy:
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value(entry), forType: .string)
            card.copyButton.title = "Copied"; status.stringValue = "Copied. Paste with ⌘V in any text field."
        case .paste:
            guard let pasteTarget else { return }
            window.orderOut(nil)
            local.pasteAgain(entry.id, text: value(entry), into: pasteTarget)
        case .expand:
            if !expanded.insert(entry.id).inserted { expanded.remove(entry.id) }
            table.reloadData()
        case .version:
            selectedVersions[entry.id] = card.versions.indexOfSelectedItem; table.reloadData()
        case .retry: player?.stop(); local.retry(entry.id)
        case .play:
            if player?.isPlaying == true && playingID == entry.id { player?.stop(); refresh(); return }
            guard let url = local.history?.audioURL(entry.id) else { return }
            do {
                player?.stop(); player = try AVAudioPlayer(contentsOf: url); playingID = entry.id
                player?.delegate = self; player?.play(); refresh()
            } catch { status.stringValue = "Could not play this recording: \(error.localizedDescription)" }
        case .delete:
            let alert = NSAlert(); alert.messageText = "Delete this transcript and recording?"
            alert.informativeText = "This removes its audio and all saved transcript versions from this Mac."
            alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertFirstButtonReturn else { return }
                self?.player?.stop(); self?.local.delete(entry.id)
            }
        }
    }
    func windowDidResize(_ notification: Notification) { table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<displayedEntries.count)) }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { refresh() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { status.stringValue = "Playback failed. The recording is still saved." }
    func windowWillClose(_ notification: Notification) { player?.stop() }
}

final class TranscriptRow: NSTableCellView {
    enum Action { case copy, paste, expand, version, retry, play, delete }
    var onAction: ((TranscriptRow, Action) -> Void)?
    let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    let versions = NSPopUpButton()
    init(entry: Transcript, text: String, expanded: Bool, canExpand: Bool, version: Int, destination: String?, busy: Bool, audio: Bool, playing: Bool, needsSaving: Bool) {
        super.init(frame: .zero)
        let box = NSBox(); box.boxType = .custom; box.borderWidth = 1
        box.borderColor = .separatorColor; box.fillColor = .controlBackgroundColor; box.cornerRadius = 10
        box.contentViewMargins = .zero; box.translatesAutoresizingMaskIntoConstraints = false; addSubview(box)
        let date = NSTextField(labelWithString: DateFormatter.localizedString(from: entry.created, dateStyle: .medium, timeStyle: .short) + (entry.duration > 0 ? " · \(Int(entry.duration))s" : ""))
        date.font = .systemFont(ofSize: 11, weight: .medium); date.textColor = .secondaryLabelColor
        let body = NSTextField(wrappingLabelWithString: text); body.isSelectable = true
        body.font = .systemFont(ofSize: 14); body.maximumNumberOfLines = expanded ? 0 : 6
        body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let detail = NSTextField(labelWithString: entry.displayMessage)
        detail.font = .systemFont(ofSize: 11); detail.textColor = entry.needsInsertionRecovery == true ? .secondaryLabelColor : .tertiaryLabelColor
        detail.lineBreakMode = .byTruncatingTail; detail.toolTip = detail.stringValue
        copyButton.target = self; copyButton.action = #selector(copyText); copyButton.isEnabled = !entry.text.isEmpty
        let paste = NSButton(title: destination.map { "Paste to \($0)" } ?? "Paste", target: self, action: #selector(pasteText))
        paste.lineBreakMode = .byTruncatingTail
        paste.widthAnchor.constraint(lessThanOrEqualToConstant: 190).isActive = true
        paste.isHidden = destination == nil
        paste.isEnabled = destination != nil && !entry.text.isEmpty && !busy
        paste.toolTip = destination == nil ? "Focus a text field before opening History, or use Copy." : "Return to the previous editor and paste. Never sends Return."
        let play = NSButton(title: playing ? "Stop" : "Play", target: self, action: #selector(playAudio)); play.isEnabled = audio && !busy
        play.image = NSImage(systemSymbolName: playing ? "stop.fill" : "play.fill", accessibilityDescription: nil); play.imagePosition = .imageLeading
        let more = NSPopUpButton(frame: .zero, pullsDown: true)
        more.addItem(withTitle: "More"); more.lastItem?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More actions")
        more.addItem(withTitle: needsSaving ? "Retry saving" : "Transcribe again")
        more.lastItem?.target = self; more.lastItem?.action = #selector(retry); more.lastItem?.isEnabled = !busy && (audio || needsSaving)
        more.menu?.addItem(.separator())
        more.addItem(withTitle: "Delete…"); more.lastItem?.target = self; more.lastItem?.action = #selector(deleteEntry); more.lastItem?.isEnabled = !busy
        more.menu?.autoenablesItems = false
        for button in [copyButton, paste, play, more] { button.controlSize = .small; button.font = .systemFont(ofSize: 12); button.bezelStyle = .rounded }
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [copyButton, paste, spacer, play, more]); actions.spacing = 8
        let stack = NSStackView(views: [date]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 9
        if !entry.previousTexts.isEmpty {
            versions.addItem(withTitle: "Latest transcript")
            for index in entry.previousTexts.indices.reversed() { versions.addItem(withTitle: "Previous transcript \(index + 1)") }
            versions.selectItem(at: min(version, versions.numberOfItems - 1)); versions.controlSize = .small
            versions.target = self; versions.action = #selector(changeVersion); stack.addArrangedSubview(versions)
        }
        stack.addArrangedSubview(body)
        if canExpand {
            let expand = NSButton(title: expanded ? "Show less" : "Show more", target: self, action: #selector(expandText))
            expand.isBordered = false; expand.font = .systemFont(ofSize: 11); stack.addArrangedSubview(expand)
        }
        stack.addArrangedSubview(detail); stack.addArrangedSubview(actions)
        stack.translatesAutoresizingMaskIntoConstraints = false; box.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1), box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            box.topAnchor.constraint(equalTo: topAnchor), box.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.contentView!.leadingAnchor, constant: 14), stack.trailingAnchor.constraint(equalTo: box.contentView!.trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: box.contentView!.topAnchor, constant: 12), stack.bottomAnchor.constraint(lessThanOrEqualTo: box.contentView!.bottomAnchor, constant: -12),
            body.widthAnchor.constraint(equalTo: stack.widthAnchor), detail.widthAnchor.constraint(equalTo: stack.widthAnchor), actions.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func copyText() { onAction?(self, .copy) }
    @objc private func pasteText() { onAction?(self, .paste) }
    @objc private func playAudio() { onAction?(self, .play) }
    @objc private func retry() { onAction?(self, .retry) }
    @objc private func deleteEntry() { onAction?(self, .delete) }
    @objc private func expandText() { onAction?(self, .expand) }
    @objc private func changeVersion() { onAction?(self, .version) }
}
