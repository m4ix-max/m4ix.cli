import AppKit
import XCTest
@testable import PrivateCLIHost

@MainActor
final class TerminalInteractionTests: XCTestCase {
    func testQuestionTakesFocusAndReceivesKeysWithoutClickingTerminal() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for agent in Agent.allCases {
            let capture = root.appendingPathComponent("\(agent.rawValue)-keys.json")
            setenv("HOST_TEST_FOCUS_CAPTURE", capture.path, 1)
            defer { unsetenv("HOST_TEST_FOCUS_CAPTURE") }
            let session = TerminalSession(agent: agent, projectPath: root.path, title: "Focus test",
                                          profileBase: root.appendingPathComponent("profiles"))
            let terminal = session.terminal
            let deck = TerminalDeckView(frame: NSRect(x: 0, y: 120, width: 800, height: 500))
            deck.agent = agent
            let editor = PromptTextView(frame: NSRect(x: 20, y: 20, width: 760, height: 80))
            editor.string = "Keep this unsent draft."
            editor.allowsAutomaticFocus = {
                CLIPrompt.terminalResponseRequest(screen: CLIPrompt.liveScreen(of: terminal), agent: agent) == nil
            }
            deck.onPromptFocus = { editor.focusWhenAttached() }
            deck.show(terminal)
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 620))
            // Match the layer-backed SwiftUI host when caching the whole view.
            content.wantsLayer = true
            content.addSubview(deck)
            content.addSubview(editor)
            let window = NSPanel(contentRect: content.bounds, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.hidesOnDeactivate = false
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); session.stop() }
            try await waitUntil { window.isKeyWindow }
            content.layoutSubtreeIfNeeded()
            session.launch(.run, in: root)
            do {
                try await waitUntil {
                    session.refreshPromptReadiness()
                    return session.acceptsPromptText && window.firstResponder === editor
                }
            } catch {
                print("Fixture startup: state=\(session.state), ready=\(session.acceptsPromptText), key=\(window.isKeyWindow), responder=\(String(describing: window.firstResponder)), concealed=\(terminal.inputIsConcealed), screen=\(CLIPrompt.liveScreen(of: terminal))")
                throw error
            }

            terminal.scrollTo(row: 10)
            XCTAssertLessThan(terminal.scrollPosition, 1)
            terminal.send(txt: "menu\r")
            try await waitUntil {
                CLIPrompt.terminalResponseRequest(screen: CLIPrompt.liveScreen(of: terminal), agent: agent) != nil
            }
            // This is the queued composer focus from a SwiftUI/session update.
            editor.focusWhenAttached()
            try await waitUntil { window.firstResponder === terminal && !editor.wantsPromptFocus }
            XCTAssertEqual(terminal.scrollPosition, 1, "A new question should be brought into view")
            XCTAssertFalse(terminal.inputIsConcealed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path), "Focus alone must not submit an answer")
            try snapshot(content, name: "\(agent.rawValue)-question")

            // Re-reading history during the same question must remain possible.
            terminal.scroll(toPosition: 0)
            deck.layout()
            XCTAssertEqual(terminal.scrollPosition, 0)
            deck.jumpToLatest()
            for (characters, keyCode) in [("\u{f701}", UInt16(125)), ("\r", UInt16(36))] {
                let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
                window.sendEvent(event)
            }
            try await waitUntil { FileManager.default.fileExists(atPath: capture.path) }
            let received = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: String])
            XCTAssertEqual(received["keys"], "\u{1b}[B\r", "Arrow and Return must reach the CLI, not the draft")
            try await waitUntil {
                session.refreshPromptReadiness()
                return session.acceptsPromptText && window.firstResponder === editor
            }
            XCTAssertEqual(editor.string, "Keep this unsent draft.")
            try snapshot(content, name: "\(agent.rawValue)-message")
            session.stop()
            try await waitUntil { !session.state.isRunning }
        }
    }

    func testSessionSwitchFocusesUnnumberedQuestionAndBackgroundOutputDoesNotStealFocus() async throws {
        let deck = TerminalDeckView(frame: NSRect(x: 0, y: 100, width: 800, height: 500))
        deck.agent = .claude
        let first = TrackedTerminalView(frame: deck.bounds)
        let second = TrackedTerminalView(frame: deck.bounds)
        let editor = PromptTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 80))
        deck.onPromptFocus = { editor.focusWhenAttached() }
        deck.show(first)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        content.wantsLayer = true
        content.addSubview(deck)
        content.addSubview(editor)
        let window = NSPanel(contentRect: content.bounds, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.hidesOnDeactivate = false
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil { window.isKeyWindow }
        content.layoutSubtreeIfNeeded()
        first.feed(text: "──────\r\n❯\r\n──────")
        deck.layout()
        try await waitUntil { window.firstResponder === editor }
        second.feed(text: "Trust this folder?\r\n❯ No, exit\r\n  Yes, trust it\r\nEnter to confirm · Esc to cancel")
        second.requestViewportUpdate()
        await Task.yield()
        XCTAssertTrue(window.firstResponder === editor)
        deck.show(second)
        content.layoutSubtreeIfNeeded()
        try await waitUntil { window.firstResponder === second }
        XCTAssertFalse(second.inputIsConcealed)
    }

    private func snapshot(_ view: NSView, name: String) throws {
        view.window?.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let deck = try XCTUnwrap(view.subviews.compactMap { $0 as? TerminalDeckView }.first)
        let scrollbar = deck.scrollbar
        let point = scrollbar.convert(NSPoint(x: scrollbar.knobRect.midX, y: scrollbar.knobRect.midY), to: view)
        let x = Int(point.x * CGFloat(bitmap.pixelsWide) / view.bounds.width)
        let y = bitmap.pixelsHigh - 1 - Int(point.y * CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(colour.redComponent, 0.4, "Scrollbar must survive the question-to-message transition")
        guard let path = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            while let event = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            guard Date() < deadline else {
                XCTFail("Window or CLI did not reach the expected state", file: file, line: line)
                throw CommandError.timedOut
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("m4ix-focus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-cli")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, tty
        if 'status' in sys.argv or 'login' in sys.argv:
            print('Fixture account ready')
            sys.exit(0)
        tty.setraw(0)
        claude = 'CLAUDE_CONFIG_DIR' in os.environ
        rule = '─' * 60
        def write(text): os.write(1, text.encode())
        def prompt():
            write('\x1b[2J\x1b[H')
            write(rule + '\r\n❯\r\n' + rule if claude else '› Ask anything\r\nModel status')
        write(''.join('History line %d\r\n' % n for n in range(250)))
        prompt()
        data = bytearray()
        waiting = False
        while True:
            byte = os.read(0, 1)
            if not byte: break
            data.extend(byte)
            if byte != b'\r': continue
            if not waiting:
                write('\x1b[2J\x1b[H')
                write('Trust this folder?\r\n❯ No, exit\r\n  Yes, trust it\r\nEnter to confirm · Esc to cancel'
                      if claude else 'Approve command?\r\n› 1. Yes\r\n  2. No\r\nEnter to confirm · Esc to cancel')
                waiting = True
            else:
                with open(os.environ['HOST_TEST_FOCUS_CAPTURE'], 'w') as f:
                    json.dump({'keys': data.decode()}, f)
                prompt()
                waiting = False
            data.clear()
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        setenv("PRIVATE_CLI_HOST_CLAUDE_BIN", executable.path, 1)
        setenv("PRIVATE_CLI_HOST_CODEX_BIN", executable.path, 1)
        addTeardownBlock {
            unsetenv("PRIVATE_CLI_HOST_CLAUDE_BIN")
            unsetenv("PRIVATE_CLI_HOST_CODEX_BIN")
        }
        return root
    }
}
