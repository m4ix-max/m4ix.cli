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

    func testComposerRendersDraftAndTerminalQuestionAtNarrowWidth() async throws {
        let suite = "m4ix.cli.composer." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dictation = Dictation(preferences: defaults, bundle: Bundle(for: Self.self))
        for blocked in [false, true] {
            let view = NSHostingView(rootView: PromptComposer(
                text: .constant("A draft stays here while I answer a question."), images: .constant([]),
                mode: blocked ? .blocked : .send, agentName: "Codex", projectName: "Motion",
                dictation: dictation, dictationTarget: "draft",
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
