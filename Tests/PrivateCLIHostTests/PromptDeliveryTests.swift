import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import PrivateCLIHost

/// A prompt reaches only the session it was written for, and stays
/// recoverable until that session confirms it was typed.
@MainActor
final class PromptDeliveryTests: XCTestCase {
    func testCommandReturnSendsOnlyThePaneInUse() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, view, window) = try hostedWindow(root: root, selected: .claude, split: true)
        defer { model.stopAllSessions(); window.orderOut(nil) }
        XCTAssertTrue(model.startNewConversation(for: .codex))
        try await waitUntil {
            view.layoutSubtreeIfNeeded(); model.updateAttention()
            return model.visibleSessions.allSatisfy(\.acceptsPromptText)
        }
        let editors = composers(in: view).sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        XCTAssertEqual(editors.count, 2)
        let claudeEditor = try XCTUnwrap(editors.first), codexEditor = try XCTUnwrap(editors.last)
        type("unsent Claude draft", into: claudeEditor)
        type("message for Codex", into: codexEditor)
        try await settle(view)
        XCTAssertEqual(model.selected, .codex, "Typing in the Codex pane makes it the pane in use")

        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        try await waitUntil { model.updateAttention(); return prompts(root, .codex) == ["message for Codex"] }
        try await settle(view)
        XCTAssertEqual(prompts(root, .claude), [], "Command-Return must not send the other pane's draft")
        XCTAssertEqual(claudeEditor.string, "unsent Claude draft")
    }

    func testConversationStartedFromTheComposerLeavesNoRecoveryDraft() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, view, window) = try hostedWindow(root: root, selected: .claude, split: false)
        defer { model.stopAllSessions(); window.orderOut(nil) }
        // Launch opens a blank Claude chat. Codex has none, so its composer starts one.
        try await waitUntil {
            view.layoutSubtreeIfNeeded(); model.updateAttention()
            return model.currentSession.acceptsPromptText
        }
        model.selected = .codex
        try await settle(view)
        let idle = model.currentSession
        XCTAssertFalse(idle.hostsConversation)
        let editor = try XCTUnwrap(composers(in: view).first)
        type("start from the composer", into: editor)
        try await settle(view)
        _ = editor.delegate?.textView?(editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        let started = model.currentSession
        XCTAssertNotEqual(started.id, idle.id)
        XCTAssertEqual(model.production.drafts.map(\.id), [started.id], "The message stays recoverable until delivered")
        try await waitUntil {
            view.layoutSubtreeIfNeeded(); model.updateAttention()
            return prompts(root, .codex) == ["start from the composer"]
        }
        try await waitUntil { model.production.drafts.isEmpty }
    }

    func testRecoveryDraftBelongsToTheSessionThatDelivers() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root, selected: .claude)
        defer { model.stopAllSessions() }
        let idle = model.currentSession
        XCTAssertTrue(model.submitPrompt("first task", images: []))
        let started = model.currentSession
        XCTAssertNotEqual(started.id, idle.id)
        XCTAssertEqual(model.production.drafts.map(\.id), [started.id])
        XCTAssertEqual(model.production.drafts.first?.deliveryUnconfirmed, true)
        try await waitUntil {
            model.updateAttention()
            return prompts(root, .claude) == ["first task"] && model.production.drafts.isEmpty
        }
        try await waitUntil { started.refreshPromptReadiness(); return started.acceptsPromptText && !started.isSendingPrompt }
        XCTAssertTrue(model.submitPrompt("second task", images: []))
        XCTAssertEqual(model.production.drafts.map(\.id), [started.id])
        try await waitUntil { prompts(root, .claude) == ["first task", "second task"] && model.production.drafts.isEmpty }
    }

    func testQueuedPromptWaitsForTheUserWhenTheCLIVersionIsUnchecked() async throws {
        _ = NSApplication.shared
        let root = try fixture(version: "codex-cli 0.1.0")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try makeModel(root: root, selected: .codex)
        defer { model.stopAllSessions() }
        XCTAssertTrue(model.startNewConversation(initialPrompt: "task for an unchecked CLI", for: .codex))
        let session = model.currentSession
        try await waitUntil { model.updateAttention(); return session.promptRecovery != nil }
        XCTAssertFalse(session.compatibility.usesComposer)
        XCTAssertTrue(session.acceptsPromptText, "The screen was recognized; the version gate held the text")
        XCTAssertEqual(session.promptRecovery?.text, "task for an unchecked CLI")
        XCTAssertEqual(prompts(root, .codex), [])
        XCTAssertEqual(model.production.drafts.first { $0.id == session.id }?.deliveryUnconfirmed, true)
    }

    private func makeModel(root: URL, selected: Agent, split: Bool = false) throws -> HostModel {
        let suite = "m4ix.cli.delivery." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "PrivateCLIHostWorkingDirectory")
        defaults.set(selected.rawValue, forKey: "PrivateCLIHostSelectedAgent")
        defaults.set(split, forKey: "PrivateCLIHostSplitView")
        return HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
    }

    private func hostedWindow(root: URL, selected: Agent, split: Bool) throws -> (HostModel, NSHostingView<HostView>, NSWindow) {
        let model = try makeModel(root: root, selected: selected, split: split)
        let view = NSHostingView(rootView: HostView(appDelegate: PrivateCLIAppDelegate(), model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1440, height: 820)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        return (model, view, window)
    }

    private func composers(in view: NSView) -> [PromptTextView] {
        ((view as? PromptTextView).map { [$0] } ?? []) + view.subviews.flatMap { composers(in: $0) }
    }

    private func type(_ text: String, into editor: PromptTextView) {
        XCTAssertTrue(editor.window?.makeFirstResponder(editor) == true)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    /// Lets SwiftUI apply bindings and shortcuts after a change.
    private func settle(_ view: NSView) async throws {
        for _ in 0..<10 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }

    private func prompts(_ root: URL, _ agent: Agent) -> [String] {
        let url = root.appendingPathComponent("prompts").appendingPathComponent(agent.rawValue)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: String])?["prompt"]
        }
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { XCTFail("Prompt delivery did not reach the expected state", file: file, line: line); throw CommandError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// A CLI that shows its input line and records each prompt it receives
    /// under `prompts/claude` or `prompts/codex`.
    private func fixture(version: String? = nil) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("prompts"), withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-cli")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, tty
        claude = 'CLAUDE_CONFIG_DIR' in os.environ
        if '--version' in sys.argv:
            print(os.environ.get('HOST_TEST_VERSION') or ('2.1.287 (Claude Code)' if claude else 'codex-cli 0.159.3'))
            sys.exit(0)
        if 'status' in sys.argv or 'login' in sys.argv:
            print('Fixture account ready')
            sys.exit(0)
        tty.setraw(0)
        rule = '─' * 60
        def screen():
            text = ('\r\n' + rule + '\r\n❯\r\n' + rule + '\r\n') if claude else '\r\n› Ask anything\r\n'
            os.write(1, ('\x1b[?2004h' + text).encode())
        screen()
        capture = os.path.join(os.environ['HOST_TEST_PROMPTS'], 'claude' if claude else 'codex')
        content = bytearray()
        while True:
            data = os.read(0, 1)
            if not data: break
            if data == b'\r':
                prompt = bytes(content).replace(b'\x1b[200~', b'').replace(b'\x1b[201~', b'').decode()
                with open(capture, 'a') as f:
                    f.write(json.dumps({'prompt': prompt}) + '\n')
                content.clear()
                screen()
            else:
                content.extend(data)
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        setenv("PRIVATE_CLI_HOST_CLAUDE_BIN", executable.path, 1)
        setenv("PRIVATE_CLI_HOST_CODEX_BIN", executable.path, 1)
        setenv("HOST_TEST_PROMPTS", root.appendingPathComponent("prompts").path, 1)
        if let version { setenv("HOST_TEST_VERSION", version, 1) }
        addTeardownBlock {
            for key in ["PRIVATE_CLI_HOST_CLAUDE_BIN", "PRIVATE_CLI_HOST_CODEX_BIN", "HOST_TEST_PROMPTS", "HOST_TEST_VERSION"] {
                unsetenv(key)
            }
        }
        return root
    }
}
