import AppKit
import Foundation
import XCTest
@testable import PrivateCLIHost

/// Opt-in because these tests use the user's authenticated private accounts.
@MainActor
final class RealCLISmokeTests: XCTestCase {
    func testInstalledProvidersCompleteBenignPromptInHostedTerminal() async throws {
        guard ProcessInfo.processInfo.environment["M4IX_REAL_CLI_TESTS"] == "1" else {
            throw XCTSkip("Set M4IX_REAL_CLI_TESTS=1 to verify installed, authenticated CLIs")
        }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for agent in Agent.allCases {
            let session = TerminalSession(agent: agent, projectPath: directory.path, title: "Runtime verification",
                                          profileBase: HostPaths.userDataDirectory)
            session.launch(.run, in: directory, sessionID: agent == .claude ? UUID().uuidString : nil)
            defer { session.stop() }
            let readyDeadline = Date().addingTimeInterval(30)
            while !session.acceptsPromptText && Date() < readyDeadline {
                session.refreshPromptReadiness()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard session.acceptsPromptText else {
                XCTFail("\(agent.title) did not reach its composer; answer startup menus in the app first")
                continue
            }
            let marker = "HOST_REAL_\(agent.rawValue.uppercased())_OK"
            XCTAssertTrue(session.sendPrompt("Reply with only the word " + marker + ". Do not use tools or edit any files."))
            let responseDeadline = Date().addingTimeInterval(60)
            var matched = false
            while Date() < responseDeadline {
                let screen = CLIPrompt.liveScreen(of: session.terminal)
                matched = screen.contains { line in
                    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text == "⏺ " + marker || text == "• " + marker
                }
                if matched { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertTrue(matched, "\(agent.title) did not produce the expected response in its hosted terminal")
            let conversationID: String?
            if agent == .claude { conversationID = session.activeConversationID }
            else {
                let records = await Task.detached(priority: .utility) { ConversationHistoryLoader.load(profileBase: HostPaths.userDataDirectory) }.value
                conversationID = session.codexSessionIDPrefix.flatMap { prefix in
                    CodexSessionIdentity.uniqueMatch(prefix: prefix, in: records.filter { $0.provider == "codex" }.map(\.sessionID))
                }
            }
            let savedID = try XCTUnwrap(conversationID, "The real conversation must have a restorable identity")
            session.stop()
            let stopDeadline = Date().addingTimeInterval(6)
            while session.state.isRunning && Date() < stopDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertFalse(session.state.isRunning)
            let resumed = TerminalSession(agent: agent, projectPath: directory.path, title: "Restored verification",
                                          pendingResumeID: savedID, profileBase: HostPaths.userDataDirectory)
            defer { resumed.stop() }
            resumed.startIfPending()
            try await waitForComposer(resumed)
            XCTAssertEqual(resumed.activeConversationID, savedID.lowercased())
            let previousResponses = responseCount(marker, session: resumed)
            XCTAssertTrue(resumed.sendPrompt("Repeat the exact word you replied with in the previous turn. Nothing else; do not use tools."))
            try await waitForResponse(marker, session: resumed, after: previousResponses)

            let image = try redImage()
            defer { try? FileManager.default.removeItem(at: image.deletingLastPathComponent()) }
            XCTAssertTrue(resumed.sendPrompt("Name the dominant color in this image. Reply only with HOST_IMAGE_RED if it is red. Do not use tools or edit files.", images: [image]))
            try await waitForResponse("HOST_IMAGE_RED", session: resumed)
            XCTAssertNil(resumed.promptRecovery, "The real image must attach and submit without interrupted delivery")
            try await waitForComposer(resumed)
            let secondImage = image.deletingLastPathComponent().appendingPathComponent("second.png")
            try FileManager.default.copyItem(at: image, to: secondImage)
            XCTAssertTrue(resumed.sendPrompt("Count the images attached to this message. Reply only HOST_IMAGES_2_RED if there are exactly two and both are red. Do not use tools.", images: [image, secondImage]))
            try await waitForResponse("HOST_IMAGES_2_RED", session: resumed)
            XCTAssertNil(resumed.promptRecovery)
            resumed.terminal.setFrameSize(NSSize(width: 800, height: 240))
            try await Task.sleep(nanoseconds: 300_000_000)
            try await waitForComposer(resumed)
            XCTAssertTrue(resumed.sendPrompt("Count the images attached to this message. Reply only HOST_IMAGES_1_RED if there is exactly one and it is red. Do not use tools.", images: [secondImage]))
            try await waitForResponse("HOST_IMAGES_1_RED", session: resumed)
            XCTAssertNil(resumed.promptRecovery)
            resumed.stop()
            let resumedDeadline = Date().addingTimeInterval(6)
            while resumed.state.isRunning && Date() < resumedDeadline { try await Task.sleep(nanoseconds: 100_000_000) }
            XCTAssertFalse(resumed.state.isRunning)
        }
    }
    private func waitForComposer(_ session: TerminalSession) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !session.acceptsPromptText && Date() < deadline {
            session.refreshPromptReadiness()
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(session.acceptsPromptText, "Resumed CLI did not reach its composer")
    }

    private func waitForResponse(_ marker: String, session: TerminalSession, after count: Int = 0) async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if responseCount(marker, session: session) > count { return }
            if session.promptRecovery != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if let output = ProcessInfo.processInfo.environment["M4IX_SMOKE_REPORT_DIR"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try session.terminal.getBufferAsData(kind: .active).write(to: directory.appendingPathComponent(session.agent.rawValue + "-failure.txt"))
        }
        XCTFail("\(session.agent.title) did not produce the expected resumed response")
    }

    private func responseCount(_ marker: String, session: TerminalSession) -> Int {
        String(decoding: session.terminal.getBufferAsData(kind: .active), as: UTF8.self).replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n").filter { line in
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return text == "⏺ " + marker || text == "• " + marker
        }.count
    }

    private func redImage() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<64 { for x in 0..<64 {
            let index = y * bitmap.bytesPerRow + x * 3
            pixels[index] = 255
            pixels[index + 1] = 0
            pixels[index + 2] = 0
        } }
        let url = directory.appendingPathComponent("image.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

}
