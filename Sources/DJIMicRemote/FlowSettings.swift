import CoreGraphics
import Foundation

/// Flow's local format is private. Decode only known fields and fail closed.
/// Never edit the running app's store: it also keeps these settings in memory.
enum FlowSettings {
    static let bundleID = "com.electron.wispr-flow"
    static let configurationURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Wispr Flow/config.json")

    enum Failure: LocalizedError {
        case unreadable, incompatible, noShortcut, noFreeBinding, running, changed
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Could not read Flow’s settings. Open Flow and finish its setup first."
            case .incompatible: return "Flow’s settings format is not recognized. Use a custom shortcut in Shortcut settings."
            case .noShortcut: return "Flow needs a compatible hands-free shortcut."
            case .noFreeBinding: return "Could not add a shortcut without conflicting with Flow’s existing bindings. Use Shortcut settings."
            case .running: return "Flow is still running. Quit Flow and try setup again."
            case .changed: return "Flow’s settings changed during setup. Nothing else was overwritten; try again."
            }
        }
    }

    private struct Configuration: Decodable {
        struct Preferences: Decodable {
            struct User: Decodable { let shortcuts: [String: String] }
            struct Cache: Decodable {
                struct Binding: Decodable { let shortcut: [Int]; let value: String }
                let splitKeybinds: [Binding]
            }
            let user: User
            let cache: Cache
        }
        let prefs: Preferences
    }

    static func read(from url: URL = configurationURL) throws -> Data {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: url) else { throw Failure.unreadable }
        return data
    }

    private static func configuration(in data: Data) throws -> Configuration {
        guard let configuration = try? JSONDecoder().decode(Configuration.self, from: data) else {
            throw Failure.incompatible
        }
        return configuration
    }

    static func shortcut(in data: Data) throws -> Shortcut {
        let configuration = try configuration(in: data)
        let bindings = configuration.prefs.user.shortcuts
        // Prefer the existing modifier-only binding, then a stable ordering.
        let candidates = bindings.filter { $0.value == "popo" }.keys.sorted {
            if ($0 == "55+58+59") != ($1 == "55+58+59") { return $0 == "55+58+59" }
            return $0 < $1
        }
        for binding in candidates {
            if let shortcut = decode(binding) {
                let keys = binding.split(separator: "+").compactMap { Int($0) }.sorted()
                guard configuration.prefs.cache.splitKeybinds.contains(where: {
                    $0.value == "popo" && $0.shortcut.sorted() == keys
                }) else { throw Failure.incompatible }
                return shortcut
            }
        }
        throw Failure.noShortcut
    }

    private static func decode(_ binding: String) -> Shortcut? {
        let parts = binding.split(separator: "+", omittingEmptySubsequences: false)
        let keys = parts.compactMap { UInt16($0) }
        guard keys.count == parts.count, (1...3).contains(keys.count),
              Set(keys).count == keys.count else { return nil }
        let modifiers: [UInt16: CGEventFlags] = [59: .maskControl, 58: .maskAlternate,
                                                56: .maskShift, 55: .maskCommand]
        var flags: CGEventFlags = []
        var regular: UInt16?
        for key in keys {
            if let flag = modifiers[key] { flags.insert(flag) }
            else {
                // Fn, right-side modifiers, Caps Lock, mouse codes, and F18
                // cannot be faithfully delivered by our current emitter.
                guard key < 128, ![54, 57, 60, 61, 62, 63, 79].contains(key), regular == nil else { return nil }
                regular = key
            }
        }
        guard !flags.isEmpty else { return nil }
        var label = ""
        for (flag, symbol): (CGEventFlags, String) in [(.maskControl, "⌃"), (.maskAlternate, "⌥"),
                                                      (.maskShift, "⇧"), (.maskCommand, "⌘")] {
            if flags.contains(flag) { label += symbol }
        }
        if let regular {
            let names: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 53: "Esc", 90: "F20"]
            label += names[regular] ?? "Key \(regular)"
        }
        return Shortcut(key: regular, flags: flags.rawValue, label: label)
    }

    static func sameBinding(_ lhs: Shortcut?, _ rhs: Shortcut?) -> Bool {
        lhs?.key == rhs?.key && lhs?.flags == rhs?.flags
    }

    static func addingShortcut(to data: Data) throws -> Data {
        do { _ = try shortcut(in: data); return data }
        catch Failure.noShortcut { /* Add only when the known schema has no usable binding. */ }
        var bindings = try configuration(in: data).prefs.user.shortcuts
        guard bindings.values.filter({ $0 == "popo" }).count < 4 else { throw Failure.noFreeBinding }
        let candidates = ["55+58+59", "58+59+90", "55+58+90", "55+56+90"]
        guard let binding = candidates.first(where: { candidate in
            let keys = Set(candidate.split(separator: "+"))
            return !bindings.keys.contains { existing in
                let other = Set(existing.split(separator: "+"))
                return keys.isSubset(of: other) || other.isSubset(of: keys)
            }
        }) else { throw Failure.noFreeBinding }
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var prefs = root["prefs"] as? [String: Any],
              var user = prefs["user"] as? [String: Any],
              var cache = prefs["cache"] as? [String: Any],
              var split = cache["splitKeybinds"] as? [[String: Any]] else { throw Failure.incompatible }
        bindings[binding] = "popo"
        user["shortcuts"] = bindings
        user["handsFreeShortcutRemoved"] = false
        // Preserve built-in cache entries (such as undo and paste).
        split.append(["shortcut": binding.split(separator: "+").compactMap { Int($0) }, "value": "popo"])
        cache["splitKeybinds"] = split
        prefs["user"] = user; prefs["cache"] = cache; root["prefs"] = prefs
        let result = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        _ = try shortcut(in: result)
        return result
    }

    /// Returns the backup URL only when a write was needed. Tests use temp files.
    @discardableResult
    static func install(at url: URL, backupDirectory: URL, isRunning: () -> Bool) throws -> URL? {
        guard !isRunning() else { throw Failure.running }
        let original = try read(from: url)
        let updated = try addingShortcut(to: original)
        guard updated != original else { return nil }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let backup = backupDirectory.appendingPathComponent("flow-\(UUID().uuidString).json")
        guard FileManager.default.createFile(atPath: backup.path, contents: original,
                                              attributes: [.posixPermissions: 0o600]) else { throw Failure.unreadable }
        guard !isRunning() else { throw Failure.running }
        guard try read(from: url) == original else { throw Failure.changed }
        try updated.write(to: url, options: .atomic)
        guard try read(from: url) == updated else { throw Failure.changed }
        return backup
    }
}
