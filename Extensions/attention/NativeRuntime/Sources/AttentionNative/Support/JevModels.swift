import Foundation

enum JevState: Sendable, Equatable, Codable {
    case text(String)
    case fields([String: String])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .fields(try container.decode([String: String].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let text): try container.encode(text)
        case .fields(let fields): try container.encode(fields)
        }
    }
}

struct JevOption: Sendable, Equatable, Codable {
    var id: String
    var meaning: String

    init(_ id: String, _ meaning: String) {
        self.id = id
        self.meaning = meaning
    }
}

enum JevQuestion: Sendable, Equatable {
    case noul(String)
    case choice(String, options: [JevOption])
    case score(String, levels: [String])

    static let maximumOptions = 255
    static let levelRange = 2...10
}

extension JevQuestion: Codable {
    private enum Keys: String, CodingKey { case type, instructions, criteria }

    init(from decoder: Decoder) throws {
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

    func encode(to encoder: Encoder) throws {
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

struct JevRequest: Codable, Sendable, Equatable {
    var model: String
    var state: JevState
    var questions: [String: JevQuestion]

    init(
        model: String = JevRequest.defaultModel, state: JevState, questions: [String: JevQuestion]
    ) {
        self.model = model
        self.state = state
        self.questions = questions
    }

    static let defaultModel = "jev-latest"

    func validated() throws -> JevRequest {
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

struct JevAnswer: Codable, Sendable, Equatable {
    var type: String
    var noul: Double?
    var choice: String?
    var probabilities: [String: Double]?
    var score: Double?
    var confidence: Double?

    init(
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

    func ranked() -> [(id: String, probability: Double)] {
        (probabilities ?? [:]).map { (id: $0.key, probability: $0.value) }
            .sorted {
                $0.probability == $1.probability ? $0.id < $1.id : $0.probability > $1.probability
            }
    }

    var chosenProbability: Double? {
        guard let choice else { return nil }
        return probabilities?[choice] ?? confidence
    }
}

struct JevUsage: Codable, Sendable, Equatable {
    var inputTokens: Int
    var outputTokens: Int

    private enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
    }

    init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

struct JevResponse: Codable, Sendable, Equatable {
    var model: String
    var answers: [String: JevAnswer]
    var usage: JevUsage?

    init(model: String, answers: [String: JevAnswer], usage: JevUsage? = nil) {
        self.model = model
        self.answers = answers
        self.usage = usage
    }
}

struct JevDecision: Codable, Sendable, Equatable {
    var response: JevResponse
    var milliseconds: Int

    init(response: JevResponse, milliseconds: Int) {
        self.response = response
        self.milliseconds = milliseconds
    }

    func noul(_ name: String) -> Double? { response.answers[name]?.noul }
    func choice(_ name: String) -> String? { response.answers[name]?.choice }
    func score(_ name: String) -> Double? { response.answers[name]?.score }
    func answer(_ name: String) -> JevAnswer? { response.answers[name] }
}

struct JevModelInfo: Codable, Sendable, Equatable {
    var name: String
    var description: String?

    init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

enum JevError: Error, Equatable, Sendable, Codable, LocalizedError {
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

    var errorDescription: String? {
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

    var isRetryable: Bool {
        switch self {
        case .rateLimited, .overloaded: true
        case .http(let status, _): status >= 500
        default: false
        }
    }
}
