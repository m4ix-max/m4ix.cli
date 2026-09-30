import AppKit
import SwiftUI
import XCTest
@testable import PrivateCLIHost

@MainActor
final class WorkspaceRefinementTests: XCTestCase {
    func testComposerFocusSurvivesAttachingToWindowAndDoesNotStealItBack() async throws {
        let text = PromptTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 80))
        text.focusWhenAttached()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(text.wantsPromptFocus)
        let window = NSWindow(contentRect: text.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = text
        defer { window.orderOut(nil) }
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(window.firstResponder === text)
        XCTAssertFalse(text.wantsPromptFocus)
        let terminal = NSView()
        text.addSubview(terminal)
        window.makeFirstResponder(nil)
        text.string = "Draft while a question is open"
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(window.firstResponder === text)
    }

    func testAnimationToolsResolveCurrentProjectBeforePersonalFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tools = WorkspaceTools(home: directory.appendingPathComponent("home"))
        XCTAssertNil(tools.root(for: directory))
        for path in ["annotator/server.js", "annotator/index.html", "motion/index.html"] {
            let file = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        XCTAssertEqual(tools.root(for: directory.appendingPathComponent("motion"))?.path, directory.path)
        let url = WorkspaceTools.Tool.annotator.url
        let ok = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        let failure = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
        let expected = Data("<title>Annotator</title>".utf8)
        XCTAssertTrue(WorkspaceTools.isExpectedPage(expected, response: ok, tool: .annotator))
        XCTAssertFalse(WorkspaceTools.isExpectedPage(expected, response: failure, tool: .annotator))
        XCTAssertFalse(WorkspaceTools.isExpectedPage(Data("Unrelated service".utf8), response: ok, tool: .annotator))
        XCTAssertFalse(WorkspaceTools.isExpectedPage(expected, response: ok, tool: .motion))
    }

    func testComposerRendersDraftAndTerminalQuestionAtNarrowWidth() async throws {
        for blocked in [false, true] {
            let view = NSHostingView(rootView: PromptComposer(
                text: .constant("A draft stays here while I answer a question."), images: .constant([]),
                mode: blocked ? .blocked : .send, agentName: "Codex", projectName: "Motion",
                onSubmit: { _, _ in false }))
            view.frame = NSRect(x: 0, y: 0, width: 640, height: 200)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
            let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: image)
            if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
                let file = URL(fileURLWithPath: output).appendingPathComponent("composer-\(blocked ? "question" : "draft").png")
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: file)
            }
            window.orderOut(nil)
        }
    }
}
