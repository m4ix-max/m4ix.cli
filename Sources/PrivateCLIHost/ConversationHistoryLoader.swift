import Foundation
import SQLite3

struct ConversationRecord: Identifiable, Equatable {
    let provider: String
    let sessionID: String
    let projectPath: String
    let title: String
    let updatedAt: Date

    var id: String { "\(provider):\(sessionID)" }
}

enum ConversationHistoryLoader {
    static func load(profileBase: URL, cache: ConversationHistoryCache? = nil) -> [ConversationRecord] {
        let codexProfile = profileBase.appendingPathComponent("codex", isDirectory: true)
        let claudeProfile = profileBase.appendingPathComponent("claude", isDirectory: true)
        let codex = loadCodexFromSQLite(codexProfile) ?? loadCodexFromRollouts(codexProfile)
        let claude = cache?.claude(profile: claudeProfile, loader: { loadClaude(claudeProfile) }) ?? loadClaude(claudeProfile)
        return (codex + claude).sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    private struct ClaudeSession {
        var projectPath: String
        var projectTimestamp: Int64
        var title: String
        var titleTimestamp: Int64
        var updatedTimestamp: Int64
    }

    private static func loadClaude(_ profile: URL) -> [ConversationRecord] {
        let history = profile.appendingPathComponent("history.jsonl")
        var sessions: [String: ClaudeSession] = [:]

        forEachJSONLine(at: history) { row in
            guard let sessionID = row["sessionId"] as? String,
                  UUID(uuidString: sessionID) != nil,
                  let timestamp = (row["timestamp"] as? NSNumber)?.int64Value,
                  timestamp > 0,
                  let rawProject = row["project"] as? String,
                  let project = normalizedProjectPath(rawProject) else { return }

            let display = cleanTitle(row["display"] as? String)
            if var session = sessions[sessionID] {
                session.updatedTimestamp = max(session.updatedTimestamp, timestamp)
                if timestamp < session.projectTimestamp {
                    session.projectPath = project
                    session.projectTimestamp = timestamp
                }
                if !display.isEmpty && timestamp < session.titleTimestamp {
                    session.title = display
                    session.titleTimestamp = timestamp
                }
                sessions[sessionID] = session
            } else {
                sessions[sessionID] = ClaudeSession(
                    projectPath: project,
                    projectTimestamp: timestamp,
                    title: display,
                    titleTimestamp: display.isEmpty ? Int64.max : timestamp,
                    updatedTimestamp: timestamp
                )
            }
        }

        return sessions.map { sessionID, value in
            ConversationRecord(
                provider: "claude",
                sessionID: sessionID,
                projectPath: value.projectPath,
                title: value.title.isEmpty ? "Claude conversation" : value.title,
                updatedAt: Date(timeIntervalSince1970: Double(value.updatedTimestamp) / 1_000)
            )
        }
    }

    // Codex keeps its session metadata in a WAL-backed SQLite database. The
    // connection is strictly read-only, so a running CLI retains ownership.
    private static func loadCodexFromSQLite(_ profile: URL) -> [ConversationRecord]? {
        let files = (try? FileManager.default.contentsOfDirectory(at: profile, includingPropertiesForKeys: nil)) ?? []
        let databases = files.compactMap { url -> (version: Int, url: URL)? in
            let name = url.lastPathComponent
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (version, url)
        }.sorted { $0.version > $1.version }

        for (_, url) in databases {
            var database: OpaquePointer?
            let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            guard result == SQLITE_OK, let database else {
                if let database { sqlite3_close(database) }
                continue
            }
            defer { sqlite3_close(database) }

            let columns = sqliteColumns(in: "threads", database: database)
            guard columns.contains("id"), columns.contains("cwd") else { continue }

            func field(_ name: String) -> String { columns.contains(name) ? name : "NULL" }
            let query = """
                SELECT id, cwd, \(field("name")), \(field("title")),
                       \(field("first_user_message")), \(field("updated_at_ms")),
                       \(field("updated_at")), \(field("thread_source")),
                       \(field("source")), \(field("archived"))
                FROM threads
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
                  let statement else { continue }
            defer { sqlite3_finalize(statement) }

            var records: [ConversationRecord] = []
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                let sessionID = sqliteText(statement, 0)
                let cwd = sqliteText(statement, 1)
                let threadSource = sqliteText(statement, 7)
                let source = sqliteText(statement, 8)
                let archived = sqlite3_column_type(statement, 9) != SQLITE_NULL && sqlite3_column_int(statement, 9) != 0

                if UUID(uuidString: sessionID) != nil,
                   let projectPath = normalizedProjectPath(cwd), !archived,
                   isUserThread(threadSource: threadSource, source: source) {
                    let candidates: [String] = [sqliteText(statement, 2), sqliteText(statement, 3), sqliteText(statement, 4)]
                        .map { cleanTitle($0) }
                    let title: String = candidates.first(where: { !$0.isEmpty }) ?? "Codex conversation"
                    let updatedMilliseconds = sqlite3_column_type(statement, 5) == SQLITE_NULL
                        ? Int64(0) : sqlite3_column_int64(statement, 5)
                    let updatedSeconds = sqlite3_column_type(statement, 6) == SQLITE_NULL
                        ? Int64(0) : sqlite3_column_int64(statement, 6)
                    let updatedAt = Date(timeIntervalSince1970: updatedMilliseconds > 0
                        ? Double(updatedMilliseconds) / 1_000 : Double(updatedSeconds))
                    records.append(ConversationRecord(
                        provider: "codex", sessionID: sessionID, projectPath: projectPath,
                        title: title, updatedAt: updatedAt
                    ))
                }
                step = sqlite3_step(statement)
            }
            if step == SQLITE_DONE { return records }
        }
        return nil
    }

    private static func sqliteColumns(in table: String, database: OpaquePointer) -> Set<String> {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW { columns.insert(sqliteText(statement, 1)) }
        return columns
    }

    private static func sqliteText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: value)
    }

    private static func isUserThread(threadSource: String, source: String) -> Bool {
        if !threadSource.isEmpty { return threadSource == "user" }
        if source == "subagent" { return false }
        if let data = source.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           object["subagent"] != nil { return false }
        return true
    }

    private struct CodexIndexEntry {
        let title: String
        let updatedAt: Date?
    }

    // Older or damaged Codex profiles may have rollouts without a readable
    // state database. Their first event contains the session's cwd and origin.
    private static func loadCodexFromRollouts(_ profile: URL) -> [ConversationRecord] {
        let indexURL = profile.appendingPathComponent("session_index.jsonl")
        var index: [String: CodexIndexEntry] = [:]
        forEachJSONLine(at: indexURL) { row in
            guard let id = row["id"] as? String, UUID(uuidString: id) != nil else { return }
            let title = cleanTitle(row["thread_name"] as? String)
            let updated = (row["updated_at"] as? String).flatMap(parseISODate)
            if let prior = index[id], (prior.updatedAt ?? .distantPast) > (updated ?? .distantPast) {
                return
            }
            index[id] = CodexIndexEntry(title: title, updatedAt: updated)
        }

        let sessionsURL = profile.appendingPathComponent("sessions", isDirectory: true)
        guard let files = FileManager.default.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var records: [String: ConversationRecord] = [:]
        for case let file as URL in files where file.pathExtension == "jsonl" {
            let stem = file.deletingPathExtension().lastPathComponent
            let nameID = String(stem.suffix(36))
            guard UUID(uuidString: nameID) != nil,
                  let metadata = firstCodexMetadata(in: file) else { continue }
            let id = metadata.id.isEmpty ? nameID : metadata.id
            guard UUID(uuidString: id) != nil,
                  let projectPath = normalizedProjectPath(metadata.cwd),
                  isUserThread(threadSource: metadata.threadSource, source: metadata.source) else { continue }
            let indexed = index[id]
            let title = indexed?.title.isEmpty == false ? indexed!.title : "Codex conversation"
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let updatedAt = max(indexed?.updatedAt ?? .distantPast, modified ?? .distantPast)
            let record = ConversationRecord(
                provider: "codex", sessionID: id, projectPath: projectPath,
                title: title, updatedAt: updatedAt
            )
            if let previous = records[id], previous.updatedAt > record.updatedAt { continue }
            records[id] = record
        }
        return Array(records.values)
    }

    private struct CodexMetadata {
        let id: String
        let cwd: String
        let threadSource: String
        let source: String
    }

    private static func firstCodexMetadata(in file: URL) -> CodexMetadata? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let prefix = try? handle.read(upToCount: 262_144) else { return nil }
        for line in prefix.split(separator: 0x0A, omittingEmptySubsequences: true).prefix(12) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["type"] as? String == "session_meta",
                  let payload = row["payload"] as? [String: Any] else { continue }
            let id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? ""
            let cwd = (payload["cwd"] as? String) ?? ""
            let threadSource = (payload["thread_source"] as? String) ?? ""
            let source: String
            if let text = payload["source"] as? String { source = text }
            else if let value = payload["source"],
                    let data = try? JSONSerialization.data(withJSONObject: value),
                    let text = String(data: data, encoding: .utf8) { source = text }
            else { source = "" }
            if !cwd.isEmpty { return CodexMetadata(id: id, cwd: cwd, threadSource: threadSource, source: source) }
        }
        return nil
    }

    private static func forEachJSONLine(at url: URL, _ body: ([String: Any]) -> Void) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        var pending = Data()
        var skippingOversizedLine = false
        let maximumLineBytes = 1_048_576
        func consume(_ line: Data) {
            guard !line.isEmpty,
                  let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            body(row)
        }
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            var start = chunk.startIndex
            for index in chunk.indices where chunk[index] == 0x0a {
                if !skippingOversizedLine {
                    pending.append(chunk[start..<index])
                    if pending.count <= maximumLineBytes { consume(pending) }
                }
                pending.removeAll(keepingCapacity: true)
                skippingOversizedLine = false
                start = chunk.index(after: index)
            }
            if !skippingOversizedLine {
                pending.append(chunk[start...])
                if pending.count > maximumLineBytes {
                    pending.removeAll(keepingCapacity: true)
                    skippingOversizedLine = true
                }
            }
        }
        if !skippingOversizedLine { consume(pending) }
    }

    private static func cleanTitle(_ raw: String?) -> String {
        let normalized = (raw ?? "").split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard normalized.count > 140 else { return normalized }
        return String(normalized.prefix(139)) + "…"
    }

    private static func normalizedProjectPath(_ raw: String) -> String? {
        guard raw.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
    }

    private static func parseISODate(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}


/// Runtime cache for the append-only Claude history. Codex's SQLite query
/// stays fresh on every refresh; unchanged Claude logs avoid repeated parsing.
final class ConversationHistoryCache: @unchecked Sendable {
    private struct Fingerprint: Equatable {
        let size: UInt64
        let modified: Date
        let inode: UInt64
    }
    private let lock = NSLock()
    private var entries: [String: (Fingerprint, [ConversationRecord])] = [:]

    private func fingerprint(_ url: URL) -> Fingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return Fingerprint(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }

    func claude(profile: URL, loader: () -> [ConversationRecord]) -> [ConversationRecord] {
        let url = profile.appendingPathComponent("history.jsonl")
        guard let before = fingerprint(url) else { return loader() }
        if let cached = lock.withLock({ entries[url.path] }), cached.0 == before { return cached.1 }
        let records = loader()
        if fingerprint(url) == before { lock.withLock { entries[url.path] = (before, records) } }
        return records
    }
}
