import AppKit
import Combine
import Darwin
import Foundation
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

private enum Agent: String, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var mark: PixelSprite { self == .claude ? .claude : .codex }
}

private enum TerminalAction: String {
    case run
    case login
    case resume

    var title: String { self == .login ? "Login" : "CLI" }
}

private enum TerminalState: Equatable {
    case idle
    case running(TerminalAction)
    case stopping
    case exited(Int32?)
    case failed(String)

    var description: String {
        switch self {
        case .idle: return "Not started"
        case .running(let action): return "\(action.title) running"
        case .stopping: return "Stopping"
        case .exited(let code):
            if let code { return code == 0 ? "Finished" : "Exited (\(code))" }
            return "Stopped"
        case .failed: return "Could not start"
        }
    }

    var isRunning: Bool {
        switch self {
        case .running, .stopping: return true
        default: return false
        }
    }
}

enum HostPaths {
    static let profileBase: URL = {
        if let override = ProcessInfo.processInfo.environment["PRIVATE_CLI_HOST_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Private CLI Host", isDirectory: true)
    }()

    static let launcher: URL? = {
        if let url = Bundle.main.url(forResource: "agent-launcher", withExtension: "sh") { return url }
        if let url = Bundle.main.url(forResource: "agent-launcher", withExtension: "sh", subdirectory: "Resources") { return url }
        // SwiftPM places resources in a sibling bundle when running `swift run`.
        let module = Bundle.module
        if let url = module.url(forResource: "agent-launcher", withExtension: "sh") { return url }
        if let url = module.url(forResource: "agent-launcher", withExtension: "sh", subdirectory: "Resources") { return url }
        return nil
    }()
}

/// Tracks keystrokes sent to the CLI so the heartbeat can tell a quiet
/// session from one that stopped answering.
private final class TrackedTerminalView: LocalProcessTerminalView {
    let activity = TerminalActivityClock()
    /// Hands images from ⌘V to the prompt bar. SwiftTerm pastes only text,
    /// so an image would otherwise paste as nothing.
    var onPasteImages: (([PromptImage]) -> Void)?

    override func paste(_ sender: Any) {
        let images = PromptImageStore.images(from: .general, isPaste: true)
        guard !images.isEmpty, let onPasteImages else { return super.paste(sender) }
        onPasteImages(images)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        activity.markInput()
        super.send(source: source, data: data)
    }
}

