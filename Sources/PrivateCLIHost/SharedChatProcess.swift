import Darwin
import Foundation

struct SharedChatReply: Sendable {
    let text: String
    let sessionID: String
}

/// Decodes public reply events only. Reasoning, tool output and nested agent
/// messages never become messages from a participant in the shared room.
struct SharedChatDecoder {
    let provider: String
    private(set) var sessionID: String?
    private(set) var text = ""
    private(set) var completed = false
    private(set) var failure: String?
    private var pending = Data()
    private var lastAgentText = ""

    init(provider: String) { self.provider = provider }

    mutating func append(_ data: Data) throws {
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = pending.prefix(upTo: newline)
            guard line.count <= 2_000_000 else { throw CommandError.failed("A reply event exceeded the size limit.") }
            if !line.isEmpty { try consume(Data(line)) }
            pending.removeSubrange(...newline)
        }
        guard pending.count <= 2_000_000 else { throw CommandError.failed("A reply event exceeded the size limit.") }
    }

    mutating func finish(status: Int32) throws -> SharedChatReply {
        if !pending.isEmpty { try consume(pending); pending.removeAll() }
        if let failure { throw CommandError.failed(failure) }
        guard status == 0 else { throw CommandError.failed("\(provider.capitalized) exited with status \(status).") }
        guard completed, let sessionID, UUID(uuidString: sessionID) != nil,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandError.failed("\(provider.capitalized) did not return a complete reply. No message was forwarded.")
        }
        return SharedChatReply(text: text, sessionID: sessionID)
    }

    private mutating func consume(_ data: Data) throws {
        guard let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            throw CommandError.failed("The CLI returned an unrecognized reply event.")
        }
        if provider == "codex" {
            switch type {
            case "thread.started": sessionID = event["thread_id"] as? String
            case "item.completed", "item.updated":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message",
                   let body = item["text"] as? String {
                    lastAgentText = body
                    text = body
                }
            case "turn.completed": completed = true; text = lastAgentText
            case "turn.failed", "error":
                let error = event["error"] as? [String: Any]
                failure = error?["message"] as? String ?? event["message"] as? String ?? "Codex could not finish this reply."
            default: break
            }
        } else {
            // Foreground and background subagents use the same event names.
            if let parent = event["parent_tool_use_id"], !(parent is NSNull) { return }
            if let id = event["session_id"] as? String { sessionID = id }
            switch type {
            case "stream_event":
                guard let body = event["event"] as? [String: Any] else { return }
                if body["type"] as? String == "message_start" { text = "" }
                if let delta = body["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                   let fragment = delta["text"] as? String { text += fragment }
            case "assistant":
                if let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] {
                    let body = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                    if !body.isEmpty { text = body }
                }
            case "result":
                if event["is_error"] as? Bool == true || event["subtype"] as? String != "success" {
                    failure = (event["errors"] as? [String])?.joined(separator: "\n") ?? event["result"] as? String ?? "Claude could not finish this reply."
                } else {
                    text = event["result"] as? String ?? ""
                    completed = true
                }
            default: break
            }
        }
        guard text.utf8.count <= 200_000 else { throw CommandError.failed("The reply exceeded the shared chat size limit.") }
    }
}

struct SharedChatRequest: Sendable {
    let provider: String
    let project: URL
    let profileBase: URL
    let sessionID: String?
    let choice: ModelChoice
    let prompt: String
}

