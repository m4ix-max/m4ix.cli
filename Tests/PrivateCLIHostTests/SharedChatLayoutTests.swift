import AppKit
import SwiftUI
import XCTest
@testable import PrivateCLIHost

@MainActor
final class SharedChatLayoutTests: XCTestCase {
    func testSharedDiscussionRendersItsSpeakersAndComposerAtBothSizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shared-chat-preview-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SharedChatStore(profileBase: root, project: root)
        var history = SharedChatHistory()
        history.threads[0].messages = [
            SharedChatMessage(speaker: "you", text: "How should the two of you work together on this project?"),
            SharedChatMessage(speaker: "claude", text: "I would start by agreeing on the expected behaviour, then propose an implementation for Codex to review."),
            SharedChatMessage(speaker: "codex", text: "I can challenge the assumptions and identify the checks we need. Once the plan is clear, you can take it into an implementation session.")
        ]
        try await store.save(history, version: 1)
        let chat = SharedChat(project: root, profileBase: root)
        await chat.load()
        for size in [NSSize(width: 840, height: 760), NSSize(width: 720, height: 620)] {
            let view = NSHostingView(rootView: SharedChatView(chat: chat))
            view.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFront(nil)
            try await Task.sleep(nanoseconds: 100_000_000)
            view.layoutSubtreeIfNeeded()
            func descendants(_ node: NSView) -> [NSView] { [node] + node.subviews.flatMap(descendants) }
            let editors = descendants(view).compactMap { $0 as? NSTextView }.filter(\.isEditable)
            XCTAssertEqual(editors.count, 1)
            for editor in editors {
                let frame = editor.convert(editor.bounds, to: view)
                XCTAssertGreaterThan(frame.width, 500)
                XCTAssertGreaterThanOrEqual(frame.minX, 0)
                XCTAssertLessThanOrEqual(frame.maxX, size.width)
                XCTAssertGreaterThanOrEqual(frame.minY, 0)
                XCTAssertLessThanOrEqual(frame.maxY, size.height)
            }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            if let output = ProcessInfo.processInfo.environment["M4IX_UI_PREVIEW_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: directory.appendingPathComponent("shared-chat-\(Int(size.width)).png"))
            }
            window.orderOut(nil)
        }
        await chat.flush()
    }
}
