import Foundation
import SQLite3
import XCTest
@testable import PrivateCLIHost

final class ConversationHistoryLoaderTests: XCTestCase {
    func testSQLiteAndClaudeHistoryUsePrivateProfilesAndDeduplicate() throws {
        let root = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let claude = root.appendingPathComponent("claude", isDirectory: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)

        let claudeID = "11111111-1111-4111-8111-111111111111"
        let codexID = "22222222-2222-4222-8222-222222222222"
        let archivedID = "33333333-3333-4333-8333-333333333333"
        let subagentID = "44444444-4444-4444-8444-444444444444"
        let badPathID = "88888888-8888-4888-8888-888888888888"
        let longTitleID = "99999999-9999-4999-8999-999999999999"
        var history = """
        {"sessionId":"\(claudeID)","timestamp":3000,"project":"/work/a","display":"Later prompt"}
        {"sessionId":"\(claudeID)","timestamp":1000,"project":"/work/a/../a","display":"  First   prompt\\nwith detail  "}
        {"sessionId":"\(claudeID)","timestamp":2000,"project":"/work/a","display":"Middle prompt"}
        malformed JSON
        {"sessionId":"bad-id","timestamp":4000,"project":"/work/a","display":"Bad"}
        {"sessionId":"55555555-5555-4555-8555-555555555555","timestamp":5000,"project":
        """
        let longPrompt = String(repeating: "e\u{301}", count: 200)
        history += "\n{\"sessionId\":\"\(longTitleID)\",\"timestamp\":1500,\"project\":\"/work/a\",\"display\":\"\(longPrompt)\"}\n"
        try history.write(to: claude.appendingPathComponent("history.jsonl"), atomically: true, encoding: .utf8)

        let dbURL = codex.appendingPathComponent("state_5.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        guard let db else { return XCTFail("Could not create fixture database") }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads (id TEXT, cwd TEXT, name TEXT, title TEXT,
          first_user_message TEXT, updated_at_ms INTEGER, updated_at INTEGER,
          thread_source TEXT, source TEXT, archived INTEGER);
        INSERT INTO threads VALUES ('\(codexID)', '/work/a', 'Named thread', 'First question',
          'First question', 4000, 4, 'user', 'cli', 0);
        INSERT INTO threads VALUES ('\(archivedID)', '/work/a', 'Archived', 'Archived',
          'Archived', 5000, 5, 'user', 'cli', 1);
        INSERT INTO threads VALUES ('\(subagentID)', '/work/a', 'Subagent', 'Subagent',
          'Subagent', 6000, 6, 'subagent', '{}', 0);
        INSERT INTO threads VALUES ('\(badPathID)', 'relative/work', 'Bad path', 'Bad path',
          'Bad path', 7000, 7, 'user', 'cli', 0);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)

        let records = ConversationHistoryLoader.load(profileBase: root)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.id), ["codex:\(codexID)", "claude:\(claudeID)", "claude:\(longTitleID)"])
        XCTAssertEqual(records[0].title, "Named thread")
        XCTAssertEqual(records[1].title, "First prompt with detail")
        XCTAssertEqual(records[1].projectPath, "/work/a")
        XCTAssertEqual(records[1].updatedAt.timeIntervalSince1970, 3)
        if let longTitle = records.first(where: { $0.sessionID == longTitleID })?.title {
            XCTAssertEqual(longTitle.count, 140)
            XCTAssertTrue(longTitle.hasSuffix("…"))
        } else {
            XCTFail("Long prompt session was omitted")
        }
    }

    func testCodexRolloutFallbackUsesIndexAndSkipsSubagents() throws {
        let root = try temporaryProfile()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        let sessions = codex.appendingPathComponent("sessions/2026/09/28", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)

        let userID = "66666666-6666-4666-8666-666666666666"
        let subagentID = "77777777-7777-4777-8777-777777777777"
        let userFile = sessions.appendingPathComponent("rollout-2026-09-28T12-00-00-\(userID).jsonl")
        let subagentFile = sessions.appendingPathComponent("rollout-2026-09-28T12-00-01-\(subagentID).jsonl")
        try """
        {"type":"session_meta","payload":{"id":"\(userID)","cwd":"/work/b/../b","thread_source":"user","source":"cli"}}
        {"partial":
        """.write(to: userFile, atomically: true, encoding: .utf8)
        try """
        {"type":"session_meta","payload":{"id":"\(subagentID)","cwd":"/work/b","thread_source":"subagent","source":{"subagent":{}}}}
        """.write(to: subagentFile, atomically: true, encoding: .utf8)
        try """
        {"id":"\(userID)","thread_name":" Indexed title ","updated_at":"2026-09-28T12:00:00Z"}
        malformed
        """.write(to: codex.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let records = ConversationHistoryLoader.load(profileBase: root)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "codex:\(userID)")
        XCTAssertEqual(records[0].title, "Indexed title")
        XCTAssertEqual(records[0].projectPath, "/work/b")
    }

    private func temporaryProfile() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateCLIHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
