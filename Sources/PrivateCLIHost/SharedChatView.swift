import AppKit
import SwiftUI

struct SharedChatView: View {
    @ObservedObject var chat: SharedChat
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Shared chat").font(ElevateTheme.serif(28))
                    Text("Claude, Codex and you · \(chat.project.lastPathComponent)")
                        .font(.callout).foregroundStyle(ElevateTheme.graphite)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu {
                    Button("New discussion", action: chat.newDiscussion)
                    Divider()
                    ForEach(chat.history.threads) { thread in
                        Button(thread.title) { chat.select(thread.id) }
                    }
                } label: { Label("Discussions", systemImage: "clock") }
                .disabled(!chat.loaded || chat.isRunning)
                Button("Close") { chat.close(); dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if chat.thread.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Give them something to think through together.")
                                    .font(ElevateTheme.serif(23))
                                Text("Both agents read this discussion and take turns replying. Ask for competing approaches, a critique, or a plan for this project.")
                                Text("Use @claude or @codex to ask just one. Stop the exchange whenever you want to add your thoughts.")
                                Text("This room is for discussion and project inspection. Use a terminal conversation to carry out the plan.")
                                    .font(.callout).foregroundStyle(ElevateTheme.graphite)
                            }.padding(.vertical, 24)
                        }
                        ForEach(chat.thread.messages) { message in
                            messageRow(speaker: message.speaker, text: message.text, status: nil).id(message.id)
                        }
                        if let speaker = chat.activeSpeaker {
                            messageRow(speaker: speaker, text: chat.partialReply,
                                status: "Replying · \(chat.repliesRemaining) repl\(chat.repliesRemaining == 1 ? "y" : "ies") remaining")
                        } else if !chat.partialReply.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Unfinished reply · not shared").font(.caption).foregroundStyle(ElevateTheme.graphite)
                                ChatMessageBody(text: chat.partialReply)
                            }
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: chat.thread.messages.count) { _ in proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: chat.thread.id) { _ in proxy.scrollTo("latest", anchor: .bottom) }
                .overlay(alignment: .bottomTrailing) {
                    if !chat.thread.messages.isEmpty {
                        Button { proxy.scrollTo("latest", anchor: .bottom) } label: {
                            Image(systemName: "arrow.down").padding(8)
                        }
                        .buttonStyle(.bordered).help("Jump to the latest reply").padding(12)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let failure = chat.failure {
                    Text(failure).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .lineLimit(5)
                } else if !chat.notice.isEmpty {
                    Text(chat.notice).font(.callout).foregroundStyle(ElevateTheme.graphite)
                }
                HStack {
                    Toggle("Let them discuss", isOn: $chat.automatic).toggleStyle(.checkbox)
                        .disabled(chat.isRunning)
                    if chat.automatic {
                        Picker("Reply limit", selection: $chat.replyLimit) {
                            ForEach([2, 4, 6, 8, 12], id: \.self) { Text("\($0) replies").tag($0) }
                        }.labelsHidden().frame(width: 110).disabled(chat.isRunning)
                            .accessibilityLabel("Reply limit")
                            .help("Maximum replies before the discussion pauses")
                    }
                    Spacer()
                    if chat.isRunning {
                        Button("Stop", action: chat.stop).keyboardShortcut(".", modifiers: .command)
                            .buttonStyle(.bordered)
                    } else if !chat.thread.messages.isEmpty {
                        Button("Continue discussion", action: chat.continueDiscussion).disabled(!chat.canContinue)
                    }
                }
                TextEditor(text: $chat.draft)
                    .font(.system(size: 14)).frame(height: 76)
                    .padding(6).background(ElevateTheme.paperDeep)
                    .overlay(Rectangle().stroke(ElevateTheme.border, lineWidth: 1))
                    .accessibilityLabel("Message to the shared chat")
                    .disabled(!chat.loaded)
                HStack {
                    Picker("To", selection: $chat.recipient) {
                        Text("Both").tag("both")
                        Text("Claude").tag("claude")
                        Text("Codex").tag("codex")
                    }.frame(width: 150).disabled(chat.isRunning)
                    Text("⌘Return to send").font(.caption).foregroundStyle(ElevateTheme.graphite)
                    Spacer()
                    Button("Send") { _ = chat.send() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .buttonStyle(.borderedProminent).tint(ElevateTheme.signal)
                        .foregroundStyle(chat.canSend ? Color.black : ElevateTheme.graphite).disabled(!chat.canSend)
                }
            }.padding(24)
        }
        .frame(minWidth: 720, idealWidth: 840, minHeight: 620, idealHeight: 760)
        .background(ElevateTheme.paper).foregroundStyle(ElevateTheme.ink)
        .task { await chat.load() }
        .onDisappear { chat.close() }
    }

    private func messageRow(speaker: String, text: String, status: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let agent = Agent(rawValue: speaker) { PixelMark(sprite: agent.mark, color: ElevateTheme.ink) }
                Text(speaker == "you" ? "YOU" : speaker.uppercased()).font(ElevateTheme.utility(12, medium: true))
                if let status { Text(status).font(.caption).foregroundStyle(ElevateTheme.graphite) }
            }
            if text.isEmpty { ProgressView().controlSize(.small) }
            else { ChatMessageBody(text: text, markdown: speaker != "you") }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
