import AppKit
import SwiftUI
import XCTest
@testable import PrivateCLIHost

final class ConversationTranscriptTests: XCTestCase {
    func testCodexUsesVisibleResponseItemsWithoutMirrorsOrInternalContext() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let file = try logFile(root, agent: .codex, id: id)
        let rows: [[String: Any]] = [
            codexMessage("developer", "Hidden system instructions"),
            codexMessage("user", "# AGENTS.md instructions for /work\nHidden workspace instructions"),
            codexMessage("user", "<environment_context>Hidden machine context</environment_context>"),
            codexMessage("user", "Show me the website"),
            codexMessage("assistant", "Private reasoning", phase: "analysis"),
            ["type": "event_msg", "payload": ["type": "agent_message", "message": "Duplicated reply"]],
            ["type": "response_item", "payload": ["type": "function_call_output", "output": "Tool output"]],
            codexMessage("assistant", "Checking the site", phase: "commentary"),
            codexMessage("assistant", "Visit [Example](https://example.com) or https://example.org.", phase: "final")
        ]
        try write(rows, to: file)
        let reader = ConversationTranscriptReader(agent: .codex, profile: root, conversationID: id)
        let snapshot = await reader.read()
        XCTAssertTrue(snapshot.foundFile)
        XCTAssertEqual(snapshot.messages.map(\.speaker), ["you", "codex", "codex"])
        XCTAssertEqual(snapshot.messages.map(\.text), ["Show me the website", "Checking the site",
                                                     "Visit [Example](https://example.com) or https://example.org."])
        XCTAssertEqual(Set(snapshot.messages.map(\.id)).count, 3, "Empty provider message IDs must not collapse distinct replies")
        let unchanged = await reader.read()
        XCTAssertEqual(unchanged, snapshot)
    }

    func testClaudeSkipsToolsSidechainsAndOtherSessionsAndShowsImages() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let file = try logFile(root, agent: .claude, id: id)
        let rows: [[String: Any]] = [
            claudeMessage("user", content: "Open the link", id: "u1", session: id),
            claudeMessage("user", content: [["type": "tool_result", "content": "Hidden command output"]], id: "tool", session: id),
            claudeMessage("assistant", content: [["type": "thinking", "thinking": "Hidden reasoning"]], id: "thinking", session: id),
            claudeMessage("assistant", content: "Wrong session", id: "other", session: UUID().uuidString),
            claudeMessage("assistant", content: "Subagent output", id: "subagent", session: id, sidechain: true),
            claudeMessage("user", content: [["type": "image"], ["type": "text", "text": "Look at this"]], id: "image", session: id),
            claudeMessage("assistant", content: [["type": "text", "text": "https://example.com"]], id: "a1", session: id),
            claudeMessage("assistant", content: [["type": "text", "text": "https://example.com"]], id: "a1", session: id)
        ]
        try write(rows, to: file)
        let reader = ConversationTranscriptReader(agent: .claude, profile: root, conversationID: id)
        let snapshot = await reader.read()
        XCTAssertEqual(snapshot.messages.map(\.text), ["Open the link", "[Image attachment]\n\nLook at this", "https://example.com"])
        XCTAssertEqual(snapshot.messages.map(\.speaker), ["you", "you", "claude"])
    }

    func testIncrementalReadsWaitForCompleteLinesAndRecoverFromReplacement() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let file = try logFile(root, agent: .codex, id: id)
        try write([codexMessage("user", "First")], to: file)
        let reader = ConversationTranscriptReader(agent: .codex, profile: root, conversationID: id)
        let first = await reader.read()
        XCTAssertEqual(first.messages.map(\.text), ["First"])
        let row = try JSONSerialization.data(withJSONObject: codexMessage("assistant", "Second café https://example.com"))
        let split = row.count / 2
        try append(row.prefix(split), to: file)
        let partial = await reader.read()
        XCTAssertEqual(partial, first)
        try append(row.suffix(row.count - split) + Data([0x0a]), to: file)
        let second = await reader.read()
        XCTAssertEqual(second.messages.map(\.text), ["First", "Second café https://example.com"])
        XCTAssertEqual(second.messages.first?.id, first.messages.first?.id)
        try write([codexMessage("user", "Replaced log")], to: file)
        let replaced = await reader.read()
        XCTAssertEqual(replaced.messages.map(\.text), ["Replaced log"])
    }

    func testFindsOnlyExactConversationAndSkipsMalformedRows() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let other = try logFile(root, agent: .codex, id: UUID().uuidString.lowercased())
        try write([codexMessage("user", "Another conversation")], to: other)
        let missing = ConversationTranscriptReader(agent: .codex, profile: root, conversationID: id)
        let absent = await missing.read()
        XCTAssertFalse(absent.foundFile)
        XCTAssertTrue(absent.messages.isEmpty)
        let file = try logFile(root, agent: .codex, id: id)
        try Data("malformed JSON\n".utf8).write(to: file)
        try append(JSONSerialization.data(withJSONObject: codexMessage("assistant", "Correct conversation")) + Data([0x0a]), to: file)
        let reader = ConversationTranscriptReader(agent: .codex, profile: root, conversationID: id)
        let loaded = await reader.read()
        XCTAssertEqual(loaded.messages.map(\.text), ["Correct conversation"])
    }

    func testClaudeToolCallsBecomeStepsBetweenReplies() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let file = try logFile(root, agent: .claude, id: id)
        try write([
            claudeMessage("user", content: "Fix the parser", id: "u1", session: id),
            claudeMessage("assistant", content: [toolUse("t1", "Read", ["file_path": "/work/Parser.swift"])], id: "a1", session: id),
            claudeMessage("user", content: [["type": "tool_result", "tool_use_id": "t1", "content": "Hidden source"]], id: "r1", session: id),
            claudeMessage("assistant", content: [toolUse("t2", "Edit", ["file_path": "/work/Parser.swift"])], id: "a2", session: id),
            claudeMessage("assistant", content: [toolUse("t3", "Edit", ["file_path": "/work/Parser.swift"])], id: "a3", session: id),
            claudeMessage("assistant", content: [toolUse("t4", "Bash", ["command": "swift test", "description": "Run the parser tests"])], id: "a4", session: id),
            claudeMessage("assistant", content: [toolUse("t5", "Bash", ["command": "cd \"/work dir\" && swift build\necho done"])], id: "a5", session: id),
            claudeMessage("assistant", content: [toolUse("t5", "Bash", ["command": "swift build"])], id: "a5", session: id),
            claudeMessage("assistant", content: [toolUse("t6", "Read", ["file_path": "/subagent"])], id: "s1", session: id, sidechain: true),
            claudeMessage("assistant", content: "Fixed.", id: "a6", session: id),
            claudeMessage("assistant", content: [toolUse("t7", "mcp__claude_ai_Gmail__search_threads", [:])], id: "a7", session: id)
        ], to: file)
        let snapshot = await ConversationTranscriptReader(agent: .claude, profile: root, conversationID: id).read()
        XCTAssertEqual(snapshot.messages.map(\.speaker), ["you", "claude", "claude", "claude"])
        XCTAssertEqual(snapshot.messages.map(\.text), ["Fix the parser", "", "Fixed.", ""])
        XCTAssertEqual(snapshot.messages[1].steps.map(\.title),
                       ["Read Parser.swift", "Edit Parser.swift", "Edit Parser.swift", "Run the parser tests", "Run swift build"])
        XCTAssertEqual(ConversationStep.summary(snapshot.messages[1].steps), "Read 1 file, edited 1 file and ran 2 commands")
        XCTAssertEqual(snapshot.messages[3].steps.map(\.title), ["Gmail: search threads"])
        XCTAssertEqual(ConversationStep.summary(snapshot.messages[3].steps), "Used 1 tool")
    }

    func testCodexStepsComeFromCompletedItems() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let file = try logFile(root, agent: .codex, id: id)
        func completed(_ item: [String: Any]) -> [String: Any] {
            ["type": "event_msg", "payload": ["type": "item_completed", "item": item]]
        }
        try write([
            codexMessage("user", "Tidy the readme"),
            ["type": "response_item", "payload": ["type": "custom_tool_call", "name": "exec", "input": "const hidden = 1"]],
            completed(["type": "CommandExecution", "id": "c1", "command": ["/bin/zsh", "-lc", "ls docs && cat docs/README.md"],
                       "parsed_cmd": [["type": "list_files", "cmd": "ls docs", "path": "docs"],
                                      ["type": "read", "cmd": "cat docs/README.md", "name": "README.md", "path": "docs/README.md"]]]),
            completed(["type": "CommandExecution", "id": "c2", "command": ["/bin/zsh", "-lc", "swift test 2>&1 | tail\nexit"],
                       "parsed_cmd": [["type": "unknown", "cmd": "swift test 2>&1 | tail"]]]),
            completed(["type": "FileChange", "id": "f1", "changes": ["docs/README.md": ["type": "update"], "docs/NEW.md": ["type": "add"]]]),
            completed(["type": "Extension", "kind": "clock.sleep", "id": "e0"]),
            completed(["type": "Extension", "kind": "web.search", "id": "e1", "query": "swift testing",
                       "action": ["type": "search", "query": "swift testing"]]),
            completed(["type": "Extension", "kind": "web.search", "id": "e2",
                       "action": ["type": "openPage", "url": "https://www.swift.org/documentation/"]]),
            completed(["type": "AgentMessage", "id": "m1", "content": [["type": "Text", "text": "Mirrored reply"]]]),
            codexMessage("assistant", "Tidied.", phase: "final_answer")
        ], to: file)
        let snapshot = await ConversationTranscriptReader(agent: .codex, profile: root, conversationID: id).read()
        XCTAssertEqual(snapshot.messages.map(\.text), ["Tidy the readme", "", "Tidied."])
        XCTAssertEqual(snapshot.messages[1].steps.map(\.title), ["List files in docs", "Read README.md", "Run swift test 2>&1 | tail",
                                                                 "Create NEW.md", "Edit README.md", "Search the web for swift testing",
                                                                 "Open www.swift.org"])
        XCTAssertEqual(ConversationStep.summary(snapshot.messages[1].steps),
                       "Read 1 file, searched once, edited 2 files, ran 1 command and used the web 2 times")
    }

    private func toolUse(_ id: String, _ name: String, _ input: [String: Any]) -> [String: Any] {
        ["type": "tool_use", "id": id, "name": name, "input": input]
    }

    private func codexMessage(_ role: String, _ text: String, phase: String = "") -> [String: Any] {
        ["type": "response_item", "payload": ["type": "message", "id": "", "role": role, "phase": phase,
            "content": [["type": role == "user" ? "input_text" : "output_text", "text": text]]]]
    }

    private func claudeMessage(_ role: String, content: Any, id: String, session: String, sidechain: Bool = false) -> [String: Any] {
        ["type": role, "uuid": id, "sessionId": session, "isSidechain": sidechain,
         "message": ["role": role, "content": content]]
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-transcript-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func logFile(_ root: URL, agent: Agent, id: String) throws -> URL {
        let folder = root.appendingPathComponent(agent == .claude ? "projects/project" : "sessions/2026/10/05")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(agent == .claude ? id + ".jsonl" : "rollout-2026-10-05T12-00-00-" + id + ".jsonl")
    }

    private func write(_ rows: [[String: Any]], to file: URL) throws {
        let data = try rows.reduce(into: Data()) { result, row in
            result.append(try JSONSerialization.data(withJSONObject: row))
            result.append(0x0a)
        }
        try data.write(to: file, options: .atomic)
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

@MainActor
final class ConversationChatTests: XCTestCase {
    func testWebLinksPreferSafariWhileFilesAndMailUseTheirUsualApps() throws {
        var safariLinks: [URL] = []
        var defaultLinks: [URL] = []
        let urls = [try XCTUnwrap(URL(string: "https://example.com/docs?q=one#details")),
                    try XCTUnwrap(URL(string: "http://example.org")),
                    URL(fileURLWithPath: "/tmp/example.swift"),
                    try XCTUnwrap(URL(string: "mailto:hello@example.com")),
                    try XCTUnwrap(URL(string: "javascript:alert(1)"))]
        for url in urls {
            ChatLinkOpener.open(url, openDefault: { defaultLinks.append($0) }, openSafari: { destination, completion in
                safariLinks.append(destination)
                completion(true)
            })
        }
        XCTAssertEqual(safariLinks, Array(urls.prefix(2)))
        XCTAssertEqual(defaultLinks, Array(urls[2...3]))
    }

    func testUnavailableSafariFallsBackToTheDefaultBrowser() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/docs"))
        var opened: [URL] = []
        ChatLinkOpener.open(url, openDefault: { opened.append($0) }, openSafari: { _, completion in completion(false) })
        XCTAssertEqual(opened, [url])
    }

    func testMarkdownAndBareURLsAreClickableButCodeURLsArePlainText() throws {
        let text = "Read [the docs](https://example.com/docs). Bare https://example.org/page?q=one&b=two. Code `https://example.net/code`."
        let attributed = ChatMessageFormatting.attributedText(text)
        var links: [String] = []
        attributed.enumerateAttribute(.link, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let url = value as? URL { links.append(url.absoluteString) }
        }
        XCTAssertEqual(links, ["https://example.com/docs", "https://example.org/page?q=one&b=two"])
        XCTAssertFalse(attributed.string.contains("[the docs]"))
        let code = ChatMessageFormatting.attributedText("curl https://example.com", code: true)
        XCTAssertNil(code.attribute(.link, at: 8, effectiveRange: nil))
        let source = ChatMessageFormatting.attributedText("[source](/tmp/example.swift:12)")
        let file = try XCTUnwrap(source.attribute(.link, at: 0, effectiveRange: nil) as? URL)
        XCTAssertTrue(file.isFileURL)
        XCTAssertEqual(file.path, "/tmp/example.swift")
    }

    func testLinkHandlerOpensTheDestinationAndKeepsMessageSelectable() throws {
        let view = ChatLinkTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        view.textStorage?.setAttributedString(ChatMessageFormatting.attributedText("Open [the website](https://example.com/target)."))
        let destination = try XCTUnwrap(view.textStorage?.attribute(.link, at: 7, effectiveRange: nil))
        var opened: [URL] = []
        view.openURL = { opened.append($0) }
        XCTAssertTrue(view.textView(view, clickedOnLink: destination, at: 7))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/target"])
        view.setSelectedRange(NSRange(location: 0, length: 4))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 4))
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
    }

    func testOrdinaryMouseClickOpensWrappedLinkAndTextCanBeSelected() async throws {
        let view = ChatLinkTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.textStorage?.setAttributedString(ChatMessageFormatting.attributedText(
            "Click [this website with a label that wraps across several lines](https://example.com/target)."))
        view.frame.size.height = view.height(for: 320)
        let window = NSPanel(contentRect: view.frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let keyDeadline = Date().addingTimeInterval(3)
        while !window.isKeyWindow, Date() < keyDeadline {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        window.layoutIfNeeded()
        guard window.isKeyWindow else {
            throw XCTSkip("WindowServer focus is unavailable in this environment; native mouse dispatch needs a focused window.")
        }
        XCTAssertTrue(view.isRichText)
        var opened: [URL] = []
        view.openURL = { opened.append($0) }
        let manager = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        var linkRange = NSRange(location: NSNotFound, length: 0)
        view.textStorage?.enumerateAttribute(.link, in: NSRange(location: 0, length: view.string.utf16.count)) { value, range, _ in
            if value != nil { linkRange = range }
        }
        XCTAssertNotEqual(linkRange.location, NSNotFound)
        // Click near the end of the label, on its wrapped continuation line.
        let character = linkRange.location + linkRange.length - 3
        let glyph = manager.glyphIndexForCharacter(at: character)
        let rect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        func mouseEvent(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        NSApp.postEvent(try mouseEvent(.leftMouseUp), atStart: true)
        window.sendEvent(try mouseEvent(.leftMouseDown))
        while let event = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(event)
        }
        XCTAssertEqual(opened.map(\.absoluteString), ["https://example.com/target"])
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 5))
        XCTAssertFalse(view.isEditable)
        XCTAssertTrue(view.isSelectable)
    }

    func testConversationLoadsInChatAtFullAndSplitWidths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chat-layout-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID().uuidString.lowercased()
        let folder = root.appendingPathComponent("claude/projects/project")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let messages: [[String: Any]] = [
            ["type": "user", "uuid": "user", "sessionId": id, "message": ["role": "user", "content": "Can I click website links in this chat?"]],
            ["type": "assistant", "uuid": "reply", "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": "Yes. Open [Example](https://example.com) or https://example.org directly.\n\n```sh\necho 'Readable code, with a Copy button'\n```\n\nYou can select and copy this reply."]]]],
            ["type": "assistant", "uuid": "tools", "sessionId": id, "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/work/ChatMessageText.swift"]],
                ["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "swift test", "description": "Run the chat tests"]]]]],
            ["type": "assistant", "uuid": "more", "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": "A second message in the same reply shares its header."]]]],
            ["type": "user", "uuid": "next", "sessionId": id, "message": ["role": "user", "content": "Start the notch"]]
        ]
        let data = try messages.reduce(into: Data()) { output, row in
            output.append(try JSONSerialization.data(withJSONObject: row)); output.append(0x0a)
        }
        try data.write(to: folder.appendingPathComponent(id + ".jsonl"))
        let session = TerminalSession(agent: .claude, projectPath: root.path, title: "Chat preview", pendingResumeID: id, profileBase: root)
        for width in [800, 440] {
            let chat = SessionConversationView(session: session, showTerminal: .constant(false), isActive: true,
                onActivate: {}, onPromptFocus: {}, onTerminal: {}, onPasteImages: { _ in })
            XCTAssertFalse(chat.isShowingTerminal)
            let view = NSHostingView(rootView: chat)
            view.frame = NSRect(x: 0, y: 0, width: width, height: 550)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            defer { window.orderOut(nil) }
            let deadline = Date().addingTimeInterval(5)
            var textViews: [ChatLinkTextView] = []
            repeat {
                try await Task.sleep(nanoseconds: 50_000_000)
                view.layoutSubtreeIfNeeded()
                textViews = descendants(view).compactMap { $0 as? ChatLinkTextView }
            } while textViews.count < 6 && Date() < deadline
            XCTAssertEqual(textViews.count, 6)
            let reply = try XCTUnwrap(textViews.first { $0.string.contains("You can select") })
            let column = reply.convert(reply.bounds, to: view)
            for textView in textViews {
                let frame = textView.convert(textView.bounds, to: view)
                XCTAssertLessThanOrEqual(frame.maxX, CGFloat(width))
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThan(frame.height, 15)
                if ["Can I click", "Start the notch"].contains(where: textView.string.hasPrefix) {
                    // Your messages hug their text inside a block at the right.
                    XCTAssertEqual(frame.maxX, column.maxX - 14, accuracy: 1)
                    XCTAssertLessThan(frame.width, column.width - 64 - 28)
                    XCTAssertGreaterThan(frame.minX, column.minX + 64)
                } else {
                    XCTAssertGreaterThan(frame.width, 200)
                    XCTAssertEqual(frame.minX, column.minX, accuracy: 13)
                }
            }
            if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("conversation-chat-\(width).png"))
            }
        }
    }

    func testRepliesReadInASofterToneWithBoldAndHeadingsInInk() throws {
        let text = ChatMessageFormatting.attributedText("# Plan\nPlain words and **a bold lead** then `code`.")
        func color(of fragment: String) -> NSColor? {
            let range = (text.string as NSString).range(of: fragment)
            return text.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(color(of: "Plan"), ElevateTheme.nsInk)
        XCTAssertEqual(color(of: "Plain words"), ElevateTheme.nsReading)
        XCTAssertEqual(color(of: "a bold lead"), ElevateTheme.nsInk)
        XCTAssertEqual(color(of: "code"), ElevateTheme.nsReading)
        XCTAssertEqual(ChatMessageFormatting.attributedText("Your own message", markdown: false)
            .attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, ElevateTheme.nsReading)

        guard let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] else { return }
        let steps = [
            ConversationStep(id: "1", kind: .read, title: "Read host-events.jsonl", file: "/work/host-events.jsonl"),
            ConversationStep(id: "2", kind: .run, title: "Read the launch queue logic"),
            ConversationStep(id: "3", kind: .run, title: "Find the session limit")
        ]
        let conversation = VStack(alignment: .leading, spacing: 0) {
            ChatTurn(speaker: "you", text: "Why can't I use Codex in all my projects? The chat window is unclickable.")
            ChatTurn(speaker: "claude", text: "", steps: steps).padding(.top, 28)
            ChatTurn(speaker: "claude", text: """
                It isn't Codex, and it isn't your projects: m4ix.CLI runs at most four agent sessions at once, and all four are in use.
                - **Codex in your home folder:** it reopened "Check Eira Blender rendition" at 19:12.
                - **Three Claude sessions,** this one included.

                Any further session waits in a queue, and a waiting session's message box is locked. Press `⌘⇧K`, open **Sessions** and raise the limit.
                """, continues: true).padding(.top, 12)
            ChatTurn(speaker: "you", text: "Make the merge more than two cards side by side.").padding(.top, 28)
            ChatTurn(speaker: "codex", text: """
                Sir, I'll turn this into a prototype: a blinking cursor, a prompt, and generated components you can combine.

                The merge should do more than place two cards beside each other. A task list and a calendar should become a planner, with dated tasks appearing on the calendar. I'll build around that.
                """).padding(.top, 28)
        }
        .padding(24).frame(maxWidth: ElevateTheme.readingWidth, alignment: .leading).frame(width: 1000)
        .background(ElevateTheme.paper).foregroundStyle(ElevateTheme.ink)
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let view = NSHostingView(rootView: conversation)
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try FileManager.default.createDirectory(at: URL(fileURLWithPath: output), withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("chat-colours-\(name).png"))
        }
    }

    func testSizesSwiftUIOnlyAsksAboutLeaveTheShownTextAtItsWidth() throws {
        let long = "Sir, I'll turn this into a prototype: a blinking cursor, a prompt, and generated components you can combine."
        let controller = NSHostingController(rootView: VStack(spacing: 12) {
            ChatTurn(speaker: "you", text: "Make the merge more than two cards side by side. " + long)
            ChatTurn(speaker: "codex", text: long + "\n\n- A task list and a calendar become a planner.")
        }.frame(width: 800))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        controller.view.layoutSubtreeIfNeeded()
        // SwiftUI measures with proposals it does not place the view at,
        // down to no width at all.
        for width: CGFloat in [0, 60, 2_000] {
            _ = controller.sizeThatFits(in: CGSize(width: width, height: 10_000))
        }
        let textViews = descendants(controller.view).compactMap { $0 as? ChatLinkTextView }
        XCTAssertEqual(textViews.count, 2)
        for textView in textViews {
            let container = try XCTUnwrap(textView.textContainer)
            XCTAssertEqual(container.containerSize.width, textView.frame.width, accuracy: 0.5)
            XCTAssertGreaterThan(textView.frame.width, 300)
            let layoutManager = try XCTUnwrap(textView.layoutManager)
            layoutManager.ensureLayout(for: container)
            XCTAssertLessThanOrEqual(layoutManager.usedRect(for: container).height, textView.frame.height + 0.5,
                                     "Text must not run past the frame it was placed in")
        }
    }

    func testOpenActivityShowsOneLinePerStepAtFullAndSplitWidths() throws {
        let short = [
            ConversationStep(id: "1", kind: .read, title: "Read ConversationTranscript.swift", file: "/work/ConversationTranscript.swift"),
            ConversationStep(id: "2", kind: .search, title: "Search for ConversationTranscriptReader"),
            ConversationStep(id: "3", kind: .edit, title: "Edit ChatMessageText.swift", file: "/work/ChatMessageText.swift"),
            ConversationStep(id: "4", kind: .run, title: "Run the chat tests")
        ]
        var long = short
        long[3] = ConversationStep(id: "4", kind: .run, title: "Run " + Array(repeating: "swift test --filter ConversationChatTests", count: 6).joined(separator: " && "))
        for width in [800, 440] {
            func height(_ steps: [ConversationStep]) -> CGFloat {
                NSHostingController(rootView: ChatActivity(steps: steps, expanded: true))
                    .sizeThatFits(in: CGSize(width: CGFloat(width - 48), height: .greatestFiniteMagnitude)).height
            }
            XCTAssertEqual(height(long), height(short), accuracy: 0.5, "A long step truncates instead of wrapping")
            XCTAssertGreaterThan(height(short), NSHostingController(rootView: ChatActivity(steps: short))
                .sizeThatFits(in: CGSize(width: CGFloat(width - 48), height: .greatestFiniteMagnitude)).height * 3)
            if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
                let turn = VStack(alignment: .leading, spacing: 12) {
                    ChatTurn(speaker: "claude", text: "Reading the transcript code first.")
                    ChatActivity(steps: long, expanded: true)
                    ChatTurn(speaker: "claude", text: "The reader now keeps tool calls.", continues: true)
                    ChatActivity(steps: short)
                }.padding(24).frame(width: CGFloat(width)).background(ElevateTheme.paper).foregroundStyle(ElevateTheme.ink)
                let view = NSHostingView(rootView: turn)
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("chat-activity-\(width).png"))
            }
        }
    }

    func testListsQuotesAndHeadingsHangFromTheirMarkers() throws {
        let attributed = ChatMessageFormatting.attributedText("""
            ## Plan ##
            - A first item long enough to wrap onto a second line
              - A nested item
              continuing the nested item
            - [x] Done
            1. Numbered **bold** step
            10. Tenth step
            > Quoted line
            Plain paragraph
            """)
        let string = attributed.string as NSString
        XCTAssertEqual(attributed.string.components(separatedBy: "\n"), [
            "Plan", "•\tA first item long enough to wrap onto a second line", "◦\tA nested item",
            "continuing the nested item", "☑\tDone", "1.\tNumbered bold step", "10.\tTenth step",
            "Quoted line", "Plain paragraph"
        ])
        func style(_ text: String) throws -> NSParagraphStyle {
            try XCTUnwrap(attributed.attribute(.paragraphStyle, at: string.range(of: text).location, effectiveRange: nil) as? NSParagraphStyle)
        }
        let first = try style("A first"), nested = try style("A nested"), step = try style("Numbered")
        XCTAssertEqual(first.firstLineHeadIndent, 0)
        XCTAssertEqual(first.tabStops.first?.location, first.headIndent, "Wrapped lines start under the item's text")
        XCTAssertEqual(nested.firstLineHeadIndent, first.headIndent)
        XCTAssertGreaterThan(nested.headIndent, nested.firstLineHeadIndent)
        XCTAssertEqual(try style("continuing").firstLineHeadIndent, nested.headIndent)
        XCTAssertEqual(step.firstLineHeadIndent, 0)
        XCTAssertEqual(try style("Tenth").headIndent, step.headIndent, "Numbers of any width share one text column")
        XCTAssertEqual(try style("Plain").headIndent, 0)
        XCTAssertGreaterThan(try style("Quoted").headIndent, 0)
        XCTAssertNotNil(attributed.attribute(ChatMessageFormatting.quoteKey, at: string.range(of: "Quoted").location, effectiveRange: nil))
        XCTAssertNil(attributed.attribute(ChatMessageFormatting.quoteKey, at: string.range(of: "Plain").location, effectiveRange: nil))
        let heading = try XCTUnwrap(attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(heading.pointSize, 14)
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.bold))
        let bold = try XCTUnwrap(attributed.attribute(.font, at: string.range(of: "bold").location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(ChatMessageFormatting.attributedText("- typed by you", markdown: false).string, "- typed by you")
        XCTAssertEqual(ChatMessageFormatting.attributedText("- echo", code: true).string, "- echo")
    }

    func testRepliesSplitIntoTextCodeTablesAndRules() {
        let blocks = ChatMessageBody.blocks("""
            Intro with a | pipe
            | Name | Status |
            |:-----|-------:|
            | Hermes \\| Nous | **ready** |
            | Codex |
            ---
            ```sh
            | not | a table |
            |---|---|
            ```
            A closing line
            """)
        XCTAssertEqual(blocks, [
            .text("Intro with a | pipe"),
            .table(ChatTable(header: ["Name", "Status"], alignments: [.leading, .trailing],
                             rows: [["Hermes | Nous", "**ready**"], ["Codex", ""]])),
            .rule,
            .code("| not | a table |\n|---|---|"),
            .text("A closing line")
        ])
    }

    func testTableColumnsKeepNarrowColumnsWholeAndShareTheRest() {
        XCTAssertEqual(ChatTableLayout.columnWidths(ideal: [60, 300, 500], available: 1000), [60, 300, 500])
        XCTAssertEqual(ChatTableLayout.columnWidths(ideal: [60, 300, 500], available: 460), [60, 200, 200])
        XCTAssertEqual(ChatTableLayout.columnWidths(ideal: [100, 100], available: 100), [50, 50])
    }

    func testFormattedReplyFitsTheColumnAtFullAndSplitWidths() throws {
        let reply = """
            Three things changed:

            - **Lists** hang from their markers, so a long item that wraps onto another line stays clear of the bullet.
              - Nested items step in under their parent.
            1. Numbered steps share one text column.
            2. Even when a step runs long enough to wrap at the narrow width of a split pane.

            > A quote keeps a rule at its left edge, down every line it wraps to.

            | Provider | Reads | Notes |
            |---|:---:|---|
            | Claude | JSONL | One row per message, written as the reply arrives, with tool rows skipped |
            | Hermes | SQLite | Follows a compressed conversation into its continuation |

            ---
            That is the whole reply.
            """
        for width in [800, 440] {
            let view = NSHostingView(rootView: ChatTurn(speaker: "claude", text: reply).padding(24)
                .frame(width: CGFloat(width)).background(ElevateTheme.paper).foregroundStyle(ElevateTheme.ink))
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let table = try XCTUnwrap(ChatMessageBody.blocks(reply).compactMap { block -> ChatTable? in
                if case .table(let table) = block { return table } else { return nil }
            }.first)
            let tableSize = NSHostingController(rootView: ChatTableView(table: table)).sizeThatFits(in: CGSize(width: width - 48, height: 10_000))
            XCTAssertLessThanOrEqual(tableSize.width, CGFloat(width - 48), "The table wraps inside the column")
            for textView in descendants(view).compactMap({ $0 as? ChatLinkTextView }) {
                let frame = textView.convert(textView.bounds, to: view)
                XCTAssertLessThanOrEqual(frame.maxX, CGFloat(width) - 23)
                XCTAssertGreaterThan(frame.height, 15)
            }
            if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("formatted-reply-\(width).png"))
            }
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
