import Foundation
import XCTest
@testable import PrivateCLIHost

private actor DiscussionFixture {
    var requests: [SharedChatRequest] = []
    var failOn: String?
    let claudeID = UUID().uuidString
    let codexID = UUID().uuidString
    init(failOn: String? = nil) { self.failOn = failOn }
    func reply(_ request: SharedChatRequest) throws -> SharedChatReply {
        requests.append(request)
        if request.provider == failOn { throw CommandError.failed("Fixture failed before completing a reply") }
        return SharedChatReply(text: "\(request.provider) reply \(requests.count)",
            sessionID: request.provider == "claude" ? claudeID : codexID)
    }
    func recorded() -> [SharedChatRequest] { requests }
}

@MainActor
final class SharedChatTests: XCTestCase {
    func testAuthenticatedProvidersExchangeAndResumeReplies() async throws {
        guard ProcessInfo.processInfo.environment["M4IX_SHARED_CHAT_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set M4IX_SHARED_CHAT_LIVE_TESTS=1 to check the authenticated providers.")
        }
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        // Use the app's existing private logins. The test sends only a short
        // discussion and does not approve tools or request project changes.
        let chat = SharedChat(project: root, profileBase: HostPaths.userDataDirectory)
        defer { chat.stop() }
        await chat.load()
        chat.replyLimit = 4
        let token = "relay-" + String(UUID().uuidString.prefix(8))
        chat.draft = "Integration check: do not use any tools or read or change files. Each participant should reply with the token \(token) followed by their provider name, and nothing else. Repeat this rule on every turn in this short discussion."
        XCTAssertTrue(chat.send())
        let deadline = Date().addingTimeInterval(240)
        while chat.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if chat.isRunning {
            chat.stop()
            try await waitUntil { !chat.isRunning }
            XCTFail("Authenticated shared discussion timed out")
        }
        XCTAssertNil(chat.failure, chat.failure ?? "")
        XCTAssertEqual(chat.thread.messages.map(\.speaker), ["you", "claude", "codex", "claude", "codex"])
        for message in chat.thread.messages.dropFirst() { XCTAssertTrue(message.text.contains(token), message.text) }
        XCTAssertNotNil(chat.thread.sessions["claude"])
        XCTAssertNotNil(chat.thread.sessions["codex"])
        await chat.flush()
        // Remove only this test's host-side discussion record. The CLIs own
        // their ordinary conversation histories and are left to retain them.
        let store = SharedChatStore(profileBase: HostPaths.userDataDirectory, project: root)
        let saved = await store.url
        try? FileManager.default.removeItem(at: saved)
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shared-chat-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(condition())
    }

    func testAgentsTakeBoundedTurnsAndReceiveOnlyNewMessages() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = DiscussionFixture()
        let chat = SharedChat(project: root, profileBase: root.appendingPathComponent("profiles")) { request, _, _ in
            try await fixture.reply(request)
        }
        await chat.load()
        chat.replyLimit = 4
        chat.draft = "Compare two navigation approaches."
        XCTAssertTrue(chat.send())
        XCTAssertFalse(chat.send(), "Sending while a turn runs must not overlap deliveries")
        XCTAssertNil(chat.handoff(to: .codex, profileID: "default"), "An implementation handoff must wait for completed replies")
        try await waitUntil { !chat.isRunning }
        XCTAssertNil(chat.failure)
        XCTAssertEqual(chat.thread.messages.map(\.speaker), ["you", "claude", "codex", "claude", "codex"])
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.map(\.provider), ["claude", "codex", "claude", "codex"])
        XCTAssertNil(requests[0].sessionID)
        XCTAssertNil(requests[1].sessionID)
        XCTAssertNotNil(requests[2].sessionID)
        XCTAssertTrue(requests[1].prompt.contains("claude reply 1"))
        XCTAssertTrue(requests[1].prompt.contains("Compare two navigation approaches."))
        XCTAssertTrue(requests[2].prompt.contains("codex reply 2"))
        XCTAssertFalse(requests[2].prompt.contains("claude reply 1"), "The agent already has its own reply")
        XCTAssertFalse(requests[2].prompt.contains("Compare two navigation approaches."), "Do not repeatedly resend prior human input")
        XCTAssertTrue(requests[3].prompt.contains("claude reply 3"))
        XCTAssertEqual(chat.repliesRemaining, 0)
    }

    func testHandoffPreparesBothProvidersWithoutStartingWorkOrChangingDiscussion() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let profileID = UUID().uuidString.lowercased()
        let profile = root.appendingPathComponent("named-profiles/\(profileID)")
        let store = SharedChatStore(profileBase: profile, project: root)
        var history = SharedChatHistory()
        history.threads[0].title = "Parser plan"
        history.threads[0].draft = "Unsent follow-up"
        history.threads[0].messages = [SharedChatMessage(speaker: "you", text: "Keep existing inputs working."),
                                      SharedChatMessage(speaker: "claude", text: "Implement a small parser."),
                                      SharedChatMessage(speaker: "codex", text: "Check malformed input too.")]
        try await store.save(history, version: 1)
        let fixture = DiscussionFixture()
        let chat = SharedChat(project: root, profileBase: profile) { request, _, _ in try await fixture.reply(request) }
        XCTAssertFalse(chat.canHandoff)
        await chat.load()
        for agent in Agent.allCases {
            let draft = try XCTUnwrap(chat.handoff(to: agent, profileID: profileID))
            XCTAssertEqual(draft.projectPath, root.path)
            XCTAssertEqual(draft.profileID, profileID)
            XCTAssertEqual(draft.target, agent.title)
            XCTAssertEqual(draft.contextKind, .discussion)
            XCTAssertTrue(draft.initialTask.isEmpty, "The user supplies the implementation task after review")
            XCTAssertTrue(draft.context.contains("Claude:\nImplement a small parser."))
            XCTAssertTrue(draft.context.contains("Codex:\nCheck malformed input too."))
            XCTAssertFalse(draft.context.contains("Unsent follow-up"))
        }
        let requests = await fixture.recorded()
        XCTAssertTrue(requests.isEmpty, "Choosing a provider only prepares an editable handoff")
        XCTAssertEqual(chat.thread.messages, history.threads[0].messages)
        XCTAssertEqual(chat.draft, "Unsent follow-up")
        await chat.flush()
    }

    func testMentionTargetsOneAgentAndPersistenceDoesNotRestartTheExchange() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = DiscussionFixture()
        let profile = root.appendingPathComponent("profiles")
        let chat = SharedChat(project: root, profileBase: profile) { request, _, _ in try await fixture.reply(request) }
        await chat.load()
        chat.draft = "@codex Check Claude's assumption."
        XCTAssertTrue(chat.send())
        try await waitUntil { !chat.isRunning }
        XCTAssertEqual(chat.thread.messages.map(\.speaker), ["you", "codex"])
        XCTAssertEqual(chat.thread.messages.first?.text, "Check Claude's assumption.")
        let restored = SharedChat(project: root, profileBase: profile) { request, _, _ in try await fixture.reply(request) }
        await restored.load()
        XCTAssertEqual(restored.thread.messages, chat.thread.messages)
        XCTAssertFalse(restored.isRunning)
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(restored.thread.sessions["codex"], chat.thread.sessions["codex"])
        let otherProfile = SharedChat(project: root, profileBase: root.appendingPathComponent("another-profile"))
        await otherProfile.load()
        XCTAssertTrue(otherProfile.thread.messages.isEmpty)
    }

    func testFailureStopsTheRelayAndKeepsTheHumanMessage() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = DiscussionFixture(failOn: "codex")
        let chat = SharedChat(project: root, profileBase: root.appendingPathComponent("profiles")) { request, _, update in
            update("Unfinished text")
            return try await fixture.reply(request)
        }
        await chat.load()
        chat.draft = "Discuss the tradeoff."
        XCTAssertTrue(chat.send())
        try await waitUntil { !chat.isRunning }
        XCTAssertNotNil(chat.failure)
        XCTAssertEqual(chat.thread.messages.map(\.speaker), ["you", "claude"])
        let requests = await fixture.recorded()
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(chat.thread.messages.contains { $0.text == "Unfinished text" })
    }

    func testStopNeverForwardsAnUnfinishedReply() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let chat = SharedChat(project: root, profileBase: root.appendingPathComponent("profiles")) { _, cancellation, update in
            update("Partial reply")
            while !cancellation.isCancelled { try await Task.sleep(nanoseconds: 10_000_000) }
            // Even a provider racing with Stop must not complete the relay.
            return SharedChatReply(text: "Late completed reply", sessionID: UUID().uuidString)
        }
        await chat.load()
        chat.draft = "Take turns."
        XCTAssertTrue(chat.send())
        try await waitUntil { chat.partialReply == "Partial reply" }
        chat.stop()
        try await waitUntil { !chat.isRunning }
        XCTAssertEqual(chat.thread.messages.map(\.speaker), ["you"])
        XCTAssertNil(chat.failure)
        XCTAssertEqual(chat.thread.nextSpeaker, "claude")
    }

    func testInterruptedSavedDiscussionWaitsForTheHumanAndNewDiscussionsKeepHistory() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("profiles")
        let store = SharedChatStore(profileBase: profile, project: root)
        var history = SharedChatHistory()
        history.threads[0].inFlight = "codex"
        history.threads[0].nextSpeaker = "codex"
        history.threads[0].draft = "A thought I had not sent"
        history.threads[0].messages = [SharedChatMessage(speaker: "you", text: "An earlier question")]
        try await store.save(history, version: 1)
        let chat = SharedChat(project: root, profileBase: profile)
        await chat.load()
        XCTAssertFalse(chat.isRunning)
        XCTAssertTrue(chat.notice.contains("interrupted"))
        XCTAssertEqual(chat.draft, "A thought I had not sent")
        let oldID = chat.thread.id
        chat.newDiscussion()
        XCTAssertTrue(chat.thread.messages.isEmpty)
        XCTAssertTrue(chat.draft.isEmpty)
        chat.select(oldID)
        XCTAssertEqual(chat.thread.messages.first?.text, "An earlier question")
        XCTAssertEqual(chat.draft, "A thought I had not sent")
        chat.close()
        try await Task.sleep(nanoseconds: 30_000_000)
    }
}

