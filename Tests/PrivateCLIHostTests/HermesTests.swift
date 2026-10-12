import Foundation
import SQLite3
import XCTest
@testable import PrivateCLIHost

final class HermesTests: XCTestCase {
    private let rule = String(repeating: "─", count: 100)

    // Screens captured from Hermes Agent 0.20.0 in a 100 by 40 terminal, the
    // approval raised by a local model asking to run a dangerous command.

    private var idle: [String] {
        ["│                                                 29 tools · 71 skills · /help for commands        │",
         "╰──────────────────────────────────────────────────────────────────────────────────────────────────╯",
         "",
         "Welcome to Hermes Agent! Type your message or /help for commands.",
         "✦ Tip: Drop a ~/.hermes/BOOT.md checklist and a gateway:startup hook runs it as a one-shot agent",
         "every boot.",
         "",
         " ⚕ probe-model │ ctx -- │ [░░░░░░░░░░] -- │ 1s │ ⏲ 0s",
         rule, "❯", rule]
    }

    private var approval: [String] {
        ["╭─────────────────────────────────────────────────╮",
         "│ ⚠️  Dangerous Command                            │",
         "│                                                 │",
         "│ rm -rf /tmp/m4ix-hermes-probe-never-created     │",
         "│                                                 │",
         "│ ❯ 1. Allow once                                 │",
         "│   2. Allow for this session                     │",
         "│   3. Add to permanent allowlist                 │",
         "│   4. Deny                                       │",
         "│                                                 │",
         "│ delete in root path                             │",
         "╰─────────────────────────────────────────────────╯",
         "",
         "  💻 rm -rf /tmp/m4ix-hermes-probe-never-created  (01m54s)",
         "  ↑/↓ to select, Enter to confirm  (186s)",
         " ⚕ probe-model │ 0/65.5K │ [░░░░░░░░░░] 0% │ 2m │ ⏱ 1m 55s",
         rule, "⚠ ❯", rule]
    }

