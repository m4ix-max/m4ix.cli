import AppKit
import SwiftUI

enum ChatLinkOpener {
    static func open(_ url: URL,
                     openDefault: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
                     openSafari: (URL, @escaping (Bool) -> Void) -> Void = launchSafari) {
        guard ChatMessageFormatting.canOpen(url) else { return }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            openSafari(url) { succeeded in
                if !succeeded { openDefault(url) }
            }
        } else { openDefault(url) }
    }

    private static func launchSafari(_ url: URL, completion: @escaping (Bool) -> Void) {
        let workspace = NSWorkspace.shared
        let installedSafari = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: true)
        let safari = workspace.urlForApplication(withBundleIdentifier: "com.apple.Safari")
            ?? (FileManager.default.fileExists(atPath: installedSafari.path) ? installedSafari : nil)
        guard let safari else { completion(false); return }
        workspace.open([url], withApplicationAt: safari, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            completion(error == nil)
        }
    }
}

enum ChatMessageFormatting {
    static let quoteKey = NSAttributedString.Key("m4ix.quote")
    private static let codeKey = NSAttributedString.Key("m4ix.inlineCode")
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    private static let heading = try? NSRegularExpression(pattern: #"^ {0,3}(#{1,6})[ \t]+"#)
    private static let closingHashes = try? NSRegularExpression(pattern: #"[ \t]+#+[ \t]*$"#)
    private static let quote = try? NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#)
    private static let bullet = try? NSRegularExpression(pattern: #"^([ \t]*)[-*+•][ \t]+(\[([ xX])\][ \t]+)?"#)
    private static let ordered = try? NSRegularExpression(pattern: #"^([ \t]*)(\d{1,3}[.)])[ \t]+"#)

    static func canOpen(_ url: URL) -> Bool {
        ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func destination(_ url: URL) -> URL? {
        if canOpen(url) { return url }
        if url.scheme == nil, url.path.hasPrefix("/") {
            // Source links can carry a line number after the absolute path.
            let path = url.path.replacingOccurrences(of: #":\d+$"#, with: "", options: .regularExpression)
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static func attributedText(_ text: String, markdown: Bool = true, code: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        if markdown, !code, let parsed = try? AttributedString(markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            for run in parsed.runs {
                let intent = run.inlinePresentationIntent ?? []
                let isCode = intent.contains(.code)
                var font = isCode ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 14)
                if intent.contains(.stronglyEmphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                if intent.contains(.emphasized) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ElevateTheme.nsInk]
                if isCode { attributes[codeKey] = true }
                if let link = run.link, let url = destination(link) { attributes[.link] = url }
                result.append(NSAttributedString(string: String(parsed.characters[run.range]), attributes: attributes))
            }
        } else {
            result.append(NSAttributedString(string: text, attributes: [
                .font: code ? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular) : NSFont.systemFont(ofSize: 14),
                .foregroundColor: ElevateTheme.nsInk
            ]))
        }
        if !code {
            let range = NSRange(location: 0, length: result.length)
            for match in detector?.matches(in: result.string, range: range) ?? [] {
                guard let url = match.url, canOpen(url) else { continue }
                var hasExistingLinkOrCode = false
                result.enumerateAttributes(in: match.range) { attributes, _, _ in
                    if attributes[.link] != nil || attributes[codeKey] != nil { hasExistingLinkOrCode = true }
                }
                if !hasExistingLinkOrCode { result.addAttribute(.link, value: url, range: match.range) }
            }
        }
        if markdown, !code { return styledLines(result) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
    }

    /// Lists, quotes and headings stay in one text view, so a selection can
    /// still span the whole reply. Their markers become hanging indents.
    private static func styledLines(_ source: NSAttributedString) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let string = source.string as NSString
        // Each open list level, as its source indentation and the column its text starts at.
        var levels: [(indent: Int, column: CGFloat)] = []
        var followsItem = false
        var location = 0
        while true {
            let newline = string.range(of: "\n", range: NSRange(location: location, length: string.length - location))
            let end = newline.location == NSNotFound ? string.length : newline.location
            let range = NSRange(location: location, length: end - location)
            let line = string.substring(with: range)
            let whole = NSRange(location: 0, length: (line as NSString).length)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            var marker: NSAttributedString?
            var prefix = 0
            var isQuote = false
            var headingLevel = 0
            var continuesItem = false

            if let match = heading?.firstMatch(in: line, range: whole) {
                prefix = match.range.length
                headingLevel = match.range(at: 1).length
                levels.removeAll()
                if output.length > 0 { paragraph.paragraphSpacingBefore = 8 }
                paragraph.paragraphSpacing = 2
            } else if let match = quote?.firstMatch(in: line, range: whole) {
                prefix = match.range.length
                isQuote = true
                levels.removeAll()
                paragraph.firstLineHeadIndent = 14
                paragraph.headIndent = 14
            } else if case let (match, isOrdered)? = listMarker(in: line, range: whole) {
                prefix = match.range.length
                let indent = width(of: (line as NSString).substring(with: match.range(at: 1)))
                while let last = levels.last, last.indent >= indent { levels.removeLast() }
                let start = levels.last?.column ?? 0
                let column = start + (isOrdered ? 24 : 16)
                levels.append((indent, column))
                let glyph: String
                if isOrdered { glyph = (line as NSString).substring(with: match.range(at: 2)) }
                else if match.range(at: 3).location != NSNotFound {
                    glyph = (line as NSString).substring(with: match.range(at: 3)) == " " ? "☐" : "☑"
                } else { glyph = ["•", "◦", "▪"][min(levels.count - 1, 2)] }
                marker = NSAttributedString(string: glyph + "\t", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: ElevateTheme.nsGraphite
                ])
                paragraph.firstLineHeadIndent = start
                paragraph.headIndent = column
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: column)]
                paragraph.paragraphSpacing = 4
                continuesItem = true
            } else if !levels.isEmpty, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                // An indented line continues the item right above it, or after
                // a blank line, the item it is indented under.
                let leading = line.prefix { $0 == " " || $0 == "\t" }
                let indent = width(of: String(leading))
                if indent >= 2 {
                    prefix = leading.utf16.count
                    let deepest = levels[levels.count - 1].column
                    let column = followsItem ? deepest : (levels.last { $0.indent < indent }?.column ?? deepest)
                    paragraph.firstLineHeadIndent = column
                    paragraph.headIndent = column
                    continuesItem = true
                } else { levels.removeAll() }
            }
            followsItem = continuesItem

            let content = NSMutableAttributedString(attributedString: source.attributedSubstring(
                from: NSRange(location: range.location + prefix, length: range.length - prefix)))
            if headingLevel > 0 {
                if let hashes = closingHashes?.firstMatch(in: content.string, range: NSRange(location: 0, length: content.length)) {
                    content.deleteCharacters(in: hashes.range)
                }
                let size: CGFloat = headingLevel == 1 ? 18 : (headingLevel == 2 ? 16 : 14)
                content.enumerateAttribute(.font, in: NSRange(location: 0, length: content.length)) { value, run, _ in
                    let font = NSFontManager.shared.convert((value as? NSFont) ?? .systemFont(ofSize: 14), toSize: size)
                    content.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: run)
                }
            }
            if isQuote {
                content.addAttribute(.foregroundColor, value: ElevateTheme.nsGraphite, range: NSRange(location: 0, length: content.length))
            }
            let start = output.length
            if let marker { output.append(marker) }
            output.append(content)
            if newline.location != NSNotFound {
                output.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            }
            let paragraphRange = NSRange(location: start, length: output.length - start)
            output.addAttribute(.paragraphStyle, value: paragraph, range: paragraphRange)
            if isQuote { output.addAttribute(quoteKey, value: true, range: paragraphRange) }
            guard newline.location != NSNotFound else { break }
            location = newline.location + 1
        }
        return output
    }

    private static func listMarker(in line: String, range: NSRange) -> (NSTextCheckingResult, Bool)? {
        if let match = bullet?.firstMatch(in: line, range: range) { return (match, false) }
        if let match = ordered?.firstMatch(in: line, range: range) { return (match, true) }
        return nil
    }

    private static func width(of indentation: String) -> Int {
        indentation.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }
}

/// AppKit supplies text selection, the pointing-hand cursor, and ordinary
/// mouse clicks on links, including when a URL wraps onto another line.
final class ChatLinkTextView: NSTextView, NSTextViewDelegate {
    var openURL: (URL) -> Void = { ChatLinkOpener.open($0) }
    private var backingStorage: NSTextStorage?