@MainActor
private final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let agent: Agent
    let projectPath: String
    let startedAt = Date()
    let initialPrompt: String?
    let terminal: TrackedTerminalView
    let profileDirectory: URL

    @Published private(set) var displayTitle: String
    @Published private(set) var state: TerminalState = .idle
    @Published private(set) var accountStatus = "Checking account"
    @Published private(set) var launchedDirectory: URL?
    @Published private(set) var activeConversationID: String?
    @Published private(set) var codexSessionIDPrefix: String?
    /// A conversation restored from the previous launch, resumed when first shown.
    @Published private(set) var pendingResumeID: String?
    @Published private(set) var isWorking = false
    /// Whether the CLI's own input line holds the screen, so the prompt
    /// bar can type into it. Refreshed once a second while shown.
    @Published private(set) var acceptsPromptText = false
    var onCodexIdentityPrefix: (() -> Void)?
    /// The last moment this session was on screen in the active app.
    var lastSeen: Date?
    private var accountStatusGeneration = 0
    private var turns = TurnDetector()
    private var pendingNotification: String?
    private var oscObservation: TerminalOscObservation?
    private var queuedPrompt: (text: String, images: [URL])?
    @Published private(set) var isSendingPrompt = false
    private var promptTask: Task<Void, Never>?

    init(agent: Agent, projectPath: String, title: String, initialPrompt: String? = nil,
         pendingResumeID: String? = nil) {
        self.agent = agent
        self.projectPath = projectPath
        self.displayTitle = title
        self.initialPrompt = initialPrompt
        self.pendingResumeID = pendingResumeID?.lowercased()
        self.profileDirectory = HostPaths.profileBase.appendingPathComponent(agent.rawValue, isDirectory: true)
        self.terminal = TrackedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        super.init()

        let activity = terminal.activity
        terminal.setProcessOutputHandler { activity.markOutput() }

        terminal.processDelegate = self
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.lineSpacing = 1.2
        terminal.nativeForegroundColor = ElevateTheme.terminalForeground
        terminal.nativeBackgroundColor = ElevateTheme.terminalBackground
        terminal.caretColor = ElevateTheme.nsSignal
        terminal.bellStyle = .none
        hideCaret()

        oscObservation = terminal.observeOscEvents { [weak self] event in
            guard let message = TerminalAttention.notification(oscCode: event.code, payload: event.payload) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.pendingNotification = message }
            }
        }
    }

    /// Advances the turn detector. Returns true when a turn has just ended.
    func updateActivity(now: Date) -> Bool {
        guard state.isRunning else { return false }
        let ended = turns.update(outputAge: terminal.activity.outputAge(now: now), now: now)
        if isWorking != turns.isWorking { isWorking = turns.isWorking }
        return ended
    }

    func takeNotification() -> String? {
        defer { pendingNotification = nil }
        return pendingNotification
    }

    /// Claude repeats "waiting for your input" a minute after a turn ends.
    /// Once that turn has been looked at, the reminder is noise.
    var wasSeenSinceLastTurn: Bool {
        guard !turns.isWorking, let lastSeen, let ended = turns.lastWorkEnded else { return false }
        return lastSeen >= ended
    }

    /// SwiftTerm shows its caret at the top-left before any process runs.
    /// Keep it hidden until a CLI asks for it: Codex shows the terminal
    /// cursor itself, and Claude draws its own.
    private func hideCaret() {
        terminal.feed(text: "\u{1b}[?25l")
    }

    func launch(_ action: TerminalAction, in directory: URL, sessionID: String? = nil, initialPrompt: String? = nil) {
        if action == .resume, sessionID.flatMap(UUID.init(uuidString:)) == nil {
            return
        }
        guard state == .idle else { return }
        start(action, in: directory, sessionID: sessionID, initialPrompt: initialPrompt)
    }

    var restorableConversationID: String? {
        state.isRunning ? activeConversationID : pendingResumeID
    }

    /// A running conversation, as opposed to a login or no process.
    var hostsConversation: Bool {
        if case .running(let action) = state { return action != .login }
        return false
    }

    var hasQueuedPrompt: Bool { queuedPrompt != nil }

    /// Holds a prompt for a conversation that is still starting. It is sent
    /// once the CLI's input line has held the screen for a full tick.
    func queuePrompt(_ text: String, images: [URL]) {
        queuedPrompt = (text, images)
    }

    func refreshPromptReadiness() {
        let wasReady = acceptsPromptText
        let ready = screenAcceptsText()
        if acceptsPromptText != ready { acceptsPromptText = ready }
        if wasReady, ready, let queued = queuedPrompt {
            queuedPrompt = nil
            _ = sendPrompt(queued.text, images: queued.images)
        }
    }

    /// Types `text` and any images into the CLI's prompt, then submits it.
    /// Sends nothing and returns false while a menu or dialog holds the screen.
    func sendPrompt(_ text: String, images: [URL] = []) -> Bool {
        let ready = screenAcceptsText()
        if acceptsPromptText != ready { acceptsPromptText = ready }
        guard ready, !isSendingPrompt else { return false }
        isSendingPrompt = true
        let bracketed = terminal.terminalStateSnapshot().bracketedPasteMode
        promptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSendingPrompt = false; self.promptTask = nil }
            await self.type(text, images: images, bracketed: bracketed)
        }
        return true
    }

    /// Attaches the images, then types the text. Return goes last, and only
    /// onto the input line.
    private func type(_ text: String, images: [URL], bracketed: Bool) async {
        guard await attach(images, bracketed: bracketed) else { return }
        // Claude does not space text away from the last image marker.
        if !text.isEmpty {
            let body = images.isEmpty ? text : " " + text
            terminal.send(data: CLIPrompt.pasteBytes(body, bracketed: bracketed)[...])
        }
        try? await Task.sleep(nanoseconds: UInt64(CLIPrompt.returnDelay * 1_000_000_000))
        // A dialog can open in the gap; Return would answer it.
        guard !Task.isCancelled, screenAcceptsText() else { return }
        terminal.send(data: [0x0d][...])
    }

    /// Pastes each image path and waits for the CLI to attach it before the
    /// next one.
    private func attach(_ images: [URL], bracketed: Bool) async -> Bool {
        var attached = CLIPrompt.imageMarkers(in: CLIPrompt.liveScreen(of: terminal))
        for image in images {
            guard !Task.isCancelled, screenAcceptsText() else { return false }
            terminal.send(data: CLIPrompt.pasteBytes(image.path, bracketed: bracketed)[...])
            attached += 1
            guard await waitForImageMarkers(attached) else {
                HostDiagnostics.record("prompt_image_timeout", agent: agent.rawValue, session: id)
                return false
            }
        }
        return true
    }

    private func waitForImageMarkers(_ count: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(CLIPrompt.imageTimeout)
        while Date() < deadline {
            guard !Task.isCancelled, hostsConversation else { return false }
            if CLIPrompt.imageMarkers(in: CLIPrompt.liveScreen(of: terminal)) >= count { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func screenAcceptsText() -> Bool {
        guard hostsConversation else { return false }
        let screen = CLIPrompt.liveScreen(of: terminal)
        switch agent {
        case .claude: return CLIPrompt.claudeAcceptsText(screen: screen)
        case .codex: return CLIPrompt.codexAcceptsText(screen: screen)
        }
    }

    func startIfPending() {
        guard state == .idle, let id = pendingResumeID else { return }
        pendingResumeID = nil
        let directory = URL(fileURLWithPath: projectPath, isDirectory: true)
        launch(.resume, in: directory, sessionID: id)
        refreshAccountStatus(in: directory)
    }

    func stop() {
        guard case .running = state else { return }
        promptTask?.cancel()
        queuedPrompt = nil
        HostDiagnostics.record("session_stop_requested", agent: agent.rawValue, session: id)
        state = .stopping
        let pid = terminal.process.shellPid
        terminal.terminate()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self,
                  self.state == .stopping,
                  pid > 0,
                  self.terminal.process.running,
                  self.terminal.process.shellPid == pid else { return }
            HostDiagnostics.record("session_stop_escalated", agent: self.agent.rawValue, session: self.id)
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    func updateTitle(_ title: String) {
        displayTitle = title
    }

    func bindConversationID(_ sessionID: String) {
        guard UUID(uuidString: sessionID) != nil else { return }
        activeConversationID = sessionID.lowercased()
        HostDiagnostics.record("session_identity_bound", agent: agent.rawValue, session: id)
    }

    private func start(_ action: TerminalAction, in directory: URL, sessionID: String?, initialPrompt: String?) {
        guard let launcher = HostPaths.launcher else {
            let message = "Bundled agent-launcher.sh is missing. Rebuild the app with its Resources folder."
            state = .failed(message)
            terminal.feed(text: "\r\n\(message)\r\n")
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            let message = "Working folder is unavailable: \(directory.path)"
            state = .failed(message)
            terminal.feed(text: "\r\n\(message)\r\n")
            return
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PRIVATE_CLI_HOST_DATA_DIR"] = HostPaths.profileBase.path
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        launchedDirectory = directory
        activeConversationID = sessionID?.lowercased()
        HostDiagnostics.record("session_start_requested", agent: agent.rawValue, session: id)
        state = .running(action)
        var arguments = [launcher.path, agent.rawValue, action.rawValue]
        if let sessionID {
            if action == .run, agent == .claude {
                arguments += ["--session-id", sessionID]
            } else if action == .resume {
                arguments.append(sessionID)
            }
        }
        if let initialPrompt { arguments.append(initialPrompt) }
        terminal.startProcess(
            executable: "/bin/bash",
            args: arguments,
            environment: environment.map { "\($0.key)=\($0.value)" },
            currentDirectory: directory.path
        )
    }

    func refreshAccountStatus(in directory: URL) {
        guard let launcher = HostPaths.launcher else {
            accountStatus = "Launcher missing"
            return
        }
        accountStatusGeneration += 1
        let generation = accountStatusGeneration
        accountStatus = "Checking account"
        let agentName = agent.rawValue
        let profileBasePath = HostPaths.profileBase.path
        let workingPath = directory.path

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [launcher.path, agentName, "status"]
            process.currentDirectoryURL = URL(fileURLWithPath: workingPath, isDirectory: true)
            var environment = ProcessInfo.processInfo.environment
            environment["PRIVATE_CLI_HOST_DATA_DIR"] = profileBasePath
            process.environment = environment
            process.standardOutput = output
            process.standardError = output
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }

            let status: String
            do {
                try process.run()
                if finished.wait(timeout: .now() + 8) == .timedOut {
                    if process.isRunning { process.terminate() }
                    if finished.wait(timeout: .now() + 2) == .timedOut && process.isRunning {
                        _ = Darwin.kill(process.processIdentifier, SIGKILL)
                    }
                    status = "Account check timed out"
                } else {
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let lines = String(decoding: data, as: UTF8.self)
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    let summary = lines.prefix(2).joined(separator: " · ")
                    status = summary.isEmpty ? (process.terminationStatus == 0 ? "Account ready" : "Account unavailable") : String(summary.prefix(180))
                }
            } catch {
                status = "Could not check account"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.accountStatusGeneration == generation else { return }
                self.accountStatus = status
                if status == "Account check timed out" {
                    HostDiagnostics.record("account_status_timeout", agent: self.agent.rawValue, session: self.id)
                }
            }
        }
    }

    func openProfileInFinder() {
        do {
            try FileManager.default.createDirectory(
                at: profileDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            NSWorkspace.shared.open(profileDirectory)
        } catch {
            state = .failed("Could not open profile: \(error.localizedDescription)")
        }
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        guard agent == .codex,
              let prefix = CodexSessionIdentity.prefix(fromTerminalTitle: title),
              codexSessionIDPrefix != prefix else { return }
        codexSessionIDPrefix = prefix
        onCodexIdentityPrefix?()
    }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        HostDiagnostics.record("session_exited", agent: agent.rawValue, session: id, exitCode: exitCode)
        state = .exited(exitCode)
        promptTask?.cancel()
        queuedPrompt = nil
        acceptsPromptText = false
        turns.reset()
        isWorking = false
        hideCaret()
        refreshAccountStatus(in: launchedDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        HostDiagnostics.record("session_launch_failed", agent: agent.rawValue, session: id)
        state = .failed(String(describing: error))
    }
}

private struct ProjectRecord: Identifiable, Hashable {
    let path: String

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { url.lastPathComponent }
    var isAvailable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

@MainActor
private final class ProjectWorkspace {
    private var standby: [Agent: TerminalSession]
    private var live: [Agent: [TerminalSession]] = [:]
    private var selectedSessionIDs: [Agent: UUID] = [:]

    init(projectPath: String) {
        standby = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in
            (agent, TerminalSession(agent: agent, projectPath: projectPath, title: "Account"))
        })
    }

    func session(for agent: Agent) -> TerminalSession {
        if let id = selectedSessionIDs[agent],
           let session = live[agent]?.first(where: { $0.id == id }) {
            return session
        }
        return standbySession(for: agent)
    }

    func standbySession(for agent: Agent) -> TerminalSession {
        standby[agent]!
    }

    func sessionForLogin(for agent: Agent) -> TerminalSession {
        let current = standbySession(for: agent)
        if current.state == .idle || current.state.isRunning { return current }
        let replacement = TerminalSession(agent: agent, projectPath: current.projectPath, title: "Account")
        standby[agent] = replacement
        return replacement
    }

    func liveSessions(for agent: Agent) -> [TerminalSession] {
        live[agent] ?? []
    }

    var hasVisibleSessions: Bool {
        live.values.contains { !$0.isEmpty } || standby.values.contains { $0.state.isRunning }
    }

    var allSessions: [TerminalSession] {
        Array(standby.values) + live.values.flatMap { $0 }
    }

    var allLiveSessions: [TerminalSession] {
        live.values.flatMap { $0 }
    }

    @discardableResult
    func createConversation(for agent: Agent, title: String, initialPrompt: String? = nil) -> TerminalSession {
        let session = TerminalSession(agent: agent, projectPath: standbySession(for: agent).projectPath,
                                      title: title, initialPrompt: initialPrompt)
        live[agent, default: []].insert(session, at: 0)
        selectedSessionIDs[agent] = session.id
        return session
    }

    func restoreConversation(for agent: Agent, title: String, conversationID: String, selected: Bool) {
        guard liveSession(for: agent, conversationID: conversationID) == nil else { return }
        let session = TerminalSession(agent: agent, projectPath: standbySession(for: agent).projectPath,
                                      title: title, pendingResumeID: conversationID)
        live[agent, default: []].append(session)
        if selected { selectedSessionIDs[agent] = session.id }
    }

    func isSelected(_ session: TerminalSession, for agent: Agent) -> Bool {
        selectedSessionIDs[agent] == session.id
    }

    func select(_ session: TerminalSession, for agent: Agent) -> Bool {
        guard live[agent]?.contains(where: { $0.id == session.id }) == true else { return false }
        selectedSessionIDs[agent] = session.id
        return true
    }

    func selectStandby(for agent: Agent) {
        selectedSessionIDs.removeValue(forKey: agent)
    }

    func remove(_ session: TerminalSession, for agent: Agent) -> Bool {
        guard !session.state.isRunning,
              live[agent]?.contains(where: { $0.id == session.id }) == true else { return false }
        live[agent]?.removeAll { $0.id == session.id }
        if selectedSessionIDs[agent] == session.id {
            selectedSessionIDs[agent] = live[agent]?.first?.id
        }
        return true
    }

    func liveSession(for agent: Agent, conversationID: String) -> TerminalSession? {
        liveSessions(for: agent).first {
            $0.restorableConversationID?.lowercased() == conversationID.lowercased()
        }
    }

    func reconcileHistory(_ records: [ConversationRecord]) {
        for agent in Agent.allCases {
            let relevant = records.filter {
                $0.provider == agent.rawValue && $0.projectPath == standbySession(for: agent).projectPath
            }
            for session in liveSessions(for: agent) {
                if session.activeConversationID == nil,
                   let prefix = session.codexSessionIDPrefix,
                   let match = CodexSessionIdentity.uniqueMatch(prefix: prefix, in: relevant.map(\.sessionID)) {
                    session.bindConversationID(match)
                }
                if let id = session.activeConversationID,
                   let record = relevant.first(where: { $0.sessionID.caseInsensitiveCompare(id) == .orderedSame }),
                   !record.title.isEmpty {
                    session.updateTitle(record.title)
                }
            }
        }
    }
}

@MainActor
private final class HostModel: ObservableObject {
    @Published var selected: Agent = .claude
    @Published private(set) var workingDirectory: URL
    @Published private(set) var projects: [ProjectRecord]
    @Published private(set) var conversations: [ConversationRecord] = []
    @Published private(set) var sessionRevision = 0
    /// Live sessions that finished a turn or asked for input while out of
    /// view, with the CLI's message when it sent one.
    @Published private(set) var attention: [UUID: String] = [:] {
        didSet { AttentionNotifier.setBadge(attention.count) }
    }

    private var workspaces: [String: ProjectWorkspace] = [:]
    private var savedProjectPaths: [String]
    private var hiddenProjectPaths: Set<String>
    private var historyRefreshInFlight = false
    private var historyRefreshPending = false
    private var historyLoaded = false

    private static let directoryPreferenceKey = "PrivateCLIHostWorkingDirectory"
    private static let projectsPreferenceKey = "PrivateCLIHostProjects"
    private static let hiddenProjectsPreferenceKey = "PrivateCLIHostHiddenProjects"
    private static let restorableSessionsPreferenceKey = "PrivateCLIHostRestorableSessions"

    init() {
        let defaults = UserDefaults.standard
        let previousSelection = defaults.string(forKey: Self.directoryPreferenceKey).map(Self.normalizedPath)
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let rawSaved = defaults.stringArray(forKey: Self.projectsPreferenceKey) ?? [previousSelection ?? home]
        var saved = Array(NSOrderedSet(array: rawSaved.map(Self.normalizedPath))) as? [String] ?? []
        if let previousSelection, !saved.contains(previousSelection) { saved.append(previousSelection) }
        let initialPath = previousSelection ?? saved.first ?? home

        self.savedProjectPaths = saved.isEmpty ? [initialPath] : saved
        self.hiddenProjectPaths = Set(defaults.stringArray(forKey: Self.hiddenProjectsPreferenceKey) ?? [])
        self.workingDirectory = URL(fileURLWithPath: initialPath, isDirectory: true)
        self.projects = self.savedProjectPaths.map(ProjectRecord.init(path:))
        self.workspaces[initialPath] = ProjectWorkspace(projectPath: initialPath)
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    var currentWorkspace: ProjectWorkspace { workspace(for: workingDirectory.path) }

    private func workspace(for path: String) -> ProjectWorkspace {
        if let workspace = workspaces[path] { return workspace }
        let workspace = ProjectWorkspace(projectPath: path)
        workspaces[path] = workspace
        return workspace
    }

    var currentSession: TerminalSession { currentWorkspace.session(for: selected) }
    var loginSession: TerminalSession { currentWorkspace.standbySession(for: selected) }
    var isCurrentProjectAvailable: Bool { ProjectRecord(path: workingDirectory.path).isAvailable }

    func liveSessionsForCurrentProject() -> [TerminalSession] {
        currentWorkspace.liveSessions(for: selected)
    }

    func isSelected(_ session: TerminalSession) -> Bool {
        currentSession.id == session.id
    }

    func selectLiveSession(_ session: TerminalSession) {
        guard currentWorkspace.select(session, for: selected) else { return }
        sessionRevision += 1
    }

    /// Starts the shown session if it was restored from the previous launch.
    /// Restored sessions in other projects wait until they are shown.
    func startCurrentIfPending() {
        guard isCurrentProjectAvailable else { return }
        currentSession.startIfPending()
    }

    /// Saves live conversations that exist in history, so a quit or a crash
    /// can be picked up where it stopped. Stopped sessions are not kept.
    func saveRestorableSessions() {
        guard historyLoaded else { return }
        let known = Set(conversations.map { "\($0.provider):\($0.sessionID.lowercased())" })
        var entries: [[String: Any]] = []
        for (path, workspace) in workspaces {
            for agent in Agent.allCases {
                for session in workspace.liveSessions(for: agent) {
                    guard let id = session.restorableConversationID?.lowercased(),
                          known.contains("\(agent.rawValue):\(id)") else { continue }
                    entries.append([
                        "project": path,
                        "agent": agent.rawValue,
                        "conversation": id,
                        "title": session.displayTitle,
                        "selected": workspace.isSelected(session, for: agent)
                    ])
                }
            }
        }
        UserDefaults.standard.set(entries, forKey: Self.restorableSessionsPreferenceKey)
    }

    func restoreSessions() {
        let entries = UserDefaults.standard.array(forKey: Self.restorableSessionsPreferenceKey) as? [[String: Any]] ?? []
        var restored = 0
        for entry in entries {
            guard let path = entry["project"] as? String,
                  let agent = (entry["agent"] as? String).flatMap(Agent.init(rawValue:)),
                  let id = entry["conversation"] as? String,
                  UUID(uuidString: id) != nil,
                  ProjectRecord(path: path).isAvailable else { continue }
            workspace(for: path).restoreConversation(
                for: agent,
                title: entry["title"] as? String ?? "Restored conversation",
                conversationID: id,
                selected: entry["selected"] as? Bool ?? false
            )
            restored += 1
        }
        if restored > 0 {
            HostDiagnostics.record("sessions_restored", details: ["count": restored])
            sessionRevision += 1
        }
    }

    private var periodicTimers: [Timer] = []

    /// Timers live on the model: a publisher created in a view body is
    /// replaced on every redraw and can restart before it fires.
    func startPeriodicWork() {
        guard periodicTimers.isEmpty else { return }
        let history = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshHistory()
                self?.saveRestorableSessions()
            }
        }
        let heartbeat = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordHeartbeat() }
        }
        let activity = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAttention() }
        }
        for timer in [history, heartbeat, activity] { RunLoop.main.add(timer, forMode: .common) }
        periodicTimers = [history, heartbeat, activity]
    }

    // MARK: Attention

    private var isShowingCurrentSession: Bool { NSApp.isActive }

    /// Once a second: note what is on screen, then collect finished turns and
    /// CLI notifications from every live session.
    func updateAttention() {
        let now = Date()
        if isShowingCurrentSession { currentSession.lastSeen = now }
        currentSession.refreshPromptReadiness()
        for workspace in workspaces.values {
            for session in workspace.allLiveSessions {
                if session.hasQueuedPrompt && session.id != currentSession.id {
                    session.refreshPromptReadiness()
                }
                if session.updateActivity(now: now) {
                    raiseAttention(session, message: nil, source: "turn_ended")
                }
                if let message = session.takeNotification(), !session.wasSeenSinceLastTurn {
                    raiseAttention(session, message: message, source: "cli_notification")
                }
            }
        }
    }

    private func raiseAttention(_ session: TerminalSession, message: String?, source: String) {
        if isShowingCurrentSession && session.id == currentSession.id { return }
        let isNew = attention[session.id] == nil
        if let message, !message.isEmpty {
            attention[session.id] = message
        } else if isNew {
            attention[session.id] = ""
        }
        guard isNew else { return }
        HostDiagnostics.record("attention_raised", agent: session.agent.rawValue, session: session.id,
                               details: ["source": source])
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        let body = attention[session.id].flatMap { $0.isEmpty ? nil : $0 } ?? "Waiting for you."
        AttentionNotifier.post(sessionID: session.id, title: "\(session.agent.title) · \(session.displayTitle)", body: body)
    }

    func clearVisibleAttention() {
        guard isShowingCurrentSession else { return }
        currentSession.lastSeen = Date()
        clearAttention(for: currentSession.id)
    }

    private func clearAttention(for id: UUID) {
        guard attention.removeValue(forKey: id) != nil else { return }
        AttentionNotifier.withdraw(sessionID: id)
    }

    func attentionMessage(for session: TerminalSession) -> String? {
        attention[session.id]
    }

    func needsAttention(project path: String, agent: Agent? = nil) -> Bool {
        guard !attention.isEmpty, let workspace = workspaces[path] else { return false }
        return Agent.allCases.contains { candidate in
            (agent == nil || agent == candidate)
                && workspace.liveSessions(for: candidate).contains { attention[$0.id] != nil }
        }
    }

    /// Shows a live session from anywhere in the app, as when its
    /// notification is clicked.
    func reveal(sessionID: UUID) {
        for (path, workspace) in workspaces {
            for agent in Agent.allCases {
                guard let session = workspace.liveSessions(for: agent).first(where: { $0.id == sessionID }) else { continue }
                selectProject(ProjectRecord(path: path))
                selected = agent
                if workspace.select(session, for: agent) { sessionRevision += 1 }
                return
            }
        }
    }

    /// One line a minute describing every running CLI, without paths or text.
    func recordHeartbeat() {
        var sessions: [[String: Any]] = []
        for workspace in workspaces.values {
            for session in workspace.allSessions where session.state.isRunning {
                let pid = session.terminal.process.shellPid
                let since = session.terminal.activity.secondsSince()
                var item: [String: Any] = [
                    "agent": session.agent.rawValue,
                    "hostSession": session.id.uuidString.lowercased(),
                    "alive": HostHealth.isProcessAlive(pid),
                    "minutes": Int(Date().timeIntervalSince(session.startedAt) / 60)
                ]
                if let output = since.output { item["quietSeconds"] = output }
                if let input = since.input { item["sinceInputSeconds"] = input }
                sessions.append(item)
            }
        }
        var details: [String: Any] = ["sessions": sessions]
        if let memory = HostHealth.residentMemoryMB() { details["memoryMB"] = memory }
        HostDiagnostics.record("heartbeat", details: details)
    }

    /// The prompt bar types into the session on screen while its CLI runs,
    /// and starts a new conversation when none is running.
    func submitPrompt(_ text: String, images: [URL]) -> Bool {
        let session = currentSession
        if session.hostsConversation { return session.sendPrompt(text, images: images) }
        return startNewConversation(initialPrompt: text, images: images)
    }

    @discardableResult
    func startNewConversation(initialPrompt: String? = nil, images: [URL] = []) -> Bool {
        guard isCurrentProjectAvailable, HostPaths.launcher != nil else { return false }
        let firstLine = initialPrompt?
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = firstLine.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "New conversation"
        // A CLI argument cannot carry images, so a prompt with images waits
        // for the input line and is typed in like any other.
        let argument = images.isEmpty ? initialPrompt : nil
        let session = currentWorkspace.createConversation(for: selected, title: title, initialPrompt: argument)
        if selected == .codex {
            session.onCodexIdentityPrefix = { [weak self] in self?.refreshHistory() }
        }
        sessionRevision += 1
        let newID = selected == .claude ? UUID().uuidString.lowercased() : nil
        session.launch(.run, in: workingDirectory, sessionID: newID, initialPrompt: argument)
        if !images.isEmpty { session.queuePrompt(initialPrompt ?? "", images: images) }
        session.refreshAccountStatus(in: workingDirectory)
        refreshHistory()
        if case .failed = session.state { return false }
        return true
    }

    func openConversation(_ record: ConversationRecord) {
        guard isCurrentProjectAvailable,
              record.provider == selected.rawValue,
              record.projectPath == workingDirectory.path else { return }
        currentWorkspace.reconcileHistory(conversations)
        if let running = currentWorkspace.liveSession(for: selected, conversationID: record.sessionID) {
            selectLiveSession(running)
            return
        }
        let session = currentWorkspace.createConversation(for: selected, title: record.title)
        sessionRevision += 1
        session.launch(.resume, in: workingDirectory, sessionID: record.sessionID)
        session.refreshAccountStatus(in: workingDirectory)
        saveRestorableSessions()
    }

    func hasUnidentifiedRunningCodexSession() -> Bool {
        guard selected == .codex else { return false }
        currentWorkspace.reconcileHistory(conversations)
        return currentWorkspace.liveSessions(for: .codex).contains {
            $0.state.isRunning && $0.activeConversationID == nil
        }
    }

    func showLogin() {
        guard isCurrentProjectAvailable else { return }
        let session = currentWorkspace.sessionForLogin(for: selected)
        currentWorkspace.selectStandby(for: selected)
        sessionRevision += 1
        if !session.state.isRunning {
            session.launch(.login, in: workingDirectory)
        }
    }

    func stopLiveSession(_ session: TerminalSession) {
        guard currentWorkspace.liveSessions(for: selected).contains(where: { $0.id == session.id }) else { return }
        session.stop()
    }

    func removeLiveSession(_ session: TerminalSession) {
        if currentWorkspace.remove(session, for: selected) {
            clearAttention(for: session.id)
            sessionRevision += 1
            saveRestorableSessions()
        }
    }

    func stopAllSessions() {
        for workspace in workspaces.values {
            for session in workspace.allSessions {
                session.stop()
            }
        }
    }

    var hasRunningSessions: Bool {
        workspaces.values.contains { workspace in
            workspace.allSessions.contains { $0.state.isRunning }
        }
    }

    func forceStopRemainingSessions() {
        for workspace in workspaces.values {
            for session in workspace.allSessions where session.state.isRunning {
                let pid = session.terminal.process.shellPid
                guard pid > 0, session.terminal.process.running else { continue }
                HostDiagnostics.record("session_stop_escalated_on_quit", agent: session.agent.rawValue, session: session.id)
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }

    func refreshCurrentAccountStatus() {
        let directory = isCurrentProjectAvailable ? workingDirectory : FileManager.default.homeDirectoryForCurrentUser
        currentSession.refreshAccountStatus(in: directory)
    }

    func selectProject(_ project: ProjectRecord) {
        guard project.path != workingDirectory.path else { return }
        if !savedProjectPaths.contains(project.path) {
            savedProjectPaths.append(project.path)
            saveProjectPreferences()
            rebuildProjects()
        }
        workingDirectory = project.url
        UserDefaults.standard.set(project.path, forKey: Self.directoryPreferenceKey)
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Add a project"
        panel.message = "Choose the folder where Claude and Codex should work."
        panel.prompt = "Add Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = workingDirectory
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        let path = picked.standardizedFileURL.path
        if !savedProjectPaths.contains(path) { savedProjectPaths.append(path) }
        hiddenProjectPaths.remove(path)
        saveProjectPreferences()
        rebuildProjects()
        selectProject(ProjectRecord(path: path))
    }

    func removeProject(_ project: ProjectRecord) {
        guard canRemoveProject(project) else { return }
        savedProjectPaths.removeAll { $0 == project.path }
        hiddenProjectPaths.insert(project.path)
        workspaces.removeValue(forKey: project.path)
        rebuildProjects()
        if projects.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
            savedProjectPaths.append(home)
            hiddenProjectPaths.remove(home)
            rebuildProjects()
        }
        if project.path == workingDirectory.path, let next = projects.first {
            selectProject(next)
        }
        saveProjectPreferences()
    }

    func canRemoveProject(_ project: ProjectRecord) -> Bool {
        workspaces[project.path]?.hasVisibleSessions != true
    }

    func revealProject(_ project: ProjectRecord) {
        NSWorkspace.shared.open(project.url)
    }

    func refreshHistory() {
        if historyRefreshInFlight {
            historyRefreshPending = true
            return
        }
        historyRefreshInFlight = true
        let profileBase = HostPaths.profileBase
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let records = ConversationHistoryLoader.load(profileBase: profileBase)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.historyRefreshInFlight = false
                for workspace in self.workspaces.values {
                    workspace.reconcileHistory(records)
                }
                self.conversations = records
                self.historyLoaded = true
                self.rebuildProjects()
                if self.historyRefreshPending {
                    self.historyRefreshPending = false
                    self.refreshHistory()
                }
            }
        }
    }

    func conversationsForCurrentProject() -> [ConversationRecord] {
        conversations.filter { $0.provider == selected.rawValue && $0.projectPath == workingDirectory.path }
    }

    private func rebuildProjects() {
        let recency = Dictionary(grouping: conversations, by: \.projectPath)
            .mapValues { $0.map(\.updatedAt).max() ?? .distantPast }
        let saved = savedProjectPaths.filter { !hiddenProjectPaths.contains($0) }
        let discovered = recency.keys
            .filter { !saved.contains($0) && !hiddenProjectPaths.contains($0) }
            .sorted { recency[$0, default: .distantPast] > recency[$1, default: .distantPast] }
        projects = (saved + discovered).map(ProjectRecord.init(path:))
    }

    private func saveProjectPreferences() {
        UserDefaults.standard.set(savedProjectPaths, forKey: Self.projectsPreferenceKey)
        UserDefaults.standard.set(Array(hiddenProjectPaths), forKey: Self.hiddenProjectsPreferenceKey)
    }
}

