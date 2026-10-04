import AppKit
import Foundation

struct AppBackup: Codable, Identifiable {
    var id: String
    var date: Date
    var version: String
    var folders: [String]
}

enum AppUpdates {
    static let managedFolders = ["projects", "production"]

    static func backup(root: URL, preferences: [String: Any], version: String) throws -> URL {
        let identifier = UUID().uuidString.lowercased()
        let destination = root.appendingPathComponent("updates/backups").appendingPathComponent(identifier)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var folders: [String] = []
        do {
            for name in managedFolders {
                let source = root.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: source.path) {
                    try FileManager.default.copyItem(at: source, to: destination.appendingPathComponent(name))
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

    static func installAfterExit(_ staged: URL, root: URL) throws {
        guard let source = installer else { throw CommandError.failed("Update helper is missing. Reinstall from the package script.") }
        let helper = root.appendingPathComponent("updates/install-after-exit.sh")
        try Data(contentsOf: source).write(to: helper, options: .atomic)
        let log = root.appendingPathComponent("updates/install.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helper.path, staged.path, "/Applications/m4ix.CLI.app", root.path, String(ProcessInfo.processInfo.processIdentifier)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
    }
}
