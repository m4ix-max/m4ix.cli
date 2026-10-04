import Darwin
import Foundation
import XCTest
@testable import PrivateCLIHost

final class SharedChatProcessTests: XCTestCase {
    private func fixture(_ script: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-chat-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-cli")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    func testRealLauncherAndProcessExchangeStructuredMessagesWithPrivateStdin() throws {
        let (root, executable) = try fixture(#"""
        #!/bin/bash
        exec python3 -c '
        import json, os, sys
        args = sys.argv[1:]
        prompt = sys.stdin.read()
        with open(os.environ["CHAT_CAPTURE"], "w") as target:
            json.dump({"args": args, "input": prompt, "codex": os.environ.get("CODEX_HOME"), "claude": os.environ.get("CLAUDE_CONFIG_DIR"), "inherited_key": os.environ.get("OPENAI_API_KEY")}, target)
        session = "bad0e8d2-26be-4033-b097-98cd2021a2f0"
        print("A harmless stderr diagnostic", file=sys.stderr)
        if "--print" in args:
            print(json.dumps({"type":"system", "subtype":"init", "session_id":session}))
            print(json.dumps({"type":"result", "subtype":"success", "is_error":False, "result":"Claude received the shared message"}))
        else:
            print(json.dumps({"type":"thread.started", "thread_id":session}))
            print(json.dumps({"type":"item.completed", "item":{"type":"agent_message", "text":"Codex received the shared message"}}))
            print(json.dumps({"type":"turn.completed"}))
        ' "$@"
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = try XCTUnwrap(HostPaths.launcher)
        let profile = root.appendingPathComponent("private profiles")
        let capture = root.appendingPathComponent("capture.json")
        var environment = ProcessInfo.processInfo.environment
        environment["PRIVATE_CLI_HOST_CLAUDE_BIN"] = executable.path
        environment["PRIVATE_CLI_HOST_CODEX_BIN"] = executable.path
        environment["CHAT_CAPTURE"] = capture.path
        environment["OPENAI_API_KEY"] = "must-not-be-inherited"
        let prompt = "Discuss café, åäö, 🧪 and literal `touch unwanted` and $(touch unwanted).\nKeep both lines."
        for provider in ["claude", "codex"] {
            for session in [nil, "bad0e8d2-26be-4033-b097-98cd2021a2f0"] as [String?] {
                let reply = try SharedChatProcess.run(SharedChatRequest(provider: provider, project: root,
                    profileBase: profile, sessionID: session, choice: ModelChoice(), prompt: prompt),
                    launcher: launcher, cancellation: CommandCancellation(), environment: environment, onText: { _ in })
                XCTAssertEqual(reply.text, "\(provider.capitalized) received the shared message")
                let received = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: capture)) as? [String: Any])
                XCTAssertEqual(received["input"] as? String, prompt)
                let args = try XCTUnwrap(received["args"] as? [String])
                XCTAssertFalse(args.contains(prompt))
                XCTAssertEqual(received[provider] as? String, profile.appendingPathComponent(provider).path)
                XCTAssertTrue(received["inherited_key"] is NSNull)
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("unwanted").path))
            }
        }
    }

    func testCancellationAndTimeoutTerminateNoisyProcessGroups() throws {
        let (root, executable) = try fixture(#"""
        #!/bin/bash
        trap '' TERM
        while true; do printf '{"type":"turn.started"}\n'; sleep 0.01; done
        """#)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = SharedChatRequest(provider: "codex", project: root, profileBase: root,
            sessionID: nil, choice: ModelChoice(), prompt: "Bounded test")
        let cancellation = CommandCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancellation.cancel() }
        let start = Date()
        XCTAssertThrowsError(try SharedChatProcess.run(request, launcher: executable,
            cancellation: cancellation, timeout: 3, onText: { _ in })) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertThrowsError(try SharedChatProcess.run(request, launcher: executable,
            cancellation: CommandCancellation(), timeout: 0.1, onText: { _ in })) { error in
            guard case CommandError.timedOut = error else { return XCTFail("Expected timeout, got \(error)") }
        }
    }
}
