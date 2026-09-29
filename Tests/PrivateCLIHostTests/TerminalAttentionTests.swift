import SwiftTerm
import XCTest
@testable import PrivateCLIHost

final class TerminalAttentionTests: XCTestCase {
    func testReadsClaudeAndCodexNotifications() {
        func parse(_ code: Int, _ payload: String) -> String? {
            TerminalAttention.notification(oscCode: code, payload: Array(payload.utf8))
        }
        // Captured from Claude Code 2.1.284 and Codex 0.158.0.
        XCTAssertEqual(parse(777, "notify;Claude Code;Claude is waiting for your input"), "Claude is waiting for your input")
        XCTAssertEqual(parse(9, "OK"), "OK")

        XCTAssertEqual(parse(777, "notify;Claude Code;"), "Claude Code")
        XCTAssertEqual(parse(777, "notify;T;a; b"), "a; b")
        XCTAssertEqual(parse(9, "First line\nsecond line"), "First line")
        XCTAssertEqual(parse(9, ""), "")
        XCTAssertNil(parse(777, "other;T;B"))
        XCTAssertNil(parse(9, "4;3;"))
        XCTAssertNil(parse(9, "4;1;50"))
        XCTAssertNil(parse(99, "i=1:p=body;B"))
        XCTAssertNil(parse(0, "Title"))
    }

    func testTurnEndsWhenOutputStopsAfterWork() {
        var turns = TurnDetector()
        let start = Date()
        func at(_ seconds: TimeInterval, age: TimeInterval?) -> Bool {
            turns.update(outputAge: age, now: start.addingTimeInterval(seconds))
        }

        XCTAssertFalse(at(0, age: nil))
        // Spinner output every second for six seconds.
        for second in 1...6 { XCTAssertFalse(at(TimeInterval(second), age: 0.2)) }
        XCTAssertTrue(turns.isWorking)
        XCTAssertFalse(at(7, age: 1.2))
        XCTAssertTrue(at(9, age: 3.2), "quiet after a long stretch ends a turn")
        XCTAssertFalse(turns.isWorking)
        XCTAssertFalse(at(10, age: 4.2), "an ended turn is reported once")

        // A short burst, such as a redraw or startup banner, is not a turn.
        XCTAssertFalse(at(20, age: 0.1))
        XCTAssertFalse(at(21, age: 0.3))
        XCTAssertFalse(at(24, age: 3.3))
        XCTAssertNotNil(turns.lastWorkEnded)
    }

    @MainActor
    func testTerminalViewDeliversNotificationPayloads() {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let received = expectation(description: "OSC notifications observed")
        received.expectedFulfillmentCount = 2
        let box = PayloadBox()
        let observation = view.observeOscEvents { event in
            if let text = TerminalAttention.notification(oscCode: event.code, payload: event.payload) {
                box.append(text)
                received.fulfill()
            }
        }
        view.feed(text: "\u{1b}]777;notify;Claude Code;Claude needs your permission to use Bash\u{07}")
        view.feed(text: "\u{1b}]9;4;3;\u{07}\u{1b}]0;title\u{07}")
        view.feed(text: "\u{1b}]9;Done\u{1b}\\")
        wait(for: [received], timeout: 2)
        XCTAssertEqual(box.values, ["Claude needs your permission to use Bash", "Done"])
        withExtendedLifetime(observation) {}
    }
}

private final class PayloadBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}
