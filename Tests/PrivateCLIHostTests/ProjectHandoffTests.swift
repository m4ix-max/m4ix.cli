import XCTest
@testable import PrivateCLIHost

final class ProjectHandoffTests: XCTestCase {
    func testHandoffCarriesTaskAndClearlyLimitsTerminalContext() {
        let draft = HandoffDraft(source: "Claude", target: "Codex", projectPath: "/tmp/project", context: "old excerpt")
        let prompt = draft.prompt(task: "  Review the parser\n", context: "Tests pass. Check Parser.swift.")
        XCTAssertTrue(prompt.contains("Requested task:\nReview the parser"))
        XCTAssertTrue(prompt.contains("Tests pass. Check Parser.swift."))
        XCTAssertFalse(prompt.contains("old excerpt"), "Only reviewed context should be shared")
        XCTAssertTrue(prompt.contains("partial terminal excerpt"))
        XCTAssertTrue(prompt.contains("Preserve existing uncommitted work"))
    }
}