    override init(frame: NSRect, textContainer: NSTextContainer? = nil) {
        let container: NSTextContainer
        let storage: NSTextStorage?
        if let textContainer {
            container = textContainer
            storage = textContainer.layoutManager?.textStorage
        }
        else {
            let newStorage = NSTextStorage()
            let manager = NSLayoutManager()
            newStorage.addLayoutManager(manager)
            container = NSTextContainer(size: NSSize(width: max(1, frame.width), height: .greatestFiniteMagnitude))
            manager.addTextContainer(container)
            storage = newStorage
        }
        super.init(frame: frame, textContainer: container)
        backingStorage = storage
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = false
        textContainerInset = .zero
        // `textContainer` in this initializer is the argument, usually nil,
        // so the container the view uses is configured by name.
        container.lineFragmentPadding = 0
        isHorizontallyResizable = false
        isVerticallyResizable = true
        container.widthTracksTextView = true
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        delegate = self
        setAccessibilityLabel("Chat message")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// A quote carries a rule at its left edge, down every line it wraps to.
    override func draw(_ dirtyRect: NSRect) {
        if let layoutManager, let storage = textStorage, storage.length > 0 {
            ElevateTheme.nsBorder.setFill()
            storage.enumerateAttribute(ChatMessageFormatting.quoteKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
                guard value != nil else { return }
                var lines = NSRect.null
                let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in lines = lines.union(fragment) }
                guard !lines.isNull else { return }
                NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y + lines.minY, width: 2, height: max(0, lines.height - 4)).fill()
            }
        }
        super.draw(dirtyRect)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, ChatMessageFormatting.canOpen(url) { openURL(url) }
        return true
    }