private final class TerminalDeckView: NSView {
    var onPasteImages: (([PromptImage]) -> Void)?
    private var shownTerminal: LocalProcessTerminalView?
    private var terminalConstraints: [NSLayoutConstraint] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ElevateTheme.terminalBackground.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let shownTerminal, window != nil {
            window?.makeFirstResponder(shownTerminal)
        }
    }

    func show(_ terminal: LocalProcessTerminalView) {
        (terminal as? TrackedTerminalView)?.onPasteImages = onPasteImages
        guard shownTerminal !== terminal || terminal.superview !== self else { return }
        NSLayoutConstraint.deactivate(terminalConstraints)
        shownTerminal?.removeFromSuperview()
        terminal.removeFromSuperview()
        shownTerminal = terminal
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        // The deck shares the terminal's background, so the inset reads as margin.
        terminalConstraints = [
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ElevateTheme.spacing24),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ElevateTheme.spacing16),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: ElevateTheme.spacing16),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ElevateTheme.spacing16)
        ]
        NSLayoutConstraint.activate(terminalConstraints)
        if window != nil { window?.makeFirstResponder(terminal) }
    }
}

private struct TerminalDeck: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    let onPasteImages: ([PromptImage]) -> Void

    func makeNSView(context: Context) -> TerminalDeckView {
        let view = TerminalDeckView(frame: .zero)
        view.onPasteImages = onPasteImages
        view.show(terminal)
        return view
    }

    func updateNSView(_ view: TerminalDeckView, context: Context) {
        view.onPasteImages = onPasteImages
        view.show(terminal)
    }
}

