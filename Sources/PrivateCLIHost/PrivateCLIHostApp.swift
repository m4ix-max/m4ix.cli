import AppKit
import Combine
import Darwin
import Foundation
import SwiftTerm
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum Agent: String, CaseIterable, Identifiable, Hashable {
    case claude
    case codex

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var mark: PixelSprite { self == .claude ? .claude : .codex }
}

enum TerminalAction: String {
    case run
    case login
    case resume

    var title: String { self == .login ? "Login" : "CLI" }
}

enum TerminalState: Equatable {
    case idle
    case queued
    case running(TerminalAction)
    case stopping
    case exited(Int32?)
    case failed(String)

    var description: String {
        switch self {
        case .idle: return "Not started"
        case .queued: return "Queued"
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

    static let preferences: UserDefaults = {
        if let suite = ProcessInfo.processInfo.environment["PRIVATE_CLI_HOST_PREFERENCES_SUITE"], !suite.isEmpty,
           let defaults = UserDefaults(suiteName: suite) { return defaults }
        return .standard
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
final class TrackedTerminalView: LocalProcessTerminalView {
    var onViewportChange: (() -> Void)?
    private var viewportUpdateQueued = false

    func requestViewportUpdate() {
        guard !viewportUpdateQueued else { return }
        viewportUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.viewportUpdateQueued = false
            self.onViewportChange?()
        }
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        requestViewportUpdate()
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        requestViewportUpdate()
    }

    let activity = TerminalActivityClock()
    var inputIsConcealed = false
    var onPromptFocus: (() -> Void)?
    /// Marks this terminal's side-by-side pane as the one in use. SwiftTerm's
    /// responder methods cannot be overridden, so a click is the signal.
    var onActivate: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onActivate?()
        super.mouseDown(with: event)
        if inputIsConcealed { onPromptFocus?() }
        requestViewportUpdate()
    }
    /// Hands images from ⌘V to the prompt bar. SwiftTerm pastes only text,
    /// so an image would otherwise paste as nothing.
    var onPasteImages: (([PromptImage]) -> Void)?

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)), onPasteImages != nil,
           PromptImageStore.canPasteImages(from: .general) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func paste(_ sender: Any) {
        let images = PromptImageStore.images(from: .general, isPaste: true)
        guard !images.isEmpty, let onPasteImages else { return super.paste(sender) }
        onPasteImages(images)
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        activity.markInput()
        super.send(source: source, data: data)
        requestViewportUpdate()
    }
}

struct PromptRecovery {
    let text: String
    let images: [URL]
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable, LocalProcessTerminalViewDelegate {
    let id = UUID()
    let agent: Agent
    let profileID: String
    let projectPath: String
    let startedAt = Date()
    let initialPrompt: String?
    let terminal: TrackedTerminalView
    let profileDirectory: URL

    @Published private(set) var displayTitle: String
    @Published private(set) var state: TerminalState = .idle
    @Published private(set) var accountStatus = "Checking account"
    @Published private(set) var launchedDirectory: URL?
    @Published private(set) var launchedChoice = ModelChoice()
    @Published private(set) var activeConversationID: String?
    @Published private(set) var codexSessionIDPrefix: String?
    /// A conversation restored from the previous launch, resumed when first shown.
    @Published private(set) var pendingResumeID: String?
    @Published private(set) var isWorking = false
    /// Whether the CLI's own input line holds the screen, so the prompt
    /// bar can type into it. Refreshed once a second while shown.
    @Published private(set) var acceptsPromptText = false
    @Published private(set) var backgroundTerminalCount = 0
    @Published var compatibility = ProviderCompatibility.checking
    @Published var baselineMessage: String?
    var onPromptDelivered: (() -> Void)?
    var onCodexIdentityPrefix: (() -> Void)?
    var onStateExit: (() -> Void)?
    /// The last moment this session was on screen in the active app.
    var lastSeen: Date?
    private var accountStatusGeneration = 0
    private var turns = TurnDetector()
    private var pendingNotification: String?
    private var oscObservation: TerminalOscObservation?
    private var queuedPrompt: (text: String, images: [URL])?
    @Published private(set) var isSendingPrompt = false
    @Published private(set) var promptRecovery: PromptRecovery?
    private var promptTask: Task<Void, Never>?

    init(agent: Agent, projectPath: String, title: String, initialPrompt: String? = nil,
         pendingResumeID: String? = nil, profileBase: URL = HostPaths.profileBase, profileID: String = "default") {
        self.agent = agent
        self.profileID = profileID
        self.projectPath = projectPath
        self.displayTitle = title
        self.initialPrompt = initialPrompt
        self.pendingResumeID = pendingResumeID?.lowercased()
        self.profileDirectory = profileBase.appendingPathComponent(agent.rawValue, isDirectory: true)
        self.terminal = TrackedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        super.init()

        let activity = terminal.activity
        terminal.setProcessOutputHandler { [weak terminal] in
            activity.markOutput()
            DispatchQueue.main.async { terminal?.requestViewportUpdate() }
        }

        terminal.processDelegate = self
        // SwiftTerm's 500-line default drops earlier turns in long conversations.
        terminal.changeScrollback(10_000)
        terminal.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        terminal.lineSpacing = 1.3
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

    func launch(_ action: TerminalAction, in directory: URL, sessionID: String? = nil, initialPrompt: String? = nil,
                choice: ModelChoice = ModelChoice()) {
        if action == .resume, sessionID.flatMap(UUID.init(uuidString:)) == nil {
            return
        }
        guard state == .idle || state == .queued else { return }
        start(action, in: directory, sessionID: sessionID, initialPrompt: initialPrompt, choice: choice)
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
        let count = agent == .codex ? CLIPrompt.backgroundTerminalCount(in: CLIPrompt.liveScreen(of: terminal)) : 0
        if backgroundTerminalCount != count { backgroundTerminalCount = count }
        if acceptsPromptText != ready { acceptsPromptText = ready }
        if wasReady, ready, let queued = queuedPrompt {
            queuedPrompt = nil
            _ = sendPrompt(queued.text, images: queued.images)
        }
    }

    /// Types `text` and any images into the CLI's prompt, then submits it.
    /// Sends nothing and returns false while a menu or dialog holds the screen.
    func clearPromptRecovery() { promptRecovery = nil }

    func sendPrompt(_ text: String, images: [URL] = []) -> Bool {
        let ready = screenAcceptsText()
        if acceptsPromptText != ready { acceptsPromptText = ready }
        guard ready, !isSendingPrompt else { return false }
        isSendingPrompt = true
        let bracketed = terminal.terminalStateSnapshot().bracketedPasteMode
        promptTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSendingPrompt = false; self.promptTask = nil }
            if await self.type(text, images: images, bracketed: bracketed) {
                self.promptRecovery = nil
                self.onPromptDelivered?()
            } else {
                self.promptRecovery = PromptRecovery(text: text, images: images)
                HostDiagnostics.record("prompt_delivery_interrupted", agent: self.agent.rawValue, session: self.id)
            }
        }
        return true
    }

    /// Attaches the images, then types the text. Return goes last, and only
    /// onto the input line.
    private func type(_ text: String, images: [URL], bracketed: Bool) async -> Bool {
        guard !Task.isCancelled, screenAcceptsText(), await attach(images, bracketed: bracketed) else { return false }
        guard !Task.isCancelled, screenAcceptsText() else { return false }
        // Claude does not space text away from the last image marker.
        if !text.isEmpty {
            let body = images.isEmpty ? text : " " + text
            terminal.send(data: CLIPrompt.pasteBytes(body, bracketed: bracketed)[...])
        }
        try? await Task.sleep(nanoseconds: UInt64(CLIPrompt.returnDelay * 1_000_000_000))
        // A dialog can open in the gap; Return would answer it.
        guard !Task.isCancelled, screenAcceptsText() else { return false }
        terminal.send(data: [0x0d][...])
        return true
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
        if state == .queued { state = .exited(nil); return }
        guard case .running = state else { return }
        promptTask?.cancel()
        if let queuedPrompt { promptRecovery = PromptRecovery(text: queuedPrompt.text, images: queuedPrompt.images) }
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

    func markQueued() { state = .queued }

    func bindConversationID(_ sessionID: String) {
        guard UUID(uuidString: sessionID) != nil else { return }
        activeConversationID = sessionID.lowercased()
        HostDiagnostics.record("session_identity_bound", agent: agent.rawValue, session: id)
    }

    private func start(_ action: TerminalAction, in directory: URL, sessionID: String?, initialPrompt: String?, choice: ModelChoice) {
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
        environment["PRIVATE_CLI_HOST_DATA_DIR"] = profileDirectory.deletingLastPathComponent().path
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        // Set or cleared on every launch, so a value in the app's own
        // environment never picks a model the toolbar did not show.
        environment["PRIVATE_CLI_HOST_MODEL"] = choice.model
        environment["PRIVATE_CLI_HOST_EFFORT"] = choice.effort
        launchedDirectory = directory
        launchedChoice = choice
        pendingResumeID = nil
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
        let profileBasePath = profileDirectory.deletingLastPathComponent().path
        let workingPath = directory.path

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var environment = ProcessInfo.processInfo.environment
            environment["PRIVATE_CLI_HOST_DATA_DIR"] = profileBasePath
            let status: String
            do {
                let result = try CommandRunner.run(executable: "/bin/bash",
                    arguments: [launcher.path, agentName, "status"],
                    directory: URL(fileURLWithPath: workingPath, isDirectory: true),
                    environment: environment, timeout: 8, outputLimit: 4096)
                let summary = result.output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }.prefix(2).joined(separator: " · ")
                status = summary.isEmpty ? (result.status == 0 ? "Account ready" : "Account unavailable") : String(summary.prefix(180))
            } catch CommandError.timedOut {
                status = "Account check timed out"
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
            accountStatus = "Could not open profile: \(error.localizedDescription)"
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
        if let queuedPrompt { promptRecovery = PromptRecovery(text: queuedPrompt.text, images: queuedPrompt.images) }
        queuedPrompt = nil
        acceptsPromptText = false
        turns.reset()
        isWorking = false
        hideCaret()
        refreshAccountStatus(in: launchedDirectory ?? FileManager.default.homeDirectoryForCurrentUser)
        onStateExit?()
    }

    func processFailedToStart(source: TerminalView, error: LocalProcessError) {
        HostDiagnostics.record("session_launch_failed", agent: agent.rawValue, session: id)
        state = .failed(String(describing: error))
        onStateExit?()
    }
}

struct ProjectRecord: Identifiable, Hashable {
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
final class ProjectWorkspace {
    private var standby: [Agent: TerminalSession]
    private var live: [Agent: [TerminalSession]] = [:]
    private var selectedSessionIDs: [Agent: UUID] = [:]