    func height(for width: CGFloat) -> CGFloat { max(24, size(for: width).height) }

    /// The width is the longest line's, so a short message can hug its text.
    /// Once the container has been resized its used rect spans the whole
    /// width, so the lines are measured one by one.
    func size(for width: CGFloat) -> CGSize {
        guard let textContainer, let layoutManager else { return CGSize(width: width, height: 24) }
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        var longest: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: textContainer)) { _, used, _, _, _ in
            longest = max(longest, used.maxX)
        }
        return CGSize(width: ceil(longest), height: ceil(layoutManager.usedRect(for: textContainer).height))
    }
}

struct ChatMessageText: NSViewRepresentable {
    let text: String
    var markdown = true
    var code = false
    var hugsContent = false

    func makeNSView(context: Context) -> ChatLinkTextView {
        let view = ChatLinkTextView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ChatLinkTextView, context: Context) {
        let attributed = ChatMessageFormatting.attributedText(text, markdown: markdown, code: code)
        if view.textStorage?.isEqual(to: attributed) != true { view.textStorage?.setAttributedString(attributed) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatLinkTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 600
        guard hugsContent else { return CGSize(width: width, height: nsView.height(for: width)) }
        let size = nsView.size(for: width)
        return CGSize(width: min(width, size.width), height: size.height)
    }
}

/// One message in a conversation. Yours sit in a block at the right, like the
/// composer they were written in. Replies run full width under the speaker's
/// mark, which is shown once for consecutive messages from the same speaker.
struct ChatTurn: View {
    let speaker: String
    let text: String
    var status: String?
    var continues = false
    var steps: [ConversationStep] = []