/// Follows the session on screen, so the composer knows whether its CLI
/// is running and whether a menu holds the screen.
private struct PromptBar: View {
    @ObservedObject var session: TerminalSession
    let text: Binding<String>
    let images: Binding<[PromptImage]>
    let focusRequest: Int
    let agentName: String
    let projectName: String
    let isEnabled: Bool
    let onSubmit: (String, [PromptImage]) -> Bool

    var body: some View {
        PromptComposer(
            text: text,
            images: images,
            focusRequest: focusRequest,
            mode: mode,
            agentName: agentName,
            projectName: projectName,
            isEnabled: isEnabled,
            onSubmit: onSubmit
        )
    }

    private var mode: PromptComposer.Mode {
        guard session.hostsConversation else { return .start }
        return session.acceptsPromptText && !session.isSendingPrompt ? .send : .blocked
    }
}

private struct WorkspaceBar: View {
    @ObservedObject var model: HostModel
    @ObservedObject var session: TerminalSession
    let sidebarVisible: Bool
    let onToggleSidebar: () -> Void
    let onNewConversation: () -> Void
    let onLogin: () -> Void
    let onHandoff: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ElevateTheme.ink)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            .padding(.trailing, ElevateTheme.spacing16)

            VStack(alignment: .leading, spacing: 3) {
                Text("WORKING IN")
                    .font(ElevateTheme.utility(10, medium: true))
                    .tracking(0.3)
                    .foregroundStyle(ElevateTheme.graphite)
                Text(model.workingDirectory.lastPathComponent)
                    .font(ElevateTheme.serif(24))
                    .foregroundStyle(ElevateTheme.ink)
                    .lineLimit(1)
                    .help(model.workingDirectory.path)
                Text("\(session.state.description) · \(session.accountStatus)")
                    .font(ElevateTheme.serif(11))
                    .foregroundStyle(ElevateTheme.graphite)
                    .lineLimit(1)
                    .help(session.accountStatus)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(Agent.allCases) { agent in
                    Button { model.selected = agent } label: {
                        let tint = model.selected == agent ? ElevateTheme.ink : ElevateTheme.graphite
                        HStack(spacing: ElevateTheme.spacing8) {
                            PixelMark(sprite: agent.mark, color: tint)
                            Text(agent.title.uppercased())
                                .font(ElevateTheme.utility(12, medium: true))
                                .foregroundStyle(tint)
                            if model.selected != agent,
                               model.needsAttention(project: model.workingDirectory.path, agent: agent) {
                                AttentionPixel()
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(minWidth: 72, minHeight: 44)
                        .contentShape(Rectangle())
                        .overlay(alignment: .bottom) {
                            if model.selected == agent {
                                Rectangle()
                                    .fill(ElevateTheme.ink)
                                    .frame(height: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(agent.title)
                    .accessibilityAddTraits(model.selected == agent ? [.isSelected] : [])
                }
            }
            .padding(.trailing, ElevateTheme.spacing24)

            Button(action: onNewConversation) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("NEW CONVERSATION")
                        .font(ElevateTheme.utility(11, medium: true))
                }
                .foregroundStyle(ElevateTheme.onSignal)
                .padding(.horizontal, ElevateTheme.spacing16)
                .frame(height: 44)
                .background(ElevateTheme.signal, in: RoundedRectangle(cornerRadius: ElevateTheme.controlRadius))
            }
            .buttonStyle(.plain)
            .disabled(!model.isCurrentProjectAvailable)
            .accessibilityLabel("New conversation")
            .keyboardShortcut("n", modifiers: .command)
            .padding(.trailing, ElevateTheme.spacing8)

            Menu {
                Button("Log in or view login") { onLogin() }
                    .disabled(!model.isCurrentProjectAvailable)
                Button("Check account status") {
                    session.refreshAccountStatus(in: model.isCurrentProjectAvailable
                        ? model.workingDirectory
                        : FileManager.default.homeDirectoryForCurrentUser)
                }
                Divider()
                Button("Hand off to \(model.selected == .claude ? "Codex" : "Claude")…", action: onHandoff)
                    .disabled(!session.hostsConversation)
                Divider()
                Button("Open private profile") { session.openProfileInFinder() }
                Button("Show diagnostics in Finder") { HostDiagnostics.revealInFinder() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(ElevateTheme.ink)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More session actions")
            .help("Session actions")
        }
        .padding(.horizontal, ElevateTheme.spacing24)
        .frame(height: 84)
        .background(ElevateTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ElevateTheme.border).frame(height: ElevateTheme.hairlineWidth)
        }
    }
}

private struct ProjectSidebar: View {
    @ObservedObject var model: HostModel
    let onSelectSession: (TerminalSession) -> Void
    let onStopSession: (TerminalSession) -> Void
    let onRemoveSession: (TerminalSession) -> Void
    let onOpenConversation: (ConversationRecord) -> Void

    @State private var searchText = ""

    private var visibleLiveSessions: [TerminalSession] {
        let sessions = model.liveSessionsForCurrentProject()
        guard !searchText.isEmpty else { return sessions }
        return sessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(searchText) }
    }

    private var visibleConversations: [ConversationRecord] {
        let runningIDs = Set(model.liveSessionsForCurrentProject().compactMap { session in
            session.restorableConversationID?.lowercased()
        })
        let records = model.conversationsForCurrentProject()
            .filter { !runningIDs.contains($0.sessionID.lowercased()) }
        guard !searchText.isEmpty else { return records }
        return records.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("m4ix.CLI")
                    .font(ElevateTheme.utility(14, medium: true))
                    .tracking(0.42)
                    .foregroundStyle(ElevateTheme.ink)
                Spacer()
            }
            .padding(.horizontal, ElevateTheme.spacing24)
            .frame(height: 84)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ElevateTheme.border).frame(height: ElevateTheme.hairlineWidth)
            }

            HStack {
                sectionLabel("PROJECTS")
                Spacer()
                Button(action: model.addProject) {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ElevateTheme.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add project")
                .help("Add project folder")
            }
            .padding(.leading, ElevateTheme.spacing24)
            .padding(.trailing, 12)
            .padding(.top, ElevateTheme.spacing24)
            .padding(.bottom, ElevateTheme.spacing8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.projects) { project in projectRow(project) }
                }
            }
            .frame(maxHeight: 144)
            .padding(.horizontal, ElevateTheme.spacing16)
            .padding(.bottom, ElevateTheme.spacing16)

            Rectangle().fill(ElevateTheme.border).frame(height: ElevateTheme.hairlineWidth)

            HStack {
                sectionLabel("CONVERSATIONS")
                Spacer()
                Button { model.refreshHistory() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(ElevateTheme.graphite)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh conversations")
                .help("Refresh conversations")
            }
            .padding(.leading, ElevateTheme.spacing24)
            .padding(.trailing, 12)
            .padding(.top, ElevateTheme.spacing16)
            .padding(.bottom, ElevateTheme.spacing8)

            HStack(spacing: ElevateTheme.spacing8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(ElevateTheme.graphite)
                TextField("Search conversations", text: $searchText)
                    .font(ElevateTheme.serif(14))
                    .foregroundStyle(ElevateTheme.ink)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search conversations")
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(ElevateTheme.paperDeep, in: RoundedRectangle(cornerRadius: ElevateTheme.controlRadius))
            .padding(.horizontal, ElevateTheme.spacing24)
            .padding(.bottom, ElevateTheme.spacing8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !visibleLiveSessions.isEmpty {
                        sectionLabel("LIVE")
                            .padding(.horizontal, ElevateTheme.spacing8)
                            .padding(.top, ElevateTheme.spacing8)
                            .padding(.bottom, ElevateTheme.spacing8)
                        ForEach(visibleLiveSessions) { session in
                            LiveConversationRow(
                                session: session,
                                isSelected: model.isSelected(session),
                                attentionMessage: model.attentionMessage(for: session),
                                onSelect: { onSelectSession(session) },
                                onStop: { onStopSession(session) },
                                onRemove: { onRemoveSession(session) }
                            )
                        }
                    }
                    if !visibleConversations.isEmpty {
                        sectionLabel("SAVED")
                            .padding(.horizontal, ElevateTheme.spacing8)
                            .padding(.top, ElevateTheme.spacing16)
                            .padding(.bottom, ElevateTheme.spacing8)
                        ForEach(visibleConversations) { record in conversationRow(record) }
                    }
                    if visibleLiveSessions.isEmpty && visibleConversations.isEmpty {
                        VStack(alignment: .leading, spacing: ElevateTheme.spacing8) {
                            Text(searchText.isEmpty ? "No conversations yet" : "No matches")
                                .font(ElevateTheme.serif(16))
                                .foregroundStyle(ElevateTheme.graphite)
                            if searchText.isEmpty {
                                Text("Your \(model.selected.title) work in this project will appear here.")
                                    .font(ElevateTheme.serif(13))
                                    .foregroundStyle(ElevateTheme.graphite)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, ElevateTheme.spacing8)
                        .padding(.top, ElevateTheme.spacing16)
                    }
                }
                .padding(.horizontal, ElevateTheme.spacing16)
                .padding(.bottom, ElevateTheme.spacing16)
            }
        }
        .frame(width: 282)
        .background(ElevateTheme.paper)
        .overlay(alignment: .trailing) {
            Rectangle().fill(ElevateTheme.border).frame(width: ElevateTheme.hairlineWidth)
        }
        .onChange(of: model.selected) { _ in searchText = "" }
        .onChange(of: model.workingDirectory) { _ in searchText = "" }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(ElevateTheme.utility(11, medium: true))
            .tracking(0.33)
            .foregroundStyle(ElevateTheme.graphite)
    }

    private func projectRow(_ project: ProjectRecord) -> some View {
        let isSelected = project.path == model.workingDirectory.path
        return Button { model.selectProject(project) } label: {
            HStack(spacing: ElevateTheme.spacing8) {
                Text(project.name)
                    .font(ElevateTheme.serif(16))
                    .foregroundStyle(project.isAvailable ? ElevateTheme.ink : ElevateTheme.graphite)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if model.needsAttention(project: project.path) {
                    AttentionPixel()
                }
                if !project.isAvailable {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(ElevateTheme.graphite)
                }
            }
            .padding(.horizontal, ElevateTheme.spacing8)
            .frame(height: 44)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ElevateTheme.paperDeep : ElevateTheme.paper)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(ElevateTheme.ink).frame(width: 2) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.path)
        .accessibilityLabel(project.isAvailable ? project.name : "\(project.name), folder unavailable")
        .accessibilityValue(project.path)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            Button("Show in Finder") { model.revealProject(project) }
                .disabled(!project.isAvailable)
            Button("Remove from sidebar") { model.removeProject(project) }
                .disabled(!model.canRemoveProject(project))
        }
    }

    private func conversationRow(_ record: ConversationRecord) -> some View {
        Button { onOpenConversation(record) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(record.title)
                    .font(ElevateTheme.serif(15))
                    .foregroundStyle(ElevateTheme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(record.updatedAt.formatted(.dateTime.month(.abbreviated).day().year()).uppercased())
                    .font(ElevateTheme.utility(10))
                    .tracking(0.3)
                    .foregroundStyle(ElevateTheme.graphite)
            }
            .padding(.horizontal, ElevateTheme.spacing8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) {
                Rectangle().fill(ElevateTheme.borderSubtle).frame(height: ElevateTheme.hairlineWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(record.title)
        .accessibilityLabel("\(record.title), \(record.updatedAt.formatted(date: .abbreviated, time: .omitted))")
        .accessibilityHint("Resume saved \(model.selected.title) conversation")
        .disabled(!model.isCurrentProjectAvailable)
    }
}

private struct LiveConversationRow: View {
    private var status: String {
        if session.pendingResumeID != nil { return "RESTORED · SELECT TO RESUME" }
        if attentionMessage != nil { return "YOUR TURN" }
        guard case .running = session.state else { return session.state.description.uppercased() }
        return session.isWorking ? "WORKING" : "READY"
    }

    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    /// Non-nil when the session needs you; empty when the CLI sent no message.
    let attentionMessage: String?
    let onSelect: () -> Void
    let onStop: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 5) {
                Text(session.displayTitle)
                    .font(ElevateTheme.serif(15))
                    .foregroundStyle(ElevateTheme.ink)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if attentionMessage != nil { AttentionPixel() }
                    Text(status)
                        .font(ElevateTheme.utility(10, medium: attentionMessage != nil))
                        .tracking(0.3)
                        .foregroundStyle(attentionMessage != nil ? ElevateTheme.ink : ElevateTheme.graphite)
                        .lineLimit(1)
                }
                .help(attentionMessage ?? "")
            }
            .padding(.horizontal, ElevateTheme.spacing8)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? ElevateTheme.paperDeep : ElevateTheme.paper)
            .overlay(alignment: .leading) {
                if isSelected { Rectangle().fill(ElevateTheme.ink).frame(width: 2) }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(ElevateTheme.borderSubtle).frame(height: ElevateTheme.hairlineWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.displayTitle), \(status.capitalized)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            if case .running = session.state {
                Button("Stop session", role: .destructive, action: onStop)
            } else if session.state == .stopping {
                Button("Stopping…") {}
                    .disabled(true)
            } else {
                Button("Remove from live list", action: onRemove)
            }
            if let initialPrompt = session.initialPrompt {
                Button("Copy original task") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(initialPrompt, forType: .string)
                }
            }
        }
    }
}

