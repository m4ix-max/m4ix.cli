import Foundation

/// The model and reasoning effort for conversations started or resumed from
/// the toolbar. A nil field leaves that choice to the profile's settings.
/// Both reach the CLI as launch flags for one session; Claude's `/model` and
/// `/effort` commands would save themselves as the profile's new default.
struct ModelChoice: Equatable, Sendable {
    var model: String?
    var effort: String?

    var isDefault: Bool { model == nil && effort == nil }

    init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }

    init(preference: Any?) {
        let values = preference as? [String: String] ?? [:]
        model = values["model"].flatMap(Self.validModel)
        effort = values["effort"].flatMap(Self.validEffort)
    }

    var preference: [String: String] {
        var values: [String: String] = [:]
        values["model"] = model
        values["effort"] = effort
        return values
    }

    /// The launcher applies the same rules before either value reaches a CLI.
    static func validModel(_ value: String) -> String? {
        value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,79}$"#, options: .regularExpression) == nil ? nil : value
    }

    static func validEffort(_ value: String) -> String? {
        value.range(of: #"^[a-z]{1,16}$"#, options: .regularExpression) == nil ? nil : value
    }
}

struct ModelOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let efforts: [String]
}

/// The models one provider offers, and the profile's own default model.
struct ModelCatalog: Equatable, Sendable {
    var options: [ModelOption]
    var defaultModel: String?

    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    static func effortTitle(_ effort: String) -> String {
        switch effort {
        case "xhigh": return "Extra high"
        default: return effort.capitalized
        }
    }

    func title(for model: String) -> String {
        options.first { $0.id == model }?.title ?? model
    }

    /// The selected model's levels; with the profile default, its default
    /// model's levels, or the levels every listed model shares.
    func efforts(for model: String?) -> [String] {
        if let option = options.first(where: { $0.id == (model ?? defaultModel) }) { return option.efforts }
        guard let first = options.first else { return [] }
        return first.efforts.filter { effort in options.allSatisfy { $0.efforts.contains(effort) } }
    }

    /// Keeps a saved model visible when this profile's list no longer has it.
    func including(_ model: String?) -> [ModelOption] {
        guard let model, !options.contains(where: { $0.id == model }) else { return options }
        return options + [ModelOption(id: model, title: model, efforts: efforts(for: nil))]
    }

    /// Claude takes these aliases for its latest models. Codex lists its own
    /// models, with the levels each supports, in the profile's model cache.
    static func load(agent: Agent, profileDirectory: URL) -> ModelCatalog {
        switch agent {
        case .claude:
            let settings = (try? Data(contentsOf: profileDirectory.appendingPathComponent("settings.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let options = [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
                .map { ModelOption(id: $0.0, title: $0.1, efforts: claudeEfforts) }
            return ModelCatalog(options: options, defaultModel: settings?["model"] as? String)
        case .codex:
            let cache = (try? Data(contentsOf: profileDirectory.appendingPathComponent("models_cache.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let models = cache?["models"] as? [[String: Any]] ?? []
            let options = models.compactMap { model -> ModelOption? in
                guard model["visibility"] as? String == "list",
                      let slug = (model["slug"] as? String).flatMap(ModelChoice.validModel) else { return nil }
                let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                    .compactMap { ($0["effort"] as? String).flatMap(ModelChoice.validEffort) }
                return ModelOption(id: slug, title: model["display_name"] as? String ?? slug, efforts: levels)
            }
            let config = (try? String(contentsOf: profileDirectory.appendingPathComponent("config.toml"), encoding: .utf8)) ?? ""
            return ModelCatalog(options: options, defaultModel: topLevelTOMLString("model", in: config))
        }
    }

    /// Reads `key = "value"` before the first table header. Enough for the
    /// one line Codex writes; anything else leaves the default unnamed.
    static func topLevelTOMLString(_ key: String, in text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == key, parts[1].count > 2,
                  parts[1].hasPrefix("\""), parts[1].hasSuffix("\"") else { continue }
            return String(parts[1].dropFirst().dropLast())
        }
        return nil
    }
}
