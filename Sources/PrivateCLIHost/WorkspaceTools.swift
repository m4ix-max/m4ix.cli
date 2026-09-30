import AppKit
import Foundation

/// The two animation surfaces share one server. Reuse a verified server;
/// processes started here belong to the app and stop when it quits.
@MainActor
final class WorkspaceTools: ObservableObject {
    enum Tool: String, CaseIterable {
        case motion, annotator
        var title: String { self == .motion ? "Motion library" : "Annotator" }
        var symbol: String { self == .motion ? "waveform.path" : "film.stack" }
        var url: URL { URL(string: "http://127.0.0.1:8705/\(rawValue)/")! }
        var pageTitle: String { self == .motion ? "Motion library" : "Annotator" }
    }

    @Published private(set) var opening: Tool?
    @Published var errorMessage: String?
    private var server: Process?
    private var log: FileHandle?
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    func root(for project: URL) -> URL? {
        var candidate = project.standardizedFileURL
        while candidate.path != "/" {
            if Self.isToolRoot(candidate) { return candidate }
            candidate.deleteLastPathComponent()
        }
        for path in ["Library/CloudStorage/Dropbox/m4ix_001/dispatch-animation", "Dropbox/m4ix_001/dispatch-animation"] {
            let candidate = home.appendingPathComponent(path)
            if Self.isToolRoot(candidate) { return candidate }
        }
        return nil
    }

    private static func isToolRoot(_ root: URL) -> Bool {
        ["annotator/server.js", "annotator/index.html", "motion/index.html"].allSatisfy {
            FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        }
    }

    static func isExpectedPage(_ data: Data, response: URLResponse, tool: Tool) -> Bool {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { return false }
        return String(decoding: data, as: UTF8.self).contains("<title>\(tool.pageTitle)</title>")
    }

    private func probe(_ tool: Tool) async -> Bool {
        var request = URLRequest(url: tool.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1)
        request.httpMethod = "GET"
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return false }
        return Self.isExpectedPage(data, response: response, tool: tool)
    }

    func open(_ tool: Tool, project: URL) async {
        guard opening == nil else { return }
        opening = tool
        errorMessage = nil
        defer { opening = nil }
        do {
            if !(await probe(tool)) {
                guard let root = root(for: project) else {
                    throw CommandError.failed("The animation tools could not be found on this Mac.")
                }
                if server?.isRunning != true {
                    let candidates = [home.appendingPathComponent(".local/bin/node").path,
                                      "/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
                    guard let node = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
                        throw CommandError.failed("Node.js is needed to open the animation tools.")
                    }
                    let logURL = HostPaths.profileBase.appendingPathComponent("animation-tools.log")
                    try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: logURL.path) {
                        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    }
                    log = try FileHandle(forWritingTo: logURL)
                    try log?.seekToEnd()
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: node)
                    process.arguments = ["annotator/server.js"]
                    process.currentDirectoryURL = root
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = log
                    process.standardError = log
                    try process.run()
                    server = process
                }
                var ready = false
                for _ in 0..<20 {
                    if await probe(tool) { ready = true; break }
                    if server?.isRunning != true { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard ready else {
                    throw CommandError.failed("The animation server did not open the expected page. Port 8705 may be in use. See animation-tools.log in the private profile folder.")
                }
            }
            if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") {
                NSWorkspace.shared.open([tool.url], withApplicationAt: chrome, configuration: .init()) { _, error in
                    if let error { Task { @MainActor in self.errorMessage = error.localizedDescription } }
                }
            } else if !NSWorkspace.shared.open(tool.url) {
                throw CommandError.failed("Could not open the animation tool in a browser.")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stopOwnedServer() {
        if server?.isRunning == true { server?.terminate() }
        server = nil
        try? log?.close()
        log = nil
    }
}
