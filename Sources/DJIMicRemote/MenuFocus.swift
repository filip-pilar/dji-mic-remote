import AppKit

/// Restore only the app displaced by our popover, never an app the user left
/// deliberately. Shortcut settings, History, and System Settings own their focus.
final class MenuFocus {
    var ownPID = ProcessInfo.processInfo.processIdentifier
    var currentPID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var activate: (pid_t) -> Void = { NSRunningApplication(processIdentifier: $0)?.activate(options: []) }
    private(set) var returnPID: pid_t?

    func opened() {
        if let pid = currentPID(), pid != ownPID { returnPID = pid }
    }
    func closed(restore: Bool) {
        defer { returnPID = nil }
        guard restore, let pid = returnPID, currentPID() == ownPID else { return }
        activate(pid)
    }
}