    var body: some View {
        if speaker == "you" {
            ChatMessageText(text: text, markdown: false, hugsContent: true)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(ElevateTheme.paperDeep, in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.leading, 64)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("You")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !continues || status != nil {
                    HStack(spacing: 8) {
                        if let agent = Agent(rawValue: speaker) { PixelMark(sprite: agent.mark, color: ElevateTheme.ink) }
                        Text(speaker.uppercased()).font(ElevateTheme.utility(12, medium: true))
                        if let status { Text(status).font(.caption).foregroundStyle(ElevateTheme.graphite) }
                    }
                }
                if !steps.isEmpty { ChatActivity(steps: steps) }
                else if text.isEmpty { ProgressView().controlSize(.small) }
                else { ChatMessageBody(text: text) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The tool steps between two replies: one quiet line that opens to the list.
struct ChatActivity: View {
    let steps: [ConversationStep]
    @State var expanded = false

    var body: some View {
        let summary = ConversationStep.summary(steps)
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    // As wide as the working spinner, so both lines share a text edge.
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 16)
                    Text(summary).lineLimit(1).truncationMode(.tail)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the steps" : "Show each step")
            .accessibilityLabel(summary)
            .accessibilityHint(expanded ? "Hides the steps" : "Shows each step")
            if expanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps, id: \.id) { step in
                        Text(step.title).lineLimit(1).truncationMode(.tail)
                    }
                }
                .padding(.leading, 24)
                .textSelection(.enabled)
            }
        }
        .font(.caption).foregroundStyle(ElevateTheme.graphite)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ChatBlock: Equatable {
    case text(String)
    case code(String)
    case table(ChatTable)
    case rule
}

struct ChatTable: Equatable {
    enum Alignment: Equatable { case leading, center, trailing }

    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

struct ChatMessageBody: View {
    let text: String
    var markdown = true

    /// Fenced code, tables and dividers become blocks of their own. The rest
    /// stays one text block, so a selection can cross its paragraphs.
    static func blocks(_ text: String) -> [ChatBlock] {
        var result: [ChatBlock] = []
        var lines: [String] = []
        var fence: String?
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !body.isEmpty { result.append(fence == nil ? .text(body) : .code(body)) }
            lines.removeAll(keepingCapacity: true)
        }
        let source = text.components(separatedBy: "\n")
        var index = 0
        while index < source.count {
            let line = source[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            index += 1
            if fence == nil, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix(3))
            } else if let marker = fence {
                if trimmed.hasPrefix(marker) { flush(); fence = nil } else { lines.append(line) }
            } else if trimmed.range(of: #"^([-*_])( *\1){2,}$"#, options: .regularExpression) != nil {
                flush()
                result.append(.rule)
            } else if index < source.count, let head = tableHead(line, delimiter: source[index]) {
                flush()
                var rows: [[String]] = []
                index += 1
                while index < source.count, source[index].contains("|"),
                      !source[index].trimmingCharacters(in: .whitespaces).isEmpty {
                    // A row is padded or cut to the header's width.
                    let row = cells(source[index]) + Array(repeating: "", count: head.names.count)
                    rows.append(Array(row.prefix(head.names.count)))
                    index += 1
                }
                result.append(.table(ChatTable(header: head.names, alignments: head.alignments, rows: rows)))
            } else { lines.append(line) }
        }
        flush()
        return result
    }

    private static func tableHead(_ line: String, delimiter: String) -> (names: [String], alignments: [ChatTable.Alignment])? {
        guard line.contains("|"), delimiter.contains("|") else { return nil }
        let names = cells(line), marks = cells(delimiter)
        guard names.count == marks.count,
              marks.allSatisfy({ $0.range(of: "^:?-+:?$", options: .regularExpression) != nil }) else { return nil }
        return (names, marks.map { mark in
            mark.hasPrefix(":") && mark.hasSuffix(":") ? .center : (mark.hasSuffix(":") ? .trailing : .leading)
        })
    }

