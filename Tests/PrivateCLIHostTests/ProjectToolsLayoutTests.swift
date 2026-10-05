import AppKit
import SwiftUI
import XCTest
@testable import PrivateCLIHost

@MainActor
final class ProjectToolsLayoutTests: XCTestCase {
    func testMainWorkspaceRendersBothProvidersAtMinimumWindowSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.preview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "PrivateCLIHostWorkingDirectory")
        defaults.set("codex", forKey: "PrivateCLIHostSelectedAgent")
        defaults.set(Agent.allCases.map { agent in
            ["project": root.path, "agent": agent.rawValue, "conversation": UUID().uuidString,
             "title": agent == .claude ? "Implement parser" : "Review parser", "selected": true] as [String: Any]
        }, forKey: "PrivateCLIHostRestorableSessions")
        let executable = root.appendingPathComponent("fake-cli")
        try Data(#"""
        #!/bin/bash
        for argument in "$@"; do
            if [[ "$argument" == --version ]]; then
                printf 'codex-cli 0.159.3\n'
                exit 0
            fi
            if [[ "$argument" == status ]]; then
                printf 'Fixture account ready\n'
                exit 0
            fi
        done
        printf '\033[?2004h\r\n› Ask anything\r\n'
        IFS= read -r input
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let overrideKeys = ["PRIVATE_CLI_HOST_CLAUDE_BIN", "PRIVATE_CLI_HOST_CODEX_BIN"]
        let previousOverrides = ProcessInfo.processInfo.environment
        for key in overrideKeys { setenv(key, executable.path, 1) }
        defer {
            for key in overrideKeys {
                if let value = previousOverrides[key] { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        defer { model.prepareForTermination(); model.stopAllSessions() }
        let delegate = PrivateCLIAppDelegate()
        let view = NSHostingView(rootView: HostView(appDelegate: delegate, model: model))
        view.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(5)
        while !model.currentSession.acceptsPromptText && Date() < deadline {
            model.currentSession.refreshPromptReadiness()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        view.layoutSubtreeIfNeeded()
        let sessions = model.liveSessionsForCurrentProject()
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.filter { $0.state.isRunning }.count, 1)
        XCTAssertEqual(sessions.filter { $0.state == .idle && $0.pendingResumeID != nil }.count, 2)
        XCTAssertEqual(model.currentSession.agent, .codex)
        XCTAssertEqual(model.currentSession.state, .running(.run))
        XCTAssertNil(model.currentSession.initialPrompt)
        XCTAssertTrue(model.currentSession.acceptsPromptText)
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("main-workspace.png"))
        }
    }

    func testSideBySideChatKeepsEachProviderTerminalMountedWithoutTakingFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.preview." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "PrivateCLIHostWorkingDirectory")
        defaults.set("claude", forKey: "PrivateCLIHostSelectedAgent")
        defaults.set(true, forKey: "PrivateCLIHostSplitView")
        let executable = root.appendingPathComponent("fake-cli")
        try Data(#"""
        #!/bin/bash
        for argument in "$@"; do
            if [[ "$argument" == --version ]]; then
                [[ -n "$CLAUDE_CONFIG_DIR" ]] && printf '2.1.287 (Claude Code)\n' || printf 'codex-cli 0.159.3\n'
                exit 0
            fi
            if [[ "$argument" == status ]]; then
                printf 'Fixture account ready\n'
                exit 0
            fi
        done
        if [[ -n "$CLAUDE_CONFIG_DIR" ]]; then
            rule=$(printf '─%.0s' {1..40})
            printf '\033[?2004h\r\nClaude fixture\r\n%s\r\n❯\r\n%s\r\n' "$rule" "$rule"
        else
            printf '\033[?2004h\r\nCodex fixture\r\n› Ask anything\r\n'
        fi
        IFS= read -r input
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let overrideKeys = ["PRIVATE_CLI_HOST_CLAUDE_BIN", "PRIVATE_CLI_HOST_CODEX_BIN"]
        let previousOverrides = ProcessInfo.processInfo.environment
        for key in overrideKeys { setenv(key, executable.path, 1) }
        defer {
            for key in overrideKeys {
                if let value = previousOverrides[key] { setenv(key, value, 1) }
                else { unsetenv(key) }
            }
        }
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        defer { model.prepareForTermination(); model.stopAllSessions() }
        XCTAssertTrue(model.isSplit)
        let delegate = PrivateCLIAppDelegate()
        let view = NSHostingView(rootView: HostView(appDelegate: delegate, model: model))
        view.frame = NSRect(x: 0, y: 0, width: 1440, height: 820)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        XCTAssertTrue(model.startNewConversation(for: .codex))
        let deadline = Date().addingTimeInterval(5)
        while !model.visibleSessions.allSatisfy(\.acceptsPromptText) && Date() < deadline {
            model.updateAttention()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        view.layoutSubtreeIfNeeded()
        let visible = model.visibleSessions
        XCTAssertEqual(visible.map(\.agent), [.claude, .codex])
        XCTAssertTrue(visible.allSatisfy { $0.state == .running(.run) && $0.acceptsPromptText })
        XCTAssertEqual(model.selected, .claude)

        func decks(in view: NSView) -> [TerminalDeckView] {
            ((view as? TerminalDeckView).map { [$0] } ?? []) + view.subviews.flatMap { decks(in: $0) }
        }
        let shown = decks(in: view)
        XCTAssertEqual(shown.count, 2)
        XCTAssertTrue(visible.allSatisfy { session in shown.contains { session.terminal.superview === $0 } })
        // The mounted terminals keep both CLIs running while chat owns input.
        XCTAssertTrue(shown.allSatisfy { !$0.takesAutomaticFocus })
        for (name, size) in [("split-workspace", view.frame.size), ("split-workspace-minimum", NSSize(width: 960, height: 600))] {
            window.setContentSize(size)
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            XCTAssertEqual(decks(in: view).count, 2)
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
            }
        }
    }

    func testProjectPanelsRenderAtTheirDeclaredSize() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for args in [["init", "-b", "main"], ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-m", "Fixture"]] {
            let result = try CommandRunner.run(executable: "/usr/bin/git", arguments: args, directory: root)
            XCTAssertEqual(result.status, 0, result.output)
        }
        let store = ProjectContextStore(directory: root.appendingPathComponent("records"))
        try await store.savePlan(path: root.path, brief: "Build a reliable parser. Preserve existing work.\nAccept Unicode input and report validation results.",
                                 tasks: [ProjectTask(title: "Implement parser", owner: "Claude", details: "Sources/Parser.swift; verify Unicode"),
                                         ProjectTask(title: "Review parser", owner: "Codex", details: "Review only; report regressions")])
        try await store.appendHandoff(path: root.path, record: ProjectHandoffRecord(id: UUID(), date: Date(timeIntervalSince1970: 1790726400),
            source: "Claude", target: "Codex", prompt: "Review Parser.swift and its tests. Preserve uncommitted work.", state: "Launch requested"))
        for tab in 0..<4 {
            let view = NSHostingView(rootView: ProjectToolsView(directory: root, store: store, initialTab: tab,
                onOpenWorkspace: { _ in }, onStartTask: { _, _ in false }))
            view.frame = NSRect(x: 0, y: 0, width: 740, height: 620)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            // A real hosted view runs .task; let asynchronous context loading finish.
            window.orderFront(nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            XCTAssertGreaterThan(image.pixelsWide, 0)
            XCTAssertGreaterThan(image.pixelsHigh, 0)
            if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("project-tab-\(tab).png"))
            }
            window.orderOut(nil)
        }
    }
}
