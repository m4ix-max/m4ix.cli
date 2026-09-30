import AppKit
import Foundation
import XCTest
@testable import PrivateCLIHost

@MainActor
final class HostedSessionTests: XCTestCase {
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
            XCTAssertTrue(session.sendPrompt("first café\nsecond line"))
            XCTAssertFalse(session.sendPrompt("must not overlap"))
            try await waitUntil { FileManager.default.fileExists(atPath: capture.path) }
            let data = try Data(contentsOf: capture)
            let records = String(decoding: data, as: UTF8.self).split(separator: "\n")
            XCTAssertEqual(records.count, 1)
            let record = try JSONSerialization.jsonObject(with: Data(records[0].utf8)) as? [String: String]
            XCTAssertEqual(record?["prompt"], "first café\nsecond line")
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
        try await waitUntil { FileManager.default.fileExists(atPath: firstCapture.path) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondCapture.path))
        model.selectProject(ProjectRecord(path: secondProject.path))
        model.selectLiveSession(second)
        XCTAssertEqual(model.selected, .codex)
        XCTAssertTrue(model.submitPrompt("PROJECT_B", images: []))
        try await waitUntil { FileManager.default.fileExists(atPath: secondCapture.path) }
        for (capture, project, prompt) in [(firstCapture, firstProject, "PROJECT_A"), (secondCapture, secondProject, "PROJECT_B")] {
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: String])
            XCTAssertEqual(record["prompt"], prompt)
            let capturedDirectory = try XCTUnwrap(record["cwd"])
            XCTAssertEqual(URL(fileURLWithPath: capturedDirectory).resolvingSymlinksInPath(), project.resolvingSymlinksInPath())
        }
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
        if 'status' in sys.argv or 'login' in sys.argv:
            print('Fixture account ready')
            sys.exit(0)
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
