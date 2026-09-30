import SwiftTerm
import XCTest
@testable import PrivateCLIHost

final class CLIPromptTests: XCTestCase {
    private let rule = String(repeating: "─", count: 60)

    // Screens captured from Claude Code 2.1.285 and Codex 0.158.0 and 0.159.1.

    func testClaudeAcceptsTextAtItsRuledInputBox() {
        let idle = [
            " ▐▛███▛█   Claude Code v2.1.285",
            rule,
            "❯ Try \"write a test for <filepath>\"",
            rule,
            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        ]
        XCTAssertTrue(CLIPrompt.claudeAcceptsText(screen: idle))

        let afterTurn = [
            "❯ Reply with only the word ok",
            "⏺ ok",
            "✻ Brewed for 1s · done 11:42 PM",
            rule,
            "❯",
            rule,
            "  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        ]
        XCTAssertTrue(CLIPrompt.claudeAcceptsText(screen: afterTurn))
    }

    func testClaudeRefusesDialogsThatUseThePromptGlyph() {
        let trust = [
            rule,
            " Accessing workspace:",
            " Claude Code'll be able to read, edit, and execute files here.",
            " ❯ No, exit",
            "   Yes, I trust this folder",
            " Enter to confirm · Esc to cancel"
        ]
        XCTAssertFalse(CLIPrompt.claudeAcceptsText(screen: trust))

        // An earlier prompt above a dialog is not an input box.
        let transcriptAboveDialog = ["❯ Reply with only the word ok", "⏺ ok"] + trust
        XCTAssertFalse(CLIPrompt.claudeAcceptsText(screen: transcriptAboveDialog))

        let numbered = [rule, "❯ fix it", rule, " Do you want to proceed?", " ❯ 1. Yes", "   2. No"]
        XCTAssertFalse(CLIPrompt.claudeAcceptsText(screen: numbered))
        XCTAssertFalse(CLIPrompt.claudeAcceptsText(screen: []))
    }

    func testCodexAcceptsTextOnlyAtItsComposer() {
        let composer = [
            "› Reply with only the word ok",
            "• ok",
            "  Worked for 2s • 23:45",
            "› Ask Codex to do anything",
            "  GPT-6.1-Sol default · /tmp/probe-project",
            "  ? for shortcuts"
        ]
        XCTAssertTrue(CLIPrompt.codexAcceptsText(screen: composer))

        let update = [
            "  Update available · 0.158.0 → 0.159.0",
            "› 1. Update now (runs `npm install -g @openai/codex`)",
            "  2. Skip",
            "  3. Skip until next version",
            "  enter continue · esc skip"
        ]
        XCTAssertFalse(CLIPrompt.codexAcceptsText(screen: update))

        let trust = [
            "  Trust this folder? Codex can read, edit, and run files here.",
            "› 1. Trust and continue",
            "  2. Quit",
            "  enter continue · esc quit"
        ]
        XCTAssertFalse(CLIPrompt.codexAcceptsText(screen: trust))

        let secondOptionSelected = ["› earlier prompt", "  1. Yes, proceed (y)", "› 2. No (esc)"]
        XCTAssertFalse(CLIPrompt.codexAcceptsText(screen: secondOptionSelected))
        XCTAssertFalse(CLIPrompt.codexAcceptsText(screen: ["  starting…"]))
    }

    func testReadsTheLiveScreenBelowScrollback() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let rows = view.terminalDimensions.rows
        let box = "\(rule)\r\n❯ \r\n\(rule)\r\n  ? for shortcuts"

        view.feed(text: box)
        XCTAssertEqual(CLIPrompt.liveScreen(of: view).count, rows)
        XCTAssertTrue(CLIPrompt.claudeAcceptsText(screen: CLIPrompt.liveScreen(of: view)))

        // The same box scrolled away under a dialog must not count.
        view.feed(text: "\r\n" + (0..<rows).map { "line \($0)" }.joined(separator: "\r\n"))
        view.feed(text: "\r\n\(rule)\r\n Accessing workspace:\r\n ❯ No, exit\r\n   Yes, I trust this folder")
        let screen = CLIPrompt.liveScreen(of: view)
        XCTAssertEqual(screen.count, rows)
        XCTAssertEqual(screen.last(where: { !$0.isEmpty }), "   Yes, I trust this folder")
        XCTAssertFalse(CLIPrompt.claudeAcceptsText(screen: screen))
    }

    func testSkippedBlankCellInsideImageMarkerIsNormalized() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        // Claude can leave the space cell untouched while drawing its marker.
        view.feed(text: "[Image\u{1b}[C#1]")
        let screen = CLIPrompt.liveScreen(of: view)
        XCTAssertEqual(CLIPrompt.imageMarkers(in: screen), 1)
        XCTAssertFalse(screen.joined().contains("\u{0}"))
    }

    func testPasteIsBracketedAndStripsControls() {
        let bracketed = CLIPrompt.pasteBytes("one\ntwo\u{1b}[31m\tthree", bracketed: true)
        XCTAssertEqual(String(decoding: bracketed, as: UTF8.self), "\u{1b}[200~one\ntwo [31m\tthree\u{1b}[201~")

        // Without bracketed paste a newline would submit the first line.
        let plain = CLIPrompt.pasteBytes("one\ntwo\r", bracketed: false)
        XCTAssertEqual(String(decoding: plain, as: UTF8.self), "one two ")

        XCTAssertEqual(String(decoding: CLIPrompt.pasteBytes("åäö ❯", bracketed: false), as: UTF8.self), "åäö ❯")
    }
}
