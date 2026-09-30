import Darwin
import Foundation

struct CommandResult: Sendable {
    let status: Int32
    let output: String
    let truncated: Bool
}

enum CommandError: LocalizedError {
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The command did not finish in time."
        case .failed(let message): return message
        }
    }
}

/// Run on a worker thread. Output is drained while the child runs, including
/// after the capture limit, so a full pipe cannot block process termination.
enum CommandRunner {
    static func run(executable: String, arguments: [String], directory: URL,
                    environment: [String: String]? = nil, timeout: TimeInterval = 10,
                    outputLimit: Int = 65_536) throws -> CommandResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw CommandError.failed("Could not prepare command output.")
        }
        defer {
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
        }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        var capture = Data()
        var truncated = false
        var buffer = [UInt8](repeating: 0, count: 16_384)
        func drain() {
            // Bound each drain so continuously noisy children cannot prevent
            // the timeout from being checked.
            for _ in 0..<64 {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                guard count > 0 else { return }
                let kept = min(count, max(0, outputLimit - capture.count))
                capture.append(contentsOf: buffer.prefix(kept))
                if kept < count { truncated = true }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.01, timeout)
        while process.isRunning {
            drain()
            if ProcessInfo.processInfo.systemUptime >= deadline {
                process.terminate()
                let grace = ProcessInfo.processInfo.systemUptime + 0.3
                while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
                    drain()
                    usleep(10_000)
                }
                if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                throw CommandError.timedOut
            }
            usleep(10_000)
        }
        drain()
        return CommandResult(status: process.terminationStatus,
                             output: String(decoding: capture, as: UTF8.self), truncated: truncated)
    }
}
