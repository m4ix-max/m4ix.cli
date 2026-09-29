import XCTest
@testable import PrivateCLIHost

final class CodexSessionIdentityTests: XCTestCase {
    func testStrictTitleParsingAndUniqueHistoryMatch() {
        let id = "12345678-1234-1234-1234-123456789abc"
        let prefix = String(id.prefix(29))
        XCTAssertEqual(CodexSessionIdentity.prefix(fromTerminalTitle: prefix + "..."), prefix)
        XCTAssertNil(CodexSessionIdentity.prefix(fromTerminalTitle: "Codex " + prefix + "..."))
        XCTAssertNil(CodexSessionIdentity.prefix(fromTerminalTitle: prefix + ".."))
        XCTAssertNil(CodexSessionIdentity.prefix(fromTerminalTitle: "12345678-1234-1234-1234-1234zzzzz..."))
        XCTAssertEqual(CodexSessionIdentity.uniqueMatch(prefix: prefix, in: [id]), id)
        XCTAssertNil(CodexSessionIdentity.uniqueMatch(prefix: prefix, in: []))
        XCTAssertNil(CodexSessionIdentity.uniqueMatch(prefix: prefix, in: [id, "12345678-1234-1234-1234-123456789def"]))
    }
}
