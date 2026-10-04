import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProductionToolsView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var center: ProductionCenter
    let onRecover: (RecoveryDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab = "Changes"
    private let tabs = ["Changes", "Checks", "Workflows", "Recovery", "Sessions", "Profiles", "Setup", "Updates"]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Workspace tools").font(ElevateTheme.serif(26))
                    Text("\(model.workingDirectory.lastPathComponent) · \(center.name(for: model.selectedProfileID))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(tabs, id: \.self) { name in
                        Button { tab = name } label: {
                            HStack { Text(name); Spacer(); if name == "Recovery", !center.drafts.isEmpty { Text(String(center.drafts.count)) } }
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                .background(tab == name ? ElevateTheme.signal.opacity(0.45) : .clear)
                        }
                        .buttonStyle(ElevateHoverButtonStyle())
                        .help(tabHelp(name))
                    }
                    Spacer()
                }.padding(12).frame(width: 165)
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    if let error = center.storageError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    switch tab {
                    case "Changes": ChangeReviewView(directory: model.workingDirectory, root: model.dataRoot)
                    case "Checks": VerificationToolsView(service: model.verification, directory: model.workingDirectory)
                    case "Workflows": WorkflowToolsView(model: model, checks: model.verification, service: model.workflows, directory: model.workingDirectory)
                    case "Recovery": RecoveryToolsView(center: center) { draft in onRecover(draft); dismiss() }
                    case "Sessions": SessionControlView(model: model) { dismiss() }
                    case "Profiles": ProfileToolsView(model: model, center: center)
                    case "Setup": SetupToolsView(model: model) { dismiss() }
                    default: UpdateToolsView(model: model)
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }.frame(width: 1060, height: 720).background(ElevateTheme.paper)
    }

    private func tabHelp(_ name: String) -> String {
        switch name {
        case "Changes": "Review project changes against the state captured when sessions started."
        case "Checks": "Configure and run project checks, then review whether their results are still current."
        case "Workflows": "Run saved multi-step workflows with explicit review and decision points."
        case "Recovery": "Restore drafts and attachments whose delivery was interrupted or uncertain."
        case "Sessions": "Inspect live sessions, queued launches, and resource use; stop or open a session."
        case "Profiles": "Separate provider account configuration and project state by profile."
        case "Setup": "Check provider CLI availability, versions, authentication, and project access."
        default: "Stage an app update for quit and reopen, or inspect rollback backups."
        }
    }
}

struct ReadOnlyLog: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 10, height: 10)
        scroll.documentView = view
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        guard let editor = view.documentView as? NSTextView, editor.string != text else { return }
        editor.string = text
    }
}

