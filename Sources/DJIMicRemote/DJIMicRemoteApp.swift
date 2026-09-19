import AppKit

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
