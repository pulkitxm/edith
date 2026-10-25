import Foundation

public enum JevState: Sendable, Equatable, Codable {
    case text(String)
    case fields([String: String])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .fields(try container.decode([String: String].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .fields(let fields): try container.encode(fields)
        }
    }
}

public struct JevOption: Sendable, Equatable, Codable {
    public var id: String
    public var meaning: String

    public init(_ id: String, _ meaning: String) {
        self.id = id
        self.meaning = meaning
    }
}

public enum JevQuestion: Sendable, Equatable {
    case noul(String)
    case choice(String, options: [JevOption])
    case score(String, levels: [String])

    public static let maximumOptions = 255
    public static let levelRange = 2...10
}

extension JevQuestion: Codable {
    private enum Keys: String, CodingKey { case type, instructions, criteria }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let instructions = try container.decode(String.self, forKey: .instructions)
        switch try container.decode(String.self, forKey: .type) {
        case "noul":
            self = .noul(instructions)
        case "choice":
            let criteria = try container.decode([String: String].self, forKey: .criteria)
            self = .choice(
                instructions,
                options: criteria.keys.sorted().map { JevOption($0, criteria[$0] ?? "") })
        case "score":
            self = .score(
                instructions, levels: try container.decode([String].self, forKey: .criteria))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown question type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .noul(let instructions):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        case .choice(let instructions, let options):
            try container.encode("choice", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            let criteria = Dictionary(
                options.map { ($0.id, $0.meaning) }, uniquingKeysWith: { first, _ in first })
            try container.encode(criteria, forKey: .criteria)
        case .score(let instructions, let levels):
            try container.encode("score", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(levels, forKey: .criteria)
        }
    }
}

public struct JevRequest: Codable, Sendable, Equatable {
    public var model: String
    public var state: JevState
    public var questions: [String: JevQuestion]

    public init(
        model: String = JevRequest.defaultModel, state: JevState, questions: [String: JevQuestion]
    ) {
        self.model = model
        self.state = state
        self.questions = questions
    }

    public static let defaultModel = "jev-latest"

    public func validated() throws -> JevRequest {
        guard !questions.isEmpty else { throw JevError.invalidRequest("ask at least one question") }
        for (name, question) in questions {
            switch question {
            case .noul: continue
            case .choice(_, let options):
                guard options.count >= 2, options.count <= JevQuestion.maximumOptions else {
                    throw JevError.invalidRequest(
                        "\(name) needs between 2 and \(JevQuestion.maximumOptions) options")
                }
                guard Set(options.map(\.id)).count == options.count else {
                    throw JevError.invalidRequest("\(name) repeats an option id")
                }
            case .score(_, let levels):
                guard JevQuestion.levelRange.contains(levels.count) else {
                    throw JevError.invalidRequest("\(name) needs between 2 and 10 levels")
                }
            }
        }
        return self
    }
}

public struct JevAnswer: Codable, Sendable, Equatable {
    public var type: String
    public var noul: Double?
    public var choice: String?
    public var probabilities: [String: Double]?
    public var score: Double?
    public var confidence: Double?

    public init(
        type: String, noul: Double? = nil, choice: String? = nil,
        probabilities: [String: Double]? = nil, score: Double? = nil, confidence: Double? = nil
    ) {
        self.type = type
        self.noul = noul
        self.choice = choice
        self.probabilities = probabilities
        self.score = score
        self.confidence = confidence
    }

    public func ranked() -> [(id: String, probability: Double)] {
        (probabilities ?? [:]).map { (id: $0.key, probability: $0.value) }
            .sorted {
                $0.probability == $1.probability ? $0.id < $1.id : $0.probability > $1.probability
            }
    }

    public var chosenProbability: Double? {
        guard let choice else { return nil }
        return probabilities?[choice] ?? confidence
    }
}

public struct JevUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct JevResponse: Codable, Sendable, Equatable {
    public var model: String
    public var answers: [String: JevAnswer]
    public var usage: JevUsage?

    public init(model: String, answers: [String: JevAnswer], usage: JevUsage? = nil) {
        self.model = model
        self.answers = answers
        self.usage = usage
    }
}

public struct JevDecision: Codable, Sendable, Equatable {
    public var response: JevResponse
    public var milliseconds: Int

    public init(response: JevResponse, milliseconds: Int) {
        self.response = response
        self.milliseconds = milliseconds
    }

    public func noul(_ name: String) -> Double? { response.answers[name]?.noul }
    public func choice(_ name: String) -> String? { response.answers[name]?.choice }
    public func score(_ name: String) -> Double? { response.answers[name]?.score }
    public func answer(_ name: String) -> JevAnswer? { response.answers[name] }
}

public struct JevModelInfo: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

public enum JevError: Error, Equatable, Sendable, Codable, LocalizedError {
    case missingKey
    case invalidRequest(String)
    case unauthorized
    case noCredits(String)
    case rejected(String)
    case rateLimited(after: TimeInterval?)
    case overloaded
    case http(Int, String)
    case malformedResponse
    case paused(until: Date)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add a TypeSafe API key in Settings to use Jev."
        case .invalidRequest(let reason): "The Jev request is invalid: \(reason)."
        case .unauthorized: "TypeSafe rejected the API key."
        case .noCredits(let message): message
        case .rejected(let message): "TypeSafe rejected the request: \(message)"
        case .rateLimited: "TypeSafe is rate limiting this key."
        case .overloaded: "TypeSafe is overloaded."
        case .http(let status, _): "TypeSafe answered with HTTP \(status)."
        case .malformedResponse: "TypeSafe returned a response Edith could not read."
        case .paused: "Jev is paused after repeated failures and will retry shortly."
        case .unavailable(let reason): reason
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded: true
        case .http(let status, _): status >= 500
        default: false
        }
    }
}
