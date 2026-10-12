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
        if !terminal.canScroll || terminal.scrollPosition == 1 {
            return terminal.terminalStateSnapshot().visibleRows.map {
                $0.text.replacingOccurrences(of: "\u{0}", with: " ")
                    .replacingOccurrences(of: "\u{00a0}", with: " ")
            }
        }
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

    /// Whether Return would submit text typed into the CLI's own input.
    static func acceptsText(screen: [String], agent: Agent) -> Bool {
        switch agent {
        case .claude, .hermes:
            return rawRuledInputAcceptsText(screen: screen, agent: agent)
                && terminalResponseRequest(screen: screen, agent: agent) == nil
        case .codex:
            return codexAcceptsText(screen: screen)
        }
    }

    /// Claude draws its input as a `❯` line between two horizontal rules.
    /// Its dialogs replace that box, and their options start with `❯` too,
    /// so only the ruled box counts.
    static func claudeAcceptsText(screen: [String]) -> Bool {
        acceptsText(screen: screen, agent: .claude)
    }

    /// Hermes draws the same ruled input, bare only while it waits for a
    /// message. Every other state marks it: `⚕ ❯` while it works, `⚠ ❯`
    /// for an approval, `? ❯` for a question, 🔐 or 🔑 for a password.
    /// Approval choices are numbered inside a panel, `│ ❯ 1. Allow once │`,
    /// where Return would choose for you.
    private static func rawRuledInputAcceptsText(screen: [String], agent: Agent) -> Bool {
        let options = agent == .hermes ? screen.map(unboxed) : screen
        guard !options.contains(where: isNumberedOption) else { return false }
        if agent == .hermes, hermesPanelChoice(in: screen) != nil { return false }
        for index in screen.indices where index > 0 && isInputLine(screen[index], agent: agent) {
            guard isRule(screen[index - 1]) else { continue }
            if screen[(index + 1)...].contains(where: isRule) { return true }
        }
        return false
    }

    /// The chosen row of a Hermes panel, however its choices are numbered:
    /// `│ ❯ 1. Allow once │`, `│ ❯ [1] Yes — do it │`.
    private static func hermesPanelChoice(in screen: [String]) -> Int? {
        screen.indices.last { trimmed(screen[$0]).hasPrefix("│") && unboxed(screen[$0]).hasPrefix("❯") }
    }

    /// A non-default Hermes profile names itself before the prompt, `work ❯`.
    private static func isInputLine(_ line: String, agent: Agent) -> Bool {
        let text = trimmed(line)
        if text.hasPrefix("❯") { return true }
        return agent == .hermes && text.range(of: #"^[a-z0-9][a-z0-9_-]{0,63} ❯"#, options: .regularExpression) != nil
    }

    /// Hermes takes no message while it works. Its input reads `⚕ ❯` until
    /// the turn ends.
    static func hermesIsWorking(screen: [String]) -> Bool {
        screen.indices.contains { index in
            index > 0 && isRule(screen[index - 1]) && trimmed(screen[index]).hasPrefix("⚕")
        }
    }

    /// The session ID in the banner Hermes opens with, `Session: 20261011_235540_a37dd0`.
    static func hermesSessionID(in text: String) -> String? {
        guard let match = text.range(of: #"Session:\s+[0-9]{8}_[0-9]{6}_[0-9a-f]{4,32}\b"#,
                                     options: .regularExpression) else { return nil }
        return text[match].split(whereSeparator: \.isWhitespace).last.map(String.init)
    }

    /// Codex's composer is the last `›` line on screen. Its menus number
    /// their options, `› 1. Trust and continue`, so a numbered last line is
    /// a menu.
    static func codexAcceptsText(screen: [String]) -> Bool {
        rawCodexAcceptsText(screen: screen) && terminalResponseRequest(screen: screen, agent: .codex) == nil
    }

    private static func rawCodexAcceptsText(screen: [String]) -> Bool {
        guard let last = screen.last(where: { trimmed($0).hasPrefix("›") }) else { return false }
        return !isNumberedOption(last)
    }

    /// Only conceal an input we recognize in the actual visible viewport.
    /// Menus, approvals, and scrolled conversation output remain visible.
    static func inputStartRow(screen: [String], agent: Agent) -> Int? {
        guard terminalResponseRequest(screen: screen, agent: agent) == nil else { return nil }
        return rawInputStartRow(screen: screen, agent: agent)
    }

    private static func rawInputStartRow(screen: [String], agent: Agent) -> Int? {
        switch agent {
        case .claude, .hermes:
            guard rawRuledInputAcceptsText(screen: screen, agent: agent),
                  let row = screen.indices.last(where: { isInputLine(screen[$0], agent: agent) }), row > 0,
                  isRule(screen[row - 1]) else { return nil }
            return row - 1
        case .codex:
            guard rawCodexAcceptsText(screen: screen),
                  let row = screen.indices.last(where: { trimmed(screen[$0]).hasPrefix("›") }) else { return nil }
            var start = row
            while start > 0 && screen[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
            if start > 0 && backgroundTerminalCount(in: [screen[start - 1]]) > 0 { start -= 1 }
            return start
        }
    }

    /// Identifies a live keyboard interaction, including unnumbered choices
    /// and confirmation prompts. The signature lets focus move once per
    /// question without pulling readers back down on every scroll event.
    static func terminalResponseRequest(screen: [String], agent: Agent) -> String? {
        if agent == .codex, let footer = codexQuestionFooter(in: screen) {
            return footer.signature
        }
        let rows = screen.map { agent == .hermes ? unboxed($0) : $0.trimmingCharacters(in: .whitespaces) }
        let nonempty = rows.indices.filter { !rows[$0].isEmpty }
        guard let last = nonempty.last else { return nil }
        let inputRow = rawInputStartRow(screen: screen, agent: agent)
        let afterInput = inputRow ?? -1
        var requestRow: Int?

        if agent == .codex {
            let footer = nonempty.suffix(5).map { rows[$0] }.joined(separator: " ").lowercased()
            if footer.contains("to submit"), footer.contains("to cancel"),
               footer.contains("change field") || footer.contains("navigate fields") {
                requestRow = nonempty.suffix(5).first(where: { $0 > afterInput })
            }
        }

        if let selected = nonempty.last(where: {
            rows[$0].range(of: #"^[❯›▶>]\s*\d+[.)]\s+"#, options: .regularExpression) != nil
        }), selected > afterInput {
            requestRow = selected
        }
        // Claude's trust and choice menus can have no numbers at all.
        if agent == .claude, inputRow == nil,
           let selected = nonempty.last(where: { rows[$0].hasPrefix("❯") }),
           let next = nonempty.first(where: { $0 > selected }),
           rows[selected].range(of: #"^❯\s*(?:yes|no|allow|deny|cancel|exit|trust|continue)\b"#,
                                options: [.regularExpression, .caseInsensitive]) != nil,
           rows[next].range(of: #"^(?:yes|no|allow|deny|cancel|exit|trust|continue)\b"#,
                            options: [.regularExpression, .caseInsensitive]) != nil {
            requestRow = selected
        }
        // Hermes marks the chosen row of each of its menus with `❯`, inside a
        // panel or, once its input is marked, on a line of its own. Only the
        // input line sits directly under a rule.
        if agent == .hermes {
            let loose = inputRow == nil
                ? nonempty.last(where: { rows[$0].hasPrefix("❯") && !($0 > 0 && isRule(screen[$0 - 1])) }) : nil
            if let selected = hermesPanelChoice(in: screen) ?? loose { requestRow = requestRow ?? selected }
        }
        for index in nonempty.suffix(4) where index > afterInput {
            let line = rows[index]
            guard line.count < 180 else { continue }
            let confirmation = line.range(of: #"(?:\[(?:y/n|yes/no)\]|\((?:y/n|yes/no)\))\s*[:?]?\s*$"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
            let pressEnter = line.range(of: #"^(?:press|hit)\s+(?:enter|return)\b"#,
                                        options: [.regularExpression, .caseInsensitive]) != nil
            let menuFooter = line.range(of: #"\b(?:enter|return)\s+(?:to\s+)?(?:confirm|continue|select|submit|accept|proceed)\b"#,
                                        options: [.regularExpression, .caseInsensitive]) != nil
                && line.range(of: #"\b(?:esc|escape|cancel|quit|skip)\b"#,
                              options: [.regularExpression, .caseInsensitive]) != nil
            if confirmation || pressEnter || menuFooter { requestRow = requestRow ?? index }
        }
        guard let requestRow else { return nil }
        return rows[max(0, requestRow - 2)...last].joined(separator: "\n")
    }

    /// Codex queues asynchronous questions above its normal input. Unlike
    /// an approval menu, that input remains visible until the form is opened.
    static func codexQuestionOpenBytes(in screen: [String]) -> [UInt8]? {
        codexQuestionFooter(in: screen)?.openBytes
    }

    private static func codexQuestionFooter(in screen: [String]) -> (signature: String, openBytes: [UInt8])? {
        let rows = screen.map { $0.trimmingCharacters(in: .whitespaces) }
        let nonempty = rows.indices.filter { !rows[$0].isEmpty }
        guard let question = nonempty.suffix(12).last(where: {
            rows[$0].range(of: #"^\?\s+[1-9]\d*\s+questions?$"#, options: .regularExpression) != nil
        }), let hint = nonempty.first(where: { $0 > question }),
           rows[hint].range(of: #"^shift\s*\+\s*(?:↵|enter|return|tab|⇥|⇤)\s+to answer$"#,
                            options: [.regularExpression, .caseInsensitive]) != nil else { return nil }
        // A footer quoted earlier in the conversation must not reopen a form.
        if let next = nonempty.first(where: { $0 > hint }), !rows[next].hasPrefix("›") { return nil }
        let signature = rows[question] + "\n" + rows[hint]
        if rows[hint].range(of: #"(?:tab|⇥|⇤)"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return (signature, Array("\u{1b}[Z".utf8))
        }
        // CSI-u preserves Shift-Return; a plain Return would submit the input.
        return (signature, Array("\u{1b}[13;2u".utf8))
    }

    /// Codex's live process footer, not arbitrary mentions in the conversation.
    private static let processFooter = try! NSRegularExpression(
        pattern: #"^\s*(\d+) background terminals? running\s*[·•]\s*/ps to view\s*[·•]\s*/stop to close\s*$"#)

    static func backgroundTerminalCount(in screen: [String]) -> Int {
        for line in screen.reversed() {
            guard let match = processFooter.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line) else { continue }
            return Int(line[range]) ?? 0
        }
        return 0
    }

    private static func trimmed(_ line: String) -> Substring {
        line.drop(while: { $0 == " " })
    }

    /// A row with a panel's side borders removed.
    private static func unboxed(_ line: String) -> String {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("│") { text.removeFirst() }
        if text.hasSuffix("│") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func isRule(_ line: String) -> Bool {
        trimmed(line).hasPrefix("────")
    }

    private static func isNumberedOption(_ line: String) -> Bool {
        line.range(of: #"^\s*[❯›]\s*\d+[.)]\s"#, options: .regularExpression) != nil
    }
}