    private let profileBase: URL
    let profileID: String
    let projectPath: String

    init(projectPath: String, profileBase: URL = HostPaths.profileBase, profileID: String = "default") {
        self.profileBase = profileBase
        self.profileID = profileID
        self.projectPath = projectPath
        standby = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in
            (agent, TerminalSession(agent: agent, projectPath: projectPath, title: "Account", profileBase: profileBase, profileID: profileID))
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
        if current.state == .idle || current.state == .queued || current.state.isRunning { return current }
        let replacement = TerminalSession(agent: agent, projectPath: current.projectPath, title: "Account", profileBase: profileBase, profileID: profileID)
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
                                      title: title, initialPrompt: initialPrompt, profileBase: profileBase, profileID: profileID)
        live[agent, default: []].insert(session, at: 0)
        selectedSessionIDs[agent] = session.id
        return session
    }

    func restoreConversation(for agent: Agent, title: String, conversationID: String, selected: Bool) {
        guard liveSession(for: agent, conversationID: conversationID) == nil else { return }
        let session = TerminalSession(agent: agent, projectPath: standbySession(for: agent).projectPath,
                                      title: title, pendingResumeID: conversationID, profileBase: profileBase, profileID: profileID)
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
final class HostModel: ObservableObject {
    let production: ProductionCenter
    let verification: VerificationService
    let workflows: WorkflowService
    let dataRoot: URL
    @Published private(set) var selectedProfileID: String
    @Published var sessionLimit: Int = 4 {
        didSet {
            if sessionLimit < 1 || sessionLimit > 16 { sessionLimit = min(16, max(1, sessionLimit)) }
            preferences.set(sessionLimit, forKey: "PrivateCLIHostSessionLimit")
            drainLaunchQueue()
        }
    }
    @Published var pendingUpdate: URL? {
        didSet {
            if let pendingUpdate { preferences.set(pendingUpdate.path, forKey: "PrivateCLIHostPendingUpdate") }
            else { preferences.removeObject(forKey: "PrivateCLIHostPendingUpdate") }
        }
    }
    @Published var operationError: String?
    @Published var selected: Agent = .claude {
        didSet { preferences.set(selected.rawValue, forKey: Self.agentPreferenceKey) }
    }
    /// Claude and Codex side by side, each showing its selected session.
    /// `selected` is then the pane with the keyboard.
    @Published var isSplit = false {
        didSet {
            guard isSplit != oldValue else { return }
            preferences.set(isSplit, forKey: Self.splitPreferenceKey)
            sessionRevision += 1
        }
    }
    @Published private(set) var modelChoices: [Agent: ModelChoice]
    @Published private(set) var modelCatalogs: [Agent: ModelCatalog] = [:]
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
    private let historyCache = ConversationHistoryCache()
    private var historyRefreshInFlight = false
    private var historyRefreshPending = false
    private var historyLoaded = false
    private var isShuttingDown = false
    private var hasStartedOnLaunch = false
    private var historyByProfile: [String: [ConversationRecord]] = [:]
    private var launchQueue: [LaunchRequest] = []
    private var preparingLaunches: Set<UUID> = []
    private var projectStores: [String: ProjectContextStore] = [:]
    private var sharedChats: [String: SharedChat] = [:]

    var sharedChat: SharedChat {
        let key = selectedProfileID + ":" + workingDirectory.path
        if let chat = sharedChats[key] {
            if !chat.isRunning {
                chat.choices = Dictionary(uniqueKeysWithValues: modelChoices.map { ($0.key.rawValue, $0.value) })
            }
            return chat
        }
        let chat = SharedChat(project: workingDirectory, profileBase: profileBase,
            choices: Dictionary(uniqueKeysWithValues: modelChoices.map { ($0.key.rawValue, $0.value) }))
        sharedChats[key] = chat
        return chat
    }
    private struct LaunchRequest {
        let session: TerminalSession
        let action: TerminalAction
        let conversationID: String?
        let prompt: String?
        let images: [URL]
        let choice: ModelChoice
    }

    private static let agentPreferenceKey = "PrivateCLIHostSelectedAgent"
    private static let splitPreferenceKey = "PrivateCLIHostSplitView"
    private static let directoryPreferenceKey = "PrivateCLIHostWorkingDirectory"
    private static let projectsPreferenceKey = "PrivateCLIHostProjects"
    private static let hiddenProjectsPreferenceKey = "PrivateCLIHostHiddenProjects"
    private static let restorableSessionsPreferenceKey = "PrivateCLIHostRestorableSessions"

    private let preferences: UserDefaults
    var profileBase: URL { production.base(for: selectedProfileID) }
    var savedPreferences: [String: Any] { preferences.dictionaryRepresentation().filter { $0.key.hasPrefix("PrivateCLIHost") } }
    var projectContextStore: ProjectContextStore {
        if let store = projectStores[selectedProfileID] { return store }
        let store = ProjectContextStore(directory: profileBase.appendingPathComponent("projects"))
        projectStores[selectedProfileID] = store
        return store
    }

    init(defaults: UserDefaults? = nil, profileBase: URL = HostPaths.profileBase) {
        let defaults = defaults ?? HostPaths.preferences
        self.preferences = defaults
        self.dataRoot = profileBase
        let production = ProductionCenter(root: profileBase)
        self.production = production
        self.verification = VerificationService(root: profileBase)
        self.workflows = WorkflowService(root: profileBase)
        let requestedProfile = defaults.string(forKey: "PrivateCLIHostSelectedProfile") ?? "default"
        self.selectedProfileID = production.profiles.contains(where: { $0.id == requestedProfile }) ? requestedProfile : "default"
        self.sessionLimit = max(1, min(16, defaults.object(forKey: "PrivateCLIHostSessionLimit") as? Int ?? 4))
        self.selected = defaults.string(forKey: Self.agentPreferenceKey).flatMap(Agent.init(rawValue:)) ?? .claude
        self.isSplit = defaults.bool(forKey: Self.splitPreferenceKey)
        self.modelChoices = Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in
            (agent, ModelChoice(preference: defaults.object(forKey: Self.modelPreferenceKey(agent))))
        })
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
        self.workspaces[workspaceKey(initialPath)] = ProjectWorkspace(projectPath: initialPath,
            profileBase: production.base(for: selectedProfileID), profileID: selectedProfileID)
        if let path = defaults.string(forKey: "PrivateCLIHostPendingUpdate"),
           path.hasPrefix(profileBase.appendingPathComponent("updates/staged/").path + "/") {
            let staged = URL(fileURLWithPath: path)
            if (try? AppUpdates.inspectApplication(staged)) != nil { self.pendingUpdate = staged }
        }
    }

    deinit { periodicTimers.forEach { $0.invalidate() } }

    private static func modelPreferenceKey(_ agent: Agent) -> String { "PrivateCLIHostModelChoice." + agent.rawValue }

    func modelChoice(for agent: Agent) -> ModelChoice { modelChoices[agent] ?? ModelChoice() }

    /// Applies to conversations started or resumed from now on. Running
    /// conversations keep the model they were launched with.
    func setModelChoice(_ choice: ModelChoice, for agent: Agent) {
        var choice = choice
        if let effort = choice.effort, let catalog = modelCatalogs[agent],
           !catalog.efforts(for: choice.model).contains(effort) {
            choice.effort = nil
        }
        modelChoices[agent] = choice
        if choice.isDefault { preferences.removeObject(forKey: Self.modelPreferenceKey(agent)) }
        else { preferences.set(choice.preference, forKey: Self.modelPreferenceKey(agent)) }
    }

    /// Codex rewrites its model cache as it runs, so this is read again with history.
    func refreshModelCatalogs() {
        let base = profileBase
        Task { @MainActor [weak self] in
            let catalogs = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: Agent.allCases.map { agent in
                    (agent, ModelCatalog.load(agent: agent, profileDirectory: base.appendingPathComponent(agent.rawValue, isDirectory: true)))
                })
            }.value
            guard let self, self.profileBase == base, self.modelCatalogs != catalogs else { return }
            self.modelCatalogs = catalogs
        }
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    var currentWorkspace: ProjectWorkspace { workspace(for: workingDirectory.path) }