struct ChangeReviewView: View {
    let directory: URL
    let root: URL
    @State private var snapshot: WorkspaceSnapshot?
    @State private var baselines: [ReviewBaseline] = []
    @State private var baselineID: UUID?
    @State private var currentPatch = ""
    @State private var files: [String] = []
    @State private var selectedFile = ""
    @State private var showStartingChanges = false
    @State private var error: String?
    @State private var busy = false
    private var baseline: ReviewBaseline? { baselines.first { $0.id == baselineID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Review changes").font(.title2)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await refresh() } }.disabled(busy)
            }
            Text("Read the current diff and compare it with the Git state recorded before a session started.").foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if !baselines.isEmpty {
                Picker("Starting state", selection: $baselineID) {
                    Text("Choose a session").tag(Optional<UUID>.none)
                    ForEach(baselines) { baseline in Text("\(baseline.date.formatted()) · \(baseline.id.uuidString.prefix(8))").tag(Optional(baseline.id)) }
                }
                if let baseline, let snapshot {
                    let changed = WorkspaceReview.changedFiles(from: baseline.snapshot, to: snapshot)
                    Text("\(changed.count) files differ from this starting state. These changes may include edits from other sessions.")
                        .font(.callout).foregroundStyle(.secondary)
                    if !changed.isEmpty {
                        Text(changed.prefix(8).joined(separator: ", ") + (changed.count > 8 ? "…" : ""))
                            .font(.caption).lineLimit(2).textSelection(.enabled)
                    }
                    Toggle("Show changes that already existed at the start", isOn: $showStartingChanges)
                }
            } else { Text("Starting states are captured for new sessions in Git repositories.").font(.callout).foregroundStyle(.secondary) }
            if !showStartingChanges {
                Picker("File", selection: $selectedFile) {
                    Text("All changed files").tag("")
                    ForEach(files, id: \.self) { Text($0).tag($0) }
                }.onChange(of: selectedFile) { _ in Task { await loadPatch() } }
            }
            ReadOnlyLog(text: showStartingChanges ? baseline?.patch ?? "Select a starting state." : currentPatch)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let snapshot { Text("Read \(snapshot.capturedAt.formatted()) · HEAD \(snapshot.head.prefix(10))").font(.caption).foregroundStyle(.secondary) }
        }.task(id: directory) { selectedFile = ""; baselineID = nil; showStartingChanges = false; await refresh() }
    }

    private func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await Task.detached(priority: .utility) {
                let snapshot = try WorkspaceReview.snapshot(in: directory)
                let baselines = try PrivateStore.read([ReviewBaseline].self, from: WorkspaceReview.baselineURL(root: root, project: directory.path), default: [])
                let changed = try WorkspaceReview.git(["diff", "--name-only", "-z", "HEAD", "--"], in: directory)
                let untracked = try WorkspaceReview.git(["ls-files", "--others", "--exclude-standard", "-z"], in: directory)
                let files = Set((changed + untracked).split(separator: "\0").map(String.init)).sorted()
                return (snapshot, baselines, files, try WorkspaceReview.patch(in: directory))
            }.value
            snapshot = result.0; baselines = result.1; files = result.2; currentPatch = result.3
            selectedFile = ""
            if baselineID == nil { baselineID = baselines.first?.id }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func loadPatch() async {
        let selection = selectedFile
        do {
            let patch = try await Task.detached(priority: .utility) { try WorkspaceReview.patch(in: directory, file: selection.isEmpty ? nil : selection) }.value
            if selectedFile == selection { currentPatch = patch }
        } catch { self.error = error.localizedDescription }
    }
}

