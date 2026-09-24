import Foundation

public struct AgentLaunchEffort: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var summary: String

    public init(_ id: String, _ summary: String = "") {
        self.id = id
        self.summary = summary
    }
}

public struct AgentLaunchModel: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var efforts: [AgentLaunchEffort]
    public var defaultEffort: String?
    public var fastSummary: String?

    public init(
        id: String, name: String? = nil, summary: String = "", efforts: [AgentLaunchEffort] = [],
        defaultEffort: String? = nil, fastSummary: String? = nil
    ) {
        self.id = id
        self.name = name ?? id
        self.summary = summary
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.fastSummary = fastSummary
    }

    public var supportsFast: Bool { fastSummary != nil }

    public func effort(_ id: String?) -> AgentLaunchEffort? {
        guard let id else { return nil }
        return efforts.first { $0.id == id }
    }
}

public enum AgentLaunchSource: Equatable, Sendable {
    case cli(String)
    case builtIn

    public var label: String {
        switch self {
        case .cli(let name): "from \(name)"
        case .builtIn: "built in"
        }
    }

    public var isLive: Bool { self != .builtIn }
}

public struct AgentLaunchOptions: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var fast: Bool

    public init(model: String? = nil, effort: String? = nil, fast: Bool = false) {
        self.model = model?.isEmpty == true ? nil : model
        self.effort = effort?.isEmpty == true ? nil : effort
        self.fast = fast
    }

    public static let none = AgentLaunchOptions()

    public var isEmpty: Bool { self == .none }
}

public struct AgentLaunchCatalog: Equatable, Sendable {
    public var kind: AgentLaunchKind
    public var models: [AgentLaunchModel]
    public var standard: AgentLaunchModel
    public var source: AgentLaunchSource

    public init(
        kind: AgentLaunchKind, models: [AgentLaunchModel], standard: AgentLaunchModel,
        source: AgentLaunchSource
    ) {
        self.kind = kind
        self.models = models
        self.standard = standard
        self.source = source
    }

    public func model(_ id: String?) -> AgentLaunchModel {
        guard let id, let found = models.first(where: { $0.id == id }) else { return standard }
        return found
    }

    public func lists(_ id: String) -> Bool { models.contains { $0.id == id } }

    public func pickerModels(including stored: String?) -> [AgentLaunchModel] {
        guard let stored, !lists(stored) else { return models }
        return models + [AgentLaunchModel(id: stored, summary: "Not in the current list.")]
    }
}

public enum AgentLaunchKind: String, CaseIterable, Sendable {
    case claude = "Claude Code"
    case codex = "Codex"
    case opencode = "OpenCode"
    case cursor = "Cursor Agent"
    case pi = "Pi"
    case gemini = "Gemini"
    case amp = "Amp"

    public init?(kind: String) {
        self.init(rawValue: HerdrKind.displayName(for: kind))
    }

    public var discoveryCommand: String? {
        switch self {
        case .codex: "codex"
        case .opencode: "opencode"
        case .pi: "pi"
        case .cursor: "agent"
        case .claude, .gemini, .amp: nil
        }
    }

    public var selectsAtLaunch: Bool { self != .opencode }

    public var effortLabel: String { self == .pi ? "Thinking" : "Effort" }

    public var acceptsUnlistedModels: Bool { self != .amp }

    public var note: String? {
        switch self {
        case .opencode:
            "OpenCode's TUI takes no model flag, so pick the model inside OpenCode."
        case .amp: "Amp picks its model from the mode."
        case .claude: "Claude Code has no model list command, so these are its documented aliases."
        default: nil
        }
    }

