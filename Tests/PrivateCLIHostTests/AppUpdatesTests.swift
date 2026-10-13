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

    func testReadyUpdateIsTheNewestBuildNeedingTheLeastWork() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let running = AppRevision(version: "0.18.9", build: "56")
        let installed = try application(at: root.appendingPathComponent("Applications/m4ix.CLI.app"), version: "0.18.9", build: "56")
        func ready(staged: URL? = nil) -> ReadyUpdate? {
            AppUpdates.readyUpdate(running: running, runningApplication: installed, staged: staged, root: root)
        }
        XCTAssertNil(ready())

        let package = try application(at: root.appendingPathComponent("outputs/m4ix.CLI 0.18.10.app"), version: "0.18.10", build: "57")
        try offer(package.path + "\n", root: root)
        XCTAssertEqual(ready(), ReadyUpdate(version: "0.18.10", source: .offered(URL(fileURLWithPath: package.path, isDirectory: true))))

        // The same build installed over the running app needs only a restart.
        try relabel(installed, version: "0.18.10", build: "57")
        XCTAssertEqual(ready(), ReadyUpdate(version: "0.18.10", source: .installed))
        let staged = try application(at: stagedPath(root: root), version: "0.18.11", build: "58")
        XCTAssertEqual(ready(staged: staged), ReadyUpdate(version: "0.18.11", source: .staged(staged)))

        try relabel(installed, version: "0.18.9", build: "56")
        let older = try application(at: root.appendingPathComponent("older/m4ix.CLI.app"), version: "0.18.8", build: "55")
        for path in [older.path, root.appendingPathComponent("missing/m4ix.CLI.app").path, "outputs/m4ix.CLI 0.18.10.app", ""] {
            try offer(path, root: root)
            XCTAssertNil(ready(), "Offer: \(path)")
        }
        XCTAssertNil(AppUpdates.readyUpdate(running: nil, runningApplication: installed, staged: staged, root: root))
    }

    func testInstallerReopensTheAppAfterAnInstallAndAfterAFailure() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try application(at: root.appendingPathComponent("Applications/m4ix.CLI.app"), version: "0.18.9", build: "56", sign: true)
        let opened = root.appendingPathComponent("opened.txt")
        let opener = root.appendingPathComponent("opener.sh")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(opened.path)'\n".utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: opener.path)
        let helper = try XCTUnwrap(AppUpdates.installer)
        func install(_ staged: URL) throws -> CommandResult {
            var arguments = try AppUpdates.installerArguments(staged: staged, root: root, target: target, waitingPID: 42, reopen: true)
            XCTAssertEqual(arguments.last, "reopen")
            arguments[3] = ""
            return try CommandRunner.run(executable: "/usr/bin/env", arguments: ["M4IX_UPDATE_OPENER=\(opener.path)", "/bin/bash", helper.path] + arguments,
                                         directory: root, timeout: 20)
        }
        let installed = try install(try application(at: stagedPath(root: root), version: "0.18.10", build: "57", sign: true))
        XCTAssertEqual(installed.status, 0, installed.output)
        XCTAssertEqual(AppUpdates.revision(of: target), AppRevision(version: "0.18.10", build: "57"))
        XCTAssertEqual(try String(contentsOf: opened, encoding: .utf8), target.path + "\n")

        let unsigned = try install(try application(at: stagedPath(root: root), version: "0.18.11", build: "58"))
        XCTAssertNotEqual(unsigned.status, 0)
        XCTAssertEqual(AppUpdates.revision(of: target), AppRevision(version: "0.18.10", build: "57"))
        XCTAssertEqual(try String(contentsOf: opened, encoding: .utf8), target.path + "\n" + target.path + "\n",
                       "A failed install must still open the app it left in place")
    }

    @MainActor
    func testRestartStagesAnOfferedBuildAndReopensThroughTheInstaller() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, running) = try restartModel(root: root)
        defer { model.stopAllSessions() }
        let package = try application(at: root.appendingPathComponent("outputs/m4ix.CLI 0.18.10.app"), version: "0.18.10", build: "57", sign: true)
        try offer(package.path, root: root)
        var quits = 0
        model.terminateApp = { quits += 1 }
        await model.refreshReadyUpdate()
        XCTAssertEqual(model.readyUpdate, ReadyUpdate(version: "0.18.10", source: .offered(URL(fileURLWithPath: package.path, isDirectory: true))))

        await model.restartToUpdate()
        XCTAssertEqual(quits, 1)
        XCTAssertTrue(model.reopensAfterQuit)
        let staged = try XCTUnwrap(model.pendingUpdate)
        XCTAssertEqual(staged.deletingLastPathComponent().deletingLastPathComponent(),
                       root.appendingPathComponent("updates/staged"))
        XCTAssertEqual(AppUpdates.revision(of: staged), AppRevision(version: "0.18.10", build: "57"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("updates/backups").path).count, 1)
        XCTAssertEqual(AppUpdates.revision(of: running), AppRevision(version: "0.18.9", build: "56"), "Nothing installs before the quit")

        let delegate = PrivateCLIAppDelegate()
        delegate.model = model
        var scheduled: (update: URL, reopen: Bool)?
        // Failing the schedule keeps the test process from quitting.
        delegate.scheduleUpdate = { update, _, reopen in
            scheduled = (update, reopen)
            throw CommandError.failed("Stopped by the test.")
        }
        delegate.scheduleReopen = { _ in XCTFail("A staged update reopens through its installer") }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(scheduled?.update, staged)
        XCTAssertEqual(scheduled?.reopen, true)
        XCTAssertFalse(model.reopensAfterQuit, "A cancelled restart must not reopen after a later quit")
    }

    @MainActor
    func testRestartIntoAnInstalledBuildReopensTheSameApp() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (model, running) = try restartModel(root: root)
        defer { model.stopAllSessions() }
        model.pendingUpdate = try application(at: stagedPath(root: root), version: "0.18.10", build: "57", sign: true)
        try relabel(running, version: "0.18.10", build: "57")
        var quits = 0
        model.terminateApp = { quits += 1 }
        await model.refreshReadyUpdate()
        XCTAssertEqual(model.readyUpdate, ReadyUpdate(version: "0.18.10", source: .installed))

        await model.restartToUpdate()
        XCTAssertEqual(quits, 1)
        XCTAssertNil(model.pendingUpdate, "The installed copy is as new as the staged one")
        let delegate = PrivateCLIAppDelegate()
        delegate.model = model
        var reopened: URL?
        delegate.scheduleReopen = { application in
            reopened = application
            throw CommandError.failed("Stopped by the test.")
        }
        delegate.scheduleUpdate = { _, _, _ in XCTFail("Nothing is left to install") }
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(reopened, running)
        XCTAssertEqual(model.operationError, "The app could not be set to open again: Stopped by the test.")
    }

    @MainActor
    private func restartModel(root: URL) throws -> (HostModel, URL) {
        let suite = "m4ix.cli.restart-update." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let running = try application(at: root.appendingPathComponent("Applications/m4ix.CLI.app"), version: "0.18.9", build: "56", sign: true)
        let model = HostModel(defaults: defaults, profileBase: root)
        model.runningRevision = AppRevision(version: "0.18.9", build: "56")
        model.runningApplication = running
        return (model, running)
    }

    private func offer(_ path: String, root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("updates"), withIntermediateDirectories: true)
        try Data(path.utf8).write(to: AppUpdates.offerFile(root: root))
    }

    private func relabel(_ application: URL, version: String, build: String) throws {
        let plist = application.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any])
        info["CFBundleShortVersionString"] = version
        info["CFBundleVersion"] = build
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: plist)
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
