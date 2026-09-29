import Foundation

/// Codex 0.158.0's `tui.terminal_title=["session-id"]` emits the first 29
/// characters of the thread UUID followed by `...`. Resolve only against
/// session IDs already read from this app's private Codex profile.
enum CodexSessionIdentity {
    static func prefix(fromTerminalTitle title: String) -> String? {
        let bytes = Array(title.utf8)
        guard bytes.count == 32, Array(bytes[29...31]) == [46, 46, 46] else { return nil }
        for index in 0..<29 {
            let byte = bytes[index]
            if [8, 13, 18, 23].contains(index) {
                guard byte == 45 else { return nil }
            } else {
                guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else {
                    return nil
                }
            }
        }
        return String(decoding: bytes[0..<29], as: UTF8.self).lowercased()
    }

    static func uniqueMatch(prefix: String, in sessionIDs: [String]) -> String? {
        guard Self.prefix(fromTerminalTitle: prefix + "...") == prefix.lowercased() else { return nil }
        let matches = Set(sessionIDs
            .filter { UUID(uuidString: $0) != nil && $0.lowercased().hasPrefix(prefix.lowercased()) }
            .map { $0.lowercased() })
        return matches.count == 1 ? matches.first : nil
    }
}
