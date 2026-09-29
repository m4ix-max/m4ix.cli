import AppKit
import Foundation

/// Small local lifecycle log for diagnosing failures without recording prompts,
/// conversation titles, account data, or project paths.
@MainActor
enum HostDiagnostics {
    static let logURL = HostPaths.profileBase.appendingPathComponent("host-events.jsonl")
    private static let previousURL = HostPaths.profileBase.appendingPathComponent("host-events.previous.jsonl")
    private static let maxBytes: UInt64 = 1_000_000

    static func record(_ event: String, agent: String? = nil, session: UUID? = nil, exitCode: Int32? = nil,
                       details: [String: Any] = [:]) {
        var entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "event": event,
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        ]
        if let agent { entry["agent"] = agent }
        if let session { entry["hostSession"] = session.uuidString.lowercased() }
        if let exitCode { entry["exitCode"] = exitCode }
        entry.merge(details) { current, _ in current }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }

        do {
            try FileManager.default.createDirectory(
                at: HostPaths.profileBase,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            if let size = (try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber,
               size.uint64Value > maxBytes {
                try? FileManager.default.removeItem(at: previousURL)
                try FileManager.default.moveItem(at: logURL, to: previousURL)
            }
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([0x0A]))
            try handle.close()
        } catch {
            // Diagnostics must never prevent a conversation from starting.
        }
    }

    static func revealInFinder() {
        record("diagnostics_opened")
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }
}

/// Records when a terminal last received output and input. Output arrives on
/// SwiftTerm's parse thread, so reads and writes are locked.
final class TerminalActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var lastOutput: Date?
    private var lastInput: Date?

    func markOutput() { lock.withLock { lastOutput = Date() } }
    func markInput() { lock.withLock { lastInput = Date() } }

    func outputAge(now: Date = Date()) -> TimeInterval? {
        lock.withLock { lastOutput.map { now.timeIntervalSince($0) } }
    }

    func secondsSince(now: Date = Date()) -> (output: Int?, input: Int?) {
        lock.withLock {
            (lastOutput.map { Int(now.timeIntervalSince($0)) }, lastInput.map { Int(now.timeIntervalSince($0)) })
        }
    }
}

/// Catches the failures a lifecycle log cannot see: a main thread that stops
/// answering, and hosted CLIs that stay "running" while dead or silent.
enum HostHealth {
    private static let watchdogQueue = DispatchQueue(label: "m4ix.cli.watchdog", qos: .utility)
    private static var watchdogTimer: DispatchSourceTimer?
    private static var pingSentAt: Date?

    /// Pings the main thread every second. A reply later than two seconds is
    /// logged with its length once the main thread recovers.
    static func startMainThreadWatchdog() {
        watchdogQueue.async {
            guard watchdogTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler {
                guard pingSentAt == nil else { return }
                let sent = Date()
                pingSentAt = sent
                DispatchQueue.main.async {
                    let stall = Date().timeIntervalSince(sent)
                    watchdogQueue.async { pingSentAt = nil }
                    guard stall > 2 else { return }
                    MainActor.assumeIsolated {
                        HostDiagnostics.record("main_thread_stall", details: ["seconds": Int(stall.rounded())])
                    }
                }
            }
            watchdogTimer = timer
            timer.resume()
        }
    }

    static func residentMemoryMB() -> Int? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return Int(info.resident_size / 1_048_576)
    }

    static func isProcessAlive(_ pid: pid_t) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
