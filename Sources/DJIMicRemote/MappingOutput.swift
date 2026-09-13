import Foundation

// hidutil prints one registry row per service, with arrays spanning several lines.
// nil means no recognizable result; never treat missing output as an empty mapping.
func receiverMappingsAreEmpty(_ output: String) -> Bool? {
    var values: [String] = []
    for line in output.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.split(whereSeparator: { $0.isWhitespace }) == ["RegistryID", "Key", "Value"] { continue }
        if let range = trimmed.range(of: #"^[0-9a-fA-F]+\s+UserKeyMapping\s+"#, options: .regularExpression) {
            values.append(String(trimmed[range.upperBound...]))
        } else if !values.isEmpty {
            values[values.count - 1] += trimmed
        } else {
            return nil
        }
    }
    guard !values.isEmpty else { return nil }
    return values.allSatisfy {
        ["(null)", "null", "()", "[]"].contains($0.filter { !$0.isWhitespace })
    }
}
