import Foundation

struct UniversalIREntry: Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String
    let signalFile: String
}

enum UniversalIRParser {
    static func parse(_ data: Data) -> [UniversalIREntry]? {
        guard let content = String(data: data, encoding: .utf8),
              content.hasPrefix("Filetype: IR library file") else { return nil }
        var entries: [UniversalIREntry] = []
        var fields: [String: String] = [:]
        var signalLines: [String] = []
        func finish() {
            guard let name = fields["name"], let type = fields["type"] else {
                fields.removeAll()
                signalLines.removeAll()
                return
            }
            let detail: String
            if type == "parsed" {
                guard fields["protocol"] != nil, fields["address"] != nil, fields["command"] != nil else {
                    fields.removeAll(); signalLines.removeAll(); return
                }
                detail = "\(fields["protocol"] ?? "?") · \(fields["address"] ?? "?") · \(fields["command"] ?? "?")"
            } else if type == "raw" {
                guard fields["frequency"] != nil, fields["duty_cycle"] != nil, fields["data"] != nil else {
                    fields.removeAll(); signalLines.removeAll(); return
                }
                detail = "RAW · \(fields["frequency"] ?? "?") Hz"
            } else {
                fields.removeAll()
                signalLines.removeAll()
                return
            }
            let file = "Filetype: IR signals file\nVersion: 1\n#\n" + signalLines.joined(separator: "\n") + "\n"
            entries.append(UniversalIREntry(id: entries.count, name: name, detail: detail, signalFile: file))
            fields.removeAll()
            signalLines.removeAll()
        }
        for line in content.components(separatedBy: .newlines) {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean == "#" { finish(); continue }
            guard let colon = clean.firstIndex(of: ":") else { continue }
            let key = String(clean[..<colon]).lowercased()
            let value = String(clean[clean.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if ["name", "type", "protocol", "address", "command", "frequency", "duty_cycle", "data"].contains(key) {
                fields[key] = value
                signalLines.append(clean)
            }
        }
        finish()
        return entries
    }
}
