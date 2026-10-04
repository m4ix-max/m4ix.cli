import AppKit
import XCTest
@testable import PrivateCLIHost

final class PromptImageTests: XCTestCase {
    private var directory: URL!
    private var sources: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("prompt-images-\(UUID().uuidString)")
        directory = base.appendingPathComponent("store")
        sources = base.appendingPathComponent("source files")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func sampleImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        return image
    }

    private func write(_ name: String, as type: NSBitmapImageRep.FileType) throws -> URL {
        let rep = NSBitmapImageRep(data: sampleImage().tiffRepresentation!)!
        let url = sources.appendingPathComponent(name)
        try rep.representation(using: type, properties: [:])!.write(to: url)
        return url
    }

    func testCopiesSupportedFilesUnderPlainNames() throws {
        // macOS screenshot names carry spaces and a narrow no-break space.
        let source = try write("Screenshot 2026-09-30 at\u{202F}00.10.png", as: .png)
        let image = try XCTUnwrap(PromptImageStore.add(fileAt: source, in: directory))
        XCTAssertEqual(image.url.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(image.url.pathExtension, "png")
        XCTAssertNil(image.url.path.rangeOfCharacter(from: .whitespaces))
        XCTAssertEqual(try Data(contentsOf: image.url), try Data(contentsOf: source))
    }

    func testConvertsOtherFormatsToPNGAndRejectsNonImages() throws {
        let tiff = try write("scan.tiff", as: .tiff)
        let image = try XCTUnwrap(PromptImageStore.add(fileAt: tiff, in: directory))
        XCTAssertEqual(image.url.pathExtension, "png")
        XCTAssertNotNil(NSImage(contentsOf: image.url))

        let text = sources.appendingPathComponent("notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        XCTAssertNil(PromptImageStore.add(fileAt: text, in: directory))
    }

    func testPasteboardImagesAndTextPrecedence() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("m4ix-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }

        board.clearContents()
        board.writeObjects([try write("a.png", as: .png) as NSURL, try write("b.jpg", as: .jpeg) as NSURL])
        XCTAssertEqual(PromptImageStore.images(from: board, isPaste: true, in: directory).count, 2)

        board.clearContents()
        board.writeObjects([sampleImage()])
        XCTAssertEqual(PromptImageStore.images(from: board, isPaste: true, in: directory).count, 1)

        // Rich text from another app often carries a picture of itself.
        board.clearContents()
        board.declareTypes([.string, .tiff], owner: nil)
        board.setString("plain words", forType: .string)
        board.setData(sampleImage().tiffRepresentation, forType: .tiff)
        XCTAssertTrue(PromptImageStore.images(from: board, isPaste: true, in: directory).isEmpty)
        XCTAssertEqual(PromptImageStore.images(from: board, isPaste: false, in: directory).count, 1)

        board.clearContents()
        board.setString("just text", forType: .string)
        XCTAssertTrue(PromptImageStore.images(from: board, isPaste: true, in: directory).isEmpty)
    }

    func testPrunesOnlyOldCopies() throws {
        let old = try XCTUnwrap(PromptImageStore.add(image: sampleImage(), in: directory))
        let fresh = try XCTUnwrap(PromptImageStore.add(image: sampleImage(), in: directory))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -40 * 24 * 3600)],
                                              ofItemAtPath: old.url.path)
        PromptImageStore.prune(in: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.url.path))
    }

    @MainActor
    func testImagePasteIsEnabledAndAttachesInBothEditorAndTerminal() throws {
        let board = NSPasteboard.general
        let previous = (board.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        defer { board.clearContents(); board.writeObjects(previous) }
        let source = try write("Saved image.png", as: .png)
        let editor = PromptTextView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        let terminal = TrackedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        var attachments: [PromptImage] = []
        editor.onImages = { attachments += $0 }
        terminal.onPasteImages = { attachments += $0 }
        let menu = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        for objects: [NSPasteboardWriting] in [[source as NSURL], [sampleImage()]] {
            board.clearContents()
            board.writeObjects(objects)
            XCTAssertTrue(editor.validateUserInterfaceItem(menu))
            XCTAssertTrue(terminal.validateUserInterfaceItem(menu))
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9))
            XCTAssertTrue(editor.performKeyEquivalent(with: event))
            terminal.paste(menu)
        }
        XCTAssertEqual(attachments.count, 4)
        XCTAssertEqual(editor.string, "")
        for image in attachments { try? FileManager.default.removeItem(at: image.url) }
    }

    func testLegacyFinderImageFileListPastesAsAttachment() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("m4ix-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setPropertyList([try write("Saved.png", as: .png).path],
                              forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        XCTAssertTrue(PromptImageStore.canPasteImages(from: board))
        XCTAssertEqual(PromptImageStore.images(from: board, isPaste: true, in: directory).count, 1)
    }

    func testCountsImageMarkersBothCLIsDraw() {
        // Captured from Claude Code 2.1.285 and Codex 0.159.1.
        XCTAssertEqual(CLIPrompt.imageMarkers(in: ["❯ [Image #1] [Image #2]what colour is it?"]), 2)
        XCTAssertEqual(CLIPrompt.imageMarkers(in: ["› [Image #1] [Image #2] what colour is it?", "› [Image #3]"]), 3)
        XCTAssertEqual(CLIPrompt.imageMarkers(in: ["❯ Try \"write a test for <filepath>\""]), 0)
    }
}
