import XCTest
@testable import DJIMicRemote

final class ReceiverMappingTests: XCTestCase {
    private let header = "RegistryID  Key  Value\n"
    private func row(_ value: String, id: String = "10006b1f3") -> String { "\(id) UserKeyMapping \(value)\n" }
    private let sentinel = "({ HIDKeyboardModifierMappingSrc = 51539607785; HIDKeyboardModifierMappingDst = 30064771181; })"

    func testEmptyFormatsAndUnrecognizedOutput() {
        for value in ["(null)", "null", "()", "(\n)", "[]"] {
            XCTAssertEqual(MappingSnapshot.parse(header + row(value))?.isEmpty, true, value)
        }
        for output in ["", header, "permission denied", row("("), row("()") + "unexpected trailing output", row("()") + row("()") ] {
            XCTAssertNil(MappingSnapshot.parse(output), output)
        }
    }

    func testExactMappingDecimalHexAndMultipleServices() throws {
        let decimal = try XCTUnwrap(MappingSnapshot.parse(header + row(sentinel)))
        XCTAssertEqual(decimal.services[0x10006b1f3], .sentinel)
        let hex = "({ HIDKeyboardModifierMappingDst = 0x70000006D; HIDKeyboardModifierMappingSrc = 0xC000000E9; })"
        XCTAssertEqual(MappingSnapshot.parse(row(hex)), decimal)
        let multiple = try XCTUnwrap(MappingSnapshot.parse(row(sentinel) + row("()", id: "abc")))
        XCTAssertFalse(multiple.isEmpty)
        XCTAssertEqual(multiple.services[0xabc], .empty)
    }

    func testAdditionalMappingsOrFieldsAreNeverOwned() {
        for value in [
            "({ HIDKeyboardModifierMappingSrc = 51539607785; HIDKeyboardModifierMappingDst = 30064771187; })",
            "({ HIDKeyboardModifierMappingSrc = 51539607785; HIDKeyboardModifierMappingDst = 30064771181; extra = 1; })",
            "({ HIDKeyboardModifierMappingSrc = 51539607785; HIDKeyboardModifierMappingDst = 30064771181; }, {})"
        ] {
            XCTAssertEqual(MappingSnapshot.parse(row(value))?.services[0x10006b1f3], .other)
        }
    }

    func testInstallAndCleanupBothRequireReadBack() throws {
        let fake = FakeHID([row("()"), "", row(sentinel), row(sentinel), "", row("()")])
        let mapping = ReceiverMapping(command: fake.run)
        try mapping.install()
        XCTAssertTrue(mapping.isVerified)
        XCTAssertTrue(mapping.needsCleanup)
        try mapping.clear()
        XCTAssertFalse(mapping.isVerified)
        XCTAssertFalse(mapping.needsCleanup)
        XCTAssertEqual(fake.commands.map { $0[0] }, ["--get", "--set", "--get", "--get", "--set", "--get"])
        XCTAssertTrue(fake.commands[1][1].contains("30064771181"))
        XCTAssertEqual(fake.commands[4][1], "{\"UserKeyMapping\":[]}")
    }

    func testPreexistingSentinelIsNotAdoptedOrRemoved() {
        let fake = FakeHID([row(sentinel)])
        let mapping = ReceiverMapping(command: fake.run)
        XCTAssertThrowsError(try mapping.install())
        XCTAssertNoThrow(try mapping.clear())
        XCTAssertFalse(mapping.needsCleanup)
        XCTAssertEqual(fake.commands.count, 1)
    }

    func testUnreadableInitialMappingNeverWrites() {
        let fake = FakeHID(["unrecognized"])
        let mapping = ReceiverMapping(command: fake.run)
        XCTAssertThrowsError(try mapping.install())
        XCTAssertFalse(mapping.needsCleanup)
        XCTAssertEqual(fake.commands.count, 1)
    }

    func testChangedMappingOrDeviceIsPreserved() throws {
        for changed in [row("({ other = 1; })"), row(sentinel, id: "999"), row(sentinel) + row("()", id: "abc")] {
            let fake = FakeHID([row("()"), "", row(sentinel), changed])
            let mapping = ReceiverMapping(command: fake.run)
            try mapping.install()
            XCTAssertThrowsError(try mapping.clear())
            XCTAssertFalse(mapping.isVerified)
            XCTAssertFalse(mapping.needsCleanup)
            XCTAssertEqual(fake.commands.filter { $0[0] == "--set" }.count, 1)
        }
    }

    func testUnreadableCleanupDoesNotWriteAndCanBeRetried() throws {
        let fake = FakeHID([row("()"), "", row(sentinel), "bad output", row(sentinel), "", row("()")])
        let mapping = ReceiverMapping(command: fake.run)
        try mapping.install()
        XCTAssertThrowsError(try mapping.clear())
        XCTAssertTrue(mapping.needsCleanup)
        XCTAssertFalse(mapping.isVerified)
        XCTAssertEqual(fake.commands.filter { $0[0] == "--set" }.count, 1)
        try mapping.clear()
        XCTAssertFalse(mapping.needsCleanup)
    }

    func testFailedInstallVerificationNeverBecomesReadyButAllowsSafeCleanup() throws {
        let fake = FakeHID([row("()"), "", "bad output", row(sentinel), "", row("()")])
        let mapping = ReceiverMapping(command: fake.run)
        XCTAssertThrowsError(try mapping.install())
        XCTAssertFalse(mapping.isVerified)
        XCTAssertTrue(mapping.needsCleanup)
        try mapping.clear()
        XCTAssertFalse(mapping.needsCleanup)
    }

    func testFailedWriteKeepsCleanupReceipt() {
        var count = 0
        let mapping = ReceiverMapping { _ in
            count += 1
            if count == 1 { return self.row("()") }
            throw MappingError(message: "write failed")
        }
        XCTAssertThrowsError(try mapping.install())
        XCTAssertTrue(mapping.needsCleanup)
        XCTAssertFalse(mapping.isVerified)
    }

    func testCleanupMustReadBackEmptyMapping() throws {
        let fake = FakeHID([row("()"), "", row(sentinel), row(sentinel), "", row(sentinel)])
        let mapping = ReceiverMapping(command: fake.run)
        try mapping.install()
        XCTAssertThrowsError(try mapping.clear())
        XCTAssertTrue(mapping.needsCleanup)
        XCTAssertFalse(mapping.isVerified)
    }

    func testExternalClearNeedsNoWriteAndDisconnectDropsOwnership() throws {
        let fake = FakeHID([row("()"), "", row(sentinel), row("()")])
        let mapping = ReceiverMapping(command: fake.run)
        try mapping.install()
        try mapping.clear()
        XCTAssertEqual(fake.commands.filter { $0[0] == "--set" }.count, 1)
        let other = FakeHID([row("()"), "", row(sentinel)])
        let disconnected = ReceiverMapping(command: other.run)
        try disconnected.install()
        disconnected.disconnected()
        try disconnected.clear()
        XCTAssertFalse(disconnected.needsCleanup)
        XCTAssertFalse(disconnected.isVerified)
        XCTAssertEqual(other.commands.count, 3)
    }
}

private final class FakeHID {
    var replies: [String]
    var commands: [[String]] = []
    init(_ replies: [String]) { self.replies = replies }
    func run(_ arguments: [String]) throws -> String {
        commands.append(arguments)
        guard !replies.isEmpty else { throw MappingError(message: "Unexpected HID command") }
        return replies.removeFirst()
    }
}
