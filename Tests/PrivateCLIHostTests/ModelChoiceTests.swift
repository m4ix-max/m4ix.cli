import Foundation
import XCTest
@testable import PrivateCLIHost

@MainActor
final class ModelChoiceTests: XCTestCase {
    func testCodexCatalogListsVisibleModelsWithTheirOwnEffortLevels() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        let cache: [String: Any] = ["models": [
            ["slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list",
             "supported_reasoning_levels": [["effort": "low"], ["effort": "high"], ["effort": "max"]]],
            ["slug": "gpt-reserve", "display_name": "GPT-Reserve", "visibility": "hide",
             "supported_reasoning_levels": [["effort": "low"]]],
            ["slug": "gpt-5.5", "display_name": "GPT-5.5", "visibility": "list",
             "supported_reasoning_levels": [["effort": "low"], ["effort": "high"]]],
            ["slug": "bad\"slug", "visibility": "list", "supported_reasoning_levels": []]
        ]]
        try JSONSerialization.data(withJSONObject: cache).write(to: profile.appendingPathComponent("models_cache.json"))
        try Data("""
        sandbox_mode = "danger-full-access"
        model = "gpt-6-astra"

        [profiles.other]
        model = "gpt-5.5"
        """.utf8).write(to: profile.appendingPathComponent("config.toml"))

        let catalog = ModelCatalog.load(agent: .codex, profileDirectory: profile)
        XCTAssertEqual(catalog.options.map(\.id), ["gpt-6-astra", "gpt-5.5"])
        XCTAssertEqual(catalog.defaultModel, "gpt-6-astra")
        XCTAssertEqual(catalog.efforts(for: nil), ["low", "high", "max"], "The default model's levels")
        XCTAssertEqual(catalog.efforts(for: "gpt-5.5"), ["low", "high"])
        XCTAssertEqual(catalog.including("gpt-retired").last?.id, "gpt-retired")
        XCTAssertEqual(ModelCatalog(options: catalog.options, defaultModel: nil).efforts(for: nil), ["low", "high"],
                       "Without a known default, only levels every model shares")
        XCTAssertNil(ModelCatalog.topLevelTOMLString("model", in: "[tui]\nmodel = \"nested\""))
    }

    func testClaudeCatalogNamesTheProfileDefault() throws {
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: profile) }
        try Data(#"{"model":"opus"}"#.utf8).write(to: profile.appendingPathComponent("settings.json"))
        let catalog = ModelCatalog.load(agent: .claude, profileDirectory: profile)
        XCTAssertEqual(catalog.defaultModel, "opus")
        XCTAssertEqual(catalog.title(for: "opus"), "Opus")
        XCTAssertEqual(catalog.efforts(for: "sonnet"), ModelCatalog.claudeEfforts)
        XCTAssertEqual(ModelCatalog.effortTitle("xhigh"), "Extra high")
    }

    func testChoiceIsKeptPerProviderAndDropsAnEffortTheModelLacks() throws {
        let suite = "m4ix.cli.model." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: profile) }
        defaults.set(["model": "--dangerously-skip-permissions", "effort": "high"], forKey: "PrivateCLIHostModelChoice.codex")
        let model = HostModel(defaults: defaults, profileBase: profile)
        XCTAssertEqual(model.modelChoice(for: .codex), ModelChoice(effort: "high"), "A malformed saved model is ignored")

        model.setModelChoice(ModelChoice(model: "sonnet", effort: "max"), for: .claude)
        XCTAssertEqual(model.modelChoice(for: .claude), ModelChoice(model: "sonnet", effort: "max"))
        model.refreshModelCatalogs()
        let deadline = Date().addingTimeInterval(3)
        while model.modelCatalogs.isEmpty && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        model.setModelChoice(ModelChoice(model: "sonnet", effort: "ultra"), for: .claude)
        XCTAssertEqual(model.modelChoice(for: .claude), ModelChoice(model: "sonnet"))

        let reopened = HostModel(defaults: defaults, profileBase: profile)
        XCTAssertEqual(reopened.modelChoice(for: .claude), ModelChoice(model: "sonnet"))
        reopened.setModelChoice(ModelChoice(), for: .claude)
        XCTAssertNil(defaults.object(forKey: "PrivateCLIHostModelChoice.claude"))
    }
}
