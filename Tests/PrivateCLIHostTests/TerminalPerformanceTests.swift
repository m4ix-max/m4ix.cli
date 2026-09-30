import AppKit
import Foundation
import SwiftTerm
import XCTest
@testable import PrivateCLIHost

@MainActor
final class TerminalPerformanceTests: XCTestCase {
    func testConcurrentTerminalOutputKeepsMainActorResponsive() async throws {
        let first = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let second = TerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let stack = NSStackView(views: [first, second])
        stack.orientation = .horizontal
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = stack
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let chunk = String(repeating: "Concurrent terminal output café 0123456789\r\n", count: 20)
        let workers = [first, second].map { view in
            Task.detached(priority: .utility) {
                for _ in 0..<200 { view.feed(text: chunk); Thread.sleep(forTimeInterval: 0.002) }
            }
        }
        var delays: [Double] = []
        for _ in 0..<100 {
            let start = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(nanoseconds: 10_000_000)
            delays.append(max(0, (ProcessInfo.processInfo.systemUptime - start - 0.01) * 1000))
        }
        for worker in workers { await worker.value }
        delays.sort()
        let p95 = delays[Int(Double(delays.count - 1) * 0.95)]
        print("Concurrent terminal main-actor delay: p95=\(p95)ms, max=\(delays.last!)ms, bytesFed=\(chunk.utf8.count * 400)")
        XCTAssertLessThan(p95, 100, "Concurrent output should not stall interface work")
    }

    func testLongScrollbackScreenReadLatency() throws {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 520))
        let history = (0..<2000).map { "line \($0): " + String(repeating: "terminal output ", count: 5) }.joined(separator: "\r\n")
        view.feed(text: history + "\r\n› Ask anything\r\n")
        var samples: [Double] = []
        for _ in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            let screen = CLIPrompt.liveScreen(of: view)
            samples.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            XCTAssertEqual(screen.count, view.terminalDimensions.rows)
            XCTAssertTrue(CLIPrompt.codexAcceptsText(screen: screen))
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let result: [String: Any] = ["screenReadP50MS": samples[samples.count / 2], "screenReadP95MS": p95,
                                     "screenRows": view.terminalDimensions.rows, "historyLinesFed": 2000,
                                     "configuration": "SwiftPM debug XCTest"]
        print("Terminal measurement: \(result)")
        // A status read runs once a second; this gate catches major regressions
        // without treating a CI VM's scheduling variance as a frame-rate claim.
        XCTAssertLessThan(p95, 100)
        if let path = ProcessInfo.processInfo.environment["M4IX_PERF_REPORT"] {
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path))
        }
    }
}
