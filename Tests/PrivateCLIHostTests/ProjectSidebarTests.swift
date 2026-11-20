import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PrivateCLIHost

@MainActor
final class ProjectSidebarTests: XCTestCase {
    func testActiveWorkSpansProjectsAndKeepsHistoryAndOtherProfilesOut() {
        let first = ProjectRecord(path: "/work/Atlas")
        let second = ProjectRecord(path: "/work/Beacon")
        let waiting = TerminalSession(agent: .claude, projectPath: first.path, title: "Design review")
        let attention = TerminalSession(agent: .codex, projectPath: second.path, title: "Fix navigation")
        let queued = TerminalSession(agent: .hermes, projectPath: first.path, title: "Check copy")
        queued.markQueued()
        let restored = TerminalSession(agent: .codex, projectPath: first.path, title: "Earlier discussion",
                                       pendingResumeID: UUID().uuidString)
        let otherProfile = TerminalSession(agent: .claude, projectPath: second.path, title: "Private work", profileID: "other")
        let stopped = TerminalSession(agent: .codex, projectPath: second.path, title: "Stopped work")
        stopped.markQueued()
        stopped.stop()
        let snapshot = SidebarSnapshot(projects: [first, second],
            sessions: [waiting, attention, queued, restored, otherProfile, stopped], profileID: "default",
            attention: [attention.id: "", restored.id: "Old notification", stopped.id: "Old notification"])

        XCTAssertEqual(snapshot.activeCount, 3)
        XCTAssertEqual(snapshot.conversations(in: .attention).map(\.id), [attention.id])
        XCTAssertEqual(snapshot.conversations(in: .queued).map(\.id), [queued.id])
        XCTAssertEqual(snapshot.conversations(in: .waiting).map(\.id), [waiting.id])
        XCTAssertEqual(Set(snapshot.conversations(in: .history).map(\.id)), [restored.id, stopped.id])
        XCTAssertEqual(snapshot.projects.map { $0.active.count }, [2, 1])
        XCTAssertEqual(snapshot.projects.map(\.attentionCount), [0, 1])
        XCTAssertFalse(snapshot.conversations.contains { $0.id == otherProfile.id })
    }

    func testSearchFindsProjectProviderAndEarlierConversationAcrossProjects() {
        let first = ProjectRecord(path: "/clients/north/Atlas")
        let second = ProjectRecord(path: "/clients/south/Atlas")
        let empty = ProjectRecord(path: "/clients/Empty project")
        let firstSession = TerminalSession(agent: .claude, projectPath: first.path, title: "Landing page")
        let history = TerminalSession(agent: .codex, projectPath: second.path, title: "Keyboard navigation",
                                      pendingResumeID: UUID().uuidString)
        func search(_ query: String) -> SidebarSnapshot {
            SidebarSnapshot(projects: [first, second, empty], sessions: [firstSession, history],
                            profileID: "default", attention: [:], query: query)
        }
        XCTAssertEqual(search("  SOUTH   CoDeX keyboard ").conversations.map(\.id), [history.id])
        XCTAssertEqual(search("keyboard").projects.map(\.id), [second.path])
        XCTAssertEqual(search("ATLAS").projects.count, 2, "Same-name folders keep distinct paths")
        XCTAssertEqual(search("ATLAS").projects.compactMap(\.parentPath), ["/clients/north", "/clients/south"])
        XCTAssertEqual(search("empty").projects.map(\.id), [empty.path], "A project with no sessions is still searchable")
        XCTAssertTrue(search("unmatched").projects.isEmpty)
        XCTAssertFalse(search(" \n ").isSearching)
        XCTAssertEqual(search(" \n ").projects.count, 3)
        XCTAssertEqual(search("keyboard").activeCount, 1, "The navigation count describes all active work")
    }

    func testCrossProjectSelectionOpensTheExactProviderWithoutChangingRecency() throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let first = model.currentWorkspace.createConversation(for: .claude, title: "First project")
        model.openWorkspace(fixture.projects[1])
        let target = model.currentWorkspace.restoreConversation(for: .codex, title: "Review in another project",
            conversationID: UUID().uuidString, selected: false, updatedAt: Date(timeIntervalSince1970: 10))
        model.selectLiveSession(first)
        XCTAssertEqual(model.currentSession.id, first.id)
        XCTAssertEqual(model.workingDirectory.path, first.projectPath)
        model.isSplit = true
        model.selectLiveSession(target)
        XCTAssertEqual(model.workingDirectory.path, target.projectPath)
        XCTAssertEqual(model.selected, .codex)
        XCTAssertEqual(model.currentSession.id, target.id)
        XCTAssertTrue(model.isSelected(target))
        XCTAssertEqual(target.conversationUpdatedAt, Date(timeIntervalSince1970: 10))
        XCTAssertEqual(target.state, .idle, "Selection lets the host resume only when the pane is shown")

