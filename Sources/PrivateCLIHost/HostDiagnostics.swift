import AppKit
import Foundation

/// Small local lifecycle log for diagnosing failures without recording prompts,
/// conversation titles, account data, or project paths.
@MainActor
enum HostDiagnostics {
    static let logURL = HostPaths.profileBase.appendingPathComponent("host-events.jsonl")
    private static let previousURL = HostPaths.profileBase.appendingPathComponent("host-events.previous.jsonl")
    private static let maxBytes: UInt64 = 1_000_000
    private static let writer = DispatchQueue(label: "m4ix.cli.diagnostics", qos: .utility)

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

        let destination = logURL
        let previous = previousURL
        let directory = HostPaths.profileBase
        let limit = maxBytes
        writer.async {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber,
                   size.uint64Value > limit {
                    try? FileManager.default.removeItem(at: previous)
                    try FileManager.default.moveItem(at: destination, to: previous)
                }
                if !FileManager.default.fileExists(atPath: destination.path) {
                    FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                   attributes: [.posixPermissions: 0o600])
                }
                let handle = try FileHandle(forWritingTo: destination)
                try handle.seekToEnd()
                try handle.write(contentsOf: data + Data([0x0A]))
                try handle.close()
            } catch {
                // Diagnostics must never prevent a conversation from starting.
            }
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

    func inputAge(now: Date = Date()) -> TimeInterval? {
        lock.withLock { lastInput.map { now.timeIntervalSince($0) } }
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
    private static var stallStack: (lines: [String], sampled: Date)?

    /// Pings the main thread every second. A reply later than two seconds is
    /// logged with its length once the main thread recovers, and with where
    /// the main thread was, sampled once while it still had not answered.
    @MainActor
    static func startMainThreadWatchdog() {
        let mainThread = pthread_mach_thread_np(pthread_self())
        watchdogQueue.async {
            guard watchdogTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: watchdogQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler {
                if let sent = pingSentAt {
                    if stallStack == nil, Date().timeIntervalSince(sent) >= 1.5 {
                        let addresses = ThreadStack.returnAddresses(of: mainThread)
                        let sampled = Date()
                        stallStack = (ThreadStack.describe(addresses), sampled)
                    }
                    return
                }
                let sent = Date()
                pingSentAt = sent
                DispatchQueue.main.async {
                    let answered = Date()
                    let stall = answered.timeIntervalSince(sent)
                    watchdogQueue.async {
                        // A sample taken after the reply shows the main thread back at work.
                        let stack = stallStack.flatMap { $0.sampled < answered ? $0.lines : nil }
                        pingSentAt = nil
                        stallStack = nil
                        guard stall > 2 else { return }
                        DispatchQueue.main.async {
                            var details: [String: Any] = ["seconds": Int(stall.rounded())]
                            if let stack, !stack.isEmpty { details["stack"] = stack }
                            MainActor.assumeIsolated { HostDiagnostics.record("main_thread_stall", details: details) }
                        }
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

    /// Whether a shell runs anywhere below `pid`. Each agent runs its
    /// commands in a shell, so one is found while a command it started is
    /// still going, a server left in the background included.
    static func runsShell(below pid: pid_t) -> Bool {
        let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
        var pending = childProcesses(of: pid)
        var visited = Set<pid_t>()
        while let next = pending.popLast(), visited.count < 4_096 {
            guard visited.insert(next).inserted else { continue }
            var name = [CChar](repeating: 0, count: 256)
            if proc_name(next, &name, UInt32(name.count)) > 0, shells.contains(String(cString: name)) { return true }
            pending += childProcesses(of: next)
        }
        return false
    }

    private static func childProcesses(of pid: pid_t) -> [pid_t] {
        guard pid > 0 else { return [] }
        let count = proc_listchildpids(pid, nil, 0)
        guard count > 0 else { return [] }
        // Room for children started between the two calls.
        var children = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listchildpids(pid, &children, Int32(children.count * MemoryLayout<pid_t>.size))
        return filled > 0 ? children.prefix(Int(filled)).filter { $0 > 0 } : []
    }
}

/// Where a thread is, read from its frame pointers while it is suspended.
/// Until it resumes, nothing may allocate or take a lock it could be holding,
/// so the walk fills memory reserved beforehand and symbols come after.
enum ThreadStack {
    static func returnAddresses(of thread: thread_act_t, limit: Int = 32) -> [UInt] {
        #if arch(arm64)
        let frames = UnsafeMutablePointer<UInt>.allocate(capacity: limit)
        defer { frames.deallocate() }
        var count = 0
        guard thread_suspend(thread) == KERN_SUCCESS else { return [] }
        var state = arm_thread_state64_t()
        var stateCount = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: natural_t.self, capacity: Int(stateCount)) {
                thread_get_state(thread, thread_state_flavor_t(ARM_THREAD_STATE64), $0, &stateCount)
            }
        }
        if status == KERN_SUCCESS {
            // A leaf function has not stored its caller yet; the link register holds it.
            frames[0] = UInt(state.__pc)
            frames[1] = UInt(state.__lr)
            count = 2
            var frame = UInt(state.__fp)
            while count < limit, frame != 0, frame & 0x7 == 0 {
                var record: (caller: UInt, returnAddress: UInt) = (0, 0)
                var copied: vm_size_t = 0
                let read = withUnsafeMutableBytes(of: &record) {
                    vm_read_overwrite(mach_task_self_, vm_address_t(frame), vm_size_t(16),
                                      vm_address_t(UInt(bitPattern: $0.baseAddress)), &copied)
                }
                guard read == KERN_SUCCESS, copied == 16, record.returnAddress != 0 else { break }
                frames[count] = record.returnAddress
                count += 1
                guard record.caller > frame else { break }
                frame = record.caller
            }
        }
        thread_resume(thread)
        // System code signs its return addresses in the high bits.
        return (0..<count).map { frames[$0] & 0x0000_7FFF_FFFF_FFFF }
        #else
        return []
        #endif
    }

    /// One line per frame: the image, the offset `atos -l 0` takes, and the
    /// nearest symbol when the image has one.
    static func describe(_ addresses: [UInt]) -> [String] {
        addresses.map { address in
            var info = Dl_info()
            guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase else {
                return String(format: "0x%lx", address)
            }
            let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
            var line = image + String(format: " +0x%lx", address - UInt(bitPattern: base))
            if let name = info.dli_sname, let start = info.dli_saddr {
                line += " \(readable(name)) + \(address - UInt(bitPattern: start))"
            }
            return line
        }
    }

    private typealias Demangle = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?,
                                                 UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?

    /// The Swift runtime's own demangler, looked up rather than linked so a
    /// missing one leaves names as they are.
    private static let demangle: Demangle? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle")
        .map { unsafeBitCast($0, to: Demangle.self) }

    private static func readable(_ symbol: UnsafePointer<CChar>) -> String {
        guard let demangle, let result = demangle(symbol, strlen(symbol), nil, nil, 0) else { return String(cString: symbol) }
        defer { free(result) }
        return String(cString: result)
    }
}
