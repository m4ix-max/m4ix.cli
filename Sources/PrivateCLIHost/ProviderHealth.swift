import Foundation

struct ProviderCompatibility: Sendable {
    var version: String
    var usesComposer: Bool
    var message: String
    static let checking = ProviderCompatibility(version: "Checking", usesComposer: true, message: "Checking CLI compatibility…")

    /// The oldest version whose screens the composer was checked against.
    /// Both CLIs update themselves every few days, so newer versions keep
    /// the composer: each send still reads the live screen first, and any
    /// screen it does not recognise blocks sending.
    static func minimumVersion(for agent: Agent) -> String {
        agent == .claude ? "2.1.287" : "0.159.3"
    }

    static func evaluate(_ output: String, agent: Agent) -> ProviderCompatibility {
        let pattern = #"\b[0-9]+\.[0-9]+\.[0-9]+\b"#
        let version = output.range(of: pattern, options: .regularExpression).map { String(output[$0]) } ?? "Unknown"
        let supported = version != "Unknown"
            && version.compare(minimumVersion(for: agent), options: .numeric) != .orderedAscending
        return ProviderCompatibility(version: version, usesComposer: supported,
            message: supported ? "Supported CLI version. The message composer is available."
                : "This CLI version has not been checked with the message composer. Use terminal input; your draft is kept.")
    }

    static func inspect(agent: Agent, profileBase: URL, directory: URL) -> ProviderCompatibility {
        guard let launcher = HostPaths.launcher else {
            return ProviderCompatibility(version: "Missing", usesComposer: false, message: "The bundled CLI launcher is missing. Reinstall the app.")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PRIVATE_CLI_HOST_DATA_DIR"] = profileBase.path
        do {
            let result = try CommandRunner.run(executable: "/bin/bash", arguments: [launcher.path, agent.rawValue, "version"],
                directory: directory, environment: environment, timeout: 3, outputLimit: 2048)
            guard result.status == 0 else {
                return ProviderCompatibility(version: "Unavailable", usesComposer: false,
                    message: "The CLI could not be found or did not start. Open Setup to check its installation.")
            }
            return evaluate(result.output, agent: agent)
        } catch {
            return ProviderCompatibility(version: "Unknown", usesComposer: false, message: "The version check did not complete. Use terminal input and inspect Setup.")
        }
    }
}

struct SetupCheck: Identifiable, Sendable {
    var id: String
    var passed: Bool
    var summary: String
    var action: String
}

enum SetupInspector {
    static func check(agent: Agent, profileBase: URL, project: URL) -> [SetupCheck] {
        var results: [SetupCheck] = []
        var isDirectory: ObjCBool = false
        let available = FileManager.default.fileExists(atPath: project.path, isDirectory: &isDirectory) && isDirectory.boolValue
        results.append(SetupCheck(id: "Project folder", passed: available,
            summary: available ? "Available" : "Folder unavailable", action: "Choose an existing folder with Add project."))
        let compatibility = ProviderCompatibility.inspect(agent: agent, profileBase: profileBase,
                directory: available ? project : FileManager.default.homeDirectoryForCurrentUser)
        results.append(SetupCheck(id: "CLI installation", passed: !["Unknown", "Unavailable", "Missing"].contains(compatibility.version),
            summary: "\(agent.title) \(compatibility.version)", action: "Install this provider's CLI, confirm its command works in Terminal, then check again."))
        results.append(SetupCheck(id: "Message composer", passed: compatibility.usesComposer,
            summary: compatibility.message, action: "Native terminal input remains available for unrecognized versions."))
        let profile = profileBase.appendingPathComponent(agent.rawValue)
        let writable = FileManager.default.isWritableFile(atPath: profile.path)
        results.append(SetupCheck(id: "Profile access", passed: writable,
            summary: writable ? "Profile is writable" : "Profile is missing or read-only", action: "Open the profile in Finder and check its permissions. Log in to initialize a new profile."))
        if let launcher = HostPaths.launcher {
            var environment = ProcessInfo.processInfo.environment
            environment["PRIVATE_CLI_HOST_DATA_DIR"] = profileBase.path
            let result = try? CommandRunner.run(executable: "/bin/bash", arguments: [launcher.path, agent.rawValue, "status"],
                directory: available ? project : FileManager.default.homeDirectoryForCurrentUser,
                environment: environment, timeout: 8, outputLimit: 4096)
            results.append(SetupCheck(id: "Authentication", passed: result?.status == 0,
                summary: result?.status == 0 ? "Account check passed" : "Login needs attention",
                action: "Choose Log in for this profile. Answer any trust or permission questions in the terminal."))
        }
        return results
    }

    static func diagnosticReport(checks: [SetupCheck], activeSessions: Int, queuedSessions: Int) -> String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development"
        return (["m4ix.CLI diagnostic report", "App: \(version)", "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                 "Active sessions: \(activeSessions)", "Queued sessions: \(queuedSessions)",
                 "App resident memory: \(HostHealth.residentMemoryMB().map(String.init) ?? "unknown") MB", ""]
                + checks.map { "\($0.id): \($0.passed ? "OK" : "Needs attention")\n\($0.summary)" }).joined(separator: "\n")
    }
}