struct VerificationToolsView: View {
    @ObservedObject var service: VerificationService
    let directory: URL
    @State private var configuration = ProjectAutomation()
    @State private var loaded = false
    @State private var failure: String?
    @State private var selectedRecord: UUID?
    private var records: [VerificationRecord] { service.records.filter { $0.project == directory.path } }
    private var running: Bool { records.contains { $0.state == "Running" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project checks").font(.title2)
            Text("Commands run in this project with your local shell environment. Configure them before running a check.").foregroundStyle(.secondary)
            ForEach($configuration.commands) { $command in
                HStack {
                    Text(command.id).frame(width: 45, alignment: .leading)
                    TextField("Command", text: $command.command).font(.system(.body, design: .monospaced))
                    Button("Run") {
                        let command = command
                        Task {
                            do { try service.save(configuration, for: directory) }
                            catch { failure = error.localizedDescription; return }
                            selectedRecord = nil
                            let record = await service.run(title: command.id, command: command.command, project: directory)
                            selectedRecord = record?.id
                        }
                    }
                    .help("Run the \(command.id) check in this project and record its output.")
                    .disabled(!loaded || running || command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.disabled(running)
            HStack {
                Button("Save commands") { do { try service.save(configuration, for: directory); failure = nil } catch { failure = error.localizedDescription } }.disabled(!loaded || running)
                Spacer()
                Button("Refresh result freshness") { Task { await service.refreshFreshness(project: directory) } }
            }
            if let failure = failure ?? service.error { Text(failure).foregroundStyle(.red) }
            Divider()
            if records.isEmpty { Text("No checks have run in this project.").foregroundStyle(.secondary); Spacer() }
            else {
                Picker("Result", selection: $selectedRecord) {
                    Text("Latest check").tag(Optional<UUID>.none)
                    ForEach(records) { record in Text("\(record.title) · \(record.startedAt.formatted()) · \(service.evidenceLabel(record))").tag(Optional(record.id)) }
                }
                if let record = records.first(where: { $0.id == selectedRecord }) ?? records.first {
                    HStack {
                        Text(service.evidenceLabel(record)).font(.headline)
                        if let code = record.exitCode { Text("Exit \(code)").foregroundStyle(.secondary) }
                        Spacer()
                        if record.state == "Running" { Button("Cancel check") { service.cancel(record.id) } }
                    }
                    if !record.note.isEmpty { Text(record.note).font(.callout).foregroundStyle(.secondary) }
                    ReadOnlyLog(text: "$ \(record.command)\n\n\(record.output)").frame(maxHeight: .infinity)
                }
            }
        }.task(id: directory) {
            loaded = false
            do { configuration = try service.configuration(for: directory); loaded = true } catch { failure = error.localizedDescription }
            while !Task.isCancelled {
                await service.refreshFreshness(project: directory)
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
            }
        }
    }
}

struct WorkflowToolsView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var checks: VerificationService
    @ObservedObject var service: WorkflowService
    let directory: URL
    @State private var configuration = ProjectAutomation()
    @State private var selectedTemplate = 0
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Repeatable workflows").font(.title2)
                Text("Agent work waits for your review. Checks advance only when they pass against unchanged source. Decisions always wait for you.").foregroundStyle(.secondary)
                if let error = error ?? service.error { Text(error).foregroundStyle(.red) }
                HStack {
                    Picker("Workflow", selection: $selectedTemplate) {
                        ForEach(configuration.workflows.indices, id: \.self) { Text(configuration.workflows[$0].name).tag($0) }
                    }
                    Button("New workflow") {
                        configuration.workflows.append(WorkflowTemplate(name: "New workflow", steps: []))
                        selectedTemplate = configuration.workflows.count - 1
                    }.disabled(!loaded)
                }
                if configuration.workflows.indices.contains(selectedTemplate) {
                    TextField("Workflow name", text: $configuration.workflows[selectedTemplate].name)
                    ForEach($configuration.workflows[selectedTemplate].steps) { $step in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Picker("Step", selection: $step.kind) { ForEach(["Agent", "Check", "Decision"], id: \.self) { Text($0) } }.frame(width: 145)
                                TextField("Step title", text: $step.title)
                                Button { configuration.workflows[selectedTemplate].steps.removeAll { $0.id == step.id } } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove step")
                            }
                            if step.kind == "Check" {
                                Picker("Saved command", selection: $step.content) { ForEach(configuration.commands) { Text($0.id).tag($0.id) } }
                            } else {
                                if step.kind == "Agent" {
                                    Picker("Provider", selection: $step.provider) { Text("Claude").tag("claude"); Text("Codex").tag("codex") }
                                }
                                TextField(step.kind == "Agent" ? "Task and acceptance criteria" : "Decision to review", text: $step.content, axis: .vertical)
                            }
                        }.padding(10).background(ElevateTheme.border.opacity(0.15))
                    }
                    HStack {
                        Button("Add step") { configuration.workflows[selectedTemplate].steps.append(WorkflowStep(kind: "Decision", title: "Review", content: "Review the result.")) }
                        Button("Save workflow") { save() }
                        Spacer()
                        Button("Start workflow") {
                            guard save() else { return }
                            do {
                                let id = try service.create(template: configuration.workflows[selectedTemplate], commands: configuration.commands,
                                    project: directory.path, profileID: model.selectedProfileID)
                                advance(id)
                            } catch { self.error = error.localizedDescription }
                        }.disabled(configuration.workflows[selectedTemplate].steps.isEmpty)
                    }.disabled(!loaded)
                }
                Divider()
                Text("Workflow runs").font(.headline)
                ForEach(service.runs.filter { $0.project == directory.path }) { run in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(run.template.name) · \(run.state)").font(.headline)
                        Text("\(model.production.name(for: run.profileID)) · Step \(min(run.step + 1, run.template.steps.count)) of \(run.template.steps.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        if run.step < run.template.steps.count { Text(run.template.steps[run.step].title) }
                        if !run.message.isEmpty { Text(run.message).font(.callout) }
                        HStack {
                            if let session = run.sessionID { Button("Open agent session") { model.reveal(sessionID: session) } }
                            if run.state == "Awaiting review" {
                                Button("Reviewed, continue") { service.approve(run.id); advance(run.id) }
                            }
                            if ["Ready", "Paused"].contains(run.state) { Button(run.state == "Paused" ? "Retry this step" : "Continue") { advance(run.id) } }
                            if !["Complete", "Cancelled"].contains(run.state) { Button("Cancel workflow") { service.cancel(run.id, checks: checks) } }
                        }
                        Divider()
                    }
                }
            }
        }.task(id: directory) {
            do { configuration = try checks.configuration(for: directory); selectedTemplate = 0; loaded = true }
            catch { self.error = error.localizedDescription }
        }
    }

    @discardableResult private func save() -> Bool {
        do { try checks.save(configuration, for: directory); error = nil; return true }
        catch { self.error = error.localizedDescription; return false }
    }
    private func advance(_ id: UUID) {
        Task { await service.advance(id, checks: checks) { project, profile, provider, prompt in
            model.startWorkflowAgent(project: project, profile: profile, provider: provider, prompt: prompt)
        } }
    }
}