private struct HostView: View {
    let appDelegate: PrivateCLIAppDelegate
    @StateObject private var model = HostModel()
    @State private var hasStarted = false
    @State private var sidebarVisible = true
    @State private var showingStopConfirmation = false
    @State private var pendingStopSession: TerminalSession?
    @State private var showingCodexIdentityConfirmation = false
    @State private var pendingSavedConversation: ConversationRecord?
    @State private var taskDrafts: [String: String] = [:]
    @State private var imageDrafts: [String: [PromptImage]] = [:]
    @State private var promptFocusRequest = 0
    @State private var handoffDraft: HandoffDraft?

    private var taskDraftKey: String {
        "\(model.workingDirectory.path):\(model.selected.rawValue):\(model.currentSession.id)"
    }

    private var imageDraft: Binding<[PromptImage]> {
        let key = taskDraftKey
        return Binding(
            get: { imageDrafts[key] ?? [] },
            set: { imageDrafts[key] = $0 }
        )
    }

    private var taskDraft: Binding<String> {
        let key = taskDraftKey
        return Binding(
            get: { taskDrafts[key] ?? "" },
            set: { taskDrafts[key] = $0 }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                ProjectSidebar(
                    model: model,
                    onSelectSession: model.selectLiveSession,
                    onStopSession: requestStopSession,
                    onRemoveSession: model.removeLiveSession,
                    onOpenConversation: requestOpenConversation
                )
            }
            VStack(spacing: 0) {
                WorkspaceBar(
                    model: model,
                    session: model.currentSession,
                    sidebarVisible: sidebarVisible,
                    onToggleSidebar: { sidebarVisible.toggle() },
                    onNewConversation: { _ = model.startNewConversation() },
                    onLogin: model.showLogin,
                    onHandoff: {
                        let session = model.currentSession
                        handoffDraft = HandoffDraft(
                            source: model.selected.title,
                            target: model.selected == .claude ? "Codex" : "Claude",
                            projectPath: model.workingDirectory.path,
                            context: CLIPrompt.liveScreen(of: session.terminal).joined(separator: "\n")
                        )
                    }
                )
                TerminalDeck(terminal: model.currentSession.terminal) { images in
                    imageDrafts[taskDraftKey, default: []] += images
                    promptFocusRequest += 1
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                PromptBar(
                    session: model.currentSession,
                    text: taskDraft,
                    images: imageDraft,
                    focusRequest: promptFocusRequest,
                    agentName: model.selected.title,
                    projectName: model.workingDirectory.lastPathComponent,
                    isEnabled: model.isCurrentProjectAvailable,
                    onSubmit: { model.submitPrompt($0, images: $1.map(\.url)) }
                )
                .id(taskDraftKey)
            }
            // Images dropped on the terminal wait in the bar, since the
            // terminal itself does not accept drops.
            .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
                let key = taskDraftKey
                PromptImageStore.load(providers) { imageDrafts[key, default: []] += $0 }
                return true
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(ElevateTheme.paper)
        .sheet(item: $handoffDraft) { draft in
            HandoffView(draft: draft) { prompt in
                guard model.workingDirectory.path == draft.projectPath else { return false }
                let previous = model.selected
                model.selected = draft.target == "Codex" ? .codex : .claude
                guard model.startNewConversation(initialPrompt: prompt) else {
                    model.selected = previous
                    return false
                }
                return true
            }
        }
        .alert("Stop this session?", isPresented: $showingStopConfirmation) {
            Button("Stop session", role: .destructive) {
                if let pendingStopSession { model.stopLiveSession(pendingStopSession) }
                pendingStopSession = nil
            }
            Button("Keep running", role: .cancel) { pendingStopSession = nil }
        } message: {
            Text("The CLI will stop. You can still view this terminal until you remove it from the live list.")
        }
        .confirmationDialog("Open another Codex session?", isPresented: $showingCodexIdentityConfirmation) {
            Button("Open saved conversation") {
                if let pendingSavedConversation { model.openConversation(pendingSavedConversation) }
                pendingSavedConversation = nil
            }
            Button("Cancel", role: .cancel) { pendingSavedConversation = nil }
        } message: {
            Text("A live Codex session has not reported its conversation ID yet. Select its Live row to return to it, or open this saved conversation separately.")
        }
        .onAppear {
            guard !hasStarted else { return }
            hasStarted = true
            appDelegate.model = model
            HostDiagnostics.record("app_opened")
            HostHealth.startMainThreadWatchdog()
            model.restoreSessions()
            model.startCurrentIfPending()
            model.refreshCurrentAccountStatus()
            model.refreshHistory()
            model.startPeriodicWork()
            DispatchQueue.global(qos: .utility).async { PromptImageStore.prune() }
        }
        .onChange(of: model.sessionRevision) { _ in
            model.startCurrentIfPending()
            model.clearVisibleAttention()
        }
        .onChange(of: model.workingDirectory) { _ in
            model.startCurrentIfPending()
            model.refreshCurrentAccountStatus()
            model.clearVisibleAttention()
        }
        .onChange(of: model.selected) { _ in
            model.startCurrentIfPending()
            model.refreshCurrentAccountStatus()
            model.clearVisibleAttention()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.clearVisibleAttention()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            HostDiagnostics.record("app_quitting")
        }
    }

    private func requestStopSession(_ session: TerminalSession) {
        pendingStopSession = session
        showingStopConfirmation = true
    }

    private func requestOpenConversation(_ record: ConversationRecord) {
        if model.hasUnidentifiedRunningCodexSession() {
            pendingSavedConversation = record
            showingCodexIdentityConfirmation = true
        } else {
            model.openConversation(record)
        }
    }
}

@MainActor
private final class PrivateCLIAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: HostModel?
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AttentionNotifier.install(delegate: self)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["hostSession"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                if let id { self.model?.reveal(sessionID: id) }
            }
            completionHandler()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationPending { return .terminateLater }
        model?.saveRestorableSessions()
        guard let model, model.hasRunningSessions else { return .terminateNow }
        terminationPending = true
        model.stopAllSessions()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while model.hasRunningSessions && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            model.forceStopRemainingSessions()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
private struct PrivateCLIHostApp: App {
    @NSApplicationDelegateAdaptor(PrivateCLIAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("m4ix.CLI", id: "main") {
            HostView(appDelegate: appDelegate)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
