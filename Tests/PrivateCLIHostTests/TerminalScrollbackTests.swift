import AppKit
import SwiftTerm
import XCTest
@testable import PrivateCLIHost

@MainActor
final class TerminalScrollbackTests: XCTestCase {
    func testLiveSessionRetainsEarlierTurnsBeyondDefaultScrollback() {
        let session = TerminalSession(agent: .codex, projectPath: "/tmp", title: "Long conversation")
        let lines = (0..<2_000).map { "Conversation line \($0)" }
        session.terminal.feed(text: lines.joined(separator: "\r\n") + "\r\n")

        let history = String(decoding: session.terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        for line in [0, 500, 1_000, 1_999] {
            XCTAssertTrue(history.components(separatedBy: "\n").contains("Conversation line \(line)"),
                          "Earlier turns must remain available after a conversation exceeds 500 lines")
        }
        session.terminal.scroll(toPosition: 0)
        XCTAssertEqual(session.terminal.terminalStateSnapshot().visibleRows.first?.text, "Conversation line 0")
    }

    func testHistoricalCodexPromptDoesNotCoverFollowingConversation() {
        let (deck, terminal) = makeDeck(agent: .codex)
        let lines = (0..<25).map { "Earlier output \($0)" }
            + ["› Earlier user message"]
            + (0..<80).map { "Later output \($0)" }
            + ["› Ask Codex", "Model status"]
        terminal.feed(text: lines.joined(separator: "\r\n"))
        terminal.scrollTo(row: 25)
        deck.layout()

        XCTAssertEqual(terminal.terminalStateSnapshot().visibleRows.first?.text, "› Earlier user message")
        XCTAssertFalse(terminal.inputIsConcealed, "A historical prompt at the top must not black out the viewport")
    }

    func testScrollingOneLineRevealsConversationAndReturningToBottomConcealsOnlyLiveInput() {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.feed(text: (0..<80).map { "Output \($0)" }.joined(separator: "\r\n")
                      + "\r\n› Ask Codex\r\nModel status")
        deck.layout()
        XCTAssertTrue(terminal.inputIsConcealed)

        terminal.scrollUp(lines: 1)
        XCTAssertTrue(terminal.terminalStateSnapshot().visibleRows.contains { $0.text == "› Ask Codex" })
        deck.layout()
        XCTAssertFalse(terminal.inputIsConcealed, "Even a partially scrolled viewport must remain unobstructed")

        terminal.scroll(toPosition: 1)
        deck.layout()
        XCTAssertTrue(terminal.inputIsConcealed)
    }

    func testHistoricalClaudeInputBoxDoesNotCoverFollowingConversation() {
        let (deck, terminal) = makeDeck(agent: .claude)
        let rule = String(repeating: "─", count: 60)
        let lines = (0..<25).map { "Earlier output \($0)" }
            + [rule, "❯ Earlier input", rule]
            + (0..<80).map { "Later output \($0)" }
            + [rule, "❯", rule, "Status"]
        terminal.feed(text: lines.joined(separator: "\r\n"))
        terminal.scrollTo(row: 25)
        deck.layout()

        XCTAssertEqual(terminal.terminalStateSnapshot().visibleRows.first?.text, rule)
        XCTAssertFalse(terminal.inputIsConcealed)
    }

    func testLiveInputIsConcealedBeforeThereIsAnyScrollback() {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.feed(text: "Result\r\n› Ask Codex\r\nModel status")
        XCTAssertFalse(terminal.canScroll)
        deck.layout()
        XCTAssertTrue(terminal.inputIsConcealed)
    }

    func testVisualInputCoverAllowsTerminalScrollingUnderneathIt() {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.feed(text: (0..<80).map { "Output \($0)" }.joined(separator: "\r\n")
                      + "\r\n› Ask Codex\r\nModel status")
        deck.layout()
        XCTAssertTrue(terminal.inputIsConcealed)

        let point = NSPoint(x: terminal.frame.midX, y: terminal.frame.minY + 1)
        XCTAssertTrue(deck.hitTest(point) === terminal, "The visual cover must let scroll and mouse events reach the terminal")
    }

    func testPersistentScrollbarAndJumpToLatest() {
        let (deck, terminal) = makeDeck(agent: .codex)
        XCTAssertEqual(terminal.scrollerStyle, .legacy)
        terminal.feed(text: (0..<100).map { "Output \($0)" }.joined(separator: "\r\n"))
        terminal.scroll(toPosition: 0)
        deck.layout()
        XCTAssertFalse(deck.jumpToLatestButton.isHidden)
        deck.jumpToLatest()
        XCTAssertEqual(terminal.scrollPosition, 1)
        XCTAssertTrue(deck.jumpToLatestButton.isHidden)
    }

    func testNewOutputPreservesReadingPosition() {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.feed(text: (0..<100).map { "Output \($0)" }.joined(separator: "\r\n"))
        terminal.scrollTo(row: 20)
        let firstRow = terminal.terminalStateSnapshot().visibleRows.first?.text
        terminal.feed(text: "\r\nNew response\r\nMore output")
        deck.layout()
        XCTAssertEqual(terminal.terminalStateSnapshot().visibleRows.first?.text, firstRow)
        XCTAssertFalse(deck.jumpToLatestButton.isHidden)
    }

    func testPersistentScrollbarThumbFollowsViewportWithoutNewOutput() throws {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.feed(text: (0..<200).map { "Output \($0)" }.joined(separator: "\r\n"))
        let scroller = deck.scrollbar
        for position in [0.0, 0.5, 1.0] {
            terminal.scroll(toPosition: position)
            deck.layout()
            XCTAssertTrue(scroller.isEnabled)
            XCTAssertEqual(scroller.position, terminal.scrollPosition, accuracy: 0.0001)
            XCTAssertEqual(scroller.proportion, terminal.scrollThumbsize, accuracy: 0.0001)
        }
    }

    func testScrollbarDrawsVisibleThumbAtEachReadingPosition() throws {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.feed(text: (0..<200).map { "Output \($0)" }.joined(separator: "\r\n"))
        let indicator = deck.scrollbar
        deck.layoutSubtreeIfNeeded()
        var previousY: CGFloat = -1
        for position in [0.0, 0.5, 1.0] {
            terminal.scroll(toPosition: position)
            deck.layout()
            XCTAssertTrue(indicator.isEnabled)
            XCTAssertGreaterThan(indicator.knobRect.minY, previousY)
            previousY = indicator.knobRect.minY
            let bitmap = try XCTUnwrap(indicator.bitmapImageRepForCachingDisplay(in: indicator.bounds))
            indicator.cacheDisplay(in: indicator.bounds, to: bitmap)
            let knob = indicator.knobRect
            let scaleX = CGFloat(bitmap.pixelsWide) / indicator.bounds.width
            let scaleY = CGFloat(bitmap.pixelsHigh) / indicator.bounds.height
            let colour = try XCTUnwrap(bitmap.colorAt(x: Int(knob.midX * scaleX),
                y: Int(knob.midY * scaleY))?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(colour.redComponent, 0.4, "The thumb must actually render, not just update its value")
            let hasSignalPixels = (0..<bitmap.pixelsHigh).contains { y in
                let pointY = CGFloat(y) / scaleY
                guard knob.minY <= pointY, pointY <= knob.maxY,
                      let pixel = bitmap.colorAt(x: Int(knob.midX * scaleX), y: y)?
                        .usingColorSpace(.deviceRGB) else { return false }
                return pixel.greenComponent > pixel.redComponent * 1.02
                    && pixel.greenComponent > pixel.blueComponent * 2
            }
            XCTAssertTrue(hasSignalPixels, "The position thumb must render the lime signal color")
            XCTAssertTrue(deck.hitTest(indicator.convert(NSPoint(x: knob.midX, y: knob.midY), to: deck)) === indicator)
        }
    }

    func testScrollbarRemainsVisibleInWindowBeforeAndAfterScrollback() async throws {
        let (deck, terminal) = makeDeck(agent: .codex)
        let window = NSWindow(contentRect: deck.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = deck
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let indicator = deck.scrollbar
        for hasHistory in [false, true] {
            if hasHistory {
                terminal.feed(text: (0..<200).map { "Output \($0)" }.joined(separator: "\r\n"))
            }
            await Task.yield()
            deck.layoutSubtreeIfNeeded()
            deck.layout()
            window.displayIfNeeded()
            XCTAssertFalse(indicator.isHidden)
            XCTAssertGreaterThan(indicator.frame.width, 0)
            let bitmap = try XCTUnwrap(deck.bitmapImageRepForCachingDisplay(in: deck.bounds))
            deck.cacheDisplay(in: deck.bounds, to: bitmap)
            let point = indicator.convert(NSPoint(x: indicator.knobRect.midX, y: indicator.knobRect.midY), to: deck)
            let x = Int(point.x * CGFloat(bitmap.pixelsWide) / deck.bounds.width)
            let y = bitmap.pixelsHigh - 1 - Int(point.y * CGFloat(bitmap.pixelsHigh) / deck.bounds.height)
            let colour = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(colour.redComponent, hasHistory ? 0.4 : 0.2)
        }
    }

    func testMenuTakesKeyboardFocusWhenSessionIsShown() {
        let (deck, terminal) = makeDeck(agent: .codex)
        let window = NSWindow(contentRect: deck.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = deck
        window.makeKeyAndOrderFront(nil)
        terminal.feed(text: "Approve command?\r\n› 1. Yes\r\n  2. No")
        deck.layout()
        XCTAssertTrue(window.firstResponder === terminal)
        window.orderOut(nil)
    }

    func testDraggingAndClickingTheVisibleScrollbarMovesTheTerminal() throws {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.changeScrollback(10_000)
        terminal.feed(text: (0..<2_000).map { "Output \($0)" }.joined(separator: "\r\n"))
        let window = NSWindow(contentRect: deck.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = deck
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        deck.layoutSubtreeIfNeeded()
        deck.layout()
        let scrollbar = deck.scrollbar
        func mouse(_ type: NSEvent.EventType, y: CGFloat) throws {
            let point = NSPoint(x: scrollbar.bounds.midX, y: y)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type,
                location: scrollbar.convert(point, to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            window.sendEvent(event)
        }
        try mouse(.leftMouseDown, y: scrollbar.bounds.midY)
        try mouse(.leftMouseUp, y: scrollbar.bounds.midY)
        XCTAssertEqual(terminal.scrollPosition, 0.5, accuracy: 0.001)
        XCTAssertEqual(scrollbar.position, terminal.scrollPosition, accuracy: 0.0001)
        XCTAssertFalse(deck.jumpToLatestButton.isHidden)
        try mouse(.leftMouseDown, y: scrollbar.knobRect.midY)
        try mouse(.leftMouseDragged, y: -80)
        XCTAssertEqual(terminal.scrollPosition, 0)
        XCTAssertEqual(terminal.terminalStateSnapshot().visibleRows.first?.text, "Output 0")
        try mouse(.leftMouseDragged, y: scrollbar.bounds.maxY + 80)
        try mouse(.leftMouseUp, y: scrollbar.bounds.maxY + 80)
        XCTAssertEqual(terminal.scrollPosition, 1)
        XCTAssertTrue(deck.jumpToLatestButton.isHidden)

        window.setContentSize(NSSize(width: 960, height: 700))
        deck.layoutSubtreeIfNeeded()
        deck.layout()
        XCTAssertEqual(scrollbar.frame.maxY, terminal.frame.maxY)
        XCTAssertEqual(scrollbar.frame.minY, terminal.frame.minY)
        XCTAssertEqual(scrollbar.frame.minX, terminal.frame.maxX)
        XCTAssertTrue(scrollbar.accessibilityPerformDecrement())
        XCTAssertLessThan(terminal.scrollPosition, 1)
        scrollbar.setAccessibilityValue(NSNumber(value: 0))
        XCTAssertEqual(terminal.scrollPosition, 0)
    }

    func testScrollUpdatesNavigationWithoutLayoutOrPolling() async {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.feed(text: (0..<200).map { "Output \($0)" }.joined(separator: "\r\n"))
        deck.layout()
        terminal.scroll(toPosition: 0)
        // Let the coalesced viewport callback run; no layout or timer tick.
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(deck.jumpToLatestButton.isHidden)
        terminal.scroll(toPosition: 1)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(deck.jumpToLatestButton.isHidden)
    }

    func testWheelScrollingLongConversationUpdatesThumb() async throws {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.changeScrollback(10_000)
        terminal.feed(text: (0..<5_000).map { "Output \($0)" }.joined(separator: "\r\n"))
        deck.layout()
        let scroller = deck.scrollbar
        let wheel = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line,
                                         wheelCount: 1, wheel1: 20, wheel2: 0, wheel3: 0))
        wheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 20)
        let event = try XCTUnwrap(NSEvent(cgEvent: wheel))
        XCTAssertGreaterThan(event.scrollingDeltaY, 0)
        terminal.scrollWheel(with: event)
        await Task.yield()
        await Task.yield()
        XCTAssertLessThan(terminal.scrollPosition, 1)
        XCTAssertEqual(scroller.position, terminal.scrollPosition, accuracy: 0.0001)
        XCTAssertFalse(deck.jumpToLatestButton.isHidden)
    }

    func testSwitchingSessionsPreservesReadingPositionWhileHiddenOutputArrives() {
        let (deck, terminal) = makeDeck(agent: .codex)
        terminal.changeScrollback(10_000)
        terminal.feed(text: (0..<2_000).map { "Output \($0)" }.joined(separator: "\r\n"))
        terminal.scrollTo(row: 500)
        let firstRow = terminal.terminalStateSnapshot().visibleRows.first?.text
        XCTAssertEqual(firstRow, "Output 500")
        let other = TrackedTerminalView(frame: deck.bounds)
        deck.show(other)
        deck.layoutSubtreeIfNeeded()
        terminal.feed(text: "\r\nHidden output\r\nMore hidden output")
        deck.show(terminal)
        deck.layoutSubtreeIfNeeded()
        deck.layout()
        XCTAssertEqual(terminal.terminalStateSnapshot().visibleRows.first?.text, firstRow)
        XCTAssertFalse(deck.jumpToLatestButton.isHidden)
    }

    private func makeDeck(agent: Agent) -> (TerminalDeckView, TrackedTerminalView) {
        let deck = TerminalDeckView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        deck.agent = agent
        let terminal = TrackedTerminalView(frame: deck.bounds)
        deck.show(terminal)
        deck.layoutSubtreeIfNeeded()
        return (deck, terminal)
    }
}