struct RecoveryToolsView: View {
    @ObservedObject var center: ProductionCenter
    let recover: (RecoveryDraft) -> Void
    @State private var discard: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recover unfinished work").font(.title2)
            Text("Drafts are saved locally as you type. Restoring opens an editor and never sends the message.").foregroundStyle(.secondary)
            if center.drafts.isEmpty { Text("No saved drafts."); Spacer() }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(center.drafts) { draft in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(draft.kind) · \(draft.provider.capitalized) · \(center.name(for: draft.profileID))").font(.headline)
                                Text("\(URL(fileURLWithPath: draft.project).lastPathComponent) · \(draft.updatedAt.formatted())")
                                    .font(.caption).foregroundStyle(.secondary)
                                if draft.kind != "Handoff" { Text(draft.text).lineLimit(3).textSelection(.enabled) }
                                if !draft.images.isEmpty { Text("\(draft.images.count) saved attachments").font(.caption) }
                                if draft.deliveryUnconfirmed { Text("Delivery was interrupted or not confirmed. Check the conversation before sending again.").foregroundStyle(.orange) }
                                HStack {
                                    Button("Restore to editor") { recover(draft) }
                                        .help(draft.deliveryUnconfirmed
                                              ? "Restore this draft, then check the conversation before resending."
                                              : "Restore this saved text and its attachments to the message editor.")
                                    Button("Discard") { discard = draft.id }
                                        .help("Permanently remove this saved draft and its recovery record.")
                                }
                                Divider()
                            }
                        }
                    }
                }
            }
        }.confirmationDialog("Discard this saved draft?", isPresented: Binding(get: { discard != nil }, set: { if !$0 { discard = nil } })) {
            Button("Discard draft", role: .destructive) { if let discard { center.removeDraft(discard) }; discard = nil }
        }
    }
}