    private func workspaceKey(_ path: String, profileID: String? = nil) -> String {
        "\(profileID ?? selectedProfileID):\(path)"
    }

    private func workspace(for path: String, profileID: String? = nil) -> ProjectWorkspace {
        let profileID = profileID ?? selectedProfileID
        let key = workspaceKey(path, profileID: profileID)
        if let workspace = workspaces[key] { return workspace }
        let workspace = ProjectWorkspace(projectPath: path, profileBase: production.base(for: profileID), profileID: profileID)
        observe(workspace.allSessions)
        workspaces[key] = workspace
        return workspace
    }

    private func observe(_ sessions: [TerminalSession]) {
        for session in sessions {
            session.onStateExit = { [weak self] in
                self?.sessionRevision += 1
                self?.drainLaunchQueue()
            }
        }
    }

    func selectProfile(_ id: String) {
        guard id != selectedProfileID, production.profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        preferences.set(id, forKey: "PrivateCLIHostSelectedProfile")
        conversations = historyByProfile[id] ?? []
        refreshHistory()
        refreshModelCatalogs()
        sessionRevision += 1
    }

    var allLiveSessions: [TerminalSession] { workspaces.values.flatMap(\.allLiveSessions).sorted { $0.startedAt > $1.startedAt } }
    var queuedSessions: [TerminalSession] { allLiveSessions.filter { $0.state == .queued } }
    var activeSessionCount: Int { workspaces.values.flatMap(\.allSessions).filter { $0.state.isRunning }.count }

    var currentSession: TerminalSession { currentWorkspace.session(for: selected) }
    /// The sessions on screen: the selected provider's, or each provider's
    /// when they are side by side.
    var visibleSessions: [TerminalSession] {
        isSplit ? Agent.allCases.map { currentWorkspace.session(for: $0) } : [currentSession]
    }
    var loginSession: TerminalSession { currentWorkspace.standbySession(for: selected) }
    var isCurrentProjectAvailable: Bool { ProjectRecord(path: workingDirectory.path).isAvailable }

    func liveSessionsForCurrentProject() -> [TerminalSession] {
        currentWorkspace.allLiveSessions.sorted { $0.startedAt > $1.startedAt }
    }

    /// On screen, in either pane.
    func isSelected(_ session: TerminalSession) -> Bool {
        visibleSessions.contains { $0.id == session.id }
    }

    func selectLiveSession(_ session: TerminalSession) {
        guard currentWorkspace.select(session, for: session.agent) else { return }
        selected = session.agent
        sessionRevision += 1
    }

    func startOnLaunch() {
        guard !hasStartedOnLaunch, !isShuttingDown else { return }
        hasStartedOnLaunch = true
        restoreSessions()
        startNewConversation()
    }

    /// Starts the shown sessions that were restored from the previous launch.
    /// Restored sessions elsewhere wait until they are shown.
    func startCurrentIfPending() {
        guard !isShuttingDown, isCurrentProjectAvailable else { return }
        for session in visibleSessions where session.state == .idle {
            guard let id = session.pendingResumeID else { continue }
            enqueue(session, action: .resume, conversationID: id)
        }
    }

    /// Saves live conversations that exist in history, so a quit or a crash
    /// can be picked up where it stopped. Stopped sessions are not kept.
    func saveRestorableSessions() {
        guard historyLoaded, !isShuttingDown else { return }
        let previous = preferences.array(forKey: Self.restorableSessionsPreferenceKey) as? [[String: Any]] ?? []
        var entries = previous.filter { historyByProfile[$0["profile"] as? String ?? "default"] == nil }
        for workspace in workspaces.values {
            guard let history = historyByProfile[workspace.profileID] else { continue }
            let known = Set(history.map { "\($0.provider):\($0.sessionID.lowercased())" })
            for agent in Agent.allCases {
                for session in workspace.liveSessions(for: agent) {
                    guard let id = session.restorableConversationID?.lowercased(),
                          known.contains("\(agent.rawValue):\(id)") else { continue }
                    entries.append([
                        "project": workspace.projectPath,
                        "profile": workspace.profileID,
                        "agent": agent.rawValue,
                        "conversation": id,
                        "title": session.displayTitle,
                        "selected": workspace.isSelected(session, for: agent)
                    ])
                }
            }
        }
        preferences.set(entries, forKey: Self.restorableSessionsPreferenceKey)
    }

