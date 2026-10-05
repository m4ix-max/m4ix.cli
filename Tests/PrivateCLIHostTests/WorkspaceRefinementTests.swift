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

    func testBundledFacesLoadWithTheirWeightsAndOpticalSizes() throws {
        // Core Text reports only the axes moved off their defaults, so start
        // from each axis's default value.
        func axes(_ font: NSFont) -> [String: Double] {
            var values: [UInt32: Double] = [:]
            for axis in CTFontCopyVariationAxes(font as CTFont) as? [[String: Any]] ?? [] {
                if let id = axis[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
                   let value = axis[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber {
                    values[id.uint32Value] = value.doubleValue
                }
            }
            for (key, value) in CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber] ?? [:] {
                values[key.uint32Value] = value.doubleValue
            }
            return Dictionary(uniqueKeysWithValues: values.map { code, value in
                (String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }, encoding: .ascii) ?? "?", value)
            })
        }
        let title = ElevateTheme.serifNS(28)
        let sidebar = ElevateTheme.serifNS(13)
        XCTAssertEqual(title.familyName, "Newsreader")
        XCTAssertEqual(axes(title)["opsz"], 28)
        XCTAssertEqual(axes(sidebar)["opsz"], 13)
        XCTAssertEqual(axes(title)["wght"], 400)

        let label = ElevateTheme.utilityNS(10)
        let control = ElevateTheme.utilityNS(12, medium: true)
        XCTAssertEqual(label.familyName, "Chivo Mono")
        XCTAssertEqual(axes(label)["wght"], 400)
        XCTAssertEqual(axes(control)["wght"], 500)
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