struct SessionControlView: View {
    @ObservedObject var model: HostModel
    let onOpen: () -> Void
    @State private var resources: [Int32: String] = [:]
    @State private var showStopped = false
    @State private var stopping: TerminalSession?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sessions across all projects").font(.title2)
            HStack {
                Stepper("Concurrent CLI limit: \(model.sessionLimit)", value: $model.sessionLimit, in: 1...16)
                Spacer()
                Text("\(model.activeSessionCount) active · \(model.queuedSessions.count) queued")
            }
            Text("A running CLI occupies a slot until it stops, including while waiting for input. Reducing the limit leaves existing sessions running.")
                .font(.callout).foregroundStyle(.secondary)
            Toggle("Show stopped sessions", isOn: $showStopped)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(model.allLiveSessions.filter { showStopped || $0.state.isRunning || $0.state == .queued || $0.pendingResumeID != nil }) { session in
                        SessionControlRow(session: session, profile: model.production.name(for: session.profileID),
                            attention: model.attentionMessage(for: session), resources: resources[session.terminal.process.shellPid]) {
                                model.reveal(sessionID: session.id); onOpen()
                            } stop: { stopping = session }
                    }
                }
            }
            Text("App memory: \(HostHealth.residentMemoryMB().map(String.init) ?? "unknown") MB. CPU and memory below describe each CLI process.")
                .font(.caption).foregroundStyle(.secondary)
        }.task {
            while !Task.isCancelled {
                let pids = model.allLiveSessions.filter { $0.state.isRunning }.map { String($0.terminal.process.shellPid) }.filter { $0 != "0" }
                if !pids.isEmpty {
                    let result = try? await Task.detached(priority: .utility) {
                        try CommandRunner.run(executable: "/bin/ps", arguments: ["-p", pids.joined(separator: ","), "-o", "pid=,%cpu=,rss="],
                            directory: FileManager.default.temporaryDirectory, timeout: 3)
                    }.value
                    var next: [Int32: String] = [:]
                    for line in (result?.output ?? "").split(separator: "\n") {
                        let parts = line.split(whereSeparator: \.isWhitespace)
                        if parts.count == 3, let pid = Int32(parts[0]), let memory = Int(parts[2]) { next[pid] = "CPU \(parts[1])% · \(memory / 1024) MB" }
                    }
                    resources = next
                }
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            }
        }.confirmationDialog("Stop this session?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } })) {
            Button("Stop session", role: .destructive) { if let stopping { model.stopLiveSession(stopping) }; stopping = nil }
        }
    }
}

private struct SessionControlRow: View {
    @ObservedObject var session: TerminalSession
    let profile: String
    let attention: String?
    let resources: String?
    let open: () -> Void
    let stop: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.displayTitle).font(.headline).lineLimit(2)
                Spacer()
                Button("Open", action: open)
                if session.state.isRunning || session.state == .queued { Button(session.state == .queued ? "Cancel" : "Stop", action: stop) }
            }
            Text("\(URL(fileURLWithPath: session.projectPath).lastPathComponent) · \(profile) · \(session.agent.title)").foregroundStyle(.secondary)
            HStack {
                Text(session.pendingResumeID != nil && session.state == .idle ? "Restored" : session.state.description)
                if attention != nil { Text("Your turn").foregroundStyle(.orange) }
                if session.state.isRunning, !HostHealth.isProcessAlive(session.terminal.process.shellPid) { Text("Process no longer responds").foregroundStyle(.red) }
                Spacer()
                if let resources { Text(resources).font(.caption) }
            }
            Divider()
        }
    }
}

struct ProfileToolsView: View {
    @ObservedObject var model: HostModel
    @ObservedObject var center: ProductionCenter
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Account profiles").font(.title2)
            Text("Each profile has separate Claude and Codex logins, settings, and conversation history. Existing sessions keep their original profile.")
                .foregroundStyle(.secondary)
            Text("Profiles share your macOS account and its filesystem permissions.").font(.caption).foregroundStyle(.secondary)
            ForEach(center.profiles) { profile in
                HStack {
                    Text(profile.name).font(.headline)
                    Spacer()
                    if model.selectedProfileID == profile.id { Text("Active").foregroundStyle(.secondary) }
                    else { Button("Use profile") { model.selectProfile(profile.id) } }
                    Button("Open folder") {
                        let path = center.base(for: profile.id)
                        do { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); NSWorkspace.shared.open(path) }
                        catch { self.error = error.localizedDescription }
                    }
                }.padding(.vertical, 6)
            }
            Divider()
            HStack {
                TextField("Profile name, for example Work", text: $name)
                Button("Create profile") {
                    do { let profile = try center.addProfile(name: name); model.selectProfile(profile.id); name = ""; error = nil }
                    catch { self.error = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("Choose the provider in the toolbar, then Log in to connect an account to the active profile.").font(.callout).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            Spacer()
        }
    }
}

