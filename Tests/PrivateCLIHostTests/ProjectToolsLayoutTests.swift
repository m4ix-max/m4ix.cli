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
        let model = HostModel(defaults: defaults, profileBase: root.appendingPathComponent("profiles"))
        _ = model.currentWorkspace.createConversation(for: .claude, title: "Implement parser")
        _ = model.currentWorkspace.createConversation(for: .codex, title: "Review parser")
        let delegate = PrivateCLIAppDelegate()
        let view = NSHostingView(rootView: HostView(appDelegate: delegate, model: model))
        view.frame = NSRect(x: 0, y: 0, width: 960, height: 600)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 400_000_000)
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.liveSessionsForCurrentProject().count, 2)
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("main-workspace.png"))
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
