import SwiftTerm
import XCTest
@testable import PrivateCLIHost

final class CLIPromptTests: XCTestCase {
    func testQueuedCodexQuestionsRevealTheTerminalAndBlockPromptSubmission() {
        for shortcut in ["shift+↵", "shift+enter", "shift+tab"] {
            let screen = ["• Queued follow-up inputs", "  ? 1 question", "    \(shortcut) to answer",
                          "", "› Ask Codex", "Model · path"]
            XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: screen, agent: .codex))
            XCTAssertNil(CLIPrompt.inputStartRow(screen: screen, agent: .codex))
            XCTAssertFalse(CLIPrompt.codexAcceptsText(screen: screen))
            XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: screen, agent: .claude))
        }
        let earlier = ["• Queued follow-up inputs", "  ? 1 question", "    shift+↵ to answer",
                       "• That question has been answered.", "› Ask Codex", "Model · path"]
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: earlier, agent: .codex))
        XCTAssertTrue(CLIPrompt.codexAcceptsText(screen: earlier))
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: ["? 0 questions", "shift+↵ to answer"], agent: .codex))
        let form = ["Where is the order wrong?", "› Messages inside a chat", "",
                    "ctrl+s to submit · tab change field · ↑↓ to navigate fields · esc to cancel"]
        XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: form, agent: .codex))
        XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: form + Array(repeating: "", count: 20), agent: .codex))
        XCTAssertFalse(CLIPrompt.codexAcceptsText(screen: form), "The open form must stay visible until answered")
    }

    func testConcealedInputLeavesApprovalsAndUnrecognizedOutputVisible() {
        XCTAssertEqual(CLIPrompt.inputStartRow(screen: ["Result", "", "› Ask Codex", "Model · path"], agent: .codex), 1)
        XCTAssertNil(CLIPrompt.inputStartRow(screen: ["Approve?", "› 1. Allow", "  2. Deny"], agent: .codex))
        XCTAssertEqual(CLIPrompt.inputStartRow(screen: ["Result", "──────", "❯", "──────", "Status"], agent: .claude), 1)
        XCTAssertNil(CLIPrompt.inputStartRow(screen: ["Result", "❯ old quoted prompt", "Other output"], agent: .claude))
    }

    func testCodexProcessFooterMovesToActivityWithoutConcealingQuestions() {
        let footer = "  2 background terminals running · /ps to view · /stop to close"
        let screen = ["• Result", "", footer, "", "› Ask Codex", "Status"]
        XCTAssertEqual(CLIPrompt.backgroundTerminalCount(in: screen), 2)
        XCTAssertEqual(CLIPrompt.inputStartRow(screen: screen, agent: .codex), 2)
        XCTAssertNil(CLIPrompt.inputStartRow(screen: screen + ["› 1. Recommended", "  2. Alternative"], agent: .codex))
        XCTAssertEqual(CLIPrompt.backgroundTerminalCount(in: ["• I started 2 background terminals running"]), 0)
        // A footer quoted in output does not hide the conversation below it.
        XCTAssertEqual(CLIPrompt.inputStartRow(screen: [footer, "• More output", "", "› Ask Codex"], agent: .codex), 2)
    }

    private let rule = String(repeating: "─", count: 60)

    // Screens captured from Claude Code 2.1.285 and Codex 0.158.0, 0.159.1, and 0.160.0.

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

    func testCodex0160IdleScreenIsConcealedBehindTheComposer() {
        let idle = [
            "  >_ OpenAI Codex (v0.160.0)",
            "     ~/Library/CloudStorage/Dropbox/m4ix.cli",
            "  permissions: YOLO mode",
            "",
            "  Same terminal, new possibilities.",
            "",
            "",
            "› Ask Codex to do anything",
            "",
            "  GPT-6-Astra max · ~/Library/CloudStorage/Dropbox/m4ix.cli",
            "  ? for shortcuts                                       ⚠ 1 warning · f2 to view"
        ]
        XCTAssertTrue(CLIPrompt.codexAcceptsText(screen: idle))
        XCTAssertEqual(CLIPrompt.inputStartRow(screen: idle, agent: .codex), 5)
    }

    func testComposerRunsOnTheCheckedCLIVersionAndNewer() {
        XCTAssertTrue(ProviderCompatibility.evaluate("codex-cli 0.159.3\n", agent: .codex).usesComposer)
        XCTAssertTrue(ProviderCompatibility.evaluate("codex-cli 0.160.0\n", agent: .codex).usesComposer)
        XCTAssertFalse(ProviderCompatibility.evaluate("codex-cli 0.158.0\n", agent: .codex).usesComposer)
        XCTAssertTrue(ProviderCompatibility.evaluate("2.1.1000 (Claude Code)\n", agent: .claude).usesComposer)
        XCTAssertFalse(ProviderCompatibility.evaluate("2.1.99 (Claude Code)\n", agent: .claude).usesComposer)
        XCTAssertFalse(ProviderCompatibility.evaluate("codex-cli\n", agent: .codex).usesComposer)
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
        view.scroll(toPosition: 0)
        XCTAssertTrue(CLIPrompt.claudeAcceptsText(screen: view.terminalStateSnapshot().visibleRows.map(\.text)))
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

    func testTerminalResponseDetectionIncludesMenusAndConfirmations() {
        let examples: [(Agent, [String])] = [
            (.codex, ["Run this command?", "› 1. Yes", "  2. No"]),
            (.codex, ["Choose an option", "› 1) Allow", "  2) Deny"]),
            (.claude, ["Accessing workspace:", "❯ No, exit", "  Yes, I trust this folder"]),
            (.codex, ["› Yes", "  No", "Enter to confirm · Esc to cancel"]),
            (.claude, ["Continue? [y/N]"]),
            (.codex, ["Press Enter to continue"])
        ]
        for (agent, screen) in examples {
            XCTAssertNotNil(CLIPrompt.terminalResponseRequest(screen: screen, agent: agent), "\(screen)")
            XCTAssertNil(CLIPrompt.inputStartRow(screen: screen, agent: agent), "Questions must not be concealed")
        }
        for agent in Agent.allCases {
            XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: ["1. First step", "2. Second step", "Working…"], agent: agent))
            XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: [], agent: agent))
        }
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: ["❯ Earlier request", "⏺ Here is the response", "More output"], agent: .claude))
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: ["Press Enter to continue", "› Ask anything"], agent: .codex))
        XCTAssertNil(CLIPrompt.terminalResponseRequest(screen: ["Continue? [y/N]", rule, "❯", rule], agent: .claude))
    }
}
