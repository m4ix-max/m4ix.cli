import Foundation
import XCTest
@testable import PrivateCLIHost

final class ProjectContextTests: XCTestCase {
    func testPlanSavePreservesConcurrentHandoffAndSurvivesNewStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectContextStore(directory: root)
        let task = ProjectTask(title: "Review", owner: "Codex", details: "Parser.swift only")
        try await store.savePlan(path: "/tmp/project", brief: "Ship the parser", tasks: [task])
        let handoff = ProjectHandoffRecord(id: UUID(), date: Date(), source: "Claude", target: "Codex", prompt: "Review tests", state: "Prepared")
        try await store.appendHandoff(path: "/tmp/project", record: handoff)
        try await store.savePlan(path: "/tmp/project", brief: "Updated brief", tasks: [task])
        try await store.updateHandoff(path: "/tmp/project", id: handoff.id, state: "Launch requested")
        let context = try await ProjectContextStore(directory: root).load(path: "/tmp/project")
        XCTAssertEqual(context.brief, "Updated brief")
        XCTAssertEqual(context.tasks, [task])
        XCTAssertEqual(context.handoffs.count, 1)
        XCTAssertEqual(context.handoffs[0].state, "Launch requested")
        let other = try await store.load(path: "/tmp/other")
        XCTAssertTrue(other.tasks.isEmpty)
    }

    func testCorruptRecordIsNeverOverwrittenWithEmptyPlan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectContextStore(directory: root)
        try await store.savePlan(path: "/tmp/project", brief: "Keep", tasks: [])
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let badData = Data("bad json".utf8)
        try badData.write(to: file)
        do {
            try await store.savePlan(path: "/tmp/project", brief: "Erase", tasks: [])
            XCTFail("Corruption must be surfaced")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: file), badData)
    }
}
