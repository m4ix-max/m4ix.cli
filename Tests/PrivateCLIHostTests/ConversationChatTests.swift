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
            ["type": "assistant", "uuid": "reply", "sessionId": id, "message": ["role": "assistant", "content": [["type": "text", "text": "Yes. Open [Example](https://example.com) or https://example.org directly.\n\n```sh\necho 'Readable code, with a Copy button'\n```\n\nYou can select and copy this reply."]]]]
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
            } while textViews.count < 4 && Date() < deadline
            XCTAssertEqual(textViews.count, 4)
            XCTAssertTrue(textViews.contains { $0.string.contains("Can I click") })
            XCTAssertTrue(textViews.contains { $0.string.contains("You can select") })
            for textView in textViews {
                let frame = textView.convert(textView.bounds, to: view)
                XCTAssertGreaterThan(frame.width, 200)
                XCTAssertLessThanOrEqual(frame.maxX, CGFloat(width))
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertGreaterThan(frame.height, 15)
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

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}
