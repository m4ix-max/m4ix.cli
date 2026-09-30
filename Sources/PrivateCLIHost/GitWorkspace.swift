import Foundation

struct GitWorkspaceSummary: Sendable {
    let root: URL
    let branch: String
    let status: String
    let changes: String
}

enum GitWorkspace {
    private static func git(_ arguments: [String], in directory: URL, timeout: TimeInterval = 10) throws -> String {
        let result = try CommandRunner.run(executable: "/usr/bin/git", arguments: arguments,
                                           directory: directory, timeout: timeout)
        guard result.status == 0 else {
            throw CommandError.failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard !result.truncated else { throw CommandError.failed("Git output is too large to display completely.") }
        return result.output.trimmingCharacters(in: .newlines)
    }

    static func contextRoot(_ directory: URL) throws -> URL {
        let common = try git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory)
        let url = URL(fileURLWithPath: common, isDirectory: true).standardizedFileURL
        // Normal and linked worktrees resolve to the same repository metadata.
        return url.lastPathComponent == ".git" ? url.deletingLastPathComponent() : url
    }

    static func inspect(_ directory: URL) throws -> GitWorkspaceSummary {
        let root = try git(["rev-parse", "--show-toplevel"], in: directory)
        let branch = try git(["branch", "--show-current"], in: directory)
        let status = try git(["status", "--short"], in: directory)
        let changes = try git(["diff", "HEAD", "--stat"], in: directory)
        return GitWorkspaceSummary(root: URL(fileURLWithPath: root),
                                   branch: branch.isEmpty ? "Detached HEAD" : branch,
                                   status: status, changes: changes)
    }

    /// Git creates a new branch from HEAD and checks it out only in the new
    /// folder. Existing uncommitted files and the original checkout stay intact.
    static func create(in directory: URL, branch: String, destination: URL) throws -> URL {
        guard !branch.isEmpty, !branch.hasPrefix("-"), !branch.contains("\n") else {
            throw CommandError.failed("Enter a valid new branch name.")
        }
        _ = try git(["check-ref-format", "--branch", branch], in: directory)
        _ = try git(["rev-parse", "--verify", "HEAD"], in: directory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw CommandError.failed("The workspace folder already exists.")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try git(["worktree", "add", "-b", branch, "--", destination.path, "HEAD"], in: directory, timeout: 30)
        return destination
    }
}