/// A finite CLI turn with typed arguments, private stdin, separate protocol
/// and diagnostics pipes, and a process group owned by this turn alone.
enum SharedChatProcess {
    static func run(_ request: SharedChatRequest, launcher: URL,
                    cancellation: CommandCancellation, timeout: TimeInterval = 600,
                    environment overrides: [String: String]? = nil,
                    onText: @escaping @Sendable (String) -> Void) throws -> SharedChatReply {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard ["claude", "codex"].contains(request.provider), request.prompt.utf8.count <= 500_000 else {
            throw CommandError.failed("The shared chat request is invalid or too large. Start a new discussion.")
        }
        let output = Pipe(), diagnostics = Pipe()
        defer {
            for pipe in [output, diagnostics] {
                try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close()
            }
        }
        // An unlinked file avoids blocking on a large stdin pipe before the
        // child starts reading. Its name and contents never enter argv.
        var inputName = Array((NSTemporaryDirectory() + "m4ix-shared-input.XXXXXX").utf8CString)
        let input = mkstemp(&inputName)
        guard input >= 0 else { throw CommandError.failed("Could not prepare the shared chat message.") }
        _ = unlink(inputName)
        defer { _ = Darwin.close(input) }
        try Data(request.prompt.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(input, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw CommandError.failed("Could not write the shared chat message.") }
                offset += written
            }
        }
        guard lseek(input, 0, SEEK_SET) == 0 else { throw CommandError.failed("Could not read the shared chat message.") }
        for pipe in [output, diagnostics] {
            let fd = pipe.fileHandleForReading.fileDescriptor
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) >= 0 else {
                throw CommandError.failed("Could not prepare shared chat output.")
            }
        }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, diagnostics.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        for fd in [input, output.fileHandleForReading.fileDescriptor, output.fileHandleForWriting.fileDescriptor,
                   diagnostics.fileHandleForReading.fileDescriptor, diagnostics.fileHandleForWriting.fileDescriptor] {
            posix_spawn_file_actions_addclose(&actions, fd)
        }
        posix_spawn_file_actions_addchdir_np(&actions, request.project.path)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
        let args = ["/bin/bash", launcher.path, request.provider, "discuss"] + (request.sessionID.map { [$0] } ?? [])
        var environment = overrides ?? ProcessInfo.processInfo.environment
        environment["PRIVATE_CLI_HOST_DATA_DIR"] = request.profileBase.path
        environment["PRIVATE_CLI_HOST_MODEL"] = request.choice.model
        environment["PRIVATE_CLI_HOST_EFFORT"] = request.choice.effort
        let argv: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let error = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { values in
                posix_spawn(&pid, "/bin/bash", &actions, &attributes, args.baseAddress!, values.baseAddress!)
            }
        }
        guard error == 0 else { throw CommandError.failed("Could not start \(request.provider.capitalized): \(String(cString: strerror(error)))") }
        try? output.fileHandleForWriting.close()
        try? diagnostics.fileHandleForWriting.close()
        var reaped = false
        defer {
            _ = Darwin.kill(-pid, SIGKILL)
            if !reaped { while waitpid(pid, nil, 0) < 0 && errno == EINTR {} }
        }
        var decoder = SharedChatDecoder(provider: request.provider)
        var stderr = Data(), bytesRead = 0
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var status: Int32 = 0
        let start = ProcessInfo.processInfo.systemUptime
        var lastUpdate = start, lastText = ""
        var stoppingAt: TimeInterval?
        func drain() throws {
            for (pipe, isOutput) in [(output, true), (diagnostics, false)] {
                for _ in 0..<32 {
                    let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
                    guard count > 0 else { break }
                    if isOutput {
                        bytesRead += count
                        guard bytesRead <= 16_000_000 else { throw CommandError.failed("The CLI output exceeded the shared chat limit.") }
                        try decoder.append(Data(buffer.prefix(count)))
                    } else {
                        stderr.append(contentsOf: buffer.prefix(count))
                        if stderr.count > 16_384 { stderr.removeFirst(stderr.count - 16_384) }
                    }
                }
            }
        }
        while true {
            try drain()
            let now = ProcessInfo.processInfo.systemUptime
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0, errno != EINTR { throw CommandError.failed("Could not read the CLI result.") }
            if stoppingAt == nil, cancellation.isCancelled || now - start >= timeout {
                stoppingAt = now
                _ = Darwin.kill(-pid, SIGTERM)
            }
            if let stoppingAt, now - stoppingAt > 0.5 { _ = Darwin.kill(-pid, SIGKILL) }
            if now - lastUpdate >= 0.1, decoder.text != lastText {
                onText(decoder.text); lastText = decoder.text; lastUpdate = now
            }
            usleep(10_000)
        }
        try drain()
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard stoppingAt == nil else { throw CommandError.timedOut }
        let code = status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        do { return try decoder.finish(status: code) }
        catch {
            if code != 0, !stderr.isEmpty {
                throw CommandError.failed("\(error.localizedDescription)\n\(String(decoding: stderr, as: UTF8.self))")
            }
            throw error
        }
    }
}
