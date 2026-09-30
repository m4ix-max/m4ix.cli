import CryptoKit
import Foundation
import SwiftUI

struct ProjectToolsRequest: Identifiable {
    let id = UUID()
    let directory: URL
}

struct ProjectTask: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var owner: String
    var state: String
    var details: String

    init(title: String, owner: String, details: String = "") {
        id = UUID()
        self.title = title
        self.owner = owner
        state = "Planned"
        self.details = details
    }
}

struct ProjectHandoffRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let source: String
    let target: String
    let prompt: String
    var state: String
}

struct ProjectContext: Codable, Sendable {
    var brief = ""
    var tasks: [ProjectTask] = []
    var handoffs: [ProjectHandoffRecord] = []
}

/// One durable record per project. The actor serializes edits and appends so
/// saving a brief cannot erase a handoff written while the editor was open.
actor ProjectContextStore {
    static let shared = ProjectContextStore(directory: HostPaths.profileBase.appendingPathComponent("projects"))
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    private func file(for path: String) -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let normalized = (try? GitWorkspace.contextRoot(url))?.path ?? url.path
        let hash = SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }

    func load(path: String) throws -> ProjectContext {
        let url = file(for: path)
        guard FileManager.default.fileExists(atPath: url.path) else { return ProjectContext() }
        return try JSONDecoder().decode(ProjectContext.self, from: Data(contentsOf: url))
    }

    private func write(_ context: ProjectContext, path: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(context)
        let url = file(for: path)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func savePlan(path: String, brief: String, tasks: [ProjectTask]) throws {
        var context = try load(path: path)
        context.brief = brief
        context.tasks = tasks
        try write(context, path: path)
    }

    func appendHandoff(path: String, record: ProjectHandoffRecord) throws {
        var context = try load(path: path)
        context.handoffs.append(record)
        try write(context, path: path)
    }

    func updateHandoff(path: String, id: UUID, state: String) throws {
        var context = try load(path: path)
        guard let index = context.handoffs.firstIndex(where: { $0.id == id }) else { return }
        context.handoffs[index].state = state
        try write(context, path: path)
    }
}

struct ProjectToolsView: View {
    let directory: URL
    let onOpenWorkspace: (URL) -> Void
    let onStartTask: (String, String) -> Bool
    let store: ProjectContextStore
    @Environment(\.dismiss) private var dismiss
    @State private var context = ProjectContext()
    @State private var git: GitWorkspaceSummary?
    @State private var error: String?
    @State private var gitError: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var savedBrief = ""
    @State private var savedTasks: [ProjectTask] = []
    private var dirty: Bool { context.brief != savedBrief || context.tasks != savedTasks }
    @State private var branch = ""
    @State private var taskTitle = ""
    @State private var taskOwner = "Claude"
    @State private var tab = 0

