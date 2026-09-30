import Foundation
import XCTest
@testable import PrivateCLIHost

final class GitWorkspaceTests: XCTestCase {
    func testCreatesIsolatedBranchWithoutMovingOrCopyingDirtyWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo with spaces")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func git(_ args: [String], in directory: URL? = nil) throws -> String {
            let result = try CommandRunner.run(executable: "/usr/bin/git", arguments: args, directory: directory ?? repo)
            XCTAssertEqual(result.status, 0, result.output)
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try git(["init", "-b", "main"])
        let file = repo.appendingPathComponent("file.txt")
        try Data("committed".utf8).write(to: file)
        _ = try git(["add", "file.txt"])
        _ = try git(["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "Fixture"])
        try Data("dirty".utf8).write(to: file)
        let destination = root.appendingPathComponent("isolated workspace")
        let created = try GitWorkspace.create(in: repo, branch: "m4ix/codex", destination: destination)
        XCTAssertEqual(created, destination)
        XCTAssertEqual(try git(["branch", "--show-current"]), "main")
        XCTAssertEqual(try git(["branch", "--show-current"], in: created), "m4ix/codex")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "dirty")
        XCTAssertEqual(try String(contentsOf: created.appendingPathComponent("file.txt"), encoding: .utf8), "committed")
        XCTAssertTrue(try GitWorkspace.inspect(created).status.isEmpty)
        XCTAssertEqual(try GitWorkspace.contextRoot(repo), try GitWorkspace.contextRoot(created))
        let store = ProjectContextStore(directory: root.appendingPathComponent("project-state"))
        try await store.savePlan(path: repo.path, brief: "One shared brief", tasks: [ProjectTask(title: "Review", owner: "Codex")])
        let shared = try await store.load(path: created.path)
        XCTAssertEqual(shared.brief, "One shared brief")
        XCTAssertEqual(shared.tasks.count, 1)
        let record = ProjectHandoffRecord(id: UUID(), date: Date(), source: "Claude", target: "Codex", prompt: "Review", state: "Prepared")
        try await store.appendHandoff(path: created.path, record: record)
        let original = try await store.load(path: repo.path)
        XCTAssertEqual(original.handoffs.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("project-state").path).count, 1)
        XCTAssertThrowsError(try GitWorkspace.create(in: repo, branch: "--help", destination: root.appendingPathComponent("bad")))
        XCTAssertThrowsError(try GitWorkspace.create(in: repo, branch: "m4ix/codex", destination: root.appendingPathComponent("duplicate")))
    }
}