    func testHermesAcceptsTextOnlyAtItsBareRuledInput() {
        XCTAssertTrue(CLIPrompt.acceptsText(screen: idle, agent: .hermes))
        XCTAssertEqual(CLIPrompt.inputStartRow(screen: idle, agent: .hermes), idle.count - 3)
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: idle, agent: .hermes))
        XCTAssertFalse(CLIPrompt.hermesIsWorking(screen: idle))

        // A non-default Hermes profile names itself before the prompt.
        var profile = idle
        profile[profile.count - 2] = "work ❯"
        XCTAssertTrue(CLIPrompt.acceptsText(screen: profile, agent: .hermes))
        XCTAssertFalse(CLIPrompt.claudeAcceptsText(screen: profile), "Only Hermes names profiles at its prompt")

        // Replies that quote a prompt glyph leave the idle input usable.
        let quoted = ["● Show me the command", "  ❯ npm test", "Done.", " ⚕ x │ ctx --", rule, "❯", rule]
        XCTAssertTrue(CLIPrompt.acceptsText(screen: quoted, agent: .hermes))
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: quoted, agent: .hermes))
    }

    func testHermesApprovalsAndQuestionsBlockTheComposer() {
        XCTAssertFalse(CLIPrompt.acceptsText(screen: approval, agent: .hermes), "Return would choose Allow once")
        XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: approval, agent: .hermes))
        XCTAssertNil(CLIPrompt.inputStartRow(screen: approval, agent: .hermes), "Questions must not be concealed")
        XCTAssertFalse(CLIPrompt.hermesIsWorking(screen: approval))

        // A later Hermes that left its prompt bare under the panel is still refused.
        var bare = approval
        bare[bare.count - 2] = "❯"
        XCTAssertFalse(CLIPrompt.acceptsText(screen: bare, agent: .hermes))
        XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: bare, agent: .hermes))

        // Its confirmations number choices in brackets inside the same kind of panel.
        let confirm = ["╭──────────────────────────────────────────────╮",
                       "│ Confirm action                               │",
                       "│ ❯ [1] Yes — reset the conversation           │",
                       "│   [2] No — keep it                           │",
                       "│ Type 1/2/3 or use ↑/↓ then Enter. ESC/Ctrl+C cancels. │",
                       "╰──────────────────────────────────────────────╯",
                       " ⚕ x │ ctx --", rule]
        for input in ["⚠ ❯", "❯"] {
            XCTAssertFalse(CLIPrompt.acceptsText(screen: confirm + [input, rule], agent: .hermes), input)
            XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: confirm + [input, rule], agent: .hermes), input)
        }

        let setup = ["⚕ No inference provider is configured yet — let's fix that.",
                     "  You'll pick a provider (Nous Portal OAuth is the fastest; no API key needed) and a model.",
                     "  Set up a provider now? [Y/n]:"]
        XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: setup, agent: .hermes))
        XCTAssertFalse(CLIPrompt.acceptsText(screen: setup, agent: .hermes))

        for marked in ["? ❯", "✎ ❯", "🔐 ❯", "🔑 ❯"] {
            XCTAssertFalse(CLIPrompt.acceptsText(screen: Array(idle.dropLast(2)) + [marked, rule], agent: .hermes), marked)
        }
    }

    func testHermesWorkingInputWaitsForTheTurnToEnd() {
        let working = ["● Please tidy the probe folder", "Initializing agent...", "  ┊ 💻 preparing terminal…",
                       " ⚕ probe-model │ 0/65.5K │ [░░░░░░░░░░] 0% │ 3s", rule, "⚕ ❯", rule]
        XCTAssertTrue(CLIPrompt.hermesIsWorking(screen: working))
        XCTAssertFalse(CLIPrompt.acceptsText(screen: working, agent: .hermes))
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: working, agent: .hermes))
    }

    func testHermesSessionIDsComeFromItsBanner() {
        let banner = "│  /private/tmp/claude-502/-Users-max-blomqvist…  github: codebase-inspection, github-auth, +4     │\n"
            + "│         Session: 20261011_235810_097908         more                                             │\n"
        XCTAssertEqual(CLIPrompt.hermesSessionID(in: banner), "20261011_235810_097908")
        XCTAssertNil(CLIPrompt.hermesSessionID(in: "Session: 67af9c61-8ee9-4e90-8b28-29e427c554b0"))
        XCTAssertNil(CLIPrompt.hermesSessionID(in: "no banner yet"))

        XCTAssertTrue(Agent.hermes.isConversationID("20260902_114247_cd5a7bf5"))
        XCTAssertTrue(Agent.hermes.isConversationID("20261011_235540_a37dd0"))
        XCTAssertFalse(Agent.hermes.isConversationID("67af9c61-8ee9-4e90-8b28-29e427c554b0"))
        XCTAssertFalse(Agent.hermes.isConversationID("20261011_235540_a37dd0; rm"))
        XCTAssertFalse(Agent.claude.isConversationID("20261011_235540_a37dd0"))
        XCTAssertTrue(Agent.codex.isConversationID("67af9c61-8ee9-4e90-8b28-29e427c554b0"))
    }

    func testComposerRunsOnHermes020AndNewer() {
        let output = "Hermes Agent v0.20.0 (2026.8.3)\nInstall directory: /Users/me/.hermes/hermes-agent\nPython: 3.11.15\n"
        let compatibility = ProviderCompatibility.evaluate(output, agent: .hermes)
        XCTAssertEqual(compatibility.version, "0.20.0")
        XCTAssertTrue(compatibility.usesComposer)
        XCTAssertTrue(ProviderCompatibility.evaluate("Hermes Agent v0.21.3 (2026.9.1)", agent: .hermes).usesComposer)
        XCTAssertFalse(ProviderCompatibility.evaluate("Hermes Agent v0.19.9 (2026.7.1)", agent: .hermes).usesComposer)
    }

    func testHermesHomeFollowsHermesHomeAndTheActiveProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let user = root.appendingPathComponent("user", isDirectory: true)

        XCTAssertEqual(HermesHome.resolve(environment: [:], userHome: user).path, user.appendingPathComponent(".hermes").path)
        XCTAssertEqual(HermesHome.resolve(environment: ["HERMES_HOME": root.path], userHome: user).path, root.path)
        try "work\n".write(to: root.appendingPathComponent("active_profile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HermesHome.resolve(environment: ["HERMES_HOME": root.path], userHome: user).path,
                       root.appendingPathComponent("profiles/work").path)
        let named = root.appendingPathComponent("profiles/coder").path
        XCTAssertEqual(HermesHome.resolve(environment: ["HERMES_HOME": named], userHome: user).path, named)
        try "../escape\n".write(to: root.appendingPathComponent("active_profile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HermesHome.resolve(environment: ["HERMES_HOME": root.path], userHome: user).path, root.path)
        try "default\n".write(to: root.appendingPathComponent("active_profile"), atomically: true, encoding: .utf8)
        XCTAssertEqual(HermesHome.resolve(environment: ["HERMES_HOME": root.path], userHome: user).path, root.path)
        XCTAssertEqual(Agent.hermes.profileDirectory(in: root), HermesHome.current())
        XCTAssertEqual(Agent.claude.profileDirectory(in: root), root.appendingPathComponent("claude", isDirectory: true))
    }

    func testHermesModelMenuNamesTheConfiguredModelAndOffersReasoningLevels() throws {
        let config = """
            # Hermes configuration
            model:
              default: anthropic/claude-fable-5.1
              provider: nous
              base_url: https://inference-api.nousresearch.com/v1
            display:
              default: not-a-model
            """
        XCTAssertEqual(ModelCatalog.hermesDefaultModel(in: config), "anthropic/claude-fable-5.1")
        XCTAssertEqual(ModelCatalog.hermesDefaultModel(in: "model: \"openai/gpt-5.5\"\n"), "openai/gpt-5.5")
        XCTAssertNil(ModelCatalog.hermesDefaultModel(in: "display:\n  default: x\n"))

        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-config-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try config.write(to: home.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let catalog = ModelCatalog.load(agent: .hermes, profileDirectory: home)
        XCTAssertTrue(catalog.options.isEmpty, "Hermes models stay with hermes model")
        XCTAssertEqual(catalog.defaultModel, "anthropic/claude-fable-5.1")
        XCTAssertEqual(catalog.efforts(for: nil), ModelCatalog.hermesEfforts)
        XCTAssertEqual(ModelCatalog.load(agent: .claude, profileDirectory: home).defaultEfforts, [])
    }

    func testHermesHistoryListsEachProjectConversationOnce() throws {
        let project = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-project-\(UUID().uuidString)").path
        let home = try hermesHome([
            "INSERT INTO sessions (id, source, cwd, title, end_reason) VALUES ('20261001_090000_aaaaaa', 'cli', '\(project)', 'Fix the parser', 'compression')",
            "INSERT INTO sessions (id, source, cwd, parent_session_id) VALUES ('20261001_120000_bbbbbb', 'cli', '\(project)', '20261001_090000_aaaaaa')",
            "INSERT INTO sessions (id, source, cwd) VALUES ('20261002_090000_cccccc', 'cli', '\(project)')",
            "INSERT INTO sessions (id, source, cwd, parent_session_id) VALUES ('20261002_093000_dddddd', 'cli', '\(project)', '20261002_090000_cccccc')",
            "INSERT INTO sessions (id, source, cwd) VALUES ('20261003_090000_eeeeee', 'slack', '\(project)')",
            "INSERT INTO sessions (id, source, cwd, archived) VALUES ('20261003_100000_ffffff', 'cli', '\(project)', 1)",
            "INSERT INTO sessions (id, source, cwd) VALUES ('20261003_110000_abcdef', 'cli', NULL)",
            "INSERT INTO sessions (id, source, cwd) VALUES ('20261003_120000_fedcba', 'cli', '\(project)')",
            "INSERT INTO sessions (id, source, cwd) VALUES ('not-a-hermes-id', 'cli', '\(project)')",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_090000_aaaaaa', 'user', 'Fix the parser', 100)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_120000_bbbbbb', 'user', 'Now the tests', 500)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261002_090000_cccccc', 'user', 'Plan the   release\nwith notes', 200)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261002_093000_dddddd', 'user', 'Review pass', 900)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261003_090000_eeeeee', 'user', 'From Slack', 300)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261003_100000_ffffff', 'user', 'Archived', 300)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261003_110000_abcdef', 'user', 'No folder', 300)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261003_120000_fedcba', 'assistant', 'Only a reply', 300)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('not-a-hermes-id', 'user', 'Bad ID', 300)"
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let records = ConversationHistoryLoader.loadHermes(home).sorted { $0.sessionID < $1.sessionID }
        XCTAssertEqual(records.map(\.sessionID), ["20261001_090000_aaaaaa", "20261002_090000_cccccc"])
        XCTAssertTrue(records.allSatisfy { $0.provider == "hermes" && $0.projectPath == project })
        XCTAssertEqual(records[0].title, "Fix the parser")
        XCTAssertEqual(records[0].updatedAt, Date(timeIntervalSince1970: 500), "A compressed conversation is as recent as its continuation")
        XCTAssertEqual(records[1].title, "Plan the release with notes")
        XCTAssertEqual(records[1].updatedAt, Date(timeIntervalSince1970: 200), "A review child is not a continuation")

        let all = ConversationHistoryLoader.load(profileBase: home.appendingPathComponent("profiles"), hermesHome: home)
        XCTAssertEqual(all.map(\.sessionID), ["20261001_090000_aaaaaa", "20261002_090000_cccccc"])
        XCTAssertTrue(ConversationHistoryLoader.loadHermes(home.appendingPathComponent("missing")).isEmpty)
    }

    func testHermesChatFollowsCompressionAndReadsOnlyNewMessages() async throws {
        let home = try hermesHome([
            "INSERT INTO sessions (id, source, cwd, end_reason) VALUES ('20261001_090000_aaaaaa', 'cli', '/tmp', 'compression')",
            "INSERT INTO sessions (id, source, cwd, parent_session_id) VALUES ('20261001_120000_bbbbbb', 'cli', '/tmp', '20261001_090000_aaaaaa')",
            "INSERT INTO sessions (id, source, cwd, parent_session_id) VALUES ('20261001_130000_cccccc', 'cli', '/tmp', '20261001_120000_bbbbbb')",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_090000_aaaaaa', 'user', 'Fix the parser', 1)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_090000_aaaaaa', 'assistant', '', 2)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_090000_aaaaaa', 'tool', '{\"ok\": true}', 3)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_090000_aaaaaa', 'assistant', 'Done.', 4)",
            "INSERT INTO messages (session_id, role, content, timestamp, display_kind) VALUES ('20261001_090000_aaaaaa', 'assistant', 'Hidden note', 5, 'hidden')",
            "INSERT INTO messages (session_id, role, content, timestamp, active) VALUES ('20261001_090000_aaaaaa', 'user', 'Rewound', 6, 0)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_120000_bbbbbb', 'user', '[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted', 7)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_120000_bbbbbb', 'user', 'Now the tests', 8)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_120000_bbbbbb', 'assistant', 'Tests pass.', 9)",
            "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_130000_cccccc', 'user', 'A branch, not a continuation', 10)"
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let reader = ConversationTranscriptReader(agent: .hermes, profile: home, conversationID: "20261001_090000_aaaaaa")
        let first = await reader.read()
        XCTAssertTrue(first.foundFile)
        XCTAssertNil(first.error)
        XCTAssertEqual(first.messages.map(\.speaker), ["you", "hermes", "you", "hermes"])
        XCTAssertEqual(first.messages.map(\.text), ["Fix the parser", "Done.", "Now the tests", "Tests pass."])

        try execute(home, "INSERT INTO messages (session_id, role, content, timestamp) VALUES ('20261001_120000_bbbbbb', 'assistant', 'One more thing.', 11)")
        let second = await reader.read()
        XCTAssertEqual(second.messages.map(\.text), ["Fix the parser", "Done.", "Now the tests", "Tests pass.", "One more thing."])
        XCTAssertEqual(Set(second.messages.map(\.id)).count, second.messages.count)

        let unknown = await ConversationTranscriptReader(agent: .hermes, profile: home, conversationID: "20261009_090000_999999").read()
        XCTAssertTrue(unknown.foundFile)
        XCTAssertTrue(unknown.messages.isEmpty)
        let invalid = await ConversationTranscriptReader(agent: .hermes, profile: home,
                                                         conversationID: "67af9c61-8ee9-4e90-8b28-29e427c554b0").read()
        XCTAssertFalse(invalid.foundFile)
    }

    /// A Hermes home whose database has the columns the app reads, written in
    /// WAL mode and closed, as when Hermes is not running.
    private func hermesHome(_ statements: [String]) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try execute(home, """
            PRAGMA journal_mode=WAL;
            CREATE TABLE sessions (id TEXT PRIMARY KEY, source TEXT NOT NULL, cwd TEXT, title TEXT, parent_session_id TEXT,
                end_reason TEXT, archived INTEGER NOT NULL DEFAULT 0, started_at REAL NOT NULL DEFAULT 0);
            CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL,
                content TEXT, timestamp REAL NOT NULL, active INTEGER NOT NULL DEFAULT 1, display_kind TEXT);
            """)
        for statement in statements { try execute(home, statement) }
        return home
    }

    /// Opt-in: runs the installed Hermes through the launcher and a hosted
    /// terminal, against a local model that asks to run a dangerous command.
    /// Hermes gets a throwaway home, so the user's own Hermes is never read.
    @MainActor
    func testInstalledHermesStartsAnswersAndRaisesItsApprovalInTheHost() async throws {
        guard ProcessInfo.processInfo.environment["M4IX_HERMES_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set M4IX_HERMES_LIVE_TESTS=1 to run the installed Hermes against a local test model")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-live-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = HermesHome.current()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let port = Int.random(in: 18_000...19_999)
        try "model:\n  provider: custom\n  base_url: http://127.0.0.1:\(port)/v1\n  default: probe-model\n"
            .write(to: home.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let server = try startLocalModel(port: port, in: root)
        defer { server.terminate() }

        let session = TerminalSession(agent: .hermes, projectPath: project.path, title: "Live Hermes",
                                      profileBase: root.appendingPathComponent("profiles"))
        defer { session.stop() }
        session.launch(.run, in: project)
        try await wait(seconds: 180, "Hermes did not reach its input") {
            session.refreshPromptReadiness()
            _ = session.updateActivity(now: Date())
            return session.acceptsPromptText && session.activeConversationID != nil
        }
        let id = try XCTUnwrap(session.activeConversationID)
        XCTAssertTrue(Agent.hermes.isConversationID(id), id)

        XCTAssertTrue(session.sendPrompt("Please tidy the probe folder"))
        try await wait(seconds: 90, "Hermes did not raise its approval") {
            session.refreshPromptReadiness()
            return session.terminalResponseRequest != nil
        }
        XCTAssertFalse(session.acceptsPromptText)
        XCTAssertFalse(session.sendPrompt("must not answer the approval"), "Return would choose Allow once")
        try await wait(seconds: 5, "The approval was not marked for attention") {
            _ = session.updateActivity(now: Date())
            return session.takeNotification() != nil
        }

        // Deny is the fourth choice.
        session.terminal.send(data: Array("\u{1b}[B\u{1b}[B\u{1b}[B".utf8)[...])
        try await Task.sleep(nanoseconds: 300_000_000)
        session.terminal.send(data: [0x0d][...])
        try await wait(seconds: 90, "Hermes did not return to its input after the denial") {
            session.refreshPromptReadiness()
            return session.acceptsPromptText
        }

        try await wait(seconds: 30, "The conversation did not reach Hermes's history") {
            ConversationHistoryLoader.loadHermes(home).contains { $0.sessionID == id && $0.projectPath == project.path }
        }
        let transcript = await ConversationTranscriptReader(agent: .hermes, profile: home, conversationID: id).read()
        XCTAssertEqual(transcript.messages.first?.text, "Please tidy the probe folder")
        XCTAssertEqual(transcript.messages.first?.speaker, "you")
        XCTAssertTrue(transcript.messages.contains { $0.speaker == "hermes" && $0.text == "Done." }, "\(transcript.messages)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/m4ix-hermes-probe-never-created"))
        session.stop()
        try await wait(seconds: 10, "Hermes did not stop") { !session.state.isRunning }
    }

    private func startLocalModel(port: Int, in root: URL) throws -> Process {
        let script = root.appendingPathComponent("local-model.py")
        try #"""
        import json, sys, threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        lock, sent = threading.Lock(), [False]
        def chunk(delta, finish=None):
            return {"id": "probe", "object": "chat.completion.chunk", "created": 0, "model": "probe-model",
                    "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def reply(self, body, kind="application/json"):
                data = body.encode()
                self.send_response(200); self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self):
                self.reply(json.dumps({"object": "list", "data": [{"id": "probe-model", "object": "model", "context_length": 65536}]}))
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
                tools = [t.get("function", {}).get("name") for t in request.get("tools") or []]
                answered = any(m.get("role") == "tool" for m in request.get("messages") or [])
                with lock:
                    call = "terminal" in tools and not answered and not sent[0]
                    sent[0] = sent[0] or call
                tool = {"index": 0, "id": "call_probe", "type": "function", "function": {"name": "terminal",
                        "arguments": json.dumps({"command": "rm -rf /tmp/m4ix-hermes-probe-never-created"})}}
                if request.get("stream"):
                    events = [chunk({"role": "assistant", "tool_calls": [tool]}), chunk({}, "tool_calls")] if call \
                        else [chunk({"role": "assistant", "content": "Done."}), chunk({}, "stop")]
                    self.reply("".join("data: %s\n\n" % json.dumps(e) for e in events) + "data: [DONE]\n\n", "text/event-stream")
                    return
                message = {"role": "assistant", "content": None, "tool_calls": [tool]} if call else {"role": "assistant", "content": "Done."}
                self.reply(json.dumps({"id": "probe", "object": "chat.completion", "created": 0, "model": "probe-model",
                    "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if call else "stop"}],
                    "usage": {"prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2}}))
        ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
        """#.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", script.path, String(port)]
        try process.run()
        return process
    }

    @MainActor
    private func wait(seconds: TimeInterval, _ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { XCTFail(message); throw CommandError.timedOut }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func execute(_ home: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(home.appendingPathComponent("state.db").path, &database) == SQLITE_OK, let database else {
            throw CommandError.failed("Could not open the fixture database")
        }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CommandError.failed(String(cString: sqlite3_errmsg(database)))
        }
    }
}