    func restoreSessions() {
        let entries = preferences.array(forKey: Self.restorableSessionsPreferenceKey) as? [[String: Any]] ?? []
        var restored = 0
        for entry in entries {
            let profile = entry["profile"] as? String ?? "default"
            guard let path = entry["project"] as? String,
                  production.profiles.contains(where: { $0.id == profile }),
                  let agent = (entry["agent"] as? String).flatMap(Agent.init(rawValue:)),
                  let id = entry["conversation"] as? String,
                  UUID(uuidString: id) != nil,
                  ProjectRecord(path: path).isAvailable else { continue }
            workspace(for: path, profileID: profile).restoreConversation(
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
        refreshModelCatalogs()
        let history = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshHistory()
                self?.refreshModelCatalogs()
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
        drainLaunchQueue()
        let now = Date()
        let visible = visibleSessions
        for session in visible {
            if isShowingCurrentSession { session.lastSeen = now }
            session.refreshPromptReadiness()
        }
        for workspace in workspaces.values {
            for session in workspace.allLiveSessions {
                if session.hasQueuedPrompt && !visible.contains(where: { $0.id == session.id }) {
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
        if isShowingCurrentSession && isSelected(session) { return }
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
        for session in visibleSessions {
            session.lastSeen = Date()
            clearAttention(for: session.id)
        }
    }

    private func clearAttention(for id: UUID) {
        guard attention.removeValue(forKey: id) != nil else { return }
        AttentionNotifier.withdraw(sessionID: id)
    }

    func attentionMessage(for session: TerminalSession) -> String? {
        attention[session.id]
    }

    func needsAttention(project path: String, agent: Agent? = nil) -> Bool {
        guard !attention.isEmpty, let workspace = workspaces[workspaceKey(path)] else { return false }
        return Agent.allCases.contains { candidate in
            (agent == nil || agent == candidate)
                && workspace.liveSessions(for: candidate).contains { attention[$0.id] != nil }
        }
    }

    /// Shows a live session from anywhere in the app, as when its
    /// notification is clicked.
    func reveal(sessionID: UUID) {
        for workspace in workspaces.values {
            for agent in Agent.allCases {
                guard let session = workspace.liveSessions(for: agent).first(where: { $0.id == sessionID }) else { continue }
                selectProfile(workspace.profileID)
                selectProject(ProjectRecord(path: workspace.projectPath))
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

    /// The prompt bar types into its provider's session on screen while the
    /// CLI runs, and starts a new conversation when none is running.
    func submitPrompt(_ text: String, images: [URL], for agent: Agent? = nil) -> Bool {
        let agent = agent ?? selected
        let session = currentWorkspace.session(for: agent)
        guard session.state != .queued else { return false }
        if session.hostsConversation { return session.sendPrompt(text, images: images) }
        return startNewConversation(initialPrompt: text, images: images, for: agent)
    }

    @discardableResult
    func startNewConversation(initialPrompt: String? = nil, images: [URL] = [], for agent: Agent? = nil) -> Bool {
        guard !isShuttingDown, isCurrentProjectAvailable, HostPaths.launcher != nil else { return false }
        let agent = agent ?? selected
        let firstLine = initialPrompt?
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title = firstLine.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "New conversation"
        let session = currentWorkspace.createConversation(for: agent, title: title)
        observe([session])
        if agent == .codex {
            session.onCodexIdentityPrefix = { [weak self] in self?.refreshHistory() }
        }
        sessionRevision += 1
        let newID = agent == .claude ? UUID().uuidString.lowercased() : nil
        enqueue(session, action: .run, conversationID: newID, prompt: initialPrompt, images: images)
        refreshHistory()
        if case .failed = session.state { return false }
        return true
    }

    private func enqueue(_ session: TerminalSession, action: TerminalAction, conversationID: String? = nil,
                         prompt: String? = nil, images: [URL] = []) {
        session.markQueued()
        launchQueue.append(LaunchRequest(session: session, action: action, conversationID: conversationID, prompt: prompt,
                                         images: images, choice: modelChoice(for: session.agent)))
        sessionRevision += 1
        drainLaunchQueue()
    }

    func drainLaunchQueue() {
        guard !isShuttingDown else { return }
        launchQueue.removeAll { $0.session.state != .queued }
        while activeSessionCount + preparingLaunches.count < sessionLimit, !launchQueue.isEmpty {
            let request = launchQueue.removeFirst()
            let session = request.session
            preparingLaunches.insert(session.id)
            let directory = URL(fileURLWithPath: session.projectPath)
            let base = session.profileDirectory.deletingLastPathComponent()
            let root = dataRoot
            Task { @MainActor [weak self, weak session] in
                let metadata = await Task.detached(priority: .utility) {
                    let compatibility = ProviderCompatibility.inspect(agent: request.session.agent, profileBase: base, directory: directory)
                    var baselineError: String?
                    do { try WorkspaceReview.captureBaseline(root: root, project: directory, session: request.session.id) }
                    catch { baselineError = "Starting Git state unavailable: \(error.localizedDescription)" }
                    return (compatibility, baselineError)
                }.value
                guard let self else { return }
                self.preparingLaunches.remove(request.session.id)
                guard let session, !self.isShuttingDown, session.state == .queued else { self.drainLaunchQueue(); return }
                session.compatibility = metadata.0
                session.baselineMessage = metadata.1
                // Submit task text through the hosted input path. This keeps
                // it out of process listings and gives recovery the delivery result.
                session.launch(request.action, in: directory, sessionID: request.conversationID, choice: request.choice)
                if request.prompt != nil || !request.images.isEmpty {
                    session.queuePrompt(request.prompt ?? "", images: request.images)
                }
                session.refreshAccountStatus(in: directory)
                self.sessionRevision += 1
                self.drainLaunchQueue()
            }
        }
    }

    func startWorkflowAgent(project: String, profile: String, provider: String, prompt: String) -> UUID? {
        guard production.profiles.contains(where: { $0.id == profile }), let agent = Agent(rawValue: provider) else { return nil }
        selectProfile(profile)
        openWorkspace(URL(fileURLWithPath: project))
        selected = agent
        guard startNewConversation(initialPrompt: prompt) else { return nil }
        return currentSession.id
    }

    @discardableResult
    func startHandoff(_ draft: HandoffDraft, prompt: String, store: ProjectContextStore? = nil) async throws -> TerminalSession {
        guard workingDirectory.path == draft.projectPath, selectedProfileID == draft.profileID else {
            throw CommandError.failed("The selected project changed. Open a new handoff in the intended project.")
        }
        let store = store ?? projectContextStore
        let context = try await store.load(path: draft.projectPath)
        let fullPrompt = context.brief.isEmpty ? prompt : prompt + "\n\nShared project brief:\n" + context.brief
        let record = ProjectHandoffRecord(id: UUID(), date: Date(), source: draft.source,
                           target: draft.target, prompt: fullPrompt, state: "Prepared")
        try await store.appendHandoff(path: draft.projectPath, record: record)
        guard workingDirectory.path == draft.projectPath, selectedProfileID == draft.profileID else {
            try await store.updateHandoff(path: draft.projectPath, id: record.id, state: "Cancelled: project changed")
            throw CommandError.failed("The project changed while preparing the handoff. No conversation was started.")
        }
        let previous = selected
        selected = draft.target == "Codex" ? .codex : .claude
        guard startNewConversation(initialPrompt: fullPrompt) else {
            selected = previous
            try await store.updateHandoff(path: draft.projectPath, id: record.id, state: "Launch failed")
            throw CommandError.failed("Could not start the conversation. Check the project folder and launcher.")
        }
        do {
            try await store.updateHandoff(path: draft.projectPath, id: record.id, state: "Launch requested")
        } catch {
            HostDiagnostics.record("handoff_status_save_failed")
        }
        return currentSession
    }

    func openConversation(_ record: ConversationRecord) {
        guard !isShuttingDown, isCurrentProjectAvailable,
              record.provider == selected.rawValue,
              record.projectPath == workingDirectory.path else { return }
        currentWorkspace.reconcileHistory(conversations)
        if let running = currentWorkspace.liveSession(for: selected, conversationID: record.sessionID) {
            selectLiveSession(running)
            return
        }
        let session = currentWorkspace.createConversation(for: selected, title: record.title)
        sessionRevision += 1
        enqueue(session, action: .resume, conversationID: record.sessionID)
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
        guard !isShuttingDown, isCurrentProjectAvailable else { return }
        let session = currentWorkspace.sessionForLogin(for: selected)
        currentWorkspace.selectStandby(for: selected)
        sessionRevision += 1
        if session.state == .idle { observe([session]); enqueue(session, action: .login) }
    }

    func stopLiveSession(_ session: TerminalSession) {
        guard allLiveSessions.contains(where: { $0.id == session.id }) else { return }
        session.stop()
        drainLaunchQueue()
    }

    func removeLiveSession(_ session: TerminalSession) {
        if workspaces[workspaceKey(session.projectPath, profileID: session.profileID)]?.remove(session, for: session.agent) == true {
            clearAttention(for: session.id)
            sessionRevision += 1
            saveRestorableSessions()
        }
    }

    func prepareForTermination() {
        guard !isShuttingDown else { return }
        saveRestorableSessions()
        isShuttingDown = true
        periodicTimers.forEach { $0.invalidate() }
        periodicTimers.removeAll()
        verification.cancelAll()
        sharedChats.values.forEach { $0.close() }
        production.flush()
        verification.flush()
    }

    func cancelTermination(message: String) {
        isShuttingDown = false
        operationError = message
        startPeriodicWork()
    }

    func stopAllSessions() {
        sharedChats.values.forEach { $0.close() }
        for workspace in workspaces.values {
            for session in workspace.allSessions {
                session.stop()
            }
        }
    }

    func flushSharedChats() async {
        for chat in sharedChats.values { await chat.flush() }
    }

    var hasRunningSessions: Bool {
        sharedChats.values.contains { $0.isRunning } || workspaces.values.contains { workspace in
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
        preferences.set(project.path, forKey: Self.directoryPreferenceKey)
    }

    func openWorkspace(_ directory: URL) {
        let path = Self.normalizedPath(directory.path)
        if !savedProjectPaths.contains(path) { savedProjectPaths.append(path) }
        hiddenProjectPaths.remove(path)
        saveProjectPreferences()
        rebuildProjects()
        selectProject(ProjectRecord(path: path))
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
        workspaces = workspaces.filter { $0.value.projectPath != project.path }
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
        !workspaces.values.contains { $0.projectPath == project.path && $0.hasVisibleSessions }
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
        let profileBase = self.profileBase
        let profileID = selectedProfileID
        let cache = historyCache
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let records = ConversationHistoryLoader.load(profileBase: profileBase, cache: cache)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.historyRefreshInFlight = false
                for workspace in self.workspaces.values where workspace.profileID == profileID {
                    workspace.reconcileHistory(records)
                }
                self.historyByProfile[profileID] = records
                if profileID == self.selectedProfileID { self.conversations = records }
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
        preferences.set(savedProjectPaths, forKey: Self.projectsPreferenceKey)
        preferences.set(Array(hiddenProjectPaths), forKey: Self.hiddenProjectsPreferenceKey)
    }
}

private final class TerminalPromptCover: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class TerminalDeckView: NSView {
    var onPasteImages: (([PromptImage]) -> Void)?
    private var shownTerminal: LocalProcessTerminalView?
    private var terminalConstraints: [NSLayoutConstraint] = []
    let scrollbar = TerminalScrollbar(frame: .zero)
    var agent: Agent = .claude
    var hidesPrompt = true
    /// False for the side-by-side pane not in use: a question there comes
    /// into view without taking the keyboard from the other pane.
    var takesAutomaticFocus = true
    var onPromptFocus: (() -> Void)?
    var onActivate: (() -> Void)?
    private let promptCover = TerminalPromptCover()
    private var windowObservations: [NSObjectProtocol] = []
    private(set) var jumpToLatestButton = NSButton(title: "Jump to latest", target: nil, action: nil)
    private let focusLabel = NSTextField(labelWithString: "")
    private let releaseLabel = NSTextField(labelWithString: "")
    private var lastFocusedResponse: String?
    private var lastShownResponse: String?
    private var isUpdatingViewport = false
    private var pendingPromptFocus = false
    private var windowWasKey = false

    @objc func jumpToLatest() {
        shownTerminal?.scroll(toPosition: 1)
        updatePromptCover()
    }

    private func updateNavigation(_ terminal: LocalProcessTerminalView, liveScreen: [String]) {
        let request = CLIPrompt.terminalResponseRequest(screen: liveScreen, agent: agent)
        let isKey = window?.isKeyWindow == true && window?.attachedSheet == nil
        if let request, isKey {
            // Bring a newly arrived question into view even if its output
            // appeared while the reader was looking through earlier turns.
            if request != lastShownResponse || !windowWasKey {
                lastShownResponse = request
                terminal.scroll(toPosition: 1)
            }
            // A pane not in use takes focus for its question once it is used.
            if takesAutomaticFocus, request != lastFocusedResponse || !windowWasKey {
                lastFocusedResponse = request
                window?.makeFirstResponder(terminal)
            }
        } else if request == nil {
            lastFocusedResponse = nil
            lastShownResponse = nil
        }
        windowWasKey = isKey
        scrollbar.update(position: terminal.scrollPosition, proportion: terminal.scrollThumbsize,
                         enabled: terminal.canScroll)
        jumpToLatestButton.isHidden = !terminal.canScroll || terminal.scrollPosition == 1
        if window?.firstResponder === terminal {
            focusLabel.stringValue = request == nil
                ? "Terminal controls · ⌘L for message input"
                : "Answer in terminal · use the keys shown above"
        } else if window?.firstResponder === scrollbar {
            focusLabel.stringValue = "Conversation history · ↑ ↓ scroll · Home / End"
        } else {
            focusLabel.stringValue = "Message input · ⌘L to focus"
        }
    }

    private func updatePromptCover() {
        guard let terminal = shownTerminal, !isUpdatingViewport else { return }
        isUpdatingViewport = true
        defer { isUpdatingViewport = false }
        updateNavigation(terminal, liveScreen: CLIPrompt.liveScreen(of: terminal))
        // Navigation may have moved the viewport to a newly arrived question.
        let snapshot = terminal.terminalStateSnapshot()
        let screen = snapshot.visibleRows.map { $0.text.replacingOccurrences(of: "\u{0}", with: " ") }
        let isAtLiveScreen = !terminal.canScroll || terminal.scrollPosition == 1
        let row = hidesPrompt && isAtLiveScreen ? CLIPrompt.inputStartRow(screen: screen, agent: agent) : nil
        guard let row else {
            promptCover.isHidden = true
            pendingPromptFocus = false
            (terminal as? TrackedTerminalView)?.inputIsConcealed = false
            return
        }
        let newlyConcealed = promptCover.isHidden
        (terminal as? TrackedTerminalView)?.inputIsConcealed = true
        if newlyConcealed { pendingPromptFocus = true }
        if pendingPromptFocus, takesAutomaticFocus, window?.isKeyWindow == true, window?.attachedSheet == nil {
            pendingPromptFocus = false
            onPromptFocus?()
        }
        let cellHeight = terminal.getOptimalFrameSize().height / CGFloat(max(1, snapshot.dimensions.rows))
        let height = terminal.bounds.height - CGFloat(row) * cellHeight
        promptCover.frame = NSRect(x: terminal.frame.minX, y: terminal.frame.minY,
                                  width: terminal.frame.width, height: height)
        promptCover.isHidden = false
    }

    override func layout() {
        super.layout()
        updatePromptCover()
    }


    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = ElevateTheme.terminalBackground.cgColor
        promptCover.wantsLayer = true
        promptCover.layer?.backgroundColor = ElevateTheme.terminalBackground.cgColor
        promptCover.isHidden = true
        addSubview(promptCover)
        scrollbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollbar)
        NSLayoutConstraint.activate([
            scrollbar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ElevateTheme.spacing16),
            scrollbar.topAnchor.constraint(equalTo: topAnchor, constant: ElevateTheme.spacing16),
            scrollbar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ElevateTheme.spacing16),
            scrollbar.widthAnchor.constraint(equalToConstant: 18)
        ])
        scrollbar.onScroll = { [weak self] position in
            self?.shownTerminal?.scroll(toPosition: position)
            self?.updatePromptCover()
        }
        scrollbar.onScrollLines = { [weak self] lines in
            if lines < 0 { self?.shownTerminal?.scrollUp(lines: -lines) }
            else { self?.shownTerminal?.scrollDown(lines: lines) }
            self?.updatePromptCover()
        }
        scrollbar.onScrollWheel = { [weak self] event in
            self?.shownTerminal?.scrollWheel(with: event)
            self?.updatePromptCover()
        }
        jumpToLatestButton.target = self
        jumpToLatestButton.action = #selector(jumpToLatest)
        jumpToLatestButton.bezelStyle = .rounded
        jumpToLatestButton.isHidden = true
        jumpToLatestButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpToLatestButton)
        focusLabel.font = .systemFont(ofSize: 10)
        focusLabel.textColor = .secondaryLabelColor
        focusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(focusLabel)
        let release = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        releaseLabel.stringValue = "(release \(release))"
        releaseLabel.font = .systemFont(ofSize: 9, weight: .regular)
        releaseLabel.textColor = NSColor(white: 0.42, alpha: 1)
        releaseLabel.alignment = .right
        releaseLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(releaseLabel)
        NSLayoutConstraint.activate([
            focusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            focusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            releaseLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            releaseLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        NSLayoutConstraint.activate([
            jumpToLatestButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
            jumpToLatestButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservations.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservations.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                windowObservations.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in self?.updatePromptCover() })
            }
            for name in [NSText.didBeginEditingNotification, NSText.didEndEditingNotification] {
                windowObservations.append(NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: .main
                ) { [weak self] notification in
                    guard let self, (notification.object as? NSView)?.window === self.window else { return }
                    self.updatePromptCover()
                })
            }
        }
        updatePromptCover()
    }

    deinit {
        windowObservations.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func show(_ terminal: LocalProcessTerminalView) {
        (terminal as? TrackedTerminalView)?.onPasteImages = onPasteImages
        (terminal as? TrackedTerminalView)?.onPromptFocus = onPromptFocus
        (terminal as? TrackedTerminalView)?.onActivate = onActivate
        guard shownTerminal !== terminal || terminal.superview !== self else {
            updatePromptCover()
            return
        }
        NSLayoutConstraint.deactivate(terminalConstraints)
        (shownTerminal as? TrackedTerminalView)?.onViewportChange = nil
        shownTerminal?.removeFromSuperview()
        terminal.removeFromSuperview()
        shownTerminal = terminal
        (terminal as? TrackedTerminalView)?.onViewportChange = { [weak self] in
            self?.updatePromptCover()
        }
        lastFocusedResponse = nil
        lastShownResponse = nil
        pendingPromptFocus = false
        promptCover.isHidden = true
        windowWasKey = false
        // Legacy style does not fade itself back in while the host owns scrolling.
        terminal.scrollerStyle = .legacy
        terminal.subviews.compactMap { $0 as? NSScroller }.forEach { $0.isHidden = true }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal, positioned: .below, relativeTo: promptCover)
        // The deck shares the terminal's background, so the inset reads as margin.
        terminalConstraints = [
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: ElevateTheme.spacing24),
            terminal.trailingAnchor.constraint(equalTo: scrollbar.leadingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: ElevateTheme.spacing16),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ElevateTheme.spacing16)
        ]
        NSLayoutConstraint.activate(terminalConstraints)
        if !hidesPrompt, takesAutomaticFocus, window != nil { window?.makeFirstResponder(terminal) }
    }
}

private struct TerminalDeck: NSViewRepresentable {
    let terminal: LocalProcessTerminalView
    let agent: Agent
    let hidesPrompt: Bool
    let takesAutomaticFocus: Bool
    let onActivate: () -> Void
    let onPromptFocus: () -> Void
    let onPasteImages: ([PromptImage]) -> Void

