import Foundation
import XCTest
@testable import PrivateCLIHost

@MainActor
final class HostModelTests: XCTestCase {
    func testUnavailableStartupProjectDoesNotLaunchInAnotherFolder() throws {
        let suite = "m4ix.cli.startup." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults.set(missing.path, forKey: "PrivateCLIHostWorkingDirectory")
        defaults.set("unknown-provider", forKey: "PrivateCLIHostSelectedAgent")
        let model = HostModel(defaults: defaults, profileBase: missing.appendingPathComponent("profiles"))
        model.startOnLaunch()
        XCTAssertEqual(model.selected, .claude)
        XCTAssertEqual(model.workingDirectory.path, missing.path)
        XCTAssertFalse(model.hasRunningSessions)
        XCTAssertTrue(model.liveSessionsForCurrentProject().isEmpty)
    }

    func testRestorationIsLazyProviderSelectionIsCorrectAndRemovedSessionsStayRemoved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("profiles")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let claudeID = UUID().uuidString.lowercased()
        let codexID = UUID().uuidString.lowercased()
        defaults.set(project.path, forKey: "PrivateCLIHostWorkingDirectory")
        defaults.set([
            ["project": project.path, "agent": "claude", "conversation": claudeID, "title": "Implementation", "selected": true],
            ["project": project.path, "agent": "codex", "conversation": codexID, "title": "Review", "selected": true]
        ], forKey: "PrivateCLIHostRestorableSessions")
        let row: [String: Any] = ["sessionId": claudeID, "timestamp": 1000, "project": project.path, "display": "Implementation"]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: profile.appendingPathComponent("claude/history.jsonl"))
        let model = HostModel(defaults: defaults, profileBase: profile)
        model.restoreSessions()
        let sessions = model.liveSessionsForCurrentProject()
        XCTAssertEqual(Set(sessions.map(\.agent)), Set(Agent.allCases))
        XCTAssertTrue(sessions.allSatisfy { $0.state == .idle && $0.pendingResumeID != nil })
        XCTAssertFalse(model.hasRunningSessions, "Restoring must not start either provider until selected")
        let codex = try XCTUnwrap(sessions.first { $0.agent == .codex })
        model.selectLiveSession(codex)
        XCTAssertEqual(model.selected, .codex)
        XCTAssertEqual(model.currentSession.id, codex.id)
        model.restoreSessions()
        XCTAssertEqual(model.liveSessionsForCurrentProject().count, 2, "Repeated restoration must not duplicate sessions")
        model.refreshHistory()
        let deadline = Date().addingTimeInterval(3)
        while model.conversations.isEmpty && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.conversations.count, 1)
        let claude = try XCTUnwrap(model.liveSessionsForCurrentProject().first { $0.agent == .claude })
        model.removeLiveSession(claude)
        model.saveRestorableSessions()
        let restored = HostModel(defaults: defaults, profileBase: profile)
        restored.restoreSessions()
        XCTAssertTrue(restored.liveSessionsForCurrentProject().isEmpty, "Removed and unknown sessions must not reappear")
        restored.selected = .claude
        restored.currentWorkspace.restoreConversation(for: .claude, title: "Pending", conversationID: claudeID, selected: true)
        restored.refreshHistory()
        let loadedDeadline = Date().addingTimeInterval(3)
        while restored.conversations.isEmpty && Date() < loadedDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        restored.prepareForTermination()
        let pending = restored.currentSession
        restored.startOnLaunch()
        restored.startCurrentIfPending()
        restored.openConversation(try XCTUnwrap(restored.conversations.first))
        restored.showLogin()
        XCTAssertFalse(restored.startNewConversation())
        XCTAssertFalse(restored.hasRunningSessions, "Shutdown must refuse all new CLI launches")
        let snapshot = defaults.array(forKey: "PrivateCLIHostRestorableSessions") as? [[String: Any]]
        XCTAssertEqual(snapshot?.count, 1)
        restored.removeLiveSession(pending)
        restored.saveRestorableSessions()
        let preserved = defaults.array(forKey: "PrivateCLIHostRestorableSessions") as? [[String: Any]]
        XCTAssertEqual(preserved?.count, 1, "Shutdown must preserve the pre-stop restoration snapshot")
    }
}
