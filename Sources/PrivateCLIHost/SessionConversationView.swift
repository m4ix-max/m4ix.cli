import AppKit
import SwiftUI

struct SessionConversationView: View {
    @ObservedObject var session: TerminalSession
    @Binding var showTerminal: Bool
    let isActive: Bool
    let onActivate: () -> Void
    let onPromptFocus: () -> Void
    let onTerminal: () -> Void
    let onPasteImages: ([PromptImage]) -> Void
    @State private var transcript = ConversationTranscriptSnapshot()
    @State private var followsLatest = true

    private var conversationID: String? { session.activeConversationID ?? session.pendingResumeID }

    var needsTerminal: Bool {
        if !session.compatibility.usesComposer || session.terminalResponseRequest != nil { return true }
        if case .running(.login) = session.state { return true }
        if case .failed = session.state { return true }
        return false
    }

    var isShowingTerminal: Bool { showTerminal || needsTerminal }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(isShowingTerminal ? "TERMINAL" : "CHAT")
                    .font(ElevateTheme.utility(11, medium: true)).foregroundStyle(ElevateTheme.graphite)
                if session.terminalResponseRequest != nil {
                    Text(session.hasQueuedQuestions ? "A question is waiting" : "Answer the request below")
                        .font(.caption).foregroundStyle(ElevateTheme.graphite)
                }
                Spacer()
                if session.hasQueuedQuestions {
                    Button("Open questions") { onActivate(); session.openQueuedQuestions() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityIdentifier("conversationOpenQuestions")
                }
                Button(isShowingTerminal ? "Show chat" : "Terminal controls") {
                    onActivate()
                    if isShowingTerminal { showTerminal = false; onPromptFocus() }
                    else { onTerminal() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(isShowingTerminal && needsTerminal)
                .help(isShowingTerminal ? "Return to the conversation (⌘L)" : "Open native CLI controls (⌘⇧T)")
            }.padding(.horizontal, 24).padding(.vertical, 10)
            Divider()
            ZStack {
                // Keep the PTY mounted and sized while chat is visible, so
                // prompt delivery and terminal approval detection keep working.
                TerminalDeck(terminal: session.terminal, agent: session.agent,
                    hidesPrompt: !isShowingTerminal && session.compatibility.usesComposer,
                    takesAutomaticFocus: isActive && isShowingTerminal,
                    onActivate: onActivate, onPromptFocus: onPromptFocus, onPasteImages: onPasteImages)
                    .opacity(isShowingTerminal ? 1 : 0)
                    .allowsHitTesting(isShowingTerminal)
                    .accessibilityHidden(!isShowingTerminal)
                chat.opacity(isShowingTerminal ? 0 : 1)
                    .allowsHitTesting(!isShowingTerminal)
                    .accessibilityHidden(isShowingTerminal)
            }
        }
        .background(ElevateTheme.paper).foregroundStyle(ElevateTheme.ink)
        .onChange(of: isShowingTerminal) { shown in
            if !shown, isActive { onPromptFocus() }
        }
        .task(id: conversationID) {
            transcript = ConversationTranscriptSnapshot()
            followsLatest = true
            guard let conversationID else { return }
            let reader = ConversationTranscriptReader(agent: session.agent, profile: session.profileDirectory,
                                                       conversationID: conversationID)
            while !Task.isCancelled {
                let next = await reader.read()
                guard !Task.isCancelled else { return }
                if next != transcript { transcript = next }
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            }
        }
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if transcript.messages.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            PixelMark(sprite: session.agent.mark, color: ElevateTheme.graphite)
                            Text(conversationID == nil ? "New conversation" : "Loading conversation…")
                                .font(ElevateTheme.serif(24))
                            Text(conversationID == nil ? "Write below, or choose a conversation from History."
                                : "Your messages and replies will appear here.")
                                .font(.callout).foregroundStyle(ElevateTheme.graphite)
                            if conversationID != nil, !transcript.foundFile {
                                Button("View terminal output", action: onTerminal).buttonStyle(.borderless)
                            }
                        }.padding(.vertical, 24)
                    }
                    ForEach(Array(transcript.messages.enumerated()), id: \.element.id) { index, message in
                        let continues = index > 0 && transcript.messages[index - 1].speaker == message.speaker
                        ChatTurn(speaker: message.speaker, text: message.text, continues: continues, steps: message.steps)
                            .padding(.top, index == 0 ? 0 : (continues ? 12 : 28) as CGFloat).id(message.id)
                    }
                    if let error = transcript.error {
                        Text(error).font(.callout).foregroundStyle(ElevateTheme.graphite).padding(.top, 28)
                    }
                    if session.isWorking {
                        // The latest step says more than "working": Claude logs a
                        // step as it starts, Codex and Hermes once it is done.
                        let latest = transcript.messages.last?.steps.last
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(latest?.title ?? "\(session.agent.title) is working…").lineLimit(1).truncationMode(.tail)
                                .font(.caption).foregroundStyle(ElevateTheme.graphite)
                        }.padding(.top, latest == nil ? 28 : 12)
                    }
                    Color.clear.frame(height: 1).id("latest")
                        .onAppear { followsLatest = true }
                        .onDisappear { followsLatest = false }
                }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
            }
            .onChange(of: transcript.messages.last) { _ in
                if followsLatest { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest, !transcript.messages.isEmpty {
                    Button("Jump to latest") { followsLatest = true; proxy.scrollTo("latest", anchor: .bottom) }
                        .padding(16)
                }
            }
        }.background(ElevateTheme.paper).foregroundStyle(ElevateTheme.ink)
    }
}