    public var builtIn: AgentLaunchCatalog {
        switch self {
        case .codex:
            AgentLaunchCatalog.derived(kind: self, models: Self.codexModels, source: .builtIn)
        case .claude:
            AgentLaunchCatalog(
                kind: self, models: Self.claudeModels,
                standard: AgentLaunchModel(
                    id: "", name: "CLI default", efforts: Self.claudeEfforts,
                    fastSummary: Self.claudeFast + " Switches to Opus."),
                source: .builtIn)
        case .pi:
            AgentLaunchCatalog(
                kind: self, models: [],
                standard: AgentLaunchModel(id: "", name: "CLI default", efforts: Self.piThinking),
                source: .builtIn)
        case .opencode, .cursor, .gemini, .amp:
            AgentLaunchCatalog(
                kind: self, models: Self.plainModels[self] ?? [],
                standard: AgentLaunchModel(id: "", name: "CLI default"), source: .builtIn)
        }
    }

    static let claudeFast = "About 2x speed, uses more of your limit."

    static let claudeEfforts = [
        AgentLaunchEffort("low", "Quickest answers, lightest thinking"),
        AgentLaunchEffort("medium", "Balanced speed and depth"),
        AgentLaunchEffort("high", "Deeper thinking for complex work"),
        AgentLaunchEffort("xhigh", "Extra depth for hard problems"),
        AgentLaunchEffort("max", "Deepest thinking, slowest and uses the most"),
    ]

    static let piThinking = [
        AgentLaunchEffort("off", "No extended thinking"),
        AgentLaunchEffort("minimal", "Barely any thinking"),
        AgentLaunchEffort("low", "Light thinking"),
        AgentLaunchEffort("medium", "Balanced thinking"),
        AgentLaunchEffort("high", "Deep thinking"),
        AgentLaunchEffort("xhigh", "Extra deep thinking"),
        AgentLaunchEffort("max", "Deepest thinking the model allows"),
    ]

    static let codexEffortSummaries = [
        "low": "Fast responses with lighter reasoning",
        "medium": "Balances speed and reasoning depth for everyday tasks",
        "high": "Greater reasoning depth for complex problems",
        "xhigh": "Extra high reasoning depth for complex problems",
        "max": "Maximum reasoning depth for the hardest problems",
        "ultra": "Maximum reasoning with automatic task delegation",
    ]

    private static func claude(
        _ id: String, _ summary: String, efforts: Bool = true, fast: Bool = false
    ) -> AgentLaunchModel {
        AgentLaunchModel(
            id: id, summary: summary, efforts: efforts ? claudeEfforts : [],
            fastSummary: fast ? claudeFast : nil)
    }

    static let claudeModels = [
        claude("default", "Recommended model for your account"),
        claude("best", "Most capable model available to you"),
        claude("fable", "Latest Fable"),
        claude("opus", "Latest Opus", fast: true),
        claude("sonnet", "Latest Sonnet"),
        claude("haiku", "Latest Haiku, the quickest", efforts: false),
        claude("fable[1m]", "Latest Fable with a 1M token context"),
        claude("opus[1m]", "Latest Opus with a 1M token context", fast: true),
        claude("sonnet[1m]", "Latest Sonnet with a 1M token context"),
        claude("opusplan", "Opus while planning, Sonnet while building"),
        claude("claude-fable-5-1", "Claude Fable 5.1"),
        claude("claude-fable-5", "Claude Fable 5"),
        claude("claude-opus-5-5", "Claude Opus 5.5", fast: true),
        claude("claude-sonnet-5", "Claude Sonnet 5"),
        claude("claude-haiku-4-5-20251001", "Claude Haiku 4.5", efforts: false),
    ]

    private static func codex(
        _ slug: String, _ name: String, _ summary: String, levels: [String], standard: String,
        fast: String
    ) -> AgentLaunchModel {
        AgentLaunchModel(
            id: slug, name: name, summary: summary,
            efforts: levels.map { AgentLaunchEffort($0, codexEffortSummaries[$0] ?? "") },
            defaultEffort: standard, fastSummary: fast)
    }

    private static let codexThroughUltra = ["low", "medium", "high", "xhigh", "max", "ultra"]
    private static let codexThroughMax = ["low", "medium", "high", "xhigh", "max"]
    private static let codexFast = "1.5x speed, increased usage"

