import CryptoKit
import Foundation

struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    var head: String
    var status: String
    var files: [String: String]
    var fingerprint: String
    var capturedAt: Date
}

struct ReviewBaseline: Codable, Identifiable, Sendable {
    let id: UUID
    let project: String
    let date: Date
    let snapshot: WorkspaceSnapshot
    let patch: String
}

enum WorkspaceReview {
    static func git(_ arguments: [String], in directory: URL, limit: Int = 4_000_000) throws -> String {
        let result = try CommandRunner.run(executable: "/usr/bin/git", arguments: ["--no-optional-locks"] + arguments,
                                           directory: directory, timeout: 20, outputLimit: limit)
        guard result.status == 0 else { throw CommandError.failed(result.output) }
        guard !result.truncated else { throw CommandError.failed("This repository exceeds the review size limit. Use Git in the terminal for a complete review.") }
        return result.output
    }

    static func snapshot(in directory: URL) throws -> WorkspaceSnapshot {
        let root = URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines))
        let head = try git(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
        let status = try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)
        let listing = try git(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: root)
        let names = Set(listing.split(separator: "\0").map(String.init)).sorted()
        guard names.count <= 30_000 else { throw CommandError.failed("Too many files to verify this workspace snapshot.") }
        var files: [String: String] = [:]
        var total = 0
        for name in names {
            let url = root.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { files[name] = "deleted"; continue }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                files[name] = "link:" + (try FileManager.default.destinationOfSymbolicLink(atPath: url.path))
            } else if attributes[.type] as? FileAttributeType == .typeRegular {
                let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
                total += size
                guard size <= 64_000_000, total <= 256_000_000 else {
                    throw CommandError.failed("Workspace contents exceed the verification limit. No verified snapshot was recorded.")
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                files[name] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                    + ":" + String((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)
            } else { files[name] = "directory" }
        }
        // Recheck Git metadata; a concurrent change must not be presented as stable evidence.
        guard head == (try git(["rev-parse", "HEAD"], in: root)).trimmingCharacters(in: .whitespacesAndNewlines),
              status == (try git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], in: root)) else {
            throw CommandError.failed("The workspace changed while it was being inspected. Refresh after edits finish.")
        }
        let manifest = head + "\0" + status + "\0" + files.keys.sorted().map { $0 + "\0" + files[$0]! }.joined(separator: "\0")
        return WorkspaceSnapshot(head: head, status: status, files: files,
                                 fingerprint: PrivateStore.key(manifest), capturedAt: Date())
    }

    static func patch(in directory: URL, file: String? = nil) throws -> String {
        let names = file.map { [":(literal)" + $0] } ?? []
        var patch = try git(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--"] + names, in: directory)
        let untracked = try git(["ls-files", "--others", "--exclude-standard", "-z", "--"] + names, in: directory)
        for name in untracked.split(separator: "\0").map(String.init) {
            let root = URL(fileURLWithPath: try git(["rev-parse", "--show-toplevel"], in: directory).trimmingCharacters(in: .whitespacesAndNewlines))
            let url = root.appendingPathComponent(name)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 200_000 else {
                patch += "\nUntracked file: \(name) (binary, link, or large file; open separately)\n"; continue
            }
            let data = try Data(contentsOf: url)
            if !data.contains(0), let text = String(data: data, encoding: .utf8) {
                patch += "\n--- /dev/null\n+++ \(name) (untracked)\n" + text.components(separatedBy: "\n").map { "+" + $0 }.joined(separator: "\n") + "\n"
            } else { patch += "\nUntracked binary file: \(name)\n" }
            guard patch.utf8.count < 4_000_000 else { throw CommandError.failed("The diff is too large to display completely.") }
        }
        return patch.isEmpty ? "No uncommitted changes." : patch
    }

    static func baselineURL(root: URL, project: String) -> URL {
        root.appendingPathComponent("production/baselines").appendingPathComponent(PrivateStore.key(project) + ".json")
    }

    static func captureBaseline(root: URL, project: URL, session: UUID) throws {
        let snapshot = try snapshot(in: project)
        let patch = try patch(in: project)
        let baseline = ReviewBaseline(id: session, project: project.path, date: Date(), snapshot: snapshot, patch: patch)
        let url = baselineURL(root: root, project: project.path)
        var existing = try PrivateStore.read([ReviewBaseline].self, from: url, default: [])
        existing.insert(baseline, at: 0)
        try PrivateStore.write(Array(existing.prefix(20)), to: url)
    }

    static func changedFiles(from before: WorkspaceSnapshot, to after: WorkspaceSnapshot) -> [String] {
        Set(before.files.keys).union(after.files.keys).filter { before.files[$0] != after.files[$0] }.sorted()
    }
}
