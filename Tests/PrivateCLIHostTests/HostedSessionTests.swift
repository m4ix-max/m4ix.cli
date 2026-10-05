import AppKit
import Foundation
import XCTest
@testable import PrivateCLIHost

@MainActor
final class HostedSessionTests: XCTestCase {
    func testLaunchStartsOneBlankChatForLastUsedProviderAndKeepsRestoredChatsIdle() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for agent in Agent.allCases {
            for hasHistory in [false, true] {
                let suite = "m4ix.cli.startup." + UUID().uuidString
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let profile = root.appendingPathComponent(suite)
                let previous = HostModel(defaults: defaults, profileBase: profile)
                previous.openWorkspace(root)
                previous.selected = agent
                let savedIDs = Agent.allCases.map { _ in UUID().uuidString.lowercased() }
                if hasHistory {
                    defaults.set(zip(Agent.allCases, savedIDs).map { provider, id in
                        ["project": root.path, "agent": provider.rawValue, "conversation": id,
                         "title": "Previous chat", "selected": true] as [String: Any]
                    }, forKey: "PrivateCLIHostRestorableSessions")
                }
                let capture = root.appendingPathComponent(suite + ".jsonl")
                setenv("HOST_TEST_LAUNCH_CAPTURE", capture.path, 1)
                defer { unsetenv("HOST_TEST_LAUNCH_CAPTURE") }
                let model = HostModel(defaults: defaults, profileBase: profile)
                defer { model.stopAllSessions() }
                XCTAssertEqual(model.selected, agent)
                XCTAssertEqual(model.workingDirectory.path, root.path)
                model.startOnLaunch()
                let fresh = model.currentSession
                try await waitUntil { fresh.refreshPromptReadiness(); return fresh.acceptsPromptText }
                XCTAssertEqual(fresh.agent, agent)
                XCTAssertEqual(fresh.state, .running(.run))
                XCTAssertNil(fresh.initialPrompt)
                XCTAssertNil(fresh.pendingResumeID)
                XCTAssertFalse(savedIDs.contains(fresh.activeConversationID ?? ""))
                XCTAssertEqual(fresh.displayTitle, "New conversation")
                let restored = model.liveSessionsForCurrentProject().filter { $0.id != fresh.id }
                XCTAssertEqual(restored.count, hasHistory ? 2 : 0)
                XCTAssertTrue(restored.allSatisfy { $0.state == .idle && savedIDs.contains($0.pendingResumeID ?? "") })
                model.startOnLaunch()
                XCTAssertEqual(model.currentSession.id, fresh.id)
                fresh.stop()
                try await waitUntil { !model.hasRunningSessions }
                model.startOnLaunch()
                XCTAssertEqual(model.currentSession.id, fresh.id, "A window reappearing must not start another chat")
                XCTAssertEqual(model.liveSessionsForCurrentProject().count, restored.count + 1)
                XCTAssertFalse(model.hasRunningSessions)
                let launches = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n")
                XCTAssertEqual(launches.count, 1, "Only the fresh chat may launch a CLI")
                let launch = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(launches[0].utf8)) as? [String: Any])
                let arguments = try XCTUnwrap(launch["arguments"] as? [String])
                XCTAssertFalse(arguments.contains("resume"))
                XCTAssertFalse(arguments.contains("--resume"))
                XCTAssertTrue(Set(arguments).isDisjoint(with: savedIDs))
                let directory = try XCTUnwrap(launch["cwd"] as? String)
                XCTAssertEqual(URL(fileURLWithPath: directory).resolvingSymlinksInPath(), root.resolvingSymlinksInPath())
            }
        }
    }

    func testToolbarModelChoiceReachesNewAndResumedConversations() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.model-launch." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let capture = root.appendingPathComponent("launches.jsonl")
        setenv("HOST_TEST_LAUNCH_CAPTURE", capture.path, 1)
        defer { unsetenv("HOST_TEST_LAUNCH_CAPTURE") }
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        defer { model.stopAllSessions() }
        model.openWorkspace(root)
        model.setModelChoice(ModelChoice(model: "sonnet", effort: "high"), for: .claude)
        model.setModelChoice(ModelChoice(model: "gpt-5.5"), for: .codex)

        XCTAssertTrue(model.startNewConversation())
        let claude = model.currentSession
        try await waitUntil { claude.refreshPromptReadiness(); return claude.acceptsPromptText }
        XCTAssertEqual(claude.launchedChoice, ModelChoice(model: "sonnet", effort: "high"))
        model.setModelChoice(ModelChoice(model: "opus"), for: .claude)
        XCTAssertEqual(claude.launchedChoice.model, "sonnet", "A running conversation keeps its launch model")

        model.selected = .codex
        let resumed = ConversationRecord(provider: "codex", sessionID: UUID().uuidString.lowercased(),
                                         projectPath: model.workingDirectory.path, title: "Earlier work", updatedAt: Date())
        model.openConversation(resumed)
        let codex = model.currentSession
        try await waitUntil { codex.refreshPromptReadiness(); return codex.acceptsPromptText }

        let launches = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])["arguments"] as? [String] ?? []
        }
        XCTAssertEqual(launches.count, 2)
        let claudeArguments = try XCTUnwrap(launches.first { $0.contains("--session-id") })
        XCTAssertTrue(claudeArguments.joined(separator: " ").contains("--model sonnet --effort high"), "\(claudeArguments)")
        let codexArguments = try XCTUnwrap(launches.first { $0.contains("resume") })
        XCTAssertTrue(codexArguments.contains(#"model="gpt-5.5""#), "\(codexArguments)")
        XCTAssertFalse(codexArguments.contains { $0.hasPrefix("model_reasoning_effort") })
    }

    func testBothProvidersAcceptOnePromptWithoutOverlappingDelivery() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for agent in Agent.allCases {
            let capture = root.appendingPathComponent(agent.rawValue + ".jsonl")
            setenv("HOST_TEST_CAPTURE", capture.path, 1)
            defer { unsetenv("HOST_TEST_CAPTURE") }
            let session = TerminalSession(agent: agent, projectPath: root.path, title: "Fixture", profileBase: root.appendingPathComponent("profiles"))
            let id = agent == .claude ? UUID().uuidString : nil
            session.launch(.run, in: root, sessionID: id)
            try await waitUntil { session.refreshPromptReadiness(); return session.acceptsPromptText }
            let activityBeforeSend = session.conversationUpdatedAt
            XCTAssertTrue(session.sendPrompt("first café\nsecond line"))
            XCTAssertFalse(session.sendPrompt("must not overlap"))
            try await waitUntil { hasCompleteRecord(capture) }
            let data = try Data(contentsOf: capture)
            let records = String(decoding: data, as: UTF8.self).split(separator: "\n")
            XCTAssertEqual(records.count, 1)
            let record = try JSONSerialization.jsonObject(with: Data(records[0].utf8)) as? [String: String]
            XCTAssertEqual(record?["prompt"], "first café\nsecond line")
            XCTAssertGreaterThan(session.conversationUpdatedAt, activityBeforeSend,
                                 "Successful message delivery must update conversation order immediately")
            session.stop()
            try await waitUntil { !session.state.isRunning }
            XCTAssertFalse(session.acceptsPromptText)
        }
    }

    func testProjectSwitchingKeepsBothProcessesLiveAndRoutesToTheirOwnFolders() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstProject = root.appendingPathComponent("first project")
        let secondProject = root.appendingPathComponent("second project")
        for project in [firstProject, secondProject] { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true) }
        let suite = "m4ix.cli.routing." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(firstProject.path, forKey: "PrivateCLIHostWorkingDirectory")
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        defer { model.stopAllSessions() }
        let firstCapture = root.appendingPathComponent("first.jsonl")
        setenv("HOST_TEST_CAPTURE", firstCapture.path, 1)
        defer { unsetenv("HOST_TEST_CAPTURE") }
        XCTAssertTrue(model.startNewConversation())
        let first = model.currentSession
        try await waitUntil { first.refreshPromptReadiness(); return first.acceptsPromptText }
        model.openWorkspace(secondProject)
        model.selected = .codex
        let secondCapture = root.appendingPathComponent("second.jsonl")
        setenv("HOST_TEST_CAPTURE", secondCapture.path, 1)
        XCTAssertTrue(model.startNewConversation())
        let second = model.currentSession
        do {
            try await waitUntil { second.refreshPromptReadiness(); return second.acceptsPromptText }
        } catch {
            print("Second hosted state: \(second.state), screen: \(CLIPrompt.liveScreen(of: second.terminal))")
            throw error
        }
        XCTAssertTrue(first.state.isRunning)
        model.selectProject(ProjectRecord(path: firstProject.path))
        model.selectLiveSession(first)
        XCTAssertEqual(model.selected, .claude)
        XCTAssertEqual(model.currentSession.id, first.id)
        XCTAssertTrue(model.submitPrompt("PROJECT_A", images: []))
        try await waitUntil { hasCompleteRecord(firstCapture) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondCapture.path))
        model.selectProject(ProjectRecord(path: secondProject.path))
        model.selectLiveSession(second)
        XCTAssertEqual(model.selected, .codex)
        XCTAssertTrue(model.submitPrompt("PROJECT_B", images: []))
        try await waitUntil { hasCompleteRecord(secondCapture) }
        for (capture, project, prompt) in [(firstCapture, firstProject, "PROJECT_A"), (secondCapture, secondProject, "PROJECT_B")] {
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: String])
            XCTAssertEqual(record["prompt"], prompt)
            let capturedDirectory = try XCTUnwrap(record["cwd"])
            XCTAssertEqual(URL(fileURLWithPath: capturedDirectory).resolvingSymlinksInPath(), project.resolvingSymlinksInPath())
        }
        model.stopAllSessions()
        try await waitUntil { !model.hasRunningSessions }
    }

    func testSideBySideComposersEachReachTheirOwnProvider() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let suite = "m4ix.cli.split." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(project.path, forKey: "PrivateCLIHostWorkingDirectory")
        let profiles = root.appendingPathComponent("profiles")
        let model = HostModel(defaults: defaults, profileBase: profiles)
        defer { model.stopAllSessions() }
        XCTAssertEqual(model.visibleSessions.map(\.id), [model.currentSession.id])
        model.isSplit = true
        XCTAssertEqual(model.visibleSessions.map(\.agent), [.claude, .codex])
        XCTAssertTrue(HostModel(defaults: defaults, profileBase: profiles).isSplit, "Side by side is remembered")

        defer { unsetenv("HOST_TEST_CAPTURE") }
        var captures: [Agent: URL] = [:]
        for agent in Agent.allCases {
            let capture = root.appendingPathComponent("\(agent.rawValue).jsonl")
            captures[agent] = capture
            setenv("HOST_TEST_CAPTURE", capture.path, 1)
            XCTAssertTrue(model.submitPrompt("TASK_FOR_\(agent.rawValue.uppercased())", images: [], for: agent))
            let session = model.currentWorkspace.session(for: agent)
            // The launcher reads the capture path when the CLI starts.
            try await waitUntil { session.state.isRunning }
        }
        XCTAssertEqual(model.selected, .claude, "Starting work in the other pane leaves the keyboard where it was")
        let visible = model.visibleSessions
        XCTAssertEqual(visible.map(\.agent), [.claude, .codex])
        XCTAssertTrue(visible.allSatisfy { model.isSelected($0) && $0.hostsConversation })
        try await waitUntil {
            model.updateAttention()
            return captures.values.allSatisfy { hasCompleteRecord($0) }
        }
        for (agent, capture) in captures {
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: String])
            XCTAssertEqual(record["prompt"], "TASK_FOR_\(agent.rawValue.uppercased())")
        }
        model.isSplit = false
        XCTAssertEqual(model.visibleSessions.map(\.id), [visible[0].id])
        XCTAssertFalse(model.isSelected(visible[1]))
        model.stopAllSessions()
        try await waitUntil { !model.hasRunningSessions }
    }

    func testStopCancelsQueuedAndInFlightPromptDelivery() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("cancelled.jsonl")
        setenv("HOST_TEST_CAPTURE", capture.path, 1)
        defer { unsetenv("HOST_TEST_CAPTURE") }
        let session = TerminalSession(agent: .codex, projectPath: root.path, title: "Fixture", profileBase: root.appendingPathComponent("profiles"))
        session.launch(.run, in: root)
        try await waitUntil { session.refreshPromptReadiness(); return session.acceptsPromptText }
        XCTAssertTrue(session.sendPrompt("cancel me"))
        session.queuePrompt("also cancel", images: [])
        session.stop()
        try await waitUntil { !session.state.isRunning && !session.isSendingPrompt }
        XCTAssertFalse(session.hasQueuedPrompt)
        XCTAssertNotNil(session.promptRecovery)
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
    }

    func testQuitThatCannotScheduleItsUpdateLeavesSessionsRunning() async throws {
        _ = NSApplication.shared
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = root.appendingPathComponent("after-cancelled-quit.jsonl")
        setenv("HOST_TEST_CAPTURE", capture.path, 1)
        defer { unsetenv("HOST_TEST_CAPTURE") }
        let suite = "m4ix.cli.update-quit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        defer { model.stopAllSessions() }
        model.openWorkspace(root)
        XCTAssertTrue(model.startNewConversation())
        let session = model.currentSession
        try await waitUntil { session.refreshPromptReadiness(); return session.acceptsPromptText }
        model.pendingUpdate = root.appendingPathComponent("staged/m4ix.CLI.app")
        let delegate = PrivateCLIAppDelegate()
        delegate.model = model
        delegate.scheduleUpdate = { _, _ in throw CommandError.failed("The update helper is unavailable.") }

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(model.operationError, "The update could not be scheduled: The update helper is unavailable.")
        XCTAssertTrue(session.state.isRunning, "A quit that cannot schedule its update must not stop sessions")
        XCTAssertTrue(model.submitPrompt("still working", images: []))
        // The fixture creates the file before it writes the record.
        try await waitUntil { ((try? String(contentsOf: capture, encoding: .utf8)) ?? "").hasSuffix("\n") }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: String])
        XCTAssertEqual(record["prompt"], "still working")
    }

    func testReviewedSharedDiscussionStartsInItsProfileAndRecordsTheHandoff() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.shared-handoff." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "PrivateCLIHostWorkingDirectory")
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        defer { model.stopAllSessions() }
        let profile = try model.production.addProfile(name: "Fixture account")
        model.selectProfile(profile.id)
        let store = model.projectContextStore
        let historyURL = root.appendingPathComponent("handoff.jsonl")
        setenv("HOST_TEST_CAPTURE", historyURL.path, 1)
        defer { unsetenv("HOST_TEST_CAPTURE") }
        let draft = HandoffDraft(source: "Shared chat", target: "Codex", projectPath: root.path,
                                 context: "Unreviewed proposal", profileID: profile.id, contextKind: .discussion)
        let prompt = draft.prompt(task: "Implement the reviewed plan", context: "You: Keep the public API.\nClaude: Add regression coverage.")
        let session = try await model.startHandoff(draft, prompt: prompt)
        XCTAssertEqual(session.agent, .codex)
        XCTAssertEqual(session.profileID, profile.id)
        XCTAssertEqual(session.profileDirectory.path, model.profileBase.appendingPathComponent("codex").path)
        try await waitUntil {
            session.refreshPromptReadiness()
            return !session.isSendingPrompt && ((try? String(contentsOf: historyURL, encoding: .utf8)) ?? "").hasSuffix("\n")
        }
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: historyURL)) as? [String: String])
        XCTAssertEqual(record["prompt"], prompt)
        XCTAssertFalse(record["prompt"]!.contains("Unreviewed proposal"))
        let saved = try await store.load(path: root.path)
        XCTAssertEqual(saved.handoffs.count, 1)
        XCTAssertEqual(saved.handoffs[0].source, "Shared chat")
        XCTAssertEqual(saved.handoffs[0].state, "Launch requested")
        model.production.flush()
        XCTAssertFalse(model.production.drafts.contains { $0.id == session.id }, "Confirmed delivery must clear the recovery draft")
        model.selectProfile("default")
        do {
            _ = try await model.startHandoff(draft, prompt: prompt)
            XCTFail("A reviewed task must not launch under a different account")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("selected project changed"))
        }
    }

    private func hasCompleteRecord(_ url: URL) -> Bool {
        (try? Data(contentsOf: url).last) == 0x0a
    }

    private func waitUntil(file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { XCTFail("Hosted session did not reach expected state", file: file, line: line); throw CommandError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-cli")
        let script = #"""
        #!/usr/bin/python3
        import json, os, sys, tty
        if '--version' in sys.argv:
            print('2.1.287 (Claude Code)' if 'CLAUDE_CONFIG_DIR' in os.environ else 'codex-cli 0.159.3')
            sys.exit(0)
        if 'status' in sys.argv or 'login' in sys.argv:
            print('Fixture account ready')
            sys.exit(0)
        if os.environ.get('HOST_TEST_LAUNCH_CAPTURE'):
            with open(os.environ['HOST_TEST_LAUNCH_CAPTURE'], 'a') as f:
                f.write(json.dumps({'arguments': sys.argv[1:], 'cwd': os.getcwd()}) + '\n')
        tty.setraw(0)
        claude = 'CLAUDE_CONFIG_DIR' in os.environ
        rule = '─' * 60
        def screen():
            text = ('\r\n' + rule + '\r\n❯\r\n' + rule + '\r\n') if claude else '\r\n› Ask anything\r\n'
            os.write(1, ('\x1b[?2004h' + text).encode())
        screen()
        content = bytearray()
        while True:
            data = os.read(0, 1)
            if not data: break
            if data == b'\r':
                prompt = bytes(content).replace(b'\x1b[200~', b'').replace(b'\x1b[201~', b'').decode()
                with open(os.environ['HOST_TEST_CAPTURE'], 'a') as f:
                    f.write(json.dumps({'prompt': prompt, 'cwd': os.getcwd()}) + '\n')
                content.clear()
                screen()
            else:
                content.extend(data)
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
