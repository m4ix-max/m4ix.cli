import AppKit
import Foundation

struct AppBackup: Codable, Identifiable {
    var id: String
    var date: Date
    var version: String
    var folders: [String]
}

struct AppRevision: Comparable {
    let version: [Int]
    let build: Int

    init?(version: String, build: String) {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
              build.allSatisfy({ $0.isASCII && $0.isNumber }), let number = Int(build), number >= 0 else { return nil }
        var numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        while numbers.count > 1, numbers.last == 0 { numbers.removeLast() }
        self.version = numbers
        self.build = number
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.version.count, rhs.version.count) {
            let left = index < lhs.version.count ? lhs.version[index] : 0
            let right = index < rhs.version.count ? rhs.version[index] : 0
            if left != right { return left < right }
        }
        return lhs.build < rhs.build
    }
}

/// A build newer than the running one that the app can restart into.
struct ReadyUpdate: Equatable {
    enum Source: Equatable {
        /// Installed over the running app, whose old code runs until it opens again.
        case installed
        /// Staged by the app, to install once it quits.
        case staged(URL)
        /// Packaged by a build, which leaves the app's path in `updates/offered`.
        case offered(URL)
    }
    let version: String
    let source: Source
}

enum AppUpdates {
    static let managedFolders = ["projects", "production", "shared-chats"]