    static let codexModels = [
        codex(
            "gpt-6-astra", "GPT-6-Astra", "Frontier intelligence for the most demanding work.",
            levels: codexThroughUltra, standard: "low", fast: "2x speed, increased usage"),
        codex(
            "gpt-6-sol", "GPT-6-Sol", "Workhorse model for coding and everyday work.",
            levels: codexThroughUltra, standard: "medium", fast: "1.5x speed"),
        codex(
            "gpt-6-luna", "GPT-6-Luna", "Fast and affordable model for easier tasks.",
            levels: codexThroughMax, standard: "medium", fast: "1.5x speed"),
        codex(
            "gpt-5.6-sol", "GPT-5.6-Sol", "Older coding model for complex work.",
            levels: codexThroughUltra, standard: "low", fast: codexFast),
        codex(
            "gpt-5.6-terra", "GPT-5.6-Terra", "Older balanced model for straightforward work.",
            levels: codexThroughUltra, standard: "medium", fast: codexFast),
        codex(
            "gpt-5.6-luna", "GPT-5.6-Luna", "Older fast and efficient model.",
            levels: codexThroughMax, standard: "medium", fast: codexFast),
        codex(
            "gpt-5.5", "GPT-5.5", "Legacy coding model.",
            levels: ["low", "medium", "high", "xhigh"], standard: "medium", fast: codexFast),
    ]

    static let plainModels: [AgentLaunchKind: [AgentLaunchModel]] = [
        .cursor: [AgentLaunchModel(id: "auto", name: "Auto", summary: "Cursor picks the model")],
        .gemini: [
            AgentLaunchModel(id: "auto", name: "Auto", summary: "Gemini CLI picks per request"),
            AgentLaunchModel(id: "pro", name: "Pro", summary: "Most capable Gemini model"),
            AgentLaunchModel(id: "flash", name: "Flash", summary: "Fast and capable"),
            AgentLaunchModel(
                id: "flash-lite", name: "Flash Lite", summary: "Quickest and cheapest"),
        ],
        .amp: [
            AgentLaunchModel(id: "low", name: "Low", summary: "GLM-5.2, quickest and cheapest"),
            AgentLaunchModel(id: "medium", name: "Medium", summary: "GPT-5.6 Sol at medium effort"),
            AgentLaunchModel(id: "high", name: "High", summary: "GPT-5.6 Sol at extra high effort"),
            AgentLaunchModel(id: "ultra", name: "Ultra", summary: "Claude Fable 5, most capable"),
        ],
    ]
}

extension AgentLaunchCatalog {
    public func explanations(for options: AgentLaunchOptions) -> [String] {
        let chosen = model(options.model)
        var lines: [String] = []
        if let id = options.model {
            let listed = lists(id)
            let name = listed ? chosen.name : id
            let summary = listed ? chosen.summary : "not in the current list"
            lines.append(summary.isEmpty ? name : "\(name): \(summary)")
        } else {
            lines.append("\(kind.rawValue) picks its own model.")
        }
        if !chosen.efforts.isEmpty {
            if let effort = chosen.effort(options.effort) {
                let detail = effort.summary.isEmpty ? "." : ": \(effort.summary)"
                lines.append("\(kind.effortLabel) \(effort.id)\(detail)")
            } else {
                let fallback = chosen.defaultEffort.map { " (\($0))" } ?? ""
                lines.append("\(kind.effortLabel): the model's default\(fallback).")
            }
        }
        if let fast = chosen.fastSummary {
            lines.append("Fast mode\(options.fast ? " on" : ""): \(fast)")
        }
        return lines
    }

    static func derived(
        kind: AgentLaunchKind, models: [AgentLaunchModel], source: AgentLaunchSource
    ) -> AgentLaunchCatalog {
        let first = models.first
        let shared = first?.efforts.filter { effort in
            models.allSatisfy { $0.effort(effort.id) != nil }
        }
        let fast = models.allSatisfy(\.supportsFast) ? first?.fastSummary : nil
        return AgentLaunchCatalog(
            kind: kind, models: models,
            standard: AgentLaunchModel(
                id: "", name: "CLI default", efforts: shared ?? [], fastSummary: fast),
            source: source)
    }
}
