/// One accepted down per release, with a monotonic debounce clock.
struct ButtonPress {
    private var down = false
    private var lastAccepted: Double?

    mutating func handle(isDown: Bool, isRepeat: Bool, time: Double) -> Bool {
        guard isDown else { down = false; return false }
        guard !down else { return false }
        down = true
        guard !isRepeat, lastAccepted.map({ time - $0 >= 0.35 }) ?? true else { return false }
        lastAccepted = time
        return true
    }

    mutating func reset(waitForRelease: Bool = false) {
        down = waitForRelease
        lastAccepted = nil
    }
}
