import AppKit
import SwiftUI

enum SidebarMode: String, Codable, CaseIterable {
    case active, projects

    var title: String { rawValue.capitalized }
}

struct SidebarNavigation: Codable, Equatable {
    var mode: SidebarMode = .active
    var expandedProjects: Set<String> = []
    var expandedHistory: Set<String> = []

    @MainActor mutating func reveal(_ session: TerminalSession) {
        expandedProjects.insert(session.projectPath)
        if SidebarActivity.classify(session, attention: nil) == .history {
            expandedHistory.insert(session.projectPath)
        }
    }
}

enum SidebarActivity: CaseIterable {
    case attention, working, queued, waiting, history

    var title: String {
        switch self {
        case .attention: return "Your turn"
        case .working: return "Working"
        case .queued: return "Queued"
        case .waiting: return "Waiting"
        case .history: return "History"
        }
    }

    @MainActor
    static func classify(_ session: TerminalSession, attention: String?) -> Self {
        if session.pendingResumeID != nil && session.state == .idle { return .history }
        switch session.state {
        case .exited, .failed: return .history
        case .queued: return .queued
        case .stopping: return .working
        case .idle, .running:
            if attention != nil { return .attention }
            return session.isWorking ? .working : .waiting
        }
    }
}

struct SidebarConversation: Identifiable {
    let session: TerminalSession
    let activity: SidebarActivity
    let attention: String?

    var id: UUID { session.id }
    var isActive: Bool { activity != .history }
    @MainActor var status: String {
        if session.state == .idle && session.pendingResumeID != nil {
            return session.isPaused ? "Paused" : "Restored"
        }
        if activity == .history || session.state == .stopping { return session.state.description }
        return activity.title
    }
}

struct SidebarProject: Identifiable {
    let project: ProjectRecord
    let conversations: [SidebarConversation]
    let parentPath: String?
    var id: String { project.path }

    @MainActor var active: [SidebarConversation] { conversations.filter(\.isActive) }
    @MainActor var history: [SidebarConversation] { conversations.filter { !$0.isActive } }
    var attentionCount: Int { conversations.filter { $0.activity == .attention }.count }
}

/// Search and grouping share one snapshot, so counts and rows describe the same sessions.
@MainActor
struct SidebarSnapshot {
    let conversations: [SidebarConversation]
    let projects: [SidebarProject]
    let isSearching: Bool
    let activeCount: Int

    init(projects: [ProjectRecord], sessions: [TerminalSession], profileID: String,
         attention: [UUID: String], query: String = "") {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        isSearching = !terms.isEmpty
        func matches(_ text: String) -> Bool {
            terms.allSatisfy { text.localizedCaseInsensitiveContains($0) }
        }
        let all = sessions.filter { $0.profileID == profileID }
            .sorted(by: TerminalSession.conversationComesBefore)
            .map { SidebarConversation(session: $0,
                activity: SidebarActivity.classify($0, attention: attention[$0.id]), attention: attention[$0.id]) }
        activeCount = all.filter(\.isActive).count
        conversations = all.filter {
            matches("\($0.session.displayTitle) \($0.session.agent.title) \($0.session.projectPath)")
        }
        let grouped = Dictionary(grouping: conversations, by: { $0.session.projectPath })
        let names = Dictionary(grouping: projects, by: \.name)
        self.projects = projects.compactMap { project in
            let rows = grouped[project.path] ?? []
            guard matches(project.path) || !rows.isEmpty else { return nil }
            let parentPath = (names[project.name]?.count ?? 0) > 1
                ? project.url.deletingLastPathComponent().path.replacingOccurrences(
                    of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") : nil
            return SidebarProject(project: project, conversations: rows, parentPath: parentPath)
        }
    }

    func conversations(in activity: SidebarActivity) -> [SidebarConversation] {
        conversations.filter { $0.activity == activity }
    }
}

@MainActor
struct ProjectSidebar: View {
    @ObservedObject var model: HostModel
    let onSelectSession: (TerminalSession) -> Void
    let onStopSession: (TerminalSession) -> Void
    let onRemoveSession: (TerminalSession) -> Void

    @State private var searchText = ""

