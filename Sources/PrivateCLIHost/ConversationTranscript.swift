import Foundation
import SQLite3

struct ConversationMessage: Identifiable, Equatable, Sendable {
    let id: String
    let speaker: String
    let text: String
    /// The tool steps an agent took between two replies. A message carries
    /// either text or steps, never both.
    var steps: [ConversationStep] = []
}

/// One tool call, titled the way a build log titles a step.
struct ConversationStep: Equatable, Sendable {
    enum Kind: Sendable { case read, search, edit, run, web, other }

    let id: String
    let kind: Kind
    let title: String
    /// The file a read or an edit touched, so a summary counts it once.
    var file: String?
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
    private var database: OpaquePointer?
    private var lastMessageRow: Int64 = 0

    init(agent: Agent, profile: URL, conversationID: String) {
        self.agent = agent
        self.profile = profile
        self.conversationID = conversationID.lowercased()
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func read() -> ConversationTranscriptSnapshot {
        guard agent.isConversationID(conversationID) else { return snapshot }
        if agent == .hermes { return readHermes() }
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

    /// Hermes keeps messages in its session database, read here without
    /// writing. A compressed conversation continues in a child session, and
    /// the summary that seeds it is context rather than a chat turn.
    private func readHermes() -> ConversationTranscriptSnapshot {
        if database == nil {
            guard Date() >= nextSearch else { return snapshot }
            nextSearch = Date().addingTimeInterval(2)
            let url = profile.appendingPathComponent("state.db")
            var handle: OpaquePointer?
            guard FileManager.default.fileExists(atPath: url.path),
                  sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                  let handle else {
                if let handle { sqlite3_close(handle) }
                return snapshot
            }
            sqlite3_busy_timeout(handle, 200)
            database = handle
        }
        let query = """
            WITH RECURSIVE chain(id) AS (
                SELECT ?1
                UNION
                SELECT child.id FROM sessions child
                JOIN sessions parent ON child.parent_session_id = parent.id
                JOIN chain ON parent.id = chain.id
                WHERE parent.end_reason = 'compression'
            )
            SELECT id, role, content, tool_calls FROM messages
            WHERE session_id IN chain AND id > ?2 AND role IN ('user', 'assistant')
              AND IFNULL(active, 1) != 0 AND IFNULL(display_kind, '') != 'hidden'
            ORDER BY id
            """
        var statement: OpaquePointer?
        guard let database, sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK, let statement else {
            return closeHermes()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, conversationID, -1, transient)
        sqlite3_bind_int64(statement, 2, lastMessageRow)
        var step = sqlite3_step(statement)
        while step == SQLITE_ROW {
            let row = sqlite3_column_int64(statement, 0)
            lastMessageRow = max(lastMessageRow, row)
            let role = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let text = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let isSummary = role == "user" && (text.hasPrefix("[CONTEXT COMPACTION") || text.hasPrefix("[CONTEXT SUMMARY]"))
            if !isSummary, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                snapshot.messages.append(ConversationMessage(id: "hermes:\(row)", speaker: role == "user" ? "you" : "hermes", text: text))
            }
            if role == "assistant", let calls = sqlite3_column_text(statement, 3),
               let list = try? JSONSerialization.jsonObject(with: Data(String(cString: calls).utf8)) as? [[String: Any]] {
                for (index, call) in list.enumerated() {
                    guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { continue }
                    let arguments = (function["arguments"] as? String).flatMap {
                        try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
                    } ?? [:]
                    append(.hermes(id: call["id"] as? String ?? "hermes:\(row):\(index)", name: name, arguments: arguments))
                }
            }
            step = sqlite3_step(statement)
        }
        guard step == SQLITE_DONE || step == SQLITE_BUSY else { return closeHermes() }
        snapshot.foundFile = true
        snapshot.error = nil
        return snapshot
    }

    private func closeHermes() -> ConversationTranscriptSnapshot {
        if let database { sqlite3_close(database) }
        database = nil
        snapshot.error = "Conversation messages could not be read. Open Terminal to continue."
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
            // Tool calls are read from the items Codex completes, which
            // carry the command and files rather than the script around them.
            if row["type"] as? String == "event_msg", let payload = row["payload"] as? [String: Any],
               payload["type"] as? String == "item_completed", let item = payload["item"] as? [String: Any] {
                ConversationStep.codex(item).forEach(append)
                return
            }
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
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seen.insert(key).inserted {
            snapshot.messages.append(ConversationMessage(id: key, speaker: role == "user" ? "you" : agent.rawValue, text: text))
        }
        guard agent == .claude, role == "assistant", let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks where block["type"] as? String == "tool_use" {
            guard let id = block["id"] as? String, let name = block["name"] as? String else { continue }
            append(.claude(id: id, name: name, input: block["input"] as? [String: Any] ?? [:]))
        }
    }

    /// Steps in a row share one activity entry; a message starts the next.
    private func append(_ step: ConversationStep) {
        guard seen.insert("step:" + step.id).inserted else { return }
        if let last = snapshot.messages.indices.last, !snapshot.messages[last].steps.isEmpty {
            snapshot.messages[last].steps.append(step)
        } else {
            snapshot.messages.append(ConversationMessage(id: "steps:" + step.id, speaker: agent.rawValue, text: "", steps: [step]))
        }
    }

    private func messageKey(_ id: String?) -> String {
        if let id, !id.isEmpty { return id }
        return "line:\(lineNumber)"
    }

    private func visibleText(_ content: Any?, role: String) -> String {
        if let text = content as? String {
            return agent == .claude && role == "user" ? Self.claudeShellText(text) ?? text : text
        }
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

    /// Claude logs a `!` command as tagged user text, `<bash-input>`, and its
    /// result as `<bash-stdout>` and `<bash-stderr>`. Chat shows the command
    /// as it was typed and the result as plain text; no result, no message.
    private static func claudeShellText(_ text: String) -> String? {
        func tagged(_ name: String) -> String? {
            guard let open = text.range(of: "<\(name)>"),
                  let close = text.range(of: "</\(name)>", range: open.upperBound..<text.endIndex) else { return nil }
            return String(text[open.upperBound..<close.lowerBound])
        }
        if text.hasPrefix("<bash-input>"), let command = tagged("bash-input") {
            return "! " + command.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.hasPrefix("<bash-stdout>") || text.hasPrefix("<bash-stderr>") else { return nil }
        return [tagged("bash-stdout"), tagged("bash-stderr")]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

extension ConversationStep {
    static func claude(id: String, name: String, input: [String: Any]) -> ConversationStep {
        func value(_ key: String) -> String { (input[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        switch name {
        case "Bash":
            // Claude describes each command it runs; the command is the fallback.
            let description = value("description")
            return ConversationStep(id: id, kind: .run, title: description.isEmpty ? phrase("Run", command(value("command"))) : description)
        case "Read": return file(id, .read, "Read", value("file_path"))
        case "Edit", "MultiEdit": return file(id, .edit, "Edit", value("file_path"))
        case "Write": return file(id, .edit, "Write", value("file_path"))
        case "NotebookEdit": return file(id, .edit, "Edit", value("notebook_path"))
        case "Grep": return ConversationStep(id: id, kind: .search, title: phrase("Search for", value("pattern")))
        case "Glob": return ConversationStep(id: id, kind: .search, title: phrase("Find", value("pattern")))
        case "WebSearch": return ConversationStep(id: id, kind: .web, title: phrase("Search the web for", value("query")))
        case "WebFetch": return ConversationStep(id: id, kind: .web, title: phrase("Open", host(value("url"))))
        case "Agent", "Task": return ConversationStep(id: id, kind: .other, title: value("description").isEmpty ? "Run an agent" : value("description"))
        case "Skill": return skill(id, value("skill"))
        case "AskUserQuestion": return ConversationStep(id: id, kind: .other, title: "Ask a question")
        default: return ConversationStep(id: id, kind: .other, title: tool(name))
        }
    }

    static func codex(_ item: [String: Any]) -> [ConversationStep] {
        guard let id = item["id"] as? String else { return [] }
        func value(_ object: [String: Any]?, _ key: String) -> String { object?[key] as? String ?? "" }
        switch item["type"] as? String {
        case "CommandExecution":
            // Codex names a command's parts only when it understood every one.
            let parts = item["parsed_cmd"] as? [[String: Any]] ?? []
            if !parts.isEmpty, parts.allSatisfy({ ["read", "search", "list_files"].contains(value($0, "type")) }) {
                return parts.enumerated().map { index, part in
                    let partID = parts.count == 1 ? id : "\(id):\(index)"
                    let path = value(part, "path")
                    switch value(part, "type") {
                    case "read": return file(partID, .read, "Read", path.isEmpty ? value(part, "name") : path)
                    case "search":
                        let query = value(part, "query")
                        return ConversationStep(id: partID, kind: .search, title: query.isEmpty ? phrase("Search", fileName(path)) : "Search for " + query)
                    default: return ConversationStep(id: partID, kind: .search, title: path.isEmpty ? "List files" : "List files in " + fileName(path))
                    }
                }
            }
            let script = (item["command"] as? [String])?.last ?? value(item, "command")
            return [ConversationStep(id: id, kind: .run, title: phrase("Run", command(script)))]
        case "FileChange":
            let changes = item["changes"] as? [String: [String: Any]] ?? [:]
            return changes.keys.sorted().map { path in
                let verb = ["add": "Create", "delete": "Delete"][value(changes[path], "type")] ?? "Edit"
                return file(id + ":" + path, .edit, verb, path)
            }
        case "ImageView":
            return [file(id, .read, "View", value(item, "path"))]
        case "Extension":
            // Waiting on a timer is not a step.
            switch value(item, "kind") {
            case "web.search":
                let action = item["action"] as? [String: Any]
                if ["openPage", "findInPage"].contains(value(action, "type")) {
                    return [ConversationStep(id: id, kind: .web, title: phrase("Open", host(value(action, "url"))))]
                }
                return [ConversationStep(id: id, kind: .web, title: phrase("Search the web for", value(item, "query")))]
            case "image_gen.generation": return [ConversationStep(id: id, kind: .other, title: "Generate an image")]
            default: return []
            }
        case "McpToolCall":
            return [ConversationStep(id: id, kind: .other, title: tool("mcp__\(value(item, "server"))__\(value(item, "tool"))"))]
        default: return []
        }
    }

    static func hermes(id: String, name: String, arguments: [String: Any]) -> ConversationStep {
        func value(_ key: String) -> String { (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        switch name {
        case "terminal": return ConversationStep(id: id, kind: .run, title: phrase("Run", command(value("command"))))
        case "read_file": return file(id, .read, "Read", value("path"))
        case "write_file": return file(id, .edit, "Write", value("path"))
        case "patch": return file(id, .edit, "Edit", value("path"))
        case "search_files": return ConversationStep(id: id, kind: .search, title: phrase("Search for", value("pattern")))
        case "session_search": return ConversationStep(id: id, kind: .search, title: phrase("Search past sessions for", value("query")))
        case "web_search": return ConversationStep(id: id, kind: .web, title: phrase("Search the web for", value("query")))
        case "web_extract":
            let url = (arguments["urls"] as? [String])?.first ?? ""
            return ConversationStep(id: id, kind: .web, title: phrase("Open", host(url)))
        case "skill_view": return skill(id, value("name"))
        case "clarify": return ConversationStep(id: id, kind: .other, title: "Ask a question")
        case "memory": return ConversationStep(id: id, kind: .other, title: "Update memory")
        default: return ConversationStep(id: id, kind: .other, title: tool(name))
        }
    }

    /// "Read 3 files, edited 2 files and ran 9 commands". A file counts once
    /// however often it was read or edited.
    static func summary(_ steps: [ConversationStep]) -> String {
        var touched: [Kind: Set<String>] = [:]
        for step in steps { touched[step.kind, default: []].insert(step.file ?? step.id) }
        func count(_ kind: Kind) -> Int { touched[kind]?.count ?? 0 }
        func files(_ count: Int) -> String { count == 1 ? "1 file" : "\(count) files" }
        func times(_ count: Int) -> String { count == 1 ? "once" : "\(count) times" }
        var parts: [String] = []
        if count(.read) > 0 { parts.append("read " + files(count(.read))) }
        if count(.search) > 0 { parts.append("searched " + times(count(.search))) }
        if count(.edit) > 0 { parts.append("edited " + files(count(.edit))) }
        if count(.run) > 0 { parts.append(count(.run) == 1 ? "ran 1 command" : "ran \(count(.run)) commands") }
        if count(.web) > 0 { parts.append("used the web " + times(count(.web))) }
        if count(.other) > 0 {
            let noun = parts.isEmpty ? "tool" : "other tool"
            parts.append("used \(count(.other)) \(noun)\(count(.other) == 1 ? "" : "s")")
        }
        guard let last = parts.popLast() else { return "" }
        let sentence = parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    private static func file(_ id: String, _ kind: Kind, _ verb: String, _ path: String) -> ConversationStep {
        ConversationStep(id: id, kind: kind, title: phrase(verb, fileName(path)), file: path.isEmpty ? nil : path)
    }

    private static func skill(_ id: String, _ name: String) -> ConversationStep {
        ConversationStep(id: id, kind: .other, title: name.isEmpty ? "Use a skill" : "Use the \(name) skill")
    }

    private static func phrase(_ verb: String, _ object: String) -> String {
        object.isEmpty ? verb : verb + " " + object
    }

    private static func fileName(_ path: String) -> String {
        let path = path.hasPrefix("file://") ? URL(string: path)?.path ?? path : path
        return (path as NSString).lastPathComponent
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// The first line of a command, without the `cd` into the project that
    /// agents often put in front of it.
    private static func command(_ script: String) -> String {
        var line = script.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if let prefix = line.range(of: #"^\s*cd\s+("[^"]*"|'[^']*'|\S+)\s*(&&|;)\s*"#, options: .regularExpression) {
            line.removeSubrange(prefix)
        }
        return String(line.trimmingCharacters(in: .whitespaces).prefix(160))
    }

    /// `mcp__claude_ai_Gmail__search_threads` reads as "Gmail: search threads".
    private static func tool(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else {
            return name.prefix(1).uppercased() + name.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
        let server = parts[1].hasPrefix("claude_ai_") ? String(parts[1].dropFirst(10)) : parts[1]
        return server.replacingOccurrences(of: "_", with: " ") + ": " + parts[2...].joined(separator: " ").replacingOccurrences(of: "_", with: " ")
    }
}
