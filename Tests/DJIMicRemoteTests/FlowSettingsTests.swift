import CoreGraphics
import XCTest
@testable import DJIMicRemote

final class FlowSettingsTests: XCTestCase {
    private func fixture(_ bindings: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "unrelated": ["keep": [1, 2, 3]],
            "prefs": [
                "user": ["shortcuts": bindings, "handsFreeShortcutRemoved": true, "language": "en"],
                "cache": ["splitKeybinds": bindings.map { ["shortcut": $0.key.split(separator: "+").compactMap { Int($0) }, "value": $0.value] }
                    + [["shortcut": [55, 6], "value": "undo"]], "other": 42]
            ]
        ], options: .sortedKeys)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testReadsFlowHandsFreeActionInsteadOfOtherActions() throws {
        let data = try fixture(["55+58+59": "popo", "59+63": "lens", "63": "ptt"])
        let shortcut = try FlowSettings.shortcut(in: data)
        XCTAssertNil(shortcut.key)
        XCTAssertEqual(shortcut.flags, Shortcut.defaultShortcut.flags)
        XCTAssertEqual(shortcut.label, "⌃⌥⌘")
        XCTAssertEqual(try FlowSettings.addingShortcut(to: data), data)
    }
    func testSelectsCompatibleBindingAndSkipsFn() throws {
        let shortcut = try FlowSettings.shortcut(in: fixture(["49+63": "popo", "58+59+90": "popo"]))
        XCTAssertEqual(shortcut.key, 90)
        XCTAssertEqual(shortcut.label, "⌃⌥F20")
    }
    func testRejectsUnsupportedAndMalformedBindings() throws {
        for binding in ["49+63", "49+62", "55+79", "55+57", "55+65535", "55+55", "55++59", "garbage", "49", "55+58+59+90", "55+36+49"] {
            XCTAssertThrowsError(try FlowSettings.shortcut(in: fixture([binding: "popo"])), binding)
        }
    }
    func testUnknownSchemaAndInconsistentCacheAreNotEdited() throws {
        let missing = Data(#"{"prefs":{"user":{"shortcuts":{}}}}"#.utf8)
        XCTAssertThrowsError(try FlowSettings.addingShortcut(to: missing))
        var root = try JSONSerialization.jsonObject(with: fixture(["55+58+59": "popo"])) as! [String: Any]
        var prefs = root["prefs"] as! [String: Any]
        prefs["cache"] = ["splitKeybinds": []]
        root["prefs"] = prefs
        XCTAssertThrowsError(try FlowSettings.addingShortcut(to: JSONSerialization.data(withJSONObject: root)))
    }
    func testAddsBindingWithoutOverwritingActionsOrOverlappingPushToTalk() throws {
        let original = try fixture(["55+58+59": "lens", "58+59": "ptt", "49+63": "popo"])
        let updated = try FlowSettings.addingShortcut(to: original)
        let shortcut = try FlowSettings.shortcut(in: updated)
        XCTAssertEqual(shortcut.label, "⌥⌘F20")
        let root = try JSONSerialization.jsonObject(with: updated) as! [String: Any]
        let prefs = root["prefs"] as! [String: Any]
        let user = prefs["user"] as! [String: Any]
        let bindings = user["shortcuts"] as! [String: String]
        XCTAssertEqual(bindings, ["55+58+59": "lens", "58+59": "ptt", "49+63": "popo", "55+58+90": "popo"])
        XCTAssertEqual(user["language"] as? String, "en")
        XCTAssertEqual(user["handsFreeShortcutRemoved"] as? Bool, false)
        XCTAssertEqual(root["unrelated"] as? NSDictionary, ["keep": [1, 2, 3]] as NSDictionary)
        let cache = prefs["cache"] as! [String: Any]
        XCTAssertEqual(cache["other"] as? Int, 42)
        let entries = cache["splitKeybinds"] as! [[String: Any]]
        XCTAssertTrue(entries.contains { $0["value"] as? String == "undo" })
        XCTAssertEqual(entries.count, 5)
    }
    func testFourBindingsAreNotExpandedOrReplaced() throws {
        let original = try fixture(["49+63": "popo", "36+63": "popo", "48+63": "popo", "63": "popo"])
        XCTAssertThrowsError(try FlowSettings.addingShortcut(to: original))
    }
    func testInstallCreatesPrivateExactBackupAndReadsBack() throws {
        let root = try directory(), config = root.appendingPathComponent("config.json")
        let original = try fixture(["63": "ptt", "49+63": "popo"])
        try original.write(to: config)
        let backup = try XCTUnwrap(FlowSettings.install(at: config, backupDirectory: root.appendingPathComponent("backups"), isRunning: { false }))
        XCTAssertEqual(try Data(contentsOf: backup), original)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertNotNil(try FlowSettings.shortcut(in: FlowSettings.read(from: config)))
    }
    func testExistingBindingDoesNotCreateBackupOrRewrite() throws {
        let root = try directory(), config = root.appendingPathComponent("config.json"), backups = root.appendingPathComponent("backups")
        let original = try fixture(["55+58+59": "popo"])
        try original.write(to: config)
        XCTAssertNil(try FlowSettings.install(at: config, backupDirectory: backups, isRunning: { false }))
        XCTAssertEqual(try Data(contentsOf: config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
    }
    func testRunningFlowPreventsAnyWrite() throws {
        let root = try directory(), config = root.appendingPathComponent("config.json")
        let original = try fixture(["63": "ptt"])
        try original.write(to: config)
        XCTAssertThrowsError(try FlowSettings.install(at: config, backupDirectory: root.appendingPathComponent("backups"), isRunning: { true }))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }
    func testFlowRestartDuringPreparationPreventsWrite() throws {
        let root = try directory(), config = root.appendingPathComponent("config.json")
        let original = try fixture(["63": "ptt"])
        try original.write(to: config)
        var checks = 0
        XCTAssertThrowsError(try FlowSettings.install(at: config, backupDirectory: root.appendingPathComponent("backups"), isRunning: {
            checks += 1; return checks > 1
        }))
        XCTAssertEqual(try Data(contentsOf: config), original)
    }
    func testConcurrentEditIsPreserved() throws {
        let root = try directory(), config = root.appendingPathComponent("config.json")
        let original = try fixture(["63": "ptt"]), changed = try fixture(["55+58+59": "lens"])
        try original.write(to: config)
        var checks = 0
        XCTAssertThrowsError(try FlowSettings.install(at: config, backupDirectory: root.appendingPathComponent("backups"), isRunning: {
            checks += 1
            if checks == 2 { try! changed.write(to: config) }
            return false
        }))
        XCTAssertEqual(try Data(contentsOf: config), changed)
    }
}