    func makeNSView(context: Context) -> TerminalDeckView {
        let view = TerminalDeckView(frame: .zero)
        configure(view)
        view.show(terminal)
        return view
    }

    func updateNSView(_ view: TerminalDeckView, context: Context) {
        configure(view)
        view.show(terminal)
    }

    private func configure(_ view: TerminalDeckView) {
        view.onPasteImages = onPasteImages
        view.agent = agent
        view.hidesPrompt = hidesPrompt
        view.takesAutomaticFocus = takesAutomaticFocus
        view.onActivate = onActivate
        view.onPromptFocus = onPromptFocus
    }
}

/// Follows the session on screen, so the composer knows whether its CLI
/// is running and whether a menu holds the screen.
private struct PromptBar: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var dictation: Dictation
    let dictationTarget: String
    let text: Binding<String>
    let images: Binding<[PromptImage]>
    let focusRequest: Int
    let agentName: String
    let projectName: String
    let isEnabled: Bool
    let onDictate: () -> Void
    let onActivate: () -> Void
    let onSubmit: (String, [PromptImage]) -> Bool
    let onRecover: (PromptRecovery) -> Void
    let onTerminal: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if let recovery = session.promptRecovery {
                HStack {
                    Text("Prompt delivery was interrupted. Check the terminal before resending.")
                        .font(.callout).foregroundStyle(ElevateTheme.ink)
                    Spacer()
                    Button("Restore draft") { onRecover(recovery); session.clearPromptRecovery() }
                    Button("Dismiss") { session.clearPromptRecovery() }
                }
                .padding(12).background(ElevateTheme.paperDeep)
            }
        PromptComposer(
            text: text,
            images: images,
            focusRequest: focusRequest,
            allowsAutomaticFocus: {
                CLIPrompt.terminalResponseRequest(screen: CLIPrompt.liveScreen(of: session.terminal),
                                                  agent: session.agent) == nil
            },
            mode: mode,
            agentName: agentName,
            projectName: projectName,
            isBusy: session.isSendingPrompt,
            isEnabled: isEnabled,
            dictation: dictation,
            dictationTarget: dictationTarget,
            isDictating: dictation.isActive(for: dictationTarget),
            onDictate: onDictate,
            onActivate: onActivate,
            onTerminal: onTerminal,
            onSubmit: onSubmit
        )
        }
    }

    private var mode: PromptComposer.Mode {
        guard session.hostsConversation else { return .start }
        return session.acceptsPromptText ? .send : .blocked
    }
}

/// Names the provider and conversation above each side-by-side pane. The
/// pane with the keyboard carries the ink rule, as the toolbar marks its
/// provider.
private struct PaneHeader: View {
    @ObservedObject var session: TerminalSession
    let isActive: Bool
    let onSelect: () -> Void

    private var title: String {
        session.hostsConversation || session.pendingResumeID != nil ? session.displayTitle : "New conversation"
    }