final class SharedChatDecoderTests: XCTestCase {
    func testCodexRequiresSuccessfulCompletionAndExcludesToolAndReasoningOutput() throws {
        let id = UUID().uuidString
        let stream = """
        {"type":"thread.started","thread_id":"\(id)"}
        {"type":"item.completed","item":{"type":"reasoning","text":"Private reasoning"}}
        {"type":"item.completed","item":{"type":"command_execution","aggregated_output":"Tool output"}}
        {"type":"item.completed","item":{"type":"agent_message","text":"A useful reply with åäö 🧪"}}
        {"type":"turn.completed"}
        """
        var decoder = SharedChatDecoder(provider: "codex")
        // Every byte boundary, including inside a multibyte Unicode character.
        for byte in stream.utf8 { try decoder.append(Data([byte])) }
        let reply = try decoder.finish(status: 0)
        XCTAssertEqual(reply.text, "A useful reply with åäö 🧪")
        XCTAssertEqual(reply.sessionID, id)
        var incomplete = SharedChatDecoder(provider: "codex")
        try incomplete.append(Data("{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"Not finished\"}}\n".utf8))
        XCTAssertThrowsError(try incomplete.finish(status: 0))
        XCTAssertThrowsError(try decoder.finish(status: 1))
    }

    func testClaudeRelaysOnlyTheFinalSuccessfulResult() throws {
        let stream = """
        {"type":"system","subtype":"init","session_id":"\(UUID().uuidString)"}
        {"type":"assistant","parent_tool_use_id":"nested-agent","message":{"content":[{"type":"text","text":"Do not relay me"}]}}
        {"type":"stream_event","event":{"delta":{"type":"thinking_delta","thinking":"Private reasoning"}}}
        {"type":"stream_event","event":{"delta":{"type":"text_delta","text":"Interim reply"}}}
        {"type":"result","subtype":"success","is_error":false,"result":"The final reply"}
        """
        var decoder = SharedChatDecoder(provider: "claude")
        try decoder.append(Data(stream.utf8))
        XCTAssertEqual(try decoder.finish(status: 0).text, "The final reply")
        var failed = SharedChatDecoder(provider: "claude")
        try failed.append(Data("{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"result\":\"Failure\"}\n".utf8))
        XCTAssertThrowsError(try failed.finish(status: 0))
    }
}