    private static func backupFolders(root: URL) throws -> [String] {
        var folders = managedFolders
        let profiles = root.appendingPathComponent("named-profiles")
        if FileManager.default.fileExists(atPath: profiles.path) {
            for profile in try FileManager.default.contentsOfDirectory(at: profiles,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.path < $1.path }) {
                let values = try profile.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard UUID(uuidString: profile.lastPathComponent) != nil,
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                folders += ["projects", "shared-chats"].map { "named-profiles/\(profile.lastPathComponent)/\($0)" }
            }
        }
        return folders
    }

    static func backup(root: URL, preferences: [String: Any], version: String) throws -> URL {
        let identifier = UUID().uuidString.lowercased()
        let destination = root.appendingPathComponent("updates/backups").appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var folders: [String] = []
        do {
            for name in try backupFolders(root: root) {
                let source = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                    let target = destination.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                           attributes: [.posixPermissions: 0o700])
                    try FileManager.default.copyItem(at: source, to: target)
                    folders.append(name)
                }
            }
            let owned = preferences.filter { $0.key.hasPrefix("PrivateCLIHost") }
            let data = try PropertyListSerialization.data(fromPropertyList: owned, format: .binary, options: 0)
            try data.write(to: destination.appendingPathComponent("preferences.plist"), options: .atomic)
            try PrivateStore.write(AppBackup(id: identifier, date: Date(), version: version, folders: folders),
                                   to: destination.appendingPathComponent("manifest.json"))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    static func inspectApplication(_ url: URL) throws -> String {
        guard url.pathExtension == "app", let bundle = Bundle(url: url),
              bundle.bundleIdentifier == "com.maxblomqvist.privateclis",
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String else {
            throw CommandError.failed("Choose a packaged m4ix.CLI application.")
        }
        let result = try CommandRunner.run(executable: "/usr/bin/codesign", arguments: ["--verify", "--strict", url.path],
                                           directory: url.deletingLastPathComponent(), timeout: 15)
        guard result.status == 0 else { throw CommandError.failed("The application's code signature is invalid.") }
        if let minimum = bundle.infoDictionary?["LSMinimumSystemVersion"] as? String {
            let numbers = minimum.split(separator: ".").compactMap { Int($0) }
            let required = OperatingSystemVersion(majorVersion: numbers.first ?? 13,
                minorVersion: numbers.count > 1 ? numbers[1] : 0, patchVersion: numbers.count > 2 ? numbers[2] : 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(required) else { throw CommandError.failed("This update requires a newer macOS version.") }
        }
        return version
    }

    static func revision(of application: URL) -> AppRevision? { release(of: application)?.revision }

    /// The build a process started from, read from its Info.plist at launch:
    /// an install replaces the file on disk while the old code keeps running.
    static func revision(info: [String: Any]?) -> AppRevision? {
        guard let version = info?["CFBundleShortVersionString"] as? String,
              let build = info?["CFBundleVersion"] as? String else { return nil }
        return AppRevision(version: version, build: build)
    }

    private static func release(of application: URL) -> (version: String, revision: AppRevision)? {
        guard let data = try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.maxblomqvist.privateclis",
              let version = info["CFBundleShortVersionString"] as? String,
              let revision = revision(info: info) else { return nil }
        return (version, revision)
    }

    /// Where Packaging/build-and-package.sh leaves the path of each app it builds.
    static func offerFile(root: URL) -> URL { root.appendingPathComponent("updates/offered") }

    /// The newest build that is newer than the running one. Of two copies of
    /// the same build, the one needing the least work wins: already
    /// installed, then staged, then offered. Signatures are checked on staging.
    static func readyUpdate(running: AppRevision?, runningApplication: URL, staged: URL?, root: URL) -> ReadyUpdate? {
        guard let running else { return nil }
        var candidates: [(application: URL, source: ReadyUpdate.Source)] = [(runningApplication, .installed)]
        if let staged { candidates.append((staged, .staged(staged))) }
        if let line = try? String(contentsOf: offerFile(root: root), encoding: .utf8) {
            let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if path.hasPrefix("/") {
                let offered = URL(fileURLWithPath: path, isDirectory: true)
                candidates.append((offered, .offered(offered)))
            }
        }
        var newest: (revision: AppRevision, update: ReadyUpdate)?
        for candidate in candidates {
            guard let release = release(of: candidate.application), release.revision > running,
                  newest.map({ release.revision > $0.revision }) ?? true else { continue }
            newest = (release.revision, ReadyUpdate(version: release.version, source: candidate.source))
        }
        return newest?.update
    }

    static func restorePending(root: URL, preferences: UserDefaults, runningApplication: URL = Bundle.main.bundleURL) -> URL? {
        let key = "PrivateCLIHostPendingUpdate"
        guard let path = preferences.string(forKey: key) else { return nil }
        let staged = URL(fileURLWithPath: path).standardizedFileURL
        let parent = staged.deletingLastPathComponent()
        let stagingRoot = root.appendingPathComponent("updates/staged").resolvingSymlinksInPath()
        // An explicit rollback applies on quit in the session that staged it.
        // Restart must not re-arm an old package after a newer manual install.
        guard staged.lastPathComponent == "m4ix.CLI.app", UUID(uuidString: parent.lastPathComponent) != nil,
              parent.resolvingSymlinksInPath().deletingLastPathComponent() == stagingRoot,
              let current = revision(of: runningApplication), let offered = revision(of: staged), offered > current,
              (try? inspectApplication(staged)) != nil else {
            preferences.removeObject(forKey: key)
            return nil
        }
        return staged
    }

    /// A staged app is immutable from the UI's perspective. The installer rechecks
    /// its signature immediately before swapping it into /Applications.
    static func stage(_ application: URL, root: URL) throws -> URL {
        _ = try inspectApplication(application)
        let parent = root.appendingPathComponent("updates/staged/" + UUID().uuidString.lowercased())
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let destination = parent.appendingPathComponent("m4ix.CLI.app")
        let result = try CommandRunner.run(executable: "/usr/bin/ditto", arguments: [application.path, destination.path],
                                           directory: parent, timeout: 120)
        guard result.status == 0 else { throw CommandError.failed("Could not stage the update.") }
        _ = try inspectApplication(destination)
        return destination
    }

    static var installer: URL? {
        Bundle.main.url(forResource: "app-update", withExtension: "sh")
            ?? Bundle.main.url(forResource: "app-update", withExtension: "sh", subdirectory: "Resources")
            ?? Bundle.module.url(forResource: "app-update", withExtension: "sh")
            ?? Bundle.module.url(forResource: "app-update", withExtension: "sh", subdirectory: "Resources")
    }

    static func installerArguments(staged: URL, root: URL, target: URL, waitingPID: Int32, reopen: Bool = false) throws -> [String] {
        let target = target.resolvingSymlinksInPath()
        guard target != staged.resolvingSymlinksInPath(),
              !target.path.hasPrefix(root.appendingPathComponent("updates/staged").resolvingSymlinksInPath().path + "/") else {
            throw CommandError.failed("Open the installed app before applying an update.")
        }
        _ = try inspectApplication(target)
        return [staged.path, target.path, root.path, String(waitingPID)] + (reopen ? ["reopen"] : [])
    }

    /// `reopen` opens the app again after the install, or after a failed one.
    static func installAfterExit(_ staged: URL, root: URL, reopen: Bool) throws {
        let arguments = try installerArguments(staged: staged, root: root, target: Bundle.main.bundleURL,
                                              waitingPID: ProcessInfo.processInfo.processIdentifier, reopen: reopen)
        guard let source = installer else { throw CommandError.failed("Update helper is missing. Reinstall from the package script.") }
        let helper = root.appendingPathComponent("updates/install-after-exit.sh")
        try Data(contentsOf: source).write(to: helper, options: .atomic)
        let log = root.appendingPathComponent("updates/install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }

    /// Opens the app again once this process has exited.
    static func reopenAfterExit(_ application: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", #"while kill -0 "$1" 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open "$2""#,
                             "reopen", String(ProcessInfo.processInfo.processIdentifier), application.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
