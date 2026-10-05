import Foundation

struct ConversationMessage: Identifiable, Equatable, Sendable {
    let id: String
    let speaker: String
    let text: String
}

struct ConversationTranscriptSnapshot: Equatable, Sendable {
    var messages: [ConversationMessage] = []
    var foundFile = false
    var error: String?
}

/// Reads only this conversation's provider log. No second transcript store
/// is created, and growing logs are read from the last complete JSON line.
actor ConversationTranscriptReader {
    private let agent: Agent
    private let profile: URL
    private let conversationID: String
    private var file: URL?
    private var inode: UInt64?
    private var offset: UInt64 = 0
    private var lineNumber = 0
    private var pending = Data()
    private var skippingLine = false
    private var seen = Set<String>()
    private var snapshot = ConversationTranscriptSnapshot()
    private var nextSearch = Date.distantPast

    init(agent: Agent, profile: URL, conversationID: String) {
        self.agent = agent
        self.profile = profile
        self.conversationID = conversationID.lowercased()
    }

    func read() -> ConversationTranscriptSnapshot {
        guard UUID(uuidString: conversationID) != nil else { return snapshot }
        if file == nil, Date() >= nextSearch {
            file = findFile()
            nextSearch = Date().addingTimeInterval(2)
        }
        guard let file else { return snapshot }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            let currentInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            if currentInode != inode || size < offset {
                offset = 0
                lineNumber = 0
                pending.removeAll()
                skippingLine = false
                seen.removeAll()
                snapshot.messages.removeAll()
                inode = currentInode
            }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            // Stop at the size observed above, even if a busy CLI keeps writing.
            while offset < size, !Task.isCancelled {
                guard let chunk = try handle.read(upToCount: Int(min(65_536, size - offset))), !chunk.isEmpty else { break }
                offset += UInt64(chunk.count)
                consume(chunk)
            }
            snapshot.foundFile = true
            snapshot.error = nil
        } catch {
            snapshot.error = "Conversation messages could not be read. Open Terminal to continue."
            self.file = nil
        }
        return snapshot
    }

    private func findFile() -> URL? {
        let root = profile.appendingPathComponent(agent == .claude ? "projects" : "sessions", isDirectory: true)
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return nil }
        for case let candidate as URL in files where candidate.pathExtension == "jsonl" {
            // Claude's subagent logs must never be confused with its parent.
            let name = candidate.deletingPathExtension().lastPathComponent.lowercased()
            if agent == .claude ? name == conversationID : name.hasSuffix("-" + conversationID) {
                return candidate
            }
        }
        return nil
    }

    private func consume(_ chunk: Data) {
        var start = chunk.startIndex
        for index in chunk.indices where chunk[index] == 0x0a {
            if !skippingLine {
                pending.append(chunk[start..<index])
                if pending.count <= 8_388_608 { consumeLine(pending) }
            }
            pending.removeAll(keepingCapacity: true)
            skippingLine = false
            start = chunk.index(after: index)
        }
        if !skippingLine {
            pending.append(chunk[start...])
            if pending.count > 8_388_608 {
                pending.removeAll(keepingCapacity: true)
                skippingLine = true
            }
        }
    }

    private func consumeLine(_ data: Data) {
        lineNumber += 1
        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let message: [String: Any]
        let key: String
        if agent == .claude {
            guard ["user", "assistant"].contains(row["type"] as? String ?? ""),
                  row["isSidechain"] as? Bool != true, row["isMeta"] as? Bool != true,
                  row["isCompactSummary"] as? Bool != true,
                  let content = row["message"] as? [String: Any] else { return }
            if let id = row["sessionId"] as? String, id.lowercased() != conversationID { return }
            message = content
            key = messageKey(row["uuid"] as? String)
        } else {
            // event_msg mirrors these response items, so reading both would
            // repeat replies. Reasoning and tool output are separate items.
            guard row["type"] as? String == "response_item",
                  let payload = row["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  !["analysis", "summary"].contains(payload["channel"] as? String ?? ""),
                  !["analysis", "summary"].contains(payload["phase"] as? String ?? "") else { return }
            message = payload
            key = messageKey(payload["id"] as? String)
        }
        guard let role = message["role"] as? String, ["user", "assistant"].contains(role) else { return }
        let text = visibleText(message["content"], role: role)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(key).inserted else { return }
        snapshot.messages.append(ConversationMessage(id: key, speaker: role == "user" ? "you" : agent.rawValue, text: text))
    }

    private func messageKey(_ id: String?) -> String {
        if let id, !id.isEmpty { return id }
        return "line:\(lineNumber)"
    }

    private func visibleText(_ content: Any?, role: String) -> String {
        if let text = content as? String { return text }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            switch block["type"] as? String {
            case "text", "input_text", "output_text":
                guard let text = block["text"] as? String else { return nil }
                // Codex records its injected workspace instructions as user
                // messages too; they are context rather than chat turns.
                if agent == .codex, role == "user",
                   text.hasPrefix("# AGENTS.md instructions for ") || text.hasPrefix("<environment_context>") {
                    return nil
                }
                return text
            case "image", "input_image": return "[Image attachment]"
            default: return nil
            }
        }.joined(separator: "\n\n")
    }
}
