import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The prompt bar under the terminal. It types into the CLI on screen, or
/// starts a conversation when none is running. Images come in by drop, by
/// paste, or from the image button. The host owns launch and PTY behavior
/// through `onSubmit`.
struct PromptComposer: View {
    enum Mode {
        /// Types into the running CLI's own prompt.
        case send
        /// A menu or dialog holds the CLI's screen, where Return would
        /// choose an option. Text can be drafted but not sent.
        case blocked
        /// No CLI is running here, so the text starts a new conversation.
        case start
    }

    let mode: Mode
    /// Moves the cursor into the bar each time it changes, as when an image
    /// is pasted while the terminal has focus.
    let focusRequest: Int
    let agentName: String
    let projectName: String
    let isBusy: Bool
    let isEnabled: Bool
    let onSubmit: (String, [PromptImage]) -> Bool

    @Binding private var taskText: String
    @Binding private var images: [PromptImage]

    init(
        text: Binding<String>,
        images: Binding<[PromptImage]>,
        focusRequest: Int = 0,
        mode: Mode,
        agentName: String,
        projectName: String,
        isBusy: Bool = false,
        isEnabled: Bool = true,
        onSubmit: @escaping (String, [PromptImage]) -> Bool
    ) {
        self._taskText = text
        self._images = images
        self.focusRequest = focusRequest
        self.mode = mode
        self.agentName = agentName
        self.projectName = projectName
        self.isBusy = isBusy
        self.isEnabled = isEnabled
        self.onSubmit = onSubmit
    }

    private var trimmedTask: String {
        taskText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        isEnabled && !isBusy && mode != .blocked && !(trimmedTask.isEmpty && images.isEmpty)
    }

    private var heading: String { mode == .start ? "NEW CONVERSATION" : "PROMPT" }

    private var keyHint: String {
        mode == .blocked ? "ANSWER THE TERMINAL FIRST" : "RETURN TO SEND  /  ⇧ RETURN NEW LINE"
    }

    private var placeholder: String {
        mode == .start ? "Start a conversation with \(agentName)…" : "Write to \(agentName)…"
    }