    private var status: String {
        if session.pendingResumeID != nil { return "RESTORED" }
        if session.hostsConversation {
            return session.isWorking ? "WORKING" : session.acceptsPromptText ? "READY" : "NEEDS INPUT"
        }
        return session.state == .idle ? "NEW" : session.state.description.uppercased()
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: ElevateTheme.spacing8) {
                PixelMark(sprite: session.agent.mark, color: isActive ? ElevateTheme.ink : ElevateTheme.graphite)
                Text(session.agent.title.uppercased())
                    .font(ElevateTheme.utility(11, medium: true))
                    .foregroundStyle(isActive ? ElevateTheme.ink : ElevateTheme.graphite)
                    .fixedSize()
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(ElevateTheme.graphite)
                    .lineLimit(1)
                Spacer(minLength: ElevateTheme.spacing8)
                Text(status)
                    .font(ElevateTheme.utility(10))
                    .tracking(0.3)
                    .foregroundStyle(ElevateTheme.graphite)
                    .fixedSize()
            }
            .padding(.horizontal, ElevateTheme.spacing24)
            .frame(height: 36)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ElevateTheme.paper)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isActive ? ElevateTheme.ink : ElevateTheme.borderSubtle)
                    .frame(height: isActive ? 2 : ElevateTheme.hairlineWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ElevateHoverButtonStyle())
        .help(isActive ? "\(session.agent.title) has the keyboard" : "Use \(session.agent.title)")
        .accessibilityLabel("\(session.agent.title), \(title), \(status.capitalized)")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
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
    let onProjectTools: () -> Void
    let onProductionTools: () -> Void
    let onSharedChat: () -> Void
    let showCLIInput: Binding<Bool>
    @ObservedObject var tools: WorkspaceTools
    let onTerminal: () -> Void

    private var activityTitle: String {
        if session.hostsConversation { return session.isWorking ? "Working" : session.acceptsPromptText ? "Ready" : "Needs input" }
        return session.state.description
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 850
        HStack(alignment: .center, spacing: 0) {
            Button(action: onToggleSidebar) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(ElevateTheme.ink)
                    .frame(width: 40, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ElevateHoverButtonStyle())
            .accessibilityLabel(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            .help(sidebarVisible ? "Hide sidebar" : "Show sidebar")
            .padding(.trailing, ElevateTheme.spacing16)

            VStack(alignment: .leading, spacing: 3) {
                Text(model.workingDirectory.lastPathComponent)
                    .font(ElevateTheme.serif(compact ? 18 : 21))
                    .foregroundStyle(ElevateTheme.ink)
                    .lineLimit(1)
                    .help(model.workingDirectory.path)
                Text("\(model.production.name(for: model.selectedProfileID)) · \(session.hostsConversation ? session.displayTitle : "New conversation")")
                    .font(.system(size: 11))
                    .foregroundStyle(ElevateTheme.graphite)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                ForEach(Agent.allCases) { agent in
                    Button { model.selected = agent } label: {
                        let tint = model.selected == agent ? ElevateTheme.ink : ElevateTheme.graphite
                        HStack(spacing: ElevateTheme.spacing8) {
                            PixelMark(sprite: agent.mark, color: tint)
                            Text(agent.title.uppercased())
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
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
                    .buttonStyle(ElevateHoverButtonStyle())
                    .accessibilityLabel(agent.title)
                    .help(model.selected == agent ? "Using \(agent.title)" : "Switch to \(agent.title)")
                    .accessibilityAddTraits(model.selected == agent ? [.isSelected] : [])
                }
            }
            .padding(.trailing, ElevateTheme.spacing8)

            Button { model.isSplit.toggle() } label: {
                Image(systemName: model.isSplit ? "rectangle.split.2x1.fill" : "rectangle.split.2x1")
                    .font(.system(size: 15))
                    .foregroundStyle(model.isSplit ? ElevateTheme.ink : ElevateTheme.graphite)
                    .frame(width: 36, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(ElevateHoverButtonStyle())
            .keyboardShortcut("\\", modifiers: .command)
            .help(model.isSplit ? "Show one provider (⌘\\)" : "Show Claude and Codex side by side (⌘\\)")
            .accessibilityLabel("Claude and Codex side by side")
            .accessibilityAddTraits(model.isSplit ? [.isSelected] : [])
            .padding(.trailing, compact ? ElevateTheme.spacing8 : ElevateTheme.spacing16)

            ModelEffortMenu(model: model, session: session, compact: compact)
                .padding(.trailing, 8)

            if !compact {
                Button(action: onSharedChat) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 15))
                        .frame(width: 36, height: 44)
                }
                .buttonStyle(ElevateHoverButtonStyle())
                .accessibilityLabel("Shared chat with Claude and Codex")
                .help("Talk with Claude and Codex in one shared discussion")
                .disabled(!model.isCurrentProjectAvailable)
            }

            Menu {
                Text("\(model.selected.title) · \(activityTitle)")
                Text(session.accountStatus)
                if session.backgroundTerminalCount > 0 {
                    Divider()
                    Text("\(session.backgroundTerminalCount) background terminals")
                    Button("View terminals") {
                        if session.sendPrompt("/ps") { onTerminal() }
                    }
                    .disabled(!session.acceptsPromptText || session.isSendingPrompt)
                }
                Divider()
                Button("Terminal controls", action: onTerminal)
            } label: {
                HStack(spacing: 6) {
                    Circle().fill(session.isWorking ? ElevateTheme.signal : ElevateTheme.graphite).frame(width: 5, height: 5)
                    Text(activityTitle).font(.system(size: 11))
                    if session.backgroundTerminalCount > 0 {
                        Text("· \(session.backgroundTerminalCount)").font(.system(size: 11))
                    }
                }
                .foregroundStyle(ElevateTheme.graphite)
                .padding(.horizontal, 10)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Session activity")
            .help("\(model.selected.title) · \(activityTitle)\(session.accountStatus.isEmpty ? "" : " · \(session.accountStatus)")")
            .padding(.trailing, 8)

            if tools.root(for: model.workingDirectory) != nil {
                Menu {
                    ForEach(WorkspaceTools.Tool.allCases, id: \.self) { tool in
                        Button {
                            Task { await tools.open(tool, project: model.workingDirectory) }
                        } label: { Label(tool.title, systemImage: tool.symbol) }
                    }
                } label: {
                    Image(systemName: "play.rectangle").font(.system(size: 16)).frame(width: 32, height: 36)
                }
                .menuStyle(.borderlessButton)
                .disabled(tools.opening != nil)
                .help(tools.opening.map { "Opening \($0.title)…" } ?? "Animation tools")
                .accessibilityLabel("Animation tools")
                .padding(.trailing, 8)
            }

            Button(action: onProjectTools) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 17))
                    .foregroundStyle(ElevateTheme.ink)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(ElevateHoverButtonStyle())
            .help("Project brief, tasks, and Git workspaces")
            .accessibilityLabel("Project tools")
            .disabled(!model.isCurrentProjectAvailable)
            .padding(.trailing, ElevateTheme.spacing8)

            Button(action: onProductionTools) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 17)).frame(width: 36, height: 44)
            }.buttonStyle(ElevateHoverButtonStyle()).help("Changes, checks, workflows, and app controls")
                .accessibilityLabel("Workspace tools").keyboardShortcut("k", modifiers: [.command, .shift])

            Button(action: onNewConversation) {
                HStack(spacing: 9) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    if !compact {
                        Text("NEW CONVERSATION")
                            .font(ElevateTheme.utility(11, medium: true))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .foregroundStyle(ElevateTheme.onSignal)
                .padding(.horizontal, ElevateTheme.spacing16)
                .frame(height: 44)
                .background(ElevateTheme.signal, in: RoundedRectangle(cornerRadius: ElevateTheme.controlRadius))
            }
            .buttonStyle(ElevateHoverButtonStyle())
            .disabled(!model.isCurrentProjectAvailable)
            .accessibilityLabel("New conversation")
            .help("Start a blank \(model.selected.title) conversation (⌘N)")
            .keyboardShortcut("n", modifiers: .command)
            .padding(.trailing, ElevateTheme.spacing8)

            Menu {
                Toggle("Claude and Codex side by side", isOn: $model.isSplit)
                Button("Shared chat with Claude and Codex…", action: onSharedChat)
                    .disabled(!model.isCurrentProjectAvailable)
                Toggle("Show CLI input and status", isOn: showCLIInput)
                Button("Focus terminal controls", action: onTerminal)
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("Log in or view login") { onLogin() }
                    .disabled(!model.isCurrentProjectAvailable)
                Button("Check account status") {
                    session.refreshAccountStatus(in: model.isCurrentProjectAvailable
                        ? model.workingDirectory
                        : FileManager.default.homeDirectoryForCurrentUser)
                }
                Divider()
                Button("Project brief, tasks, and workspaces…", action: onProjectTools)
                Button("Changes, checks, and workflows…", action: onProductionTools)
                Menu("Account profile") {
                    ForEach(model.production.profiles) { profile in
                        Button(profile.name + (model.selectedProfileID == profile.id ? " ✓" : "")) { model.selectProfile(profile.id) }
                    }
                    Button("Manage profiles…", action: onProductionTools)
                }
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
        .frame(height: 68)
        .padding(.horizontal, ElevateTheme.spacing24)
        }
        .frame(height: 68)
        .background(ElevateTheme.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ElevateTheme.borderSubtle).frame(height: ElevateTheme.hairlineWidth)
        }
    }
}

/// Model and reasoning effort for the selected provider's next conversation.
private struct ModelEffortMenu: View {
    @ObservedObject var model: HostModel
    @ObservedObject var session: TerminalSession
    let compact: Bool

