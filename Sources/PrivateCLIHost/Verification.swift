import Darwin
import Foundation

final class CommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.withLock { value } }
    func cancel() { lock.withLock { value = true } }
}

/// A command owns a process group, including children spawned by build tools.
/// Cancelling a check terminates that group without touching hosted agents.
enum ManagedCommand {
    static func run(command: String, directory: URL, cancellation: CommandCancellation,
                    timeout: TimeInterval = 1800, outputLimit: Int = 1_000_000,
                    onOutput: @escaping @Sendable (String) -> Void = { _ in }) throws -> CommandResult {
        let pipe = Pipe()
        let input = pipe.fileHandleForReading.fileDescriptor
        let output = pipe.fileHandleForWriting.fileDescriptor
        defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
        guard fcntl(input, F_SETFL, fcntl(input, F_GETFL) | O_NONBLOCK) >= 0 else {
            throw CommandError.failed("Could not prepare verification output.")
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, input)
        posix_spawn_file_actions_addclose(&actions, output)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        let arguments: [UnsafeMutablePointer<CChar>?] = ["/bin/bash", "-lc", command].map { text in text.withCString { strdup($0) } } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { pair in
            "\(pair.key)=\(pair.value)".withCString { strdup($0) }
        } + [nil]
        defer { arguments.forEach { free($0) }; environment.forEach { free($0) } }
        var pid: pid_t = 0
        let error = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/bash", &actions, &attributes, argv.baseAddress!, env.baseAddress!)
            }
        }
        guard error == 0 else { throw CommandError.failed("Could not launch verification: \(String(cString: strerror(error)))") }
        try? pipe.fileHandleForWriting.close()
        var capture = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var status: Int32 = 0
        var terminatedAt: TimeInterval?
        var timedOut = false
        let start = ProcessInfo.processInfo.systemUptime
        var lastUpdate = start
        func drain() {
            for _ in 0..<32 {
                let count = Darwin.read(input, &buffer, buffer.count)
                guard count > 0 else { return }
                let remaining = max(0, outputLimit - capture.count)
                capture.append(contentsOf: buffer.prefix(min(remaining, count)))
                if count > remaining { truncated = true }
            }
        }
        while true {
            drain()
            let now = ProcessInfo.processInfo.systemUptime
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            if waited < 0, errno != EINTR { throw CommandError.failed("Could not read the verification process result.") }
            if terminatedAt == nil, cancellation.isCancelled || now - start >= timeout {
                timedOut = !cancellation.isCancelled
                terminatedAt = now
                _ = Darwin.kill(-pid, SIGTERM)
            }
            if let terminatedAt, now - terminatedAt > 0.5 { _ = Darwin.kill(-pid, SIGKILL) }
            if now - lastUpdate >= 0.2 {
                onOutput(String(decoding: capture, as: UTF8.self))
                lastUpdate = now
            }
            usleep(10_000)
        }
        // A check is finite; detached descendants must not keep working after it ends.
        _ = Darwin.kill(-pid, SIGTERM)
        drain()
        if timedOut { throw CommandError.timedOut }
        return CommandResult(status: status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f),
                             output: String(decoding: capture, as: UTF8.self), truncated: truncated)
    }
}

struct VerificationCommand: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var command: String
}

struct ProjectAutomation: Codable, Equatable, Sendable {
    var commands: [VerificationCommand] = ["Test", "Lint", "Build"].map { VerificationCommand(id: $0, command: "") }
    var workflows: [WorkflowTemplate] = [.implementation]
}

struct VerificationRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let project: String
    let title: String
    let command: String
    let startedAt: Date
    var finishedAt: Date?
    var state: String
    var exitCode: Int32?
    var output: String
    var fingerprint: String?
    var note: String
}

@MainActor
final class VerificationService: ObservableObject {
    let root: URL
    @Published private(set) var records: [VerificationRecord] = []
    @Published var error: String?
    @Published private(set) var currentFingerprints: [String: String] = [:]
    private var cancellations: [UUID: CommandCancellation] = [:]
    private let writer = DispatchQueue(label: "m4ix.cli.verification", qos: .utility)
    private var writable = true
    private var resultsURL: URL { root.appendingPathComponent("production/check-results.json") }

    init(root: URL) {
        self.root = root
        do {
            records = try PrivateStore.read([VerificationRecord].self, from: resultsURL, default: [])
            for index in records.indices where records[index].state == "Running" {
                records[index].state = "Interrupted"
                records[index].note = "The app stopped before this result was recorded. Run the check again."
            }
        } catch { writable = false; self.error = error.localizedDescription }
    }