    private static func cells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        for character in body {
            if character == "|", current.last == "\\" { current.removeLast(); current.append("|") }
            else if character == "|" { cells.append(current); current = "" }
            else { current.append(character) }
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array((markdown ? Self.blocks(text) : [ChatBlock.text(text)]).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let content): ChatMessageText(text: content, markdown: markdown)
                case .code(let content): codeBlock(content)
                case .table(let table): ChatTableView(table: table)
                case .rule: Rectangle().fill(ElevateTheme.border).frame(height: 1)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codeBlock(_ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CODE").font(ElevateTheme.utility(10)).foregroundStyle(ElevateTheme.graphite)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                }.buttonStyle(.borderless).font(.caption)
            }
            ChatMessageText(text: content, code: true)
        }.padding(12).background(ElevateTheme.paperDeep)
    }
}

/// A table from a reply. Its first column starts at the text column, and
/// cells wrap when the pane is too narrow for the table.
struct ChatTableView: View {
    let table: ChatTable

    var body: some View {
        ChatTableLayout(columns: table.header.count) {
            ForEach(Array(table.header.enumerated()), id: \.offset) { column, name in
                cell(name, column: column, header: true)
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                ForEach(Array(row.enumerated()), id: \.offset) { column, value in
                    cell(value, column: column, header: false)
                }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            ChatLinkOpener.open(url)
            return .handled
        })
    }

    private func cell(_ text: String, column: Int, header: Bool) -> some View {
        let alignment = table.alignments[column]
        let content = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        return Text(content)
            .font(.system(size: 13, weight: header ? .semibold : .regular))
            .multilineTextAlignment(alignment == .trailing ? .trailing : (alignment == .center ? .center : .leading))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, column == 0 ? 0 : 8).padding(.trailing, column == table.header.count - 1 ? 0 : 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: alignment == .trailing ? .topTrailing : (alignment == .center ? .top : .topLeading))
            .overlay(alignment: .bottom) {
                Rectangle().fill(header ? ElevateTheme.border : ElevateTheme.borderSubtle).frame(height: 1)
            }
    }
}

/// Lays cells out row by row. Every cell in a row takes the row's height, so
/// the rules under them line up.
struct ChatTableLayout: Layout {
    let columns: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = measure(proposal.width, subviews)
        return CGSize(width: size.widths.reduce(0, +), height: size.heights.reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = measure(bounds.width, subviews)
        var y = bounds.minY
        for (row, height) in size.heights.enumerated() {
            var x = bounds.minX
            for (column, width) in size.widths.enumerated() where row * columns + column < subviews.count {
                subviews[row * columns + column].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: width, height: height))
                x += width
            }
            y += height
        }
    }

    private func measure(_ available: CGFloat?, _ subviews: Subviews) -> (widths: [CGFloat], heights: [CGFloat]) {
        guard columns > 0 else { return ([], []) }
        var ideal = Array(repeating: CGFloat.zero, count: columns)
        for (index, subview) in subviews.enumerated() {
            ideal[index % columns] = max(ideal[index % columns], ceil(subview.sizeThatFits(.unspecified).width))
        }
        let widths = Self.columnWidths(ideal: ideal, available: available ?? ideal.reduce(0, +))
        var heights = Array(repeating: CGFloat.zero, count: (subviews.count + columns - 1) / columns)
        for (index, subview) in subviews.enumerated() {
            let height = subview.sizeThatFits(ProposedViewSize(width: widths[index % columns], height: nil)).height
            heights[index / columns] = max(heights[index / columns], ceil(height))
        }
        return (widths, heights)
    }

    /// Columns keep their natural width when the table fits. Otherwise the
    /// narrow ones stay whole and the wide ones share what is left equally.
    static func columnWidths(ideal: [CGFloat], available: CGFloat) -> [CGFloat] {
        guard ideal.reduce(0, +) > available else { return ideal }
        var remaining = max(0, available)
        var cap = remaining
        for (index, width) in ideal.sorted().enumerated() {
            let share = remaining / CGFloat(ideal.count - index)
            if width > share { cap = share; break }
            remaining -= width
        }
        return ideal.map { min($0, cap) }
    }
}