struct SetupToolsView: View {
    @ObservedObject var model: HostModel
    let onLogin: () -> Void
    @State private var checks: [SetupCheck] = []
    @State private var busy = false
    @State private var report = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Setup and repair").font(.title2)
            Text("\(model.selected.title) · \(model.production.name(for: model.selectedProfileID))").foregroundStyle(.secondary)
            HStack {
                Button("Check setup") { Task { await inspect() } }.disabled(busy)
                Button("Log in") { model.showLogin(); onLogin() }
                Button("Choose project") { model.addProject(); checks = []; report = "" }
                if busy { ProgressView().controlSize(.small) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(checks) { check in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(check.id, systemImage: check.passed ? "checkmark.circle" : "exclamationmark.circle").font(.headline)
                            Text(check.summary).textSelection(.enabled)
                            if !check.passed { Text(check.action).font(.callout).foregroundStyle(.secondary) }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !report.isEmpty {
                Text("Diagnostic report preview").font(.headline)
                ReadOnlyLog(text: report).frame(height: 140)
                Button("Save report…") {
                    let panel = NSSavePanel(); panel.nameFieldStringValue = "m4ix-diagnostics.txt"
                    if panel.runModal() == .OK, let url = panel.url {
                        do { try report.write(to: url, atomically: true, encoding: .utf8) } catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }.task(id: "\(model.selectedProfileID):\(model.selected.rawValue):\(model.workingDirectory.path)") { await inspect() }
    }
    private func inspect() async {
        guard !busy else { return }
        busy = true
        let agent = model.selected; let profile = model.profileBase; let directory = model.workingDirectory
        checks = await Task.detached(priority: .utility) { SetupInspector.check(agent: agent, profileBase: profile, project: directory) }.value
        report = SetupInspector.diagnosticReport(checks: checks, activeSessions: model.activeSessionCount, queuedSessions: model.queuedSessions.count)
        busy = false
    }
}

struct UpdateToolsView: View {
    @ObservedObject var model: HostModel
    @State private var candidate: URL?
    @State private var version = ""
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Updates and recovery").font(.title2)
            Text("Install a local app package after this app quits. The installer retains the previous app, and settings are backed up before the update.")
                .foregroundStyle(.secondary)
            Text("Local builds use ad hoc signing. Choose a package from a source you trust.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Choose app package…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
                    panel.allowedContentTypes = [.applicationBundle]
                    if panel.runModal() == .OK, let url = panel.url { inspect(url) }
                }
                Button("Previous app versions") { open("updates/versions") }
                if busy { ProgressView().controlSize(.small) }
            }.disabled(busy)
            if let candidate {
                Text("Selected: m4ix.CLI \(version)").font(.headline)
                Text(candidate.path).font(.caption).textSelection(.enabled)
                Button("Back up and install on quit") {
                    busy = true
                    let root = model.dataRoot
                    let preferences = model.savedPreferences
                    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
                    model.production.flush(); model.verification.flush()
                    Task {
                        do {
                            let staged = try await Task.detached(priority: .utility) {
                                _ = try AppUpdates.backup(root: root, preferences: preferences, version: currentVersion)
                                return try AppUpdates.stage(candidate, root: root)
                            }.value
                            model.pendingUpdate = staged
                            note = "Update prepared. It will install after you quit the app."
                            error = nil
                        } catch { self.error = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy)
            }
            if model.pendingUpdate != nil { Button("Cancel pending update") { model.pendingUpdate = nil; note = "The pending installation was cancelled." } }
            Divider()
            Text("Rollback").font(.headline)
            Text("Open Previous app versions, choose a retained app with Choose app package, then install it on quit. Saved-data snapshots are kept separately from provider credentials.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Open data backups") { open("updates/backups") }
                Button("Open installer log") { open("updates") }
            }
            if let note { Text(note) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Spacer()
        }
    }
    private func inspect(_ url: URL) {
        busy = true
        Task {
            do { version = try await Task.detached { try AppUpdates.inspectApplication(url) }.value; candidate = url; error = nil }
            catch { self.error = error.localizedDescription; candidate = nil }
            busy = false
        }
    }
    private func open(_ component: String) {
        let url = model.dataRoot.appendingPathComponent(component)
        do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); NSWorkspace.shared.open(url) }
        catch { self.error = error.localizedDescription }
    }
}