        let unknown = TerminalSession(agent: .hermes, projectPath: fixture.root.path, title: "Not in the model")
        model.selectLiveSession(unknown)
        XCTAssertEqual(model.currentSession.id, target.id, "Unknown sessions must not change projects")
    }

    func testSidebarNavigationPersistsAndRevealsSelectedHistory() throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let session = fixture.model.currentWorkspace.restoreConversation(for: .claude, title: "Earlier conversation",
            conversationID: UUID().uuidString, selected: true)
        fixture.model.sidebarNavigation.mode = .projects
        fixture.model.sidebarNavigation.reveal(session)
        let restored = HostModel(defaults: fixture.defaults, profileBase: fixture.root.appendingPathComponent("data"))
        XCTAssertEqual(restored.sidebarNavigation.mode, .projects)
        XCTAssertTrue(restored.sidebarNavigation.expandedProjects.contains(session.projectPath))
        XCTAssertTrue(restored.sidebarNavigation.expandedHistory.contains(session.projectPath))
    }

    func testSidebarUpdatesOnSessionStateWithoutTriggeringSelectionEffects() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set([
            ["project": fixture.projects[1].path, "agent": "codex", "conversation": UUID().uuidString,
             "title": "Background work", "selected": false] as [String: Any]
        ], forKey: "PrivateCLIHostRestorableSessions")
        fixture.model.restoreSessions()
        let session = try XCTUnwrap(fixture.model.allLiveSessions.first)
        let selectionRevision = fixture.model.sessionRevision
        let sidebarRevision = fixture.model.sidebarRevision
        session.markQueued()
        try await waitUntil { fixture.model.sidebarRevision > sidebarRevision }
        XCTAssertEqual(fixture.model.sessionRevision, selectionRevision)
        XCTAssertEqual(SidebarActivity.classify(session, attention: nil), .queued)
        let queuedRevision = fixture.model.sidebarRevision
        fixture.model.stopLiveSession(session)
        try await waitUntil { fixture.model.sidebarRevision > queuedRevision }
        XCTAssertEqual(SidebarActivity.classify(session, attention: nil), .history)
        XCTAssertEqual(fixture.model.workingDirectory.path, fixture.projects[0].path)
    }

    func testWorkingSessionMovesToWaitingAndAttentionWithoutLosingItsProject() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let session = fixture.model.currentWorkspace.createConversation(for: .claude, title: "Running work")
        session.launch(.run, in: fixture.projects[0])
        try await waitUntil { session.terminal.activity.outputAge() != nil }
        session.terminal.activity.markOutput()
        _ = session.updateActivity(now: Date())
        XCTAssertEqual(SidebarActivity.classify(session, attention: nil), .working)
        _ = session.updateActivity(now: Date().addingTimeInterval(4))
        XCTAssertEqual(SidebarActivity.classify(session, attention: nil), .waiting)
        XCTAssertEqual(SidebarActivity.classify(session, attention: "Approval needed"), .attention)
        XCTAssertEqual(session.projectPath, fixture.projects[0].path)
    }

    func testRenderedRowDropsQueuedStatusWhenItsSessionStarts() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set([
            ["project": fixture.projects[0].path, "agent": "claude", "conversation": UUID().uuidString,
             "title": "Review the layout", "selected": true] as [String: Any]
        ], forKey: "PrivateCLIHostRestorableSessions")
        let model = fixture.model
        model.restoreSessions()
        let session = model.currentSession
        session.markQueued()
        let view = NSHostingView(rootView: ProjectSidebar(model: model,
            onSelectSession: model.selectLiveSession, onStopSession: model.stopLiveSession,
            onRemoveSession: model.removeLiveSession))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        func visibleText(_ bitmap: NSBitmapImageRep) throws -> String {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: XCTUnwrap(bitmap.cgImage), options: [:]).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n").uppercased()
        }
        let queued = try await render(view, named: "sidebar-transition-queued")
        XCTAssertTrue(try visibleText(queued).contains("QUEUED"))
        session.launch(.run, in: fixture.projects[0])
        try await waitUntil { session.terminal.activity.outputAge() != nil }
        let running = try await render(view, named: "sidebar-transition-running")
        let text = try visibleText(running)
        XCTAssertTrue(text.contains("WAITING"), text)
        XCTAssertFalse(text.contains("QUEUED"), "The row must update along with its section heading: \(text)")
    }

    func testSidebarRendersAndNavigatesProjectsHistoryAndGlobalSearchInBothAppearances() async throws {
        let fixture = try SidebarFixture()
        defer { fixture.cleanUp() }
        let model = fixture.model
        let active = model.currentWorkspace.createConversation(for: .claude, title: "Refine the project navigation")
        _ = model.currentWorkspace.restoreConversation(for: .codex, title: "Earlier decisions and keyboard shortcuts",
            conversationID: UUID().uuidString, selected: false)
        model.openWorkspace(fixture.projects[1])
        let queued = model.currentWorkspace.createConversation(for: .codex, title: "Review the conversation list")
        queued.markQueued()
        let attention = model.currentWorkspace.createConversation(for: .claude, title: "Approve the next step")
        attention.terminal.feed(text: "\u{1b}]777;notify;Claude Code;Approval needed\u{07}")
        try await Task.sleep(nanoseconds: 50_000_000)
        model.updateAttention()
        model.selectLiveSession(active)

        let view = NSHostingView(rootView: ProjectSidebar(model: model,
            onSelectSession: model.selectLiveSession, onStopSession: model.stopLiveSession,
            onRemoveSession: model.removeLiveSession))
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }

        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            window.appearance = NSAppearance(named: appearance)
            model.sidebarNavigation.mode = .active
            try await render(view, named: "sidebar-active-\(suffix)")
            try click(view, x: 215, top: 104)
            try await render(view, named: "sidebar-projects-\(suffix)")
            XCTAssertEqual(model.sidebarNavigation.mode, .projects, "Projects tab must respond to a pointer click")
            model.sidebarNavigation.expandedHistory.insert(active.projectPath)
            try await render(view, named: "sidebar-history-\(suffix)")
            model.sidebarNavigation.expandedHistory.removeAll()
        }

        let search = try XCTUnwrap(descendants(view).compactMap { $0 as? NSTextField }.first)
        search.stringValue = "earlier decisions"
        search.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: search))
        try await render(view, named: "sidebar-search")
        XCTAssertEqual(search.stringValue, "earlier decisions")
        let fieldFrame = search.convert(search.bounds, to: view)
        XCTAssertGreaterThan(fieldFrame.width, 200)
        XCTAssertGreaterThanOrEqual(fieldFrame.minX, 0)
        XCTAssertLessThanOrEqual(fieldFrame.maxX, 300)
        // Clearing the query restores the project tree without changing projects.
        try click(view, x: 268, top: 155)
        try await render(view, named: "sidebar-search-cleared")
        XCTAssertEqual(search.stringValue, "")
        XCTAssertEqual(model.workingDirectory.path, active.projectPath)
    }

    private func click(_ view: NSView, x: CGFloat, top: CGFloat) throws {
        let window = try XCTUnwrap(view.window)
        window.makeKey()
        let point = view.convert(NSPoint(x: x, y: view.isFlipped ? top : view.bounds.height - top), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    @discardableResult
    private func render(_ view: NSView, named name: String) async throws -> NSBitmapImageRep {
        try await Task.sleep(nanoseconds: 120_000_000)
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                to: directory.appendingPathComponent(name + ".png"))
        }
        return bitmap
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class SidebarFixture {
    let root: URL
    let projects: [URL]
    let suite: String
    let defaults: UserDefaults
    let model: HostModel
    private let previousEnvironment = ProcessInfo.processInfo.environment
    private let overrideKeys = ["PRIVATE_CLI_HOST_CLAUDE_BIN", "PRIVATE_CLI_HOST_CODEX_BIN", "PRIVATE_CLI_HOST_HERMES_BIN"]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-" + UUID().uuidString)
        projects = [root.appendingPathComponent("Atlas"), root.appendingPathComponent("Beacon")]
        for project in projects { try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true) }
        suite = "m4ix.cli.sidebar." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(projects[0].path, forKey: "PrivateCLIHostWorkingDirectory")
        defaults.set(projects.map(\.path), forKey: "PrivateCLIHostProjects")
        let executable = root.appendingPathComponent("fake-cli")
        try Data(#"""
        #!/bin/bash
        for argument in "$@"; do
            if [[ "$argument" == --version ]]; then
                [[ -n "$CLAUDE_CONFIG_DIR" ]] && printf '2.1.287 (Claude Code)\n' || printf 'codex-cli 0.159.3\n'
                exit 0
            fi
            if [[ "$argument" == status ]]; then printf 'Fixture account ready\n'; exit 0; fi
        done
        printf 'Sidebar fixture ready\n'
        IFS= read -r input
        """#.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for key in overrideKeys { setenv(key, executable.path, 1) }
        model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("data"))
    }

    func cleanUp() {
        model.prepareForTermination()
        model.stopAllSessions()
        for key in overrideKeys {
            if let value = previousEnvironment[key] { setenv(key, value, 1) }
            else { unsetenv(key) }
        }
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}