    init(directory: URL, store: ProjectContextStore = .shared, initialTab: Int = 0,
         onOpenWorkspace: @escaping (URL) -> Void, onStartTask: @escaping (String, String) -> Bool) {
        self.directory = directory
        self.store = store
        self.onOpenWorkspace = onOpenWorkspace
        self.onStartTask = onStartTask
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(directory.lastPathComponent).font(ElevateTheme.serif(26)).lineLimit(1).truncationMode(.middle).help(directory.path)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(dirty ? "Save and close" : "Close") {
                    Task {
                        if dirty { guard await save() else { return } }
                        dismiss()
                    }
                }.disabled(busy)
            }
            Picker("Project tools", selection: $tab) {
                Text("Brief").tag(0)
                Text("Tasks").tag(1)
                Text("Handoffs").tag(2)
                Text("Git workspaces").tag(3)
            }.pickerStyle(.segmented)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Group {
                switch tab {
                case 0: brief
                case 1: tasks
                case 2: handoffs
                default: workspaces
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(24).frame(width: 740, height: 620)
        .background(ElevateTheme.paper)
        .interactiveDismissDisabled(dirty || busy)
        .task { await load() }
    }

    private var brief: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project brief").font(.headline)
            Text("Keep the goal, constraints, and decisions both agents need. The brief accompanies tasks started here and agent handoffs.")
                .foregroundStyle(.secondary)
            TextEditor(text: $context.brief).font(.system(.body, design: .monospaced))
                .border(ElevateTheme.border).disabled(!loaded || busy)

            Button("Save brief") { Task { _ = await save() } }.disabled(!loaded || busy || !dirty)
        }
    }

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Assign separate files or responsibilities before parallel work.").foregroundStyle(.secondary)
            HStack {
                TextField("Task title", text: $taskTitle)
                Picker("Owner", selection: $taskOwner) { Text("Claude").tag("Claude"); Text("Codex").tag("Codex") }
                    .frame(width: 140)
                Button("Add") {
                    context.tasks.append(ProjectTask(title: taskTitle.trimmingCharacters(in: .whitespacesAndNewlines), owner: taskOwner))
                    taskTitle = ""
                }.disabled(taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || !loaded)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($context.tasks) { $task in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Title", text: $task.title)
                            HStack {
                                Picker("Owner", selection: $task.owner) { Text("Claude").tag("Claude"); Text("Codex").tag("Codex") }
                                Picker("Status", selection: $task.state) {
                                    ForEach(["Planned", "In progress", "Review", "Done"], id: \.self) { Text($0).tag($0) }
                                }
                                Button {
                                    context.tasks.removeAll { $0.id == task.id }
                                } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Remove task")
                                .help("Remove task from the plan")
                                Button("Start \(task.owner)") {
                                    let prompt = taskPrompt(task)
                                    let owner = task.owner
                                    Task {
                                        guard await save() else { return }
                                        if onStartTask(owner, prompt) { dismiss() }
                                        else { error = "Could not start the task. Check that the project folder is available." }
                                    }
                                }.disabled(busy || task.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            TextField("Files, acceptance criteria, and context", text: $task.details, axis: .vertical)
                            Divider()
                        }
                    }
                }
            }.disabled(!loaded || busy)

            Button("Save tasks") { Task { _ = await save() } }.disabled(!loaded || busy || !dirty)
        }
    }

    private var handoffs: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if context.handoffs.isEmpty { Text("No handoffs yet. Use the session menu to hand work to the other agent.").foregroundStyle(.secondary) }
                ForEach(context.handoffs.reversed()) { record in
                    DisclosureGroup("\(record.source) → \(record.target) · \(record.date.formatted()) · \(record.state)") {
                        Text(record.prompt).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var workspaces: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            if let gitError { Text(gitError).foregroundStyle(.secondary).textSelection(.enabled) }
            if let git {
                Text("Branch: \(git.branch)").font(.headline)
                Text(git.status.isEmpty ? "Working tree is clean." : "Uncommitted changes:\n" + git.status)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                if !git.changes.isEmpty { Text(git.changes).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                Divider()
                Text("Create an isolated workspace").font(.headline)
                Text("A new branch starts at the current commit. Uncommitted changes stay here. Open a separate workspace for each agent to avoid editing the same files.")
                    .foregroundStyle(.secondary)
                TextField("New branch, for example m4ix/codex-review", text: $branch).disabled(busy)
                Button("Create and open workspace") { Task { await createWorkspace() } }
                    .disabled(busy || !loaded || branch.isEmpty)
                Text("When work is ready, review the branch diff and integrate it with Git in the terminal. This app never merges or removes worktrees automatically.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Git information is unavailable. A repository with an initial commit is required to create isolated workspaces.").foregroundStyle(.secondary)
            }
            Button("Refresh Git status") { Task { await refreshGit() } }.disabled(busy)
        }
        }
    }

    private func taskPrompt(_ task: ProjectTask) -> String {
        """
        Assigned task: \(task.title)

        Project brief:
        \(context.brief)
        Owner: \(task.owner)
        Files and acceptance criteria:
        \(task.details)

        Inspect the current files and Git state before making changes. Preserve other work. Keep edits within this task's scope. Report changed files, validation results, and anything requiring review. Task status is tracked by the user; do not infer completion from a quiet terminal.
        """
    }

    @MainActor private func load() async {
        do {
            context = try await store.load(path: directory.path)
            loaded = true
            savedBrief = context.brief
            savedTasks = context.tasks
        } catch { self.error = "Could not load project notes: \(error.localizedDescription)"; return }
        await refreshGit()
    }

    @MainActor private func save() async -> Bool {
        busy = true
        defer { busy = false }
        do {
            try await store.savePlan(path: directory.path, brief: context.brief, tasks: context.tasks)
            savedBrief = context.brief
            savedTasks = context.tasks
            error = nil
            return true
        } catch { self.error = "Could not save project notes: \(error.localizedDescription)"; return false }
    }

    @MainActor private func refreshGit() async {
        busy = true
        defer { busy = false }
        do {
            let directory = directory
            git = try await Task.detached(priority: .utility) { try GitWorkspace.inspect(directory) }.value
            gitError = nil
        } catch {
            git = nil
            gitError = error.localizedDescription.contains("not a git repository")
                ? "This folder is not a Git repository."
                : "Could not read Git status: \(error.localizedDescription)"
        }
    }

    @MainActor private func createWorkspace() async {
        if dirty { guard await save() else { return } }
        busy = true
        defer { busy = false }
        let directory = directory
        let branch = branch
        let label = (directory.lastPathComponent + "-" + branch).map { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-") ? character : "-"
        }
        let name = String(label.prefix(80)) + "-" + UUID().uuidString.prefix(8)
        let destination = HostPaths.profileBase.appendingPathComponent("worktrees").appendingPathComponent(name)
        do {
            let url = try await Task.detached(priority: .utility) {
                try GitWorkspace.create(in: directory, branch: branch, destination: destination)
            }.value
            onOpenWorkspace(url)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
