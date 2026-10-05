import Foundation
import XCTest
@testable import PrivateCLIHost

final class AppUpdatesTests: XCTestCase {
    func testBackupIncludesDiscussionAndNamedProfileRecordsWithoutProviderCredentials() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = UUID().uuidString.lowercased()
        let owned = ["projects/brief.json", "production/recovery.json", "shared-chats/discussion.json",
                     "named-profiles/\(profile)/projects/brief.json", "named-profiles/\(profile)/shared-chats/discussion.json"]
        let provider = ["claude/.credentials.json", "codex/auth.json", "named-profiles/\(profile)/claude/.credentials.json",
                        "named-profiles/\(profile)/codex/auth.json"]
        for name in owned + provider {
            let file = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture-only".utf8).write(to: file)
        }
        let backup = try AppUpdates.backup(root: root, preferences: ["PrivateCLIHostSelectedProfile": profile, "unrelated": "omit"], version: "0.16.2")
        for name in owned {
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(name)), Data("fixture-only".utf8), name)
        }
        for name in provider { XCTAssertFalse(FileManager.default.fileExists(atPath: backup.appendingPathComponent(name).path), name) }
        let manifest = try PrivateStore.read(AppBackup.self, from: backup.appendingPathComponent("manifest.json"),
                                            default: AppBackup(id: "", date: .distantPast, version: "", folders: []))
        XCTAssertEqual(Set(manifest.folders), Set(owned.map { String($0.dropLast($0.split(separator: "/").last!.count + 1)) }))
        let preferences = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: backup.appendingPathComponent("preferences.plist")), format: nil) as? [String: String])
        XCTAssertEqual(preferences, ["PrivateCLIHostSelectedProfile": profile])
    }

    func testRestartDisarmsSameOlderMissingAndUnmanagedPackages() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.update-restore." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let current = try application(at: root.appendingPathComponent("Applications/m4ix.CLI.app"), version: "0.16.2", build: "45")
        let same = try application(at: stagedPath(root: root), version: "0.16.2", build: "45")
        let older = try application(at: stagedPath(root: root), version: "0.16.1", build: "99")
        let lowerBuild = try application(at: stagedPath(root: root), version: "0.16.2", build: "44")
        let outside = try application(at: root.appendingPathComponent("other/m4ix.CLI.app"), version: "0.17.0", build: "46")
        for staged in [same, older, lowerBuild, outside, stagedPath(root: root)] {
            preferences.set(staged.path, forKey: "PrivateCLIHostPendingUpdate")
            XCTAssertNil(AppUpdates.restorePending(root: root, preferences: preferences, runningApplication: current))
            XCTAssertNil(preferences.string(forKey: "PrivateCLIHostPendingUpdate"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: older.path), "Disarming an update must preserve a package the user may choose for rollback")
    }

    func testNewerSignedPackageRestoresUntilInstalledInTheSelectedApplicationsFolder() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "m4ix.cli.update-install." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let current = try application(at: root.appendingPathComponent("User Applications/m4ix.CLI.app"), version: "0.16.2", build: "45", sign: true)
        let staged = try application(at: stagedPath(root: root), version: "0.16.2", build: "46", sign: true)
        preferences.set(staged.path, forKey: "PrivateCLIHostPendingUpdate")
        XCTAssertEqual(AppUpdates.restorePending(root: root, preferences: preferences, runningApplication: current)?.path, staged.path)
        let arguments = try AppUpdates.installerArguments(staged: staged, root: root, target: current, waitingPID: 42)
        XCTAssertEqual(arguments[1], current.path, "Updates must replace the running installation, including ~/Applications")
        let helper = try XCTUnwrap(AppUpdates.installer)
        let result = try CommandRunner.run(executable: "/bin/bash", arguments: [helper.path] + Array(arguments.prefix(3)), directory: root, timeout: 20)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(AppUpdates.revision(of: current), AppRevision(version: "0.16.2", build: "46"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "A successfully installed package must not remain armed")
        let copies = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("updates/versions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(AppUpdates.revision(of: copies[0].appendingPathComponent("m4ix.CLI.app")), AppRevision(version: "0.16.2", build: "45"))
        XCTAssertNil(AppUpdates.restorePending(root: root, preferences: preferences, runningApplication: current))
        XCTAssertNil(preferences.string(forKey: "PrivateCLIHostPendingUpdate"))
    }

    func testFailedInstallKeepsStagedPackageAndExistingTarget() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try application(at: stagedPath(root: root), version: "0.16.3", build: "46", sign: true)
        let target = root.appendingPathComponent("Applications/m4ix.CLI.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("retain".utf8).write(to: target.appendingPathComponent("original.txt"))
        let result = try CommandRunner.run(executable: "/bin/bash", arguments: [try XCTUnwrap(AppUpdates.installer).path, staged.path, target.path, root.path], directory: root, timeout: 20)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("original.txt"), encoding: .utf8), "retain")
    }

    func testManualInstallerUsesChosenFolderAndRetainsPreviousVersion() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("User Applications")
        let target = try application(at: folder.appendingPathComponent("m4ix.CLI.app"), version: "0.16.2", build: "45", sign: true)
        let source = try application(at: root.appendingPathComponent("package/m4ix.CLI.app"), version: "0.16.3", build: "46", sign: true)
        let backups = root.appendingPathComponent("backups")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let result = try CommandRunner.run(executable: "/usr/bin/env", arguments: ["M4IX_INSTALL_DIR=\(folder.path)",
            "M4IX_INSTALL_BACKUPS_DIR=\(backups.path)", "/bin/bash", repository.appendingPathComponent("Packaging/install.sh").path, source.path], directory: root, timeout: 20)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(AppUpdates.revision(of: target), AppRevision(version: "0.16.3", build: "46"))
        let previous = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(previous.count, 1)
        XCTAssertEqual(AppUpdates.revision(of: previous[0].appendingPathComponent("m4ix.CLI.app")), AppRevision(version: "0.16.2", build: "45"))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("app-update-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func stagedPath(root: URL) -> URL {
        root.appendingPathComponent("updates/staged/\(UUID().uuidString.lowercased())/m4ix.CLI.app")
    }

    private func application(at url: URL, version: String, build: String, sign: Bool = false) throws -> URL {
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.maxblomqvist.privateclis", "CFBundleExecutable": "PrivateCLIHost",
                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: contents.appendingPathComponent("MacOS/PrivateCLIHost"))
        if sign {
            let result = try CommandRunner.run(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", url.path], directory: url.deletingLastPathComponent(), timeout: 10)
            XCTAssertEqual(result.status, 0, result.output)
        }
        return url
    }
}
