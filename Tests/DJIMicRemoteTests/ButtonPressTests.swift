import XCTest
@testable import DJIMicRemote

final class ButtonPressTests: XCTestCase {
    func testHoldingDoesNotRetriggerEvenWithoutAutorepeatFlag() {
        var button = ButtonPress()
        XCTAssertTrue(button.handle(isDown: true, isRepeat: false, time: 1))
        XCTAssertFalse(button.handle(isDown: true, isRepeat: true, time: 2))
        XCTAssertFalse(button.handle(isDown: true, isRepeat: false, time: 3))
        XCTAssertFalse(button.handle(isDown: false, isRepeat: false, time: 4))
        XCTAssertTrue(button.handle(isDown: true, isRepeat: false, time: 5))
    }

    func testBounceStaysSuppressedUntilRelease() {
        var button = ButtonPress()
        XCTAssertTrue(button.handle(isDown: true, isRepeat: false, time: 1))
        _ = button.handle(isDown: false, isRepeat: false, time: 1.05)
        XCTAssertFalse(button.handle(isDown: true, isRepeat: false, time: 1.1))
        XCTAssertFalse(button.handle(isDown: true, isRepeat: false, time: 2))
        _ = button.handle(isDown: false, isRepeat: false, time: 2.1)
        XCTAssertTrue(button.handle(isDown: true, isRepeat: false, time: 2.2))
    }

    func testFirstObservedRepeatWaitsForRelease() {
        var button = ButtonPress()
        XCTAssertFalse(button.handle(isDown: true, isRepeat: true, time: 1))
        XCTAssertFalse(button.handle(isDown: true, isRepeat: false, time: 2))
        _ = button.handle(isDown: false, isRepeat: false, time: 3)
        XCTAssertTrue(button.handle(isDown: true, isRepeat: false, time: 4))
    }

    func testDisconnectResetAndEventTapRecovery() {
        var button = ButtonPress()
        _ = button.handle(isDown: true, isRepeat: false, time: 1)
        button.reset()
        XCTAssertTrue(button.handle(isDown: true, isRepeat: false, time: 1.1))
        button.reset(waitForRelease: true)
        XCTAssertFalse(button.handle(isDown: true, isRepeat: false, time: 2))
        _ = button.handle(isDown: false, isRepeat: false, time: 3)
        XCTAssertTrue(button.handle(isDown: true, isRepeat: false, time: 4))
    }
}
