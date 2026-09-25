import Foundation

public enum AgentLaunchOptionsError: LocalizedError, Equatable {
    case notSelectable(String)
    case unknownModel(String, kind: String, allowed: [String])
    case effortUnsupported(String, model: String, allowed: [String])
    case fastUnsupported(model: String)

    public var errorDescription: String? {
        switch self {
        case .notSelectable(let kind):
            "\(kind) cannot take a model, effort or fast mode at launch"
        case .unknownModel(let model, let kind, let allowed):
            "\(kind) has no \(model); choose one of " + allowed.joined(separator: ", ")
        case .effortUnsupported(let effort, let model, let allowed):
            allowed.isEmpty
                ? "\(model) takes no effort level, so \(effort) cannot be used"
                : "\(model) does not support \(effort); choose one of "
                    + allowed.joined(separator: ", ")
        case .fastUnsupported(let model):
            "\(model) has no fast mode"
        }
    }
}

public enum AgentLaunchArguments {
    public static let claudeFastSettings = #"{"fastMode":true}"#

    public static func validate(_ options: AgentLaunchOptions, in catalog: AgentLaunchCatalog)
        throws
    {
        guard !options.isEmpty else { return }
        let kind = catalog.kind
        guard kind.selectsAtLaunch else {
            throw AgentLaunchOptionsError.notSelectable(kind.rawValue)
        }
        if let model = options.model, !kind.acceptsUnlistedModels, !catalog.lists(model) {
            throw AgentLaunchOptionsError.unknownModel(
                model, kind: kind.rawValue, allowed: catalog.models.map(\.id))
        }
        let chosen = catalog.model(options.model)
        let label = options.model ?? "The \(kind.rawValue) default model"
        if let effort = options.effort, chosen.effort(effort) == nil {
            throw AgentLaunchOptionsError.effortUnsupported(
                effort, model: label, allowed: chosen.efforts.map(\.id))
        }
        if options.fast, !chosen.supportsFast {
            throw AgentLaunchOptionsError.fastUnsupported(model: label)
        }
    }

    public static func sanitized(_ options: AgentLaunchOptions, in catalog: AgentLaunchCatalog)
        -> AgentLaunchOptions
    {
        guard catalog.kind.selectsAtLaunch else { return .none }
        var model = options.model
        if let chosen = model, !catalog.kind.acceptsUnlistedModels, !catalog.lists(chosen) {
            model = nil
        }
        let chosen = catalog.model(model)
        return AgentLaunchOptions(
            model: model, effort: chosen.effort(options.effort)?.id,
            fast: options.fast && chosen.supportsFast)
    }

    public static func arguments(_ options: AgentLaunchOptions, in catalog: AgentLaunchCatalog)
        throws -> [String]
    {
        try validate(options, in: catalog)
        return flags(options, for: catalog.kind)
    }

    public static func launchArguments(
        kind: String, options: AgentLaunchOptions, catalog: AgentLaunchCatalog? = nil
    ) -> [String] {
        guard let launchKind = AgentLaunchKind(kind: kind) else { return [] }
        let resolved = catalog ?? launchKind.builtIn
        return flags(sanitized(options, in: resolved), for: launchKind)
    }

    static func flags(_ options: AgentLaunchOptions, for kind: AgentLaunchKind) -> [String] {
        var flags: [String] = []
        switch kind {
        case .claude:
            if let model = options.model { flags += ["--model", model] }
            if let effort = options.effort { flags += ["--effort", effort] }
            if options.fast { flags += ["--settings", claudeFastSettings] }
        case .codex:
            if let model = options.model { flags += ["-m", model] }
            if let effort = options.effort {
                flags += ["-c", "model_reasoning_effort=\"\(effort)\""]
            }
            if options.fast { flags += ["-c", "service_tier=\"fast\""] }
        case .pi:
            if let model = options.model { flags += ["--model", model] }
            if let effort = options.effort { flags += ["--thinking", effort] }
        case .cursor:
            if let model = options.model { flags += ["--model", model] }
        case .gemini:
            if let model = options.model { flags += ["-m", model] }
        case .amp:
            if let model = options.model { flags += ["--mode", model] }
        case .opencode:
            break
        }
        return flags
    }
}