    var body: some View {
        let snapshot = SidebarSnapshot(projects: model.projects, sessions: model.allLiveSessions,
            profileID: model.selectedProfileID, attention: model.attention, query: searchText)
        VStack(alignment: .leading, spacing: 0) {
            header
            navigation(activeCount: snapshot.activeCount)
            searchField
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if snapshot.isSearching {
                            sectionHeading("Matching projects", count: snapshot.projects.count)
                            projectList(snapshot)
                        } else if model.sidebarNavigation.mode == .active {
                            activeList(snapshot)
                        } else {
                            projectList(snapshot)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 16)
                }
                .id(snapshot.isSearching ? "search" : model.sidebarNavigation.mode.rawValue)
                .onChange(of: model.currentSession.id) { id in
                    revealSelection()
                    // A selection from a notification or the toolbar may be below the fold.
                    DispatchQueue.main.async { scroll.scrollTo(id, anchor: .center) }
                }
            }
            footer
        }
        .frame(width: 300)
        .background(HostTheme.paper)
        .overlay(alignment: .trailing) {
            Rectangle().fill(HostTheme.border).frame(width: 1)
        }
        .onAppear { revealSelection() }
        .onChange(of: model.workingDirectory) { _ in revealSelection() }
    }

    private var header: some View {
        HStack {
            Text("M4IX.CLI")
                .font(HostTheme.utility(14, medium: true))
                .tracking(0.28)
            Spacer()
            Button {
                searchText = ""
                model.sidebarNavigation.mode = .active
                _ = model.startNewConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(HoverButtonStyle())
            .accessibilityLabel("New conversation")
            .help("New \(model.selected.title) conversation in \(model.workingDirectory.lastPathComponent)")
        }
        .foregroundStyle(HostTheme.ink)
        .padding(.horizontal, 20)
        .frame(height: 68)
        .overlay(alignment: .bottom) { Rectangle().fill(HostTheme.border).frame(height: 1) }
    }

    private func navigation(activeCount: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(SidebarMode.allCases, id: \.self) { mode in
                let selected = model.sidebarNavigation.mode == mode
                Button {
                    searchText = ""
                    model.sidebarNavigation.mode = mode
                } label: {
                    HStack(spacing: 8) {
                        Text(mode.title.uppercased())
                            .font(HostTheme.utility(11, medium: selected))
                        Text("\(mode == .active ? activeCount : model.projects.count)")
                            .font(HostTheme.utility(10))
                            .foregroundStyle(HostTheme.graphite)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(selected ? HostTheme.paper : Color.clear,
                                in: RoundedRectangle(cornerRadius: 3))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(selected ? HostTheme.borderSubtle : Color.clear, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(HoverButtonStyle())
                .foregroundStyle(selected ? HostTheme.ink : HostTheme.graphite)
                .accessibilityLabel(mode == .active ? "Active conversations, all projects" : "Browse projects")
                .accessibilityValue("\(mode == .active ? activeCount : model.projects.count)")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .help(mode == .active ? "Active conversations across all projects" : "Projects and conversation history")
            }
        }
        .padding(4)
        .background(HostTheme.paperDeep, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(HostTheme.graphite)
            TextField("Search projects & conversations", text: $searchText)
                .font(HostTheme.serif(14))
                .textFieldStyle(.plain)
                .accessibilityLabel("Search projects and conversations")
                .onExitCommand { searchText = "" }
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(HostTheme.graphite)
                }
                .buttonStyle(HoverButtonStyle())
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .foregroundStyle(HostTheme.ink)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .overlay {
            RoundedRectangle(cornerRadius: HostTheme.controlRadius)
                .strokeBorder(HostTheme.borderSubtle, lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func activeList(_ snapshot: SidebarSnapshot) -> some View {
        if snapshot.activeCount == 0 {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(HostTheme.graphite)
                Text("No active conversations")
                    .font(HostTheme.serif(19))
                Text("Start a conversation, or return to earlier work in Projects.")
                    .font(HostTheme.serif(15))
                    .foregroundStyle(HostTheme.graphite)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Browse projects") { model.sidebarNavigation.mode = .projects }
                    .buttonStyle(HoverButtonStyle())
                    .font(HostTheme.serif(15))
                    .help("Open projects and conversation history")
            }
            .foregroundStyle(HostTheme.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 24)
        } else {
            Text("ACROSS ALL PROJECTS")
                .font(HostTheme.utility(9))
                .tracking(0.3)
                .foregroundStyle(HostTheme.graphite)
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 6)
            ForEach(SidebarActivity.allCases.filter { $0 != .history }, id: \.self) { activity in
                let rows = snapshot.conversations(in: activity)
                if !rows.isEmpty {
                    sectionHeading(activity.title, count: rows.count, attention: activity == .attention)
                    ForEach(rows) { conversation in
                        conversationRow(conversation, showsProject: true)
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }

    @ViewBuilder
    private func projectList(_ snapshot: SidebarSnapshot) -> some View {
        if snapshot.projects.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("No matches")
                    .font(HostTheme.serif(19))
                Text("Try a project, conversation title or provider.")
                    .font(HostTheme.serif(15))
                    .foregroundStyle(HostTheme.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(HostTheme.ink)
            .padding(8)
        }
        ForEach(snapshot.projects) { group in
            let expanded = snapshot.isSearching || model.sidebarNavigation.expandedProjects.contains(group.id)
            SidebarProjectHeader(
                group: group, isSelected: group.id == model.workingDirectory.path, isExpanded: expanded,
                canToggle: !snapshot.isSearching,
                onSelect: {
                    model.selectProject(group.project)
                    model.sidebarNavigation.expandedProjects.insert(group.id)
                },
                onToggle: { toggleProject(group.id) },
                onReveal: { model.revealProject(group.project) },
                onRemove: { model.removeProject(group.project) },
                canRemove: model.canRemoveProject(group.project)
            )
            if expanded {
                ForEach(group.active) { conversation in
                    conversationRow(conversation, showsProject: false)
                        .padding(.leading, 14)
                }
                if !group.history.isEmpty {
                    let historyExpanded = snapshot.isSearching || model.sidebarNavigation.expandedHistory.contains(group.id)
                    Button {
                        if !model.sidebarNavigation.expandedHistory.insert(group.id).inserted {
                            model.sidebarNavigation.expandedHistory.remove(group.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: historyExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .medium))
                                .frame(width: 10)
                            Text("HISTORY")
                                .font(HostTheme.utility(10))
                            Text("\(group.history.count)")
                                .font(HostTheme.utility(10))
                            Spacer()
                        }
                        .foregroundStyle(HostTheme.graphite)
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HoverButtonStyle())
                    .padding(.leading, 14)
                    .disabled(snapshot.isSearching)
                    .accessibilityLabel("\(historyExpanded ? "Collapse" : "Expand") history for \(group.project.name), \(group.history.count) conversations")
                    .help("Earlier conversations in \(group.project.name)")
                    if historyExpanded {
                        ForEach(group.history) { conversation in
                            conversationRow(conversation, showsProject: false)
                                .padding(.leading, 14)
                        }
                    }
                }
                if group.conversations.isEmpty {
                    Text("No conversations yet")
                        .font(HostTheme.serif(14))
                        .foregroundStyle(HostTheme.graphite)
                        .padding(.leading, 34)
                        .padding(.vertical, 10)
                }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int, attention: Bool = false) -> some View {
        HStack(spacing: 7) {
            if attention { AttentionPixel() }
            Text(title.uppercased())
                .font(HostTheme.utility(10, medium: true))
                .tracking(0.2)
            Spacer()
            Text("\(count)").font(HostTheme.utility(10))
        }
        .foregroundStyle(attention ? HostTheme.ink : HostTheme.graphite)
        .padding(.horizontal, 8)
        .frame(height: 32)
    }

    private func conversationRow(_ conversation: SidebarConversation, showsProject: Bool) -> some View {
        SidebarConversationRow(
            session: conversation.session, attention: conversation.attention,
            isSelected: model.isSelected(conversation.session), showsProject: showsProject,
            onSelect: { onSelectSession(conversation.session) },
            onStop: { onStopSession(conversation.session) },
            onRemove: { onRemoveSession(conversation.session) }
        )
        .id(conversation.id)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                searchText = ""
                model.sidebarNavigation.mode = .projects
                model.addProject()
            } label: {
                Label("Add project", systemImage: "plus")
                    .font(HostTheme.serif(14))
                    .padding(.horizontal, 8)
                    .frame(height: 32)
            }
            .buttonStyle(HoverButtonStyle())
            .help("Add a project folder")
            Spacer()
            Button { model.refreshHistory() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(HoverButtonStyle())
            .accessibilityLabel("Refresh conversations")
            .help("Refresh conversations")
        }
        .foregroundStyle(HostTheme.graphite)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(HostTheme.borderSubtle).frame(height: 1) }
    }

    private func toggleProject(_ path: String) {
        if !model.sidebarNavigation.expandedProjects.insert(path).inserted {
            model.sidebarNavigation.expandedProjects.remove(path)
        }
    }

    private func revealSelection() {
        for session in model.visibleSessions { model.sidebarNavigation.reveal(session) }
    }
}

@MainActor
private struct SidebarProjectHeader: View {
    let group: SidebarProject
    let isSelected: Bool
    let isExpanded: Bool
    let canToggle: Bool
    let onSelect: () -> Void
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void
    let canRemove: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggle) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HostTheme.graphite)
                    .frame(width: 26, height: group.parentPath == nil ? 40 : 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .disabled(!canToggle)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(group.project.name)")
            .help("\(isExpanded ? "Collapse" : "Expand") conversations")
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: group.project.isAvailable ? (isExpanded ? "folder.fill" : "folder") : "folder.badge.questionmark")
                        .font(.system(size: 13))
                        .foregroundStyle(HostTheme.graphite)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.project.name)
                            .font(HostTheme.serif(17))
                            .lineLimit(1)
                        if let parentPath = group.parentPath {
                            Text(parentPath)
                                .font(HostTheme.serif(11))
                                .foregroundStyle(HostTheme.graphite)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer(minLength: 0)
                    if group.attentionCount > 0 {
                        Text("\(group.attentionCount)")
                            .font(HostTheme.utility(10, medium: true))
                            .foregroundStyle(HostTheme.onSignal)
                            .padding(.horizontal, 5)
                            .frame(minWidth: 20, minHeight: 20)
                            .background(HostTheme.signal, in: RoundedRectangle(cornerRadius: 3))
                            .help("\(group.attentionCount) waiting for you")
                    } else if !group.active.isEmpty {
                        Text("\(group.active.count)")
                            .font(HostTheme.utility(10))
                            .foregroundStyle(HostTheme.graphite)
                            .help("\(group.active.count) active conversations")
                    }
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity, minHeight: group.parentPath == nil ? 40 : 48, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoverButtonStyle())
            .accessibilityLabel("\(group.project.name), \(group.active.count) active conversations, \(group.attentionCount) waiting for you")
            .accessibilityValue(group.project.path)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            .help(group.project.path + (group.project.isAvailable ? "" : " (folder unavailable)"))
        }
        .foregroundStyle(HostTheme.ink)
        .background(isSelected ? HostTheme.paperDeep.opacity(0.6) : Color.clear,
                    in: RoundedRectangle(cornerRadius: HostTheme.controlRadius))
        .contextMenu {
            Button("Show in Finder", action: onReveal).disabled(!group.project.isAvailable)
            Button("Remove from sidebar", action: onRemove).disabled(!canRemove)
        }
        .padding(.top, 4)
    }
}

@MainActor
private struct SidebarConversationRow: View {
    @ObservedObject var session: TerminalSession
    let attention: String?
    let isSelected: Bool
    let showsProject: Bool
    let onSelect: () -> Void
    let onStop: () -> Void
    let onRemove: () -> Void

    private var conversation: SidebarConversation {
        SidebarConversation(session: session, activity: SidebarActivity.classify(session, attention: attention),
                            attention: attention)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayTitle)
                    .font(HostTheme.serif(16))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if showsProject {
                    HStack(spacing: 5) {
                        Image(systemName: "folder").font(.system(size: 10))
                        Text(ProjectRecord(path: session.projectPath).name)
                            .font(HostTheme.serif(12))
                            .lineLimit(1)
                    }
                    .foregroundStyle(HostTheme.graphite)
                }
                HStack(spacing: 5) {
                    Circle().fill(session.agent.tint).frame(width: 5, height: 5)
                    Text(session.agent.title.uppercased())
                        .foregroundStyle(HostTheme.graphite)
                    Spacer(minLength: 4)
                    if conversation.activity == .attention { AttentionPixel() }
                    Text(conversation.status.uppercased())
                        .foregroundStyle(conversation.activity == .attention ? HostTheme.ink : HostTheme.graphite)
                        .lineLimit(1)
                }
                .font(HostTheme.utility(9, medium: conversation.activity == .attention))
                .help(conversation.attention ?? (conversation.isActive
                    ? "Waiting means the terminal is quiet; it does not confirm task completion."
                    : "Select to return to this conversation."))
            }
            .foregroundStyle(HostTheme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? HostTheme.paperDeep : Color.clear,
                        in: RoundedRectangle(cornerRadius: HostTheme.controlRadius))
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1).fill(HostTheme.ink)
                        .frame(width: 2).padding(.vertical, 10)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .padding(.vertical, 2)
        .accessibilityLabel("\(session.displayTitle), \(ProjectRecord(path: session.projectPath).name), \(session.agent.title), \(conversation.status)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help("\(session.displayTitle)\n\(session.projectPath)\n\(session.agent.title) · \(conversation.status)")
        .contextMenu {
            if case .running = session.state {
                Button("Stop session", role: .destructive, action: onStop)
            } else if session.state == .stopping {
                Button("Stopping…") {}.disabled(true)
            } else if session.state == .queued {
                Button("Cancel queued session", action: onStop)
            } else {
                Button("Remove from history", action: onRemove)
            }
            if let prompt = session.initialPrompt {
                Button("Copy original task") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(prompt, forType: .string)
                }
            }
        }
    }
}