    func configuration(for project: URL) throws -> ProjectAutomation {
        try PrivateStore.read(ProjectAutomation.self, from: configurationURL(project), default: ProjectAutomation())
    }

    func save(_ configuration: ProjectAutomation, for project: URL) throws {
        guard writable else { throw CommandError.failed(error ?? "Verification storage is unavailable.") }
        // Validate the existing schema before overwriting it.
        _ = try self.configuration(for: project)
        try PrivateStore.write(configuration, to: configurationURL(project))
    }

    private func configurationURL(_ project: URL) -> URL {
        root.appendingPathComponent("production/automation").appendingPathComponent(PrivateStore.key(project.standardizedFileURL.path) + ".json")
    }

    func refreshFreshness(project: URL) async {
        let snapshot = try? await Task.detached(priority: .utility) { try WorkspaceReview.snapshot(in: project) }.value
        currentFingerprints[project.path] = snapshot?.fingerprint
    }

    func evidenceLabel(_ record: VerificationRecord) -> String {
        guard record.state == "Passed" else { return record.state }
        guard let fingerprint = record.fingerprint else { return "Passed · source not verified" }
        guard let current = currentFingerprints[record.project] else { return "Passed · freshness unchecked" }
        return fingerprint == current ? "Passed · current files" : "Passed · outdated"
    }

    @discardableResult
    func run(title: String, command: String, project: URL, timeout: TimeInterval = 1800) async -> VerificationRecord? {
        guard writable, !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !records.contains(where: { $0.project == project.path && $0.state == "Running" }) else {
            error = "Save a command first and wait for the running check in this project to finish."
            return nil
        }
        let id = UUID()
        let cancellation = CommandCancellation()
        cancellations[id] = cancellation
        records.insert(VerificationRecord(id: id, project: project.path, title: title, command: command,
                       startedAt: Date(), state: "Running", output: "", note: "Capturing source state…"), at: 0)
        persist()
        let result: (CommandResult?, WorkspaceSnapshot?, WorkspaceSnapshot?, String)
        result = await Task.detached(priority: .utility) { [self] in
            let before = try? WorkspaceReview.snapshot(in: project)
            do {
                if cancellation.isCancelled { return (nil, before, nil, "Cancelled before launch.") }
                let output = try ManagedCommand.run(command: command, directory: project, cancellation: cancellation,
                                                    timeout: timeout) { output in
                    Task { @MainActor in
                        guard let index = self.records.firstIndex(where: { $0.id == id && $0.state == "Running" }) else { return }
                        self.records[index].output = output
                        self.records[index].note = ""
                    }
                }
                let after = try? WorkspaceReview.snapshot(in: project)
                return (output, before, after, "")
            } catch { return (nil, before, nil, error.localizedDescription) }
        }.value
        guard let index = records.firstIndex(where: { $0.id == id }) else { return nil }
        let (output, before, after, failure) = result
        records[index].finishedAt = Date()
        records[index].exitCode = output?.status
        records[index].state = cancellation.isCancelled ? "Cancelled" : output?.status == 0 ? "Passed" : "Failed"
        if let output { records[index].output = output.output + (output.truncated ? "\n[Output limited to 1 MB]" : "") }
        records[index].note = failure
        if let before, let after, before.fingerprint == after.fingerprint {
            records[index].fingerprint = after.fingerprint
        } else if output?.status == 0 {
            records[index].note = "Source changed during the check or could not be fingerprinted. Run again before relying on this result."
        }
        currentFingerprints[project.path] = after?.fingerprint
        cancellations.removeValue(forKey: id)
        persist()
        return records[index]
    }

    func cancel(_ id: UUID) { cancellations[id]?.cancel() }
    func cancelAll() { cancellations.values.forEach { $0.cancel() } }
    var hasRunningChecks: Bool { !cancellations.isEmpty }
    func flush() { writer.sync {} }

    private func persist() {
        guard writable else { return }
        let running = records.filter { $0.state == "Running" }
        records = running + Array(records.filter { $0.state != "Running" }.prefix(30))
        let snapshot = records
        let url = resultsURL
        writer.async { [weak self] in
            do { try PrivateStore.write(snapshot, to: url) }
            catch { Task { @MainActor in self?.error = error.localizedDescription } }
        }
    }
}
