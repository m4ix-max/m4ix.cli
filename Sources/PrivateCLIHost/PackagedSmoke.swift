import AppKit
import Darwin
import Foundation

/// Explicit developer verification for a packaged app. A separate preferences
/// suite is mandatory so the user's sidebar and restored sessions stay intact.
@MainActor
enum PackagedSmoke {
    static func run(model: HostModel, report: URL) async {
        var result: [String: Any] = ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "unknown"]
        var resumed: HostModel?
        do {
            guard ProcessInfo.processInfo.environment["PRIVATE_CLI_HOST_PREFERENCES_SUITE"]?.hasPrefix("m4ix.cli.qa.") == true else {
                throw CommandError.failed("Packaged verification requires an isolated m4ix.cli.qa.* preferences suite.")
            }
            guard let launcher = HostPaths.launcher, launcher.path.hasPrefix(Bundle.main.bundleURL.path + "/") else {
                throw CommandError.failed("The packaged launcher resource is missing.")
            }
            result["bundledLauncher"] = true
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            model.openWorkspace(directory)
            model.selected = .claude
            guard model.startNewConversation() else { throw CommandError.failed("Could not start Claude") }
            let claude = model.currentSession
            try await ready(claude)
            let marker = "HOST_PACKAGED_HANDOFF_" + UUID().uuidString.prefix(8)
            guard claude.sendPrompt("Reply with only the word \(marker). Do not use tools or edit files.") else {
                throw CommandError.failed("Claude composer refused the prompt")
            }
            try await response(marker, in: claude)
            result["claudePrompt"] = true

            let store = ProjectContextStore(directory: report.deletingLastPathComponent().appendingPathComponent("project-records"))
            try await store.savePlan(path: directory.path, brief: "Runtime verification only. Do not edit files or use tools.", tasks: [])
            let draft = HandoffDraft(source: "Claude", target: "Codex", projectPath: directory.path,
                                     context: CLIPrompt.liveScreen(of: claude.terminal).joined(separator: "\n"))
            let codex = try await model.startHandoff(draft,
                prompt: draft.prompt(task: "Read the verification word in Claude's reference output. Reply with that exact word only. Do not use tools.", context: draft.context), store: store)
            try await response(marker, in: codex)
            try await ready(codex)
            let saved = try await store.load(path: directory.path)
            guard saved.handoffs.count == 1, saved.handoffs[0].state == "Launch requested" else {
                throw CommandError.failed("Handoff history did not persist")
            }
            result["claudeToCodexHandoff"] = true
            result["durableHandoff"] = true
            model.refreshHistory()
            try await wait(timeout: 10) { claude.activeConversationID != nil && codex.activeConversationID != nil }
            model.refreshHistory()
            try await wait(timeout: 10) { model.conversations.contains { $0.sessionID == codex.activeConversationID } }
            model.saveRestorableSessions()

            // Measure a visible, quiet release app with both conversations live.
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let before = cpuSeconds()
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: 5_000_000_000)
            result["idleCPUPercent"] = (cpuSeconds() - before) / (ProcessInfo.processInfo.systemUptime - start) * 100
            result["residentMemoryMB"] = HostHealth.residentMemoryMB()
            model.prepareForTermination()
            model.stopAllSessions()
            try await wait(timeout: 7) { !model.hasRunningSessions }

            let restored = HostModel()
            resumed = restored
            restored.restoreSessions()
            guard restored.liveSessionsForCurrentProject().count == 2,
                  restored.liveSessionsForCurrentProject().allSatisfy({ $0.pendingResumeID != nil && !$0.state.isRunning }) else {
                throw CommandError.failed("Conversations were not restored lazily")
            }
            let image = try redImage(in: report.deletingLastPathComponent())
            for agent in Agent.allCases {
                guard let session = restored.liveSessionsForCurrentProject().first(where: { $0.agent == agent }) else {
                    throw CommandError.failed("Restored provider missing")
                }
                restored.selectLiveSession(session)
                restored.startCurrentIfPending()
                try await ready(session)
                let previous = count(marker, in: session)
                guard session.sendPrompt("Repeat the exact verification word you previously replied with. Nothing else; do not use tools.") else {
                    throw CommandError.failed("Resumed composer refused prompt")
                }
                try await response(marker, in: session, after: previous)
                result[agent.rawValue + "Resume"] = true
                try await ready(session)
                guard session.sendPrompt("Name the dominant color in the image. Reply only HOST_IMAGE_RED if it is red. Do not use tools.", images: [image]) else {
                    throw CommandError.failed("Image prompt refused")
                }
                try await response("HOST_IMAGE_RED", in: session)
                result[agent.rawValue + "Image"] = true
                session.stop()
                try await wait(timeout: 7) { !session.state.isRunning }
            }
            result["shutdown"] = true
            result["passed"] = true
        } catch {
            result["passed"] = false
            result["error"] = error.localizedDescription
        }
        model.stopAllSessions()
        resumed?.stopAllSessions()
        // Shutdown is checked before recording success.
        do {
            try await wait(timeout: 7) { !model.hasRunningSessions && resumed?.hasRunningSessions != true }
        } catch {
            model.forceStopRemainingSessions()
            resumed?.forceStopRemainingSessions()
            result["passed"] = false
            result["shutdownError"] = error.localizedDescription
        }
        try? FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: report, options: .atomic)
        }
        NSApp.terminate(nil)
    }

    private static func ready(_ session: TerminalSession) async throws {
        try await wait(timeout: 30) {
            session.refreshPromptReadiness()
            return session.acceptsPromptText && !session.isSendingPrompt
        }
    }

    private static func response(_ marker: String, in session: TerminalSession, after baseline: Int = 0) async throws {
        try await wait(timeout: 60) { count(marker, in: session) > baseline || session.promptRecovery != nil }
        guard count(marker, in: session) > baseline else { throw CommandError.failed("Image or prompt delivery was interrupted") }
    }

    private static func count(_ marker: String, in session: TerminalSession) -> Int {
        let prefix = session.agent == .claude ? "⏺ " : "• "
        return String(decoding: session.terminal.getBufferAsData(kind: .active), as: UTF8.self)
            .replacingOccurrences(of: "\u{0}", with: " ")
            .components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespacesAndNewlines) == prefix + marker }.count
    }

    private static func wait(timeout: TimeInterval, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw CommandError.timedOut }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func redImage(in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0), let pixels = bitmap.bitmapData else {
            throw CommandError.failed("Could not create verification image")
        }
        for y in 0..<64 { for x in 0..<64 {
            let index = y * bitmap.bytesPerRow + x * 3
            pixels[index] = 255; pixels[index + 1] = 0; pixels[index + 2] = 0
        } }
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw CommandError.failed("Could not encode verification image") }
        let url = directory.appendingPathComponent("image.png")
        try data.write(to: url)
        return url
    }
}
