import Darwin
import Foundation
import SwiftTerm
import XCTest

final class TerminalLifecycleTests: XCTestCase {
    func testLocalProcessLaunchesAndReportsNormalExit() throws {
        let script = try makeScript("printf 'ready\\n'\nexit 7\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let probe = LifecycleProbe()
        let process = LocalProcess(delegate: probe, dispatchQueue: .main)
        let exited = expectation(description: "normal child exit")
        probe.onExit = { exited.fulfill() }

        try process.startProcessChecked(executable: script.path).get()
        wait(for: [exited], timeout: 3)

        XCTAssertTrue(probe.output.contains("ready"))
        XCTAssertEqual(probe.exitCode, 7)
        XCTAssertFalse(process.running)
        XCTAssertFalse(process.windingDown)
    }

    func testTermIgnoringChildNeedsEscalationAndReportsExit() throws {
        let script = try makeScript("trap '' TERM\nprintf 'ready\\n'\nwhile :; do read -r line; done\n")
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let probe = LifecycleProbe()
        let process = LocalProcess(delegate: probe, dispatchQueue: .main)
        let ready = expectation(description: "child installed signal handler")
        let exited = expectation(description: "child killed after ignored SIGTERM")
        var sawReady = false
        probe.onOutput = { text in
            if !sawReady && text.contains("ready") {
                sawReady = true
                ready.fulfill()
            }
        }
        probe.onExit = { exited.fulfill() }

        try process.startProcessChecked(executable: script.path).get()
        wait(for: [ready], timeout: 3)

        let childPID = process.shellPid
        XCTAssertGreaterThan(childPID, 0)
        process.terminate()

        let gracePeriod = expectation(description: "SIGTERM grace period")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { gracePeriod.fulfill() }
        wait(for: [gracePeriod], timeout: 1)
        XCTAssertTrue(process.running, "SIGTERM should not stop this child")
        XCTAssertEqual(process.shellPid, childPID)

        if process.shellPid == childPID, childPID > 0 {
            XCTAssertEqual(Darwin.kill(childPID, SIGKILL), 0)
        }
        wait(for: [exited], timeout: 3)
        XCTAssertNil(probe.exitCode)
        XCTAssertFalse(process.running)
    }

    private func makeScript(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-cli-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("fake-cli")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }
}

private final class LifecycleProbe: LocalProcessDelegate {
    var output = ""
    var exitCode: Int32?
    var onOutput: ((String) -> Void)?
    var onExit: (() -> Void)?

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }

    func dataReceived(slice: ArraySlice<UInt8>) {
        output += String(decoding: slice, as: UTF8.self)
        onOutput?(output)
    }

    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        self.exitCode = exitCode
        onExit?()
    }
}
