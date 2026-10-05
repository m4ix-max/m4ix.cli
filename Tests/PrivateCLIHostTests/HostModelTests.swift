import Foundation
import XCTest
@testable import PrivateCLIHost

@MainActor
final class HostModelTests: XCTestCase {
    func testConversationOrderSurvivesRestorationAndUsesLatestActivity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let profile = root.appendingPathComponent("profiles")
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.order." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recentID = UUID().uuidString.lowercased()
        let olderID = UUID().uuidString.lowercased()
        defaults.set(project.path, forKey: "PrivateCLIHostWorkingDirectory")
        defaults.set([
            ["project": project.path, "agent": "claude", "conversation": recentID, "title": "Recent", "updatedAt": 20.0],
            ["project": project.path, "agent": "claude", "conversation": olderID, "title": "Older", "updatedAt": 10.0]
        ], forKey: "PrivateCLIHostRestorableSessions")
        let rows: [[String: Any]] = [
            ["sessionId": recentID, "timestamp": 20_000, "project": project.path, "display": "Recent"],
            ["sessionId": olderID, "timestamp": 10_000, "project": project.path, "display": "Older"]
        ]
        let data = try rows.reduce(into: Data()) { result, row in
            result.append(try JSONSerialization.data(withJSONObject: row)); result.append(0x0a)
        }
        try data.write(to: profile.appendingPathComponent("claude/history.jsonl"))
        let model = HostModel(defaults: defaults, profileBase: profile)
        model.restoreSessions()
        XCTAssertEqual(model.liveSessionsForCurrentProject().map(\.pendingResumeID), [recentID, olderID],
                       "Recreating terminal objects must not reverse the saved order")
        model.refreshHistory()
        let deadline = Date().addingTimeInterval(3)
        while model.conversations.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(model.conversations.count, 2)
        let older = try XCTUnwrap(model.liveSessionsForCurrentProject().first { $0.pendingResumeID == olderID })
        model.selectLiveSession(older)
        XCTAssertEqual(model.liveSessionsForCurrentProject().map(\.pendingResumeID), [recentID, olderID],
                       "Reading an old conversation must not count as a new message")
        model.currentWorkspace.reconcileHistory([
            ConversationRecord(provider: "claude", sessionID: recentID, projectPath: project.path,
                               title: "Recent", updatedAt: Date(timeIntervalSince1970: 20)),
            ConversationRecord(provider: "claude", sessionID: olderID, projectPath: project.path,
                               title: "Continued", updatedAt: Date(timeIntervalSince1970: 30))
        ])
        XCTAssertEqual(model.liveSessionsForCurrentProject().map(\.pendingResumeID), [olderID, recentID])
        XCTAssertEqual(older.displayTitle, "Continued")
        model.saveRestorableSessions()
        let restored = HostModel(defaults: defaults, profileBase: profile)
        restored.restoreSessions()
        XCTAssertEqual(restored.liveSessionsForCurrentProject().map(\.pendingResumeID), [olderID, recentID])
        XCTAssertFalse(restored.hasRunningSessions)
    }

    func testLegacyRestorationUsesProviderTimestampsAcrossBothAgents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.legacy-order." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "PrivateCLIHostWorkingDirectory")
        let ids = (0..<3).map { _ in UUID().uuidString.lowercased() }
        defaults.set(zip(["claude", "codex", "claude"], ids).map { agent, id in
            ["project": root.path, "agent": agent, "conversation": id, "title": "Saved"]
        }, forKey: "PrivateCLIHostRestorableSessions")
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        model.restoreSessions()
        let records = zip(["claude", "codex", "claude"], ids).enumerated().map { index, entry in
            ConversationRecord(provider: entry.0, sessionID: entry.1, projectPath: root.path,
                               title: "Saved", updatedAt: Date(timeIntervalSince1970: Double(3 - index)))
        }
        model.currentWorkspace.reconcileHistory(records)
        XCTAssertEqual(model.liveSessionsForCurrentProject().map(\.pendingResumeID), ids)
        model.currentWorkspace.reconcileHistory(records)
        XCTAssertEqual(model.liveSessionsForCurrentProject().map(\.pendingResumeID), ids)
    }

    func testTestRunsKeepOutOfTheUserDataDirectory() {
        let base = HostPaths.profileBase.standardizedFileURL.path
        XCTAssertNotEqual(base, HostPaths.userDataDirectory.standardizedFileURL.path,
                          "A test run must not write into the app's private profiles or event log")
        XCTAssertTrue(HostDiagnostics.logURL.path.hasPrefix(base + "/"))
    }

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
