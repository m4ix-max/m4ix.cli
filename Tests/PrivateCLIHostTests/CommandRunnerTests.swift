import Foundation
import XCTest
@testable import PrivateCLIHost

final class CommandRunnerTests: XCTestCase {
    func testLargeOutputIsDrainedWithoutDeadlockAndCaptureIsBounded() throws {
        let result = try CommandRunner.run(executable: "/bin/sh",
            arguments: ["-c", "yes output | head -c 200000"], directory: URL(fileURLWithPath: "/tmp"),
            timeout: 3, outputLimit: 1024)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output.utf8.count, 1024)
        XCTAssertTrue(result.truncated)
    }

    func testArgumentsStayLiteralAndNonzeroStatusSurvives() throws {
        let text = "$(whoami); café\n--literal"
        let result = try CommandRunner.run(executable: "/bin/sh",
            arguments: ["-c", "printf '%s' \"$1\"; exit 7", "test", text], directory: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(result.output, text)
        XCTAssertEqual(result.status, 7)
    }

    func testIgnoringTerminationStillHasBoundedTimeout() throws {
        let start = Date()
        XCTAssertThrowsError(try CommandRunner.run(executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"], directory: URL(fileURLWithPath: "/tmp"), timeout: 0.1)) {
            guard case CommandError.timedOut = $0 else { return XCTFail("Expected timeout, got \($0)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
