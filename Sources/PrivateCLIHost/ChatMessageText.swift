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
    private static let codeKey = NSAttributedString.Key("m4ix.inlineCode")
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

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
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        result.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: result.length))
        return result
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
        textContainer?.lineFragmentPadding = 0
        isHorizontallyResizable = false
        isVerticallyResizable = true
        textContainer?.widthTracksTextView = true
        linkTextAttributes = [.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue]
        delegate = self
        setAccessibilityLabel("Chat message")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
        if let url, ChatMessageFormatting.canOpen(url) { openURL(url) }
        return true
    }

    func height(for width: CGFloat) -> CGFloat {
        guard let textContainer, let layoutManager else { return 24 }
        textContainer.containerSize = NSSize(width: max(1, width), height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        return max(24, ceil(layoutManager.usedRect(for: textContainer).height))
    }
}

struct ChatMessageText: NSViewRepresentable {
    let text: String
    var markdown = true
    var code = false

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
        return CGSize(width: width, height: nsView.height(for: width))
    }
}

struct ChatMessageBody: View {
    let text: String
    var markdown = true

    private struct Block: Identifiable {
        let id: Int
        let text: String
        let code: Bool
    }

    private var blocks: [Block] {
        guard markdown else { return [Block(id: 0, text: text, code: false)] }
        var result: [Block] = []
        var lines: [String] = []
        var fence: String?
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !body.isEmpty { result.append(Block(id: result.count, text: body, code: fence != nil)) }
            lines.removeAll(keepingCapacity: true)
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence == nil, trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                fence = String(trimmed.prefix(3))
            } else if let marker = fence, trimmed.hasPrefix(marker) {
                flush()
                fence = nil
            } else { lines.append(line) }
        }
        flush()
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                if block.code {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("CODE").font(ElevateTheme.utility(10)).foregroundStyle(ElevateTheme.graphite)
                            Spacer()
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(block.text, forType: .string)
                            }.buttonStyle(.borderless).font(.caption)
                        }
                        ChatMessageText(text: block.text, code: true)
                    }.padding(12).background(ElevateTheme.paperDeep)
                } else { ChatMessageText(text: block.text, markdown: markdown) }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