    private var agent: Agent { model.selected }
    private var catalog: ModelCatalog { model.modelCatalogs[agent] ?? ModelCatalog(options: [], defaultModel: nil) }
    private var choice: ModelChoice { model.modelChoice(for: agent) }

    private var efforts: [String] {
        let efforts = catalog.efforts(for: choice.model)
        guard let effort = choice.effort, !efforts.contains(effort) else { return efforts }
        return efforts + [effort]
    }

    /// Names the profile's default model when it is known, so the label
    /// says what a new conversation will actually run.
    private func summary(_ choice: ModelChoice) -> String {
        let name = (choice.model ?? catalog.defaultModel).map(catalog.title(for:)) ?? "Default model"
        return choice.effort.map { "\(name) · \(ModelCatalog.effortTitle($0))" } ?? name
    }

    var body: some View {
        Menu {
            Text("For new and resumed \(agent.title) conversations")
            if session.hostsConversation, session.launchedChoice != choice {
                Text("This conversation: \(summary(session.launchedChoice))")
            }
            Section("Model") {
                Picker("Model", selection: Binding(
                    get: { choice.model },
                    set: { model.setModelChoice(ModelChoice(model: $0, effort: choice.effort), for: agent) }
                )) {
                    Text(catalog.defaultModel.map { "Profile default (\(catalog.title(for: $0)))" } ?? "Profile default")
                        .tag(String?.none)
                    ForEach(catalog.including(choice.model)) { option in
                        Text(option.title).tag(Optional(option.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("Reasoning effort") {
                Picker("Reasoning effort", selection: Binding(
                    get: { choice.effort },
                    set: { model.setModelChoice(ModelChoice(model: choice.model, effort: $0), for: agent) }
                )) {
                    Text("Profile default").tag(String?.none)
                    ForEach(efforts, id: \.self) { effort in
                        Text(ModelCatalog.effortTitle(effort)).tag(Optional(effort))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu").font(.system(size: 12))
                if !compact { Text(summary(choice)).font(.system(size: 11)).lineLimit(1) }
            }
            .foregroundStyle(ElevateTheme.graphite)
            .padding(.horizontal, 10)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model and reasoning effort for new conversations")
        .accessibilityLabel("Model and reasoning effort")
        .accessibilityValue(summary(choice))
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
            session.restorableConversationID.map { session.agent.rawValue + ":" + $0.lowercased() }
        })
        let records = model.conversationsForCurrentProject()
            .filter { !runningIDs.contains($0.id.lowercased()) }
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
            .frame(height: 68)
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
                .buttonStyle(ElevateHoverButtonStyle())
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
                .buttonStyle(ElevateHoverButtonStyle())
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
        .buttonStyle(ElevateHoverButtonStyle())
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
        .buttonStyle(ElevateHoverButtonStyle())
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
        return session.isWorking ? "WORKING" : "WAITING"
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
                    if session.pendingResumeID != nil {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    if attentionMessage != nil { AttentionPixel() }
                    Text("\(session.agent.title.uppercased()) · \(status)")
                        .font(ElevateTheme.utility(10, medium: attentionMessage != nil))
                        .tracking(0.3)
                        .foregroundStyle(attentionMessage != nil ? ElevateTheme.ink : ElevateTheme.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(session.pendingResumeID != nil
                      ? "Saved from the previous launch. Select to start the CLI and resume."
                      : attentionMessage ?? "")
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
        .buttonStyle(ElevateHoverButtonStyle())
        .help("\(session.agent.title) · \(session.displayTitle) · \(status.capitalized). Select to open this session.")
        .accessibilityLabel("\(session.agent.title), \(session.displayTitle), \(status.capitalized)")
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

@MainActor
struct HostView: View {
    let appDelegate: PrivateCLIAppDelegate
    @StateObject private var model: HostModel
    @StateObject private var production: ProductionCenter
    @State private var hasStarted = false
    @State private var sidebarVisible = true
    @State private var showingStopConfirmation = false
    @State private var pendingStopSession: TerminalSession?
    @State private var showingCodexIdentityConfirmation = false
    @State private var pendingSavedConversation: ConversationRecord?
    @State private var taskDrafts: [String: String] = [:]
    @State private var imageDrafts: [String: [PromptImage]] = [:]
    @State private var showCLIInput = false
    /// One counter per provider, so a request moves the keyboard into that
    /// provider's composer and no other.
    @State private var promptFocusRequests: [Agent: Int] = [:]
    /// Set when a pane changes in order to reach its terminal.
    @State private var terminalFocusPending: Agent?
    @State private var handoffDraft: HandoffDraft?
    @State private var projectToolsRequest: ProjectToolsRequest?
    @State private var showingProductionTools = false
    @State private var showingSharedChat = false
    @StateObject private var tools = WorkspaceTools()
    @StateObject private var dictation = Dictation()

    init(appDelegate: PrivateCLIAppDelegate) {
        self.init(appDelegate: appDelegate, model: HostModel())
    }

    init(appDelegate: PrivateCLIAppDelegate, model: HostModel) {
        self.appDelegate = appDelegate
        _model = StateObject(wrappedValue: model)
        _production = StateObject(wrappedValue: model.production)
    }

    private func draftKey(for session: TerminalSession) -> String {
        "\(model.workingDirectory.path):\(session.agent.rawValue):\(session.id)"
    }

    /// The draft of the session with the keyboard.
    private var taskDraftKey: String { draftKey(for: model.currentSession) }

    private func imageDraft(for session: TerminalSession) -> Binding<[PromptImage]> {
        let key = draftKey(for: session)
        return Binding(
            get: { imageDrafts[key] ?? [] },
            set: { imageDrafts[key] = $0; persistDraft(key: key, session: session) }
        )
    }

    private func taskDraft(for session: TerminalSession) -> Binding<String> {
        let key = draftKey(for: session)
        return Binding(
            get: { taskDrafts[key] ?? "" },
            set: { taskDrafts[key] = $0; persistDraft(key: key, session: session) }
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
                        let directory = model.workingDirectory
                        let profile = model.selectedProfileID
                        let excerpt = CLIPrompt.liveScreen(of: session.terminal).joined(separator: "\n")
                        let records = model.verification.records
                        let store = model.projectContextStore
                        Task {
                            do {
                                let notes = try await store.load(path: directory.path)
                                let context = await Task.detached(priority: .utility) {
                                    HandoffEvidence.build(project: directory, notes: notes, checks: records, terminal: excerpt)
                                }.value
                                guard model.workingDirectory == directory, model.selectedProfileID == profile else { return }
                                handoffDraft = HandoffDraft(source: session.agent.title, target: session.agent == .claude ? "Codex" : "Claude",
                                    projectPath: directory.path, context: context, profileID: profile)
                            } catch { model.operationError = error.localizedDescription }
                        }
                    },
                    onProjectTools: { projectToolsRequest = ProjectToolsRequest(directory: model.workingDirectory) },
                    onProductionTools: { showingProductionTools = true },
                    onSharedChat: { dictation.finish(); showingSharedChat = true },
                    showCLIInput: $showCLIInput,
                    tools: tools,
                    onTerminal: { focusTerminal() }
                )
                if !model.isSplit, !model.currentSession.compatibility.usesComposer {
                    compatibilityBanner(model.currentSession)
                }
                if !production.drafts.isEmpty {
                    HStack {
                        Text("\(production.drafts.count) saved draft\(production.drafts.count == 1 ? "" : "s")").font(.caption)
                        Spacer()
                        Button("Review recovery") { showingProductionTools = true }
                    }.padding(.horizontal, 24).padding(.vertical, 4)
                }
                if model.isSplit {
                    HStack(spacing: 0) {
                        sessionPane(model.currentWorkspace.session(for: .claude), split: true)
                        Rectangle().fill(ElevateTheme.border).frame(width: ElevateTheme.hairlineWidth)
                        sessionPane(model.currentWorkspace.session(for: .codex), split: true)
                    }
                } else {
                    sessionPane(model.currentSession, split: false)
                }
            }
        }
        .onChange(of: taskDraftKey) { key in
            // The words still land in the draft that was listening.
            if dictation.target != key { dictation.finish() }
            // A pane changed to reach its terminal keeps the terminal in front.
            if let pending = terminalFocusPending, pending == model.selected {
                terminalFocusPending = nil
                return
            }
            terminalFocusPending = nil
            showCLIInput = false
            requestPromptFocus()
        }
        .background {
            Button("Focus message") {
                showCLIInput = false
                requestPromptFocus()
            }
            .keyboardShortcut("l", modifiers: .command)
            .hidden()
        }
        .alert("Could not open animation tool", isPresented: Binding(
            get: { tools.errorMessage != nil },
            set: { if !$0 { tools.errorMessage = nil } }
        )) {
            Button("OK") { tools.errorMessage = nil }
        } message: { Text(tools.errorMessage ?? "") }
        .frame(minWidth: 960, minHeight: 600)
        .background(ElevateTheme.paper)
        .sheet(item: $projectToolsRequest) { request in
            let directory = request.directory
            ProjectToolsView(directory: directory, store: model.projectContextStore, onOpenWorkspace: model.openWorkspace) { owner, prompt in
                guard model.workingDirectory == directory else { return false }
                let previous = model.selected
                model.selected = owner == "Claude" ? .claude : .codex
                guard model.startNewConversation(initialPrompt: prompt) else {
                    model.selected = previous
                    return false
                }
                return true
            }
        }
        .sheet(item: $handoffDraft) { draft in
            HandoffView(draft: draft, recovery: production) { prompt in
                _ = try await model.startHandoff(draft, prompt: prompt)
            }
        }
        .sheet(isPresented: $showingProductionTools) {
            ProductionToolsView(model: model, center: production, onRecover: recoverDraft)
        }
        .sheet(isPresented: $showingSharedChat) {
            SharedChatView(chat: model.sharedChat)
        }
        .alert("Workspace tools", isPresented: Binding(get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } })) {
            Button("OK") { model.operationError = nil }
        } message: { Text(model.operationError ?? "") }
        .alert("Dictation", isPresented: Binding(get: { dictation.problem != nil }, set: { if !$0 { dictation.problem = nil } })) {
            if dictation.problem?.opensPrivacySettings == true {
                Button("Open System Settings") { Dictation.openMicrophoneSettings() }
            }
            Button("OK", role: .cancel) {}
        } message: { Text(dictation.problem?.message ?? "") }
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
            let smokeReport = ProcessInfo.processInfo.environment["M4IX_PACKAGED_SMOKE_REPORT"]
            // Packaged verification manages its own startup conversations.
            if smokeReport == nil { model.startOnLaunch() }
            model.refreshCurrentAccountStatus()
            model.refreshHistory()
            model.startPeriodicWork()
            dictation.monitorCapsLock { toggleDictation(for: model.currentSession) }
            if let report = smokeReport {
                Task { await PackagedSmoke.run(model: model, report: URL(fileURLWithPath: report)) }
            }
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
            tools.stopOwnedServer()
        }
    }

    private func persistDraft(key: String? = nil, session: TerminalSession? = nil) {
        let key = key ?? taskDraftKey
        let session = session ?? model.currentSession
        production.saveDraft(id: session.id, project: session.projectPath, provider: session.agent.rawValue,
            profileID: session.profileID, text: taskDrafts[key] ?? "", images: (imageDrafts[key] ?? []).map(\.url))
    }

    private func recoverDraft(_ draft: RecoveryDraft) {
        guard production.profiles.contains(where: { $0.id == draft.profileID }), let provider = Agent(rawValue: draft.provider),
              ProjectRecord(path: draft.project).isAvailable else {
            model.operationError = "The draft's project or account profile is unavailable. Restore access before opening it."
            return
        }
        model.selectProfile(draft.profileID)
        model.openWorkspace(URL(fileURLWithPath: draft.project))
        model.selected = provider
        if draft.kind == "Handoff" {
            guard let payload = try? JSONDecoder().decode(HandoffRecoveryPayload.self, from: Data(draft.text.utf8)) else {
                model.operationError = "This handoff draft could not be decoded. Its saved copy has been kept."; return
            }
            DispatchQueue.main.async {
                handoffDraft = HandoffDraft(id: draft.id, source: payload.source, target: payload.target, projectPath: draft.project,
                    context: payload.context, profileID: draft.profileID, initialTask: payload.task)
            }
            return
        }
        let images = draft.images.compactMap { path -> PromptImage? in
            let url = URL(fileURLWithPath: path)
            return NSImage(contentsOf: url).map { PromptImage(url: url, thumbnail: $0) }
        }
        guard images.count == draft.images.count else {
            model.operationError = "An attachment could not be read. The saved draft has been kept."; return
        }
        guard model.startNewConversation() else { model.operationError = "Could not open a conversation for this draft."; return }
        taskDrafts[taskDraftKey] = draft.text
        imageDrafts[taskDraftKey] = images
        persistDraft()
        production.removeDraft(draft.id)
        requestPromptFocus()
    }

    /// One provider's terminal and composer. Side by side, each pane keeps
    /// its own draft, dictation, dropped images, and keyboard focus.
    @ViewBuilder
    private func sessionPane(_ session: TerminalSession, split: Bool) -> some View {
        let agent = session.agent
        let key = draftKey(for: session)
        let isActive = model.selected == agent
        VStack(spacing: 0) {
            if split {
                PaneHeader(session: session, isActive: isActive) {
                    activate(agent)
                    requestPromptFocus(agent)
                }
                if !session.compatibility.usesComposer { compatibilityBanner(session) }
            }
            TerminalDeck(terminal: session.terminal, agent: agent,
                         hidesPrompt: !(showCLIInput && isActive) && session.compatibility.usesComposer,
                         takesAutomaticFocus: isActive,
                         onActivate: { activate(agent) },
                         onPromptFocus: { activate(agent); requestPromptFocus(agent) }) { images in
                imageDrafts[key, default: []] += images
                persistDraft(key: key, session: session)
                requestPromptFocus(agent)
            }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if session.state == .idle, session.pendingResumeID == nil {
                        VStack(spacing: 12) {
                            PixelMark(sprite: agent.mark, color: ElevateTheme.ash)
                            Text("New conversation")
                                .font(ElevateTheme.serif(24))
                                .foregroundStyle(Color(nsColor: ElevateTheme.terminalForeground))
                            Text("Write below, or choose a saved conversation.")
                                .font(.system(size: 12))
                                .foregroundStyle(ElevateTheme.ash)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: ElevateTheme.terminalBackground))
                    }
                }
            PromptBar(
                session: session,
                dictation: dictation,
                dictationTarget: key,
                text: taskDraft(for: session),
                images: imageDraft(for: session),
                focusRequest: promptFocusRequests[agent, default: 0],
                agentName: agent.title,
                projectName: model.workingDirectory.lastPathComponent,
                isEnabled: model.isCurrentProjectAvailable && session.state != .queued && session.compatibility.usesComposer,
                onDictate: {
                    activate(agent)
                    toggleDictation(for: session)
                },
                onActivate: { activate(agent) },
                onSubmit: { text, images in
                    production.saveDraft(id: session.id, project: session.projectPath, provider: session.agent.rawValue,
                        profileID: session.profileID, text: text, images: images.map(\.url), deliveryUnconfirmed: true)
                    production.flush()
                    let draftID = session.id
                    session.onPromptDelivered = { [weak production = production] in production?.removeDraft(draftID) }
                    let accepted = model.submitPrompt(text, images: images.map(\.url), for: agent)
                    if !accepted { persistDraft(key: key, session: session) }
                    return accepted
                },
                onRecover: { recovery in
                    taskDrafts[key] = recovery.text
                    imageDrafts[key] = recovery.images.compactMap { url in
                        NSImage(contentsOf: url).map { PromptImage(url: url, thumbnail: $0) }
                    }
                    persistDraft(key: key, session: session)
                },
                onTerminal: { focusTerminal(for: agent) }
            )
            .id(key)
        }
        // Images dropped on the terminal wait in the bar, since the
        // terminal itself does not accept drops.
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            activate(agent)
            PromptImageStore.load(providers) {
                imageDrafts[key, default: []] += $0
                persistDraft(key: key, session: session)
                requestPromptFocus(agent)
            }
            return true
        }
    }

    private func compatibilityBanner(_ session: TerminalSession) -> some View {
        HStack {
            Text(session.compatibility.message).font(.callout)
            Spacer()
            Button("Use terminal") { focusTerminal(for: session.agent) }
        }.padding(10).background(ElevateTheme.signal.opacity(0.25))
    }

    private func requestPromptFocus(_ agent: Agent? = nil) {
        promptFocusRequests[agent ?? model.selected, default: 0] += 1
    }

    /// Gives a side-by-side pane the keyboard; the toolbar follows it.
    private func activate(_ agent: Agent) {
        if model.selected != agent { model.selected = agent }
    }

    /// Dictation writes into a session's draft, after the text already
    /// there. The draft is saved once the words settle.
    private func toggleDictation(for session: TerminalSession) {
        guard dictation.phase == .idle else { return dictation.finish() }
        guard model.isCurrentProjectAvailable, session.state != .queued, session.compatibility.usesComposer else { return }
        let key = draftKey(for: session)
        let base = taskDrafts[key] ?? ""
        dictation.start(target: key) { transcript, isFinal in
            taskDrafts[key] = DictationText.join(base, transcript)
            guard isFinal else { return }
            persistDraft(key: key, session: session)
            if model.selected == session.agent { requestPromptFocus(session.agent) }
        }
    }

    private func focusTerminal(for agent: Agent? = nil) {
        let agent = agent ?? model.selected
        if agent != model.selected {
            terminalFocusPending = agent
            model.selected = agent
        }
        showCLIInput = true
        let terminal = model.currentWorkspace.session(for: agent).terminal
        DispatchQueue.main.async { terminal.window?.makeFirstResponder(terminal) }
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
final class PrivateCLIAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
        model?.prepareForTermination()
        guard let model else { return .terminateNow }
        terminationPending = true
        model.stopAllSessions()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while (model.hasRunningSessions || model.verification.hasRunningChecks) && Date() < deadline {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            model.forceStopRemainingSessions()
            await model.flushSharedChats()
            model.production.flush()
            model.verification.flush()
            if let update = model.pendingUpdate {
                do { try AppUpdates.installAfterExit(update, root: model.dataRoot) }
                catch {
                    self.terminationPending = false
                    model.cancelTermination(message: "The update could not be scheduled: \(error.localizedDescription)")
                    sender.reply(toApplicationShouldTerminate: false)
                    return
                }
            }
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
