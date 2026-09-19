import Foundation

enum ReceiverIdentity {
    static let vendor = 11427
    static let product = 16401
    static let match = "{\"VendorID\":\(vendor),\"ProductID\":\(product)}"
    static let volumeUp: UInt64 = 0xC000000E9
    static let sentinel: UInt64 = 0x70000006D // F18
    static let sentinelKey: UInt16 = 79
}

/// Preserve service identities as well as values: a replacement device is not ours.
struct MappingSnapshot: Equatable {
    enum Value { case empty, sentinel, other }
    let services: [UInt64: Value]
    var isEmpty: Bool { services.values.allSatisfy { $0 == .empty } }
    var withSentinel: MappingSnapshot { .init(services: services.mapValues { _ in .sentinel }) }

    static func parse(_ output: String) -> MappingSnapshot? {
        var rows: [(UInt64, String)] = []
        for line in output.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.split(whereSeparator: { $0.isWhitespace }) == ["RegistryID", "Key", "Value"] { continue }
            let parts = line.split(maxSplits: 2, whereSeparator: { $0.isWhitespace })
            if parts.count == 3, parts[1] == "UserKeyMapping" {
                let rawID = parts[0].lowercased()
                guard let id = UInt64(rawID.hasPrefix("0x") ? String(rawID.dropFirst(2)) : rawID, radix: 16),
                      !rows.contains(where: { $0.0 == id }) else { return nil }
                rows.append((id, String(parts[2])))
            } else if !rows.isEmpty {
                rows[rows.count - 1].1 += "\n" + line
            } else { return nil }
        }
        guard !rows.isEmpty else { return nil }
        var services: [UInt64: Value] = [:]
        for (id, value) in rows {
            let compact = value.filter { !$0.isWhitespace }
            if ["(null)", "null", "()", "[]"].contains(compact) {
                services[id] = .empty
                continue
            }
            // hidutil uses OpenStep property-list syntax. Parsing the entire value
            // avoids treating a matching pair hidden inside extra mappings as ours.
            guard let array = try? PropertyListSerialization.propertyList(from: Data(value.utf8), format: nil) as? [[String: Any]] else { return nil }
            let source = "HIDKeyboardModifierMappingSrc", destination = "HIDKeyboardModifierMappingDst"
            if array.count == 1, let pair = array.first, Set(pair.keys) == [source, destination],
               number(pair[source]) == ReceiverIdentity.volumeUp,
               number(pair[destination]) == ReceiverIdentity.sentinel {
                services[id] = .sentinel
            } else { services[id] = .other }
        }
        return .init(services: services)
    }

    private static func number(_ value: Any?) -> UInt64? {
        guard let text = value as? String else { return nil }
        return text.lowercased().hasPrefix("0x") ? UInt64(text.dropFirst(2), radix: 16) : UInt64(text)
    }
}

struct MappingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Owns only a mapping installed during this process, never a pre-existing F18 map.
final class ReceiverMapping {
    typealias Command = ([String]) throws -> String
    private let command: Command
    private var expected: MappingSnapshot?
    private(set) var isVerified = false
    var needsCleanup: Bool { expected != nil }

    init(command: @escaping Command = ReceiverMapping.hidutil) { self.command = command }

    func install() throws {
        guard expected == nil else { throw MappingError(message: "Mapping cleanup is pending. Disable the remote or reconnect the receiver.") }
        let before = try read()
        guard before.isEmpty else { throw MappingError(message: "Unplug and reconnect your DJI receiver, then try again. A previous session or another app left a button mapping. If it returns, close the other remapper.") }
        // Retain the intended identities even if a write partially succeeds or its
        // read-back fails. Cleanup still requires an exact match before any write.
        expected = before.withSentinel
        _ = try command(["--set", "{\"UserKeyMapping\":[{\"HIDKeyboardModifierMappingSrc\":\(ReceiverIdentity.volumeUp),\"HIDKeyboardModifierMappingDst\":\(ReceiverIdentity.sentinel)}]}"])
        guard try read() == expected else { throw MappingError(message: "Receiver mapping could not be verified. Disable the remote and reconnect the receiver.") }
        isVerified = true
    }

    func clear() throws {
        isVerified = false
        guard let expected else { return }
        let current = try read()
        if current.isEmpty { self.expected = nil; return }
        guard current == expected else {
            self.expected = nil
            throw MappingError(message: "Receiver mappings changed; left them untouched. Reconnect the receiver before retrying.")
        }
        _ = try command(["--set", "{\"UserKeyMapping\":[]}"])
        let after = try read()
        guard after.isEmpty, Set(after.services.keys) == Set(expected.services.keys) else {
            throw MappingError(message: "Mapping cleanup could not be verified. Reconnect the receiver.")
        }
        self.expected = nil
    }

    func disconnected() { expected = nil; isVerified = false }

    private func read() throws -> MappingSnapshot {
        guard let snapshot = MappingSnapshot.parse(try command(["--get", "UserKeyMapping"])) else {
            throw MappingError(message: "Could not read receiver mapping values. Reconnect the receiver.")
        }
        return snapshot
    }

    private static func hidutil(_ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
        process.arguments = ["property", "--matching", ReceiverIdentity.match] + arguments
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw MappingError(message: "hidutil failed (\(process.terminationStatus)). Reconnect the receiver and retry.") }
        return String(decoding: data, as: UTF8.self)
    }
}
