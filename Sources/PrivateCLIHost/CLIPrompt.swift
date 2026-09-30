import Foundation
import SwiftTerm

/// Types the prompt bar's text into a running CLI, and reads its screen to
/// tell whether Return would submit that text or choose a menu option.
///
/// Images go in as their file paths, one paste each, which both CLIs turn
/// into attachments.
///
/// Both CLIs draw menus with the same pointer glyph as their input line:
/// approvals, folder trust, and Codex's update offer, where Return runs
/// `npm install`. So the bar sends only when the input line itself is on
/// screen, and any screen it does not recognise blocks sending.
enum CLIPrompt {
    /// Waits between the paste and Return, so each CLI has taken in the
    /// paste as text before Return submits it.
    static let returnDelay: TimeInterval = 0.15

    /// How long a CLI gets to turn a pasted image path into `[Image #n]`.
    static let imageTimeout: TimeInterval = 5

    /// Both CLIs show an attached image in their input as `[Image #n]`.
    static func imageMarkers(in screen: [String]) -> Int {
        screen.reduce(0) { $0 + $1.components(separatedBy: "[Image #").count - 1 }
    }

    /// The text as one paste. Control characters become spaces. Without
    /// bracketed paste each newline would submit, so lines are joined.
    static func pasteBytes(_ text: String, bracketed: Bool) -> [UInt8] {
        var body: [UInt8] = []
        for byte in text.utf8 {
            switch byte {
            case 0x0a: body.append(bracketed ? 0x0a : 0x20)
            case 0x09: body.append(0x09)
            case 0x00...0x1f, 0x7f: body.append(0x20)
            default: body.append(byte)
            }
        }
        guard bracketed else { return body }
        return Array("\u{1b}[200~".utf8) + body + Array("\u{1b}[201~".utf8)
    }

    /// The rows the CLI is drawing now, whatever has been scrolled back to:
    /// a menu can be open below the scrolled view.
    static func liveScreen(of terminal: TerminalView) -> [String] {
        let rows = terminal.terminalDimensions.rows
        guard rows > 0 else { return [] }
        let data = terminal.getBufferAsData(kind: .active)
        guard !data.isEmpty else { return [] }
        var end = data.endIndex
        if data[data.index(before: end)] == 0x0a { end = data.index(before: end) }
        var start = end
        var newlines = 0
        while start > data.startIndex {
            let previous = data.index(before: start)
            if data[previous] == 0x0a {
                newlines += 1
                if newlines == rows { break }
            }
            start = previous
        }
        return String(decoding: data[start..<end], as: UTF8.self)
            .replacingOccurrences(of: "\u{0}", with: " ")
            .replacingOccurrences(of: "\u{00a0}", with: " ")
            .components(separatedBy: "\n")
    }

    /// Claude draws its input as a `❯` line between two horizontal rules.
    /// Its dialogs replace that box, and their options start with `❯` too,
    /// so only the ruled box counts.
    static func claudeAcceptsText(screen: [String]) -> Bool {
        guard !screen.contains(where: isNumberedOption) else { return false }
        for index in screen.indices where index > 0 && trimmed(screen[index]).hasPrefix("❯") {
            guard isRule(screen[index - 1]) else { continue }
            if screen[(index + 1)...].contains(where: isRule) { return true }
        }
        return false
    }

    /// Codex's composer is the last `›` line on screen. Its menus number
    /// their options, `› 1. Trust and continue`, so a numbered last line is
    /// a menu.
    static func codexAcceptsText(screen: [String]) -> Bool {
        guard let last = screen.last(where: { trimmed($0).hasPrefix("›") }) else { return false }
        return !isNumberedOption(last)
    }

    private static func trimmed(_ line: String) -> Substring {
        line.drop(while: { $0 == " " })
    }

    private static func isRule(_ line: String) -> Bool {
        trimmed(line).hasPrefix("────")
    }

    private static func isNumberedOption(_ line: String) -> Bool {
        line.range(of: #"^\s*[❯›]\s*\d+\.\s"#, options: .regularExpression) != nil
    }
}
