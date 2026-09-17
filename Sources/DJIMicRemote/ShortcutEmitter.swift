import CoreGraphics
import Foundation

struct Shortcut: Codable {
    var key: UInt16?
    var flags: UInt64
    var label: String
    var directHIDUsage: UInt64? = nil
    static let defaultShortcut = Shortcut(key: nil, flags: CGEventFlags([.maskControl, .maskAlternate, .maskCommand]).rawValue, label: "⌃⌥⌘")
}

/// Prepares down AND release events before posting anything. Tests replace the
/// posting closure, so they never inject keys into the user's session.
final class ShortcutEmitter {
    enum Outcome { case sent, alreadyHeld, allocationFailed }
    typealias EventFactory = (CGKeyCode, Bool) -> CGEvent?
    private let makeEvent: EventFactory
    private let post: (CGEvent) -> Void
    private let scheduleRelease: (DispatchWorkItem) -> Void
    private var releases: [CGEvent] = []
    private var pendingRelease: DispatchWorkItem?
    private var generation = 0

    init(makeEvent: EventFactory? = nil,
         post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         scheduleRelease: @escaping (DispatchWorkItem) -> Void = { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: $0) }) {
        let source = CGEventSource(stateID: .privateState)
        self.makeEvent = makeEvent ?? { CGEvent(keyboardEventSource: source, virtualKey: $0, keyDown: $1) }
        self.post = post
        self.scheduleRelease = scheduleRelease
    }

    func send(_ shortcut: Shortcut, heldFlags: @autoclosure () -> CGEventFlags) -> Outcome {
        release()
        // Read physical/session state only after releasing our previous chord.
        let held = heldFlags().intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        let requested = CGEventFlags(rawValue: shortcut.flags)
        let modifiers: [(CGKeyCode, CGEventFlags)] = [(59, .maskControl), (58, .maskAlternate), (56, .maskShift), (55, .maskCommand)]
        let needed = modifiers.filter { requested.contains($0.1) && !held.contains($0.1) }
        guard shortcut.key != nil || !needed.isEmpty else { return .alreadyHeld }
        var downs: [CGEvent] = [], ups: [CGEvent] = []
        var flags = held
        for (key, modifier) in needed {
            guard let down = makeEvent(key, true), let up = makeEvent(key, false) else { return .allocationFailed }
            down.type = .flagsChanged; up.type = .flagsChanged
            up.flags = flags
            flags.insert(modifier); down.flags = flags
            downs.append(down); ups.insert(up, at: 0)
        }
        if let key = shortcut.key {
            guard let down = makeEvent(key, true), let up = makeEvent(key, false) else { return .allocationFailed }
            down.flags = held.union(requested); up.flags = down.flags
            downs.append(down); ups.insert(up, at: 0)
        }
        releases = ups
        downs.forEach(post)
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.release()
        }
        pendingRelease = work
        scheduleRelease(work)
        return .sent
    }

    func release() {
        generation += 1
        pendingRelease?.cancel(); pendingRelease = nil
        let events = releases
        releases = []
        events.forEach(post)
    }
}