    private var buttonTitle: String {
        if isBusy { return "STARTING…" }
        return mode == .start ? "START" : "SEND"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ElevateTheme.spacing8) {
            HStack(alignment: .firstTextBaseline, spacing: ElevateTheme.spacing16) {
                Text(heading)
                    .font(ElevateTheme.utility(11, medium: true))
                    .tracking(0.3)
                    .foregroundStyle(ElevateTheme.ink)

                Spacer(minLength: ElevateTheme.spacing16)

                Text("\(agentName.uppercased())  /  \(projectName.uppercased())")
                    .font(ElevateTheme.utility(10))
                    .tracking(0.2)
                    .foregroundStyle(ElevateTheme.graphite)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Send to \(agentName) in \(projectName)")

                Text(keyHint)
                    .font(ElevateTheme.utility(10, medium: mode == .blocked))
                    .tracking(0.2)
                    .foregroundStyle(mode == .blocked ? ElevateTheme.ink : ElevateTheme.graphite)
                    .fixedSize()
            }

            if !images.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: ElevateTheme.spacing8) {
                        ForEach(images) { image in
                            PromptImageChip(image: image) { images.removeAll { $0 == image } }
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: ElevateTheme.spacing16) {
                ZStack(alignment: .topLeading) {
                    if taskText.isEmpty {
                        Text(placeholder)
                            .font(ElevateTheme.serif(16))
                            .foregroundStyle(ElevateTheme.graphite)
                            .padding(.leading, 5)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }

                    SubmittingTextView(
                        text: $taskText,
                        isEditable: isEnabled && !isBusy,
                        focusRequest: focusRequest,
                        onSubmit: submit,
                        onImages: { images += $0 }
                    )
                    .frame(height: 74)
                    .accessibilityLabel("Prompt for \(agentName) in \(projectName)")
                    .accessibilityHint(accessibilityHint)
                    .accessibilityIdentifier("promptInput")
                }
                .padding(8)
                .background(ElevateTheme.paper)
                .overlay {
                    RoundedRectangle(cornerRadius: ElevateTheme.controlRadius)
                        .strokeBorder(ElevateTheme.border, lineWidth: ElevateTheme.hairlineWidth)
                }

                Button(action: chooseImages) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(isEnabled ? ElevateTheme.ink : ElevateTheme.graphite)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .help("Add images")
                .accessibilityLabel("Add images")
                .accessibilityIdentifier("promptAddImages")

                Button(action: submit) {
                    HStack(spacing: ElevateTheme.spacing8) {
                        Text(buttonTitle)
                            .font(ElevateTheme.utility(11, medium: true))
                        if !isBusy {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(canSubmit ? ElevateTheme.onSignal : ElevateTheme.graphite)
                    .padding(.horizontal, ElevateTheme.spacing16)
                    .frame(height: 44)
                    .background(
                        canSubmit ? ElevateTheme.signal : ElevateTheme.paperDeep,
                        in: RoundedRectangle(cornerRadius: ElevateTheme.controlRadius)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityLabel(mode == .start ? "Start a conversation" : "Send prompt")
                .accessibilityHint("Return")
                .accessibilityIdentifier("promptSubmit")
            }
        }
        .padding(.horizontal, ElevateTheme.spacing24)
        .padding(.vertical, ElevateTheme.spacing16)
        .background(ElevateTheme.paper)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(ElevateTheme.border)
                .frame(height: ElevateTheme.hairlineWidth)
        }
    }

    private var accessibilityHint: String {
        switch mode {
        case .send: return "Sends to the conversation on screen. Press Return to submit, Shift Return for a new line"
        case .blocked: return "The terminal is showing a menu. Answer it in the terminal before sending"
        case .start: return "Starts a new conversation. Press Return to submit, Shift Return for a new line"
        }
    }

    private func submit() {
        guard canSubmit else { return }
        let task = trimmedTask
        if onSubmit(task, images) {
            taskText = ""
            images = []
        }
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        images += panel.urls.compactMap { PromptImageStore.add(fileAt: $0) }
    }
}

/// One attached image, with a button to take it out again.
private struct PromptImageChip: View {
    let image: PromptImage
    let onRemove: () -> Void

    var body: some View {
        Image(nsImage: image.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: ElevateTheme.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ElevateTheme.controlRadius)
                    .strokeBorder(ElevateTheme.border, lineWidth: ElevateTheme.hairlineWidth)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ElevateTheme.paper)
                        .frame(width: 16, height: 16)
                        .background(ElevateTheme.ink, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .accessibilityLabel("Remove image")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Attached image")
    }
}

/// Takes images from ⌘V and drops as attachments, where a plain text view
/// would paste nothing or insert the file's path.
private final class PromptTextView: NSTextView {
    var onImages: (([PromptImage]) -> Void)?

    override func paste(_ sender: Any?) {
        let images = PromptImageStore.images(from: .general, isPaste: true)
        guard images.isEmpty else { return onImages?(images) ?? () }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let images = PromptImageStore.images(from: sender.draggingPasteboard, isPaste: false)
        guard images.isEmpty else {
            onImages?(images)
            return true
        }
        return super.performDragOperation(sender)
    }
}

/// A plain-text editor where Return submits and Shift or Option Return
/// inserts a line break. SwiftUI's TextEditor cannot intercept Return on
/// macOS 13, so this wraps NSTextView directly.
private struct SubmittingTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let focusRequest: Int
    let onSubmit: () -> Void
    let onImages: ([PromptImage]) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        let size = scrollView.contentSize
        let textView = PromptTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = NSSize(width: 0, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        textView.onImages = onImages
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = ElevateTheme.serifNS(16)
        textView.textColor = ElevateTheme.inkNS
        textView.insertionPointColor = ElevateTheme.inkNS
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.string = text
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PromptTextView else { return }
        textView.onImages = onImages
        if focusRequest != context.coordinator.focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        if textView.string != text { textView.string = text }
        textView.isEditable = isEditable
        textView.isSelectable = isEditable
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SubmittingTextView

        var focusRequest: Int

        init(_ parent: SubmittingTextView) {
            self.parent = parent
            self.focusRequest = parent.focusRequest
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            // Keep IME composition (e.g. Japanese input) confirming on Return.
            if textView.hasMarkedText() { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            if modifiers.contains(.shift) || modifiers.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }
    }
}
