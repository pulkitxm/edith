import Foundation

public struct CompanionHealth: Codable, Equatable, Sendable {
    public let ok: Bool
    public let degraded: Bool?
    public let checks: [CompanionCheck]

    public init(ok: Bool, degraded: Bool? = nil, checks: [CompanionCheck]) {
        self.ok = ok
        self.degraded = degraded
        self.checks = checks
    }

    public var failing: [CompanionCheck] { checks.filter { !$0.ok } }

    public var blocking: [CompanionCheck] {
        failing.filter { $0.severityKind == .blocker }
    }
}

public enum CompanionCheckSeverity: String, Codable, Equatable, Sendable {
    case blocker
    case degraded
    case optional
}

public struct CompanionCheck: Codable, Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let severity: String?
    public let detail: String

    public init(name: String, ok: Bool, severity: String? = nil, detail: String) {
        self.name = name
        self.ok = ok
        self.severity = severity
        self.detail = detail
    }

    public var severityKind: CompanionCheckSeverity {
        guard let severity, let parsed = CompanionCheckSeverity(rawValue: severity) else {
            return .blocker
        }
        return parsed
    }
}

public struct CompanionStatus: Codable, Equatable, Sendable {
    public let sources: Int
    public let episodes: Int
    public let claims: Int
    public let observations: Int
    public let chunks: Int
    public let pendingEpisodes: Int
    public let latestIngestedAt: String?

    public init(
        sources: Int, episodes: Int, claims: Int, observations: Int,
        chunks: Int, pendingEpisodes: Int, latestIngestedAt: String?
    ) {
        self.sources = sources
        self.episodes = episodes
        self.claims = claims
        self.observations = observations
        self.chunks = chunks
        self.pendingEpisodes = pendingEpisodes
        self.latestIngestedAt = latestIngestedAt
    }

    enum CodingKeys: String, CodingKey {
        case sources
        case episodes
        case claims
        case observations
        case chunks
        case pendingEpisodes = "pending_episodes"
        case latestIngestedAt = "latest_ingested_at"
    }
}

public struct CompanionSearchHit: Codable, Equatable, Sendable {
    public let chunkId: String
    public let episodeId: String
    public let ord: Int
    public let title: String
    public let occurredAt: String
    public let kind: String
    public let snippet: String
    public let score: Double

    public init(
        chunkId: String, episodeId: String, ord: Int, title: String, occurredAt: String,
        kind: String, snippet: String, score: Double
    ) {
        self.chunkId = chunkId
        self.episodeId = episodeId
        self.ord = ord
        self.title = title
        self.occurredAt = occurredAt
        self.kind = kind
        self.snippet = snippet
        self.score = score
    }
}

public struct CompanionIndexOutcome: Codable, Equatable, Sendable {
    public let episodesIndexed: Int
    public let chunksCreated: Int

    public init(episodesIndexed: Int, chunksCreated: Int) {
        self.episodesIndexed = episodesIndexed
        self.chunksCreated = chunksCreated
    }
}

public struct CompanionEpisode: Codable, Equatable, Sendable {
    public let id: String
    public let occurredAt: String
    public let kind: String
    public let title: String
    public let sha256: String

    public init(id: String, occurredAt: String, kind: String, title: String, sha256: String) {
        self.id = id
        self.occurredAt = occurredAt
        self.kind = kind
        self.title = title
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case id
        case occurredAt = "occurred_at"
        case kind
        case title
        case sha256
    }
}

public struct CompanionIngestFile: Codable, Equatable, Sendable {
    public let name: String
    public let text: String
    public let mtime: String?

    public init(name: String, text: String, mtime: String? = nil) {
        self.name = name
        self.text = text
        self.mtime = mtime
    }
}

public struct CompanionIngestOutcome: Codable, Equatable, Sendable {
    public let name: String
    public let status: String
    public let episodeId: String
    public let occurredAt: String

    public init(name: String, status: String, episodeId: String, occurredAt: String) {
        self.name = name
        self.status = status
        self.episodeId = episodeId
        self.occurredAt = occurredAt
    }
}

public struct CompanionSyncOutcome: Codable, Equatable, Sendable {
    public let eventsFetched: Int
    public let observationsInserted: Int

    public init(eventsFetched: Int, observationsInserted: Int) {
        self.eventsFetched = eventsFetched
        self.observationsInserted = observationsInserted
    }
}

public struct CompanionObservation: Codable, Equatable, Sendable {
    public let id: String
    public let source: String
    public let observedAt: String
    public let kind: String
    public let summary: String

    public init(id: String, source: String, observedAt: String, kind: String, summary: String) {
        self.id = id
        self.source = source
        self.observedAt = observedAt
        self.kind = kind
        self.summary = summary
    }
}

public struct CompanionAskCitation: Codable, Equatable, Sendable {
    public let episodeId: String
    public let quote: String
    public let support: String
    public let title: String
    public let occurredAt: String

    public init(
        episodeId: String, quote: String, support: String, title: String, occurredAt: String
    ) {
        self.episodeId = episodeId
        self.quote = quote
        self.support = support
        self.title = title
        self.occurredAt = occurredAt
    }
}

public struct CompanionAskOutcome: Codable, Equatable, Sendable {
    public let answer: String
    public let citations: [CompanionAskCitation]
    public let chunksConsidered: Int
    public let model: String
    public let persona: String
    public let abstained: Bool
    public let grounding: CompanionGrounding
    public let reframed: String?
    public let opinion: String?
    public let beliefs: [CompanionBeliefHit]
    public let stages: [String]

    public init(
        answer: String, citations: [CompanionAskCitation], chunksConsidered: Int, model: String,
        persona: String, abstained: Bool, grounding: CompanionGrounding, reframed: String?,
        opinion: String?, beliefs: [CompanionBeliefHit], stages: [String]
    ) {
        self.answer = answer
        self.citations = citations
        self.chunksConsidered = chunksConsidered
        self.model = model
        self.persona = persona
        self.abstained = abstained
        self.grounding = grounding
        self.reframed = reframed
        self.opinion = opinion
        self.beliefs = beliefs
        self.stages = stages
    }
}

public struct CompanionRunStep: Codable, Equatable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String?

    public init(name: String, ok: Bool, detail: String? = nil) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case name
        case ok
        case detail
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        ok = try container.decode(Bool.self, forKey: .ok)
        if let text = try? container.decode(String.self, forKey: .detail) {
            detail = text
        } else if let value = try? container.decode(JSONValueBox.self, forKey: .detail) {
            detail = value.description
        } else {
            detail = nil
        }
    }
}

struct JSONValueBox: Decodable, CustomStringConvertible {
    let description: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let object = try? container.decode([String: Double].self) {
            description = object.sorted { $0.key < $1.key }
                .map { "\($0.key) \(Int($0.value))" }
                .joined(separator: ", ")
        } else if let text = try? container.decode(String.self) {
            description = text
        } else if let number = try? container.decode(Double.self) {
            description = number == number.rounded() ? String(Int(number)) : String(number)
        } else if let flag = try? container.decode(Bool.self) {
            description = flag ? "yes" : "no"
        } else if let object = try? container.decode([String: String].self) {
            description = object.sorted { $0.key < $1.key }
                .map { "\($0.key) \($0.value)" }
                .joined(separator: ", ")
        } else {
            description = ""
        }
    }
}

public struct CompanionRun: Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: String
    public let finishedAt: String?
    public let ok: Bool
    public let steps: [CompanionRunStep]

    public init(
        id: String, startedAt: String, finishedAt: String?, ok: Bool, steps: [CompanionRunStep]
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.ok = ok
        self.steps = steps
    }
}

public struct CompanionExtractOutcome: Codable, Equatable, Sendable {
    public let episodesConsidered: Int
    public let claimsExtracted: Int

    public init(episodesConsidered: Int, claimsExtracted: Int) {
        self.episodesConsidered = episodesConsidered
        self.claimsExtracted = claimsExtracted
    }
}

public struct CompanionCorroborateOutcome: Codable, Equatable, Sendable {
    public let claimsChecked: Int
    public let corroborated: Int
    public let contradicted: Int
    public let unclear: Int

    public init(claimsChecked: Int, corroborated: Int, contradicted: Int, unclear: Int) {
        self.claimsChecked = claimsChecked
        self.corroborated = corroborated
        self.contradicted = contradicted
        self.unclear = unclear
    }
}

public struct CompanionClaim: Codable, Equatable, Sendable {
    public let id: String
    public let statement: String
    public let claimType: String
    public let testable: Bool
    public let assertedAt: String
    public let episodeId: String?
    public let verdict: String?
    public let verdictNote: String?
    public let observationIds: [String]?

    public init(
        id: String, statement: String, claimType: String, testable: Bool, assertedAt: String,
        episodeId: String?, verdict: String?, verdictNote: String?, observationIds: [String]?
    ) {
        self.id = id
        self.statement = statement
        self.claimType = claimType
        self.testable = testable
        self.assertedAt = assertedAt
        self.episodeId = episodeId
        self.verdict = verdict
        self.verdictNote = verdictNote
        self.observationIds = observationIds
    }
}

public struct CompanionReflectOutcome: Codable, Equatable, Sendable {
    public let episodesConsidered: Int
    public let beliefsFormed: Int
    public let model: String

    public init(episodesConsidered: Int, beliefsFormed: Int, model: String) {
        self.episodesConsidered = episodesConsidered
        self.beliefsFormed = beliefsFormed
        self.model = model
    }
}

public struct CompanionBelief: Codable, Equatable, Sendable {
    public let id: String
    public let statement: String
    public let kind: String
    public let confidence: Double
    public let firstFormed: String
    public let evidenceEpisodeIds: [String]
    public let status: String

    public init(
        id: String, statement: String, kind: String, confidence: Double, firstFormed: String,
        evidenceEpisodeIds: [String], status: String
    ) {
        self.id = id
        self.statement = statement
        self.kind = kind
        self.confidence = confidence
        self.firstFormed = firstFormed
        self.evidenceEpisodeIds = evidenceEpisodeIds
        self.status = status
    }
}

public struct CompanionWriteAck: Codable, Equatable, Sendable {
    public let ok: Bool
    public let id: String?
    public let section: String?

    public init(ok: Bool, id: String? = nil, section: String? = nil) {
        self.ok = ok
        self.id = id
        self.section = section
    }
}

public enum CompanionClientError: Error, Equatable, LocalizedError, Sendable {
    case unreachable(String)
    case badResponse(Int, String)

    public var errorDescription: String? {
        switch self {
        case let .unreachable(detail):
            return detail
        case let .badResponse(status, detail):
            return detail.isEmpty ? "HTTP \(status)" : detail
        }
    }
}

public struct CompanionClient: Sendable {
    public static let defaultEndpointString = "http://127.0.0.1:4820"
    public static let defaultTimeout: TimeInterval = 20
    public static let longRequestTimeout: TimeInterval = 300

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static func endpoint(override: String?) -> URL {
        let fallback = URL(string: defaultEndpointString)!
        let value =
            override
            ?? ProcessInfo.processInfo.environment["EDITH_COMPANION_URL"]
            ?? SharedDefaults.store.string(forKey: AppStorageKeys.Companion.endpoint)
        guard let value, !value.isEmpty else { return fallback }
        return URL(string: value) ?? fallback
    }

    public func health() async throws -> CompanionHealth {
        try await get("health", allowing: [503])
    }

    public func status() async throws -> CompanionStatus {
        try await get("status")
    }

    public func episodes(limit: Int) async throws -> [CompanionEpisode] {
        var components = URLComponents(url: url(for: "episodes"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        return try await request(URLRequest(url: components?.url ?? url(for: "episodes")))
    }

    public func search(query: String, k: Int) async throws -> [CompanionSearchHit] {
        var components = URLComponents(url: url(for: "search"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "q", value: query), URLQueryItem(name: "k", value: String(k)),
        ]
        return try await request(URLRequest(url: components?.url ?? url(for: "search")))
    }

    public func index() async throws -> CompanionIndexOutcome {
        var request = URLRequest(url: url(for: "index"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        return try await self.request(request, timeout: CompanionClient.longRequestTimeout)
    }

    public func ingest(files: [CompanionIngestFile]) async throws -> [CompanionIngestOutcome] {
        var request = URLRequest(url: url(for: "ingest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(IngestRequest(files: files))
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        return try await self.request(request, timeout: CompanionClient.longRequestTimeout)
    }

    public func runs(limit: Int) async throws -> [CompanionRun] {
        var components = URLComponents(url: url(for: "runs"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        return try await request(URLRequest(url: components?.url ?? url(for: "runs")))
    }

    public func extractClaims() async throws -> CompanionExtractOutcome {
        var request = URLRequest(url: url(for: "claims/extract"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        return try await self.request(request, timeout: 600)
    }

    public func corroborate() async throws -> CompanionCorroborateOutcome {
        var request = URLRequest(url: url(for: "corroborate"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        return try await self.request(request, timeout: 600)
    }

    public func claims(limit: Int) async throws -> [CompanionClaim] {
        var components = URLComponents(url: url(for: "claims"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        return try await request(URLRequest(url: components?.url ?? url(for: "claims")))
    }

    public func ask(question: String) async throws -> CompanionAskOutcome {
        var request = URLRequest(url: url(for: "ask"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(AskRequest(question: question))
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        return try await self.request(request, timeout: 600)
    }

    public func reflect() async throws -> CompanionReflectOutcome {
        var request = URLRequest(url: url(for: "reflect"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        return try await self.request(request, timeout: 600)
    }

    public func beliefs(limit: Int) async throws -> [CompanionBelief] {
        var components = URLComponents(url: url(for: "beliefs"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        return try await request(URLRequest(url: components?.url ?? url(for: "beliefs")))
    }

    public func syncGithub() async throws -> CompanionSyncOutcome {
        var request = URLRequest(url: url(for: "connectors/github/sync"))
        request.httpMethod = "POST"
        request.httpBody = Data()
        return try await self.request(request, timeout: 120)
    }

    public func observations(limit: Int, kind: String?) async throws -> [CompanionObservation] {
        var components = URLComponents(
            url: url(for: "observations"), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let kind, !kind.isEmpty {
            items.append(URLQueryItem(name: "kind", value: kind))
        }
        components?.queryItems = items
        return try await request(URLRequest(url: components?.url ?? url(for: "observations")))
    }

    public func ingestPdf(name: String, data: Data, mtime: String?) async throws
        -> CompanionIngestOutcome
    {
        var request = URLRequest(url: url(for: "ingest/pdf"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(
                AudioIngestRequest(name: name, dataB64: data.base64EncodedString(), mtime: mtime))
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        return try await self.request(request, timeout: 120)
    }

    public func ingestAudio(name: String, data: Data, mtime: String?) async throws
        -> CompanionIngestOutcome
    {
        var request = URLRequest(url: url(for: "ingest/audio"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(
                AudioIngestRequest(name: name, dataB64: data.base64EncodedString(), mtime: mtime))
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        return try await self.request(request, timeout: 600)
    }

    public func connectorSettings() async throws -> CompanionConnectorSettings {
        try await get("settings/connectors")
    }

    public func updateConnectorSettings(github: String?, notion: String?) async throws
        -> CompanionConnectorSettings
    {
        try await post(
            "settings/connectors", body: ConnectorTokenRequest(github: github, notion: notion))
    }

    public func importConnector(source: String, json: Data) async throws
        -> CompanionImportOutcome
    {
        var request = URLRequest(url: url(for: "connectors/\(source)/import"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        return try await self.request(request, timeout: 900)
    }

    public func facts(asOf: String?, timeline: String, limit: Int) async throws
        -> [CompanionFact]
    {
        var query = ["timeline": timeline, "limit": String(limit)]
        if let asOf { query["asOf"] = asOf }
        return try await get("facts", query: query)
    }

    public func correctBelief(id: String, retire: Bool, statement: String?) async throws
        -> CompanionCorrectOutcome
    {
        try await post(
            "beliefs/\(id)/correct",
            body: CorrectRequest(retire: retire, statement: statement))
    }

    public func weekly() async throws -> CompanionCurateOutcome {
        try await post("reflect/weekly", body: EmptyBody(), timeout: 1800)
    }

    public func db(_ action: String) async throws -> CompanionRebuildOutcome {
        try await post("db/\(action)", body: EmptyBody(), timeout: 900)
    }

    public func rateTurn(id: String, rating: Int) async throws -> [String: CodableIgnored] {
        try await post("turns/\(id)/feedback", body: RatingRequest(rating: rating))
    }

    public func personas() async throws -> [CompanionPersona] {
        try await get("personas")
    }

    public func askPersona(question: String, persona: String?) async throws
        -> CompanionAskOutcome
    {
        try await post(
            "ask", body: PersonaAskRequest(question: question, persona: persona),
            timeout: 900)
    }

    public func council(question: String, personas: [String]) async throws -> CompanionCouncil {
        try await post(
            "council", body: CouncilRequest(question: question, personas: personas), timeout: 1800)
    }

    public func core() async throws -> [CompanionCoreSection] {
        try await get("core")
    }

    public func writeCore(section: String, content: String) async throws -> CompanionWriteAck {
        try await post("core", body: CoreWriteRequest(section: section, content: content))
    }

    public func hypotheses(limit: Int) async throws -> [CompanionHypothesis] {
        try await get("hypotheses", query: ["limit": String(limit)])
    }

    public func runHypotheses() async throws -> [String: CodableIgnored] {
        try await post("hypotheses/run", body: EmptyBody(), timeout: 1800)
    }

    public func predictions(limit: Int) async throws -> [CompanionPrediction] {
        try await get("predictions", query: ["limit": String(limit)])
    }

    public func commitments(limit: Int) async throws -> [CompanionCommitment] {
        try await get("commitments", query: ["limit": String(limit)])
    }

    public func discrepancies(limit: Int) async throws -> [CompanionDiscrepancy] {
        try await get("discrepancies", query: ["limit": String(limit)])
    }

    public func overrideDiscrepancy(id: String, real: String) async throws -> CompanionWriteAck {
        try await post("discrepancies/\(id)/override", body: OverrideRequest(real: real))
    }

    public func calibration() async throws -> [CompanionCalibration] {
        try await get("calibration")
    }

    public func questions(limit: Int) async throws -> CompanionQuestionList {
        try await get("questions", query: ["limit": String(limit)])
    }

    public func nextQuestion() async throws -> CompanionNextQuestion {
        try await post("questions/next", body: EmptyBody(), timeout: 60)
    }

    public func answerQuestion(id: String, answer: String) async throws
        -> CompanionQuestionAnswer
    {
        try await post("questions/\(id)/answer", body: AnswerRequest(answer: answer), timeout: 120)
    }

    public func skipQuestion(id: String) async throws -> [String: String] {
        try await post("questions/\(id)/skip", body: EmptyBody())
    }

    public func muteTopic(_ topic: String) async throws -> MuteOutcome {
        try await post("questions/mute", body: MuteRequest(topic: topic))
    }

    public func entities(limit: Int) async throws -> [CompanionEntity] {
        try await get("entities", query: ["limit": String(limit)])
    }

    public func lenses() async throws -> [CompanionLens] {
        try await get("lenses")
    }

    public func evals(limit: Int) async throws -> [CompanionEvalRun] {
        try await get("evals", query: ["limit": String(limit)])
    }

    public func runEvals(persona: String?) async throws -> CompanionEvalOutcome {
        var query: [String: String] = [:]
        if let persona { query["persona"] = persona }
        return try await post("evals/run", body: EmptyBody(), query: query, timeout: 3600)
    }

    public func standup(text: String, verify: Bool) async throws -> CompanionStandupOutcome {
        try await post("standup", body: StandupRequest(text: text, verify: verify), timeout: 1800)
    }

    public func standupAggregate() async throws -> CompanionStandupReport {
        try await get("standup/aggregate")
    }

    public func machines() async throws -> [CompanionMachine] {
        try await get("machines")
    }

    public func addMachine(name: String, transport: String, endpoint: String) async throws
        -> [String: String]
    {
        try await post(
            "machines",
            body: MachineRequest(name: name, transport: transport, endpoint: endpoint))
    }

    public func probeMachine(name: String) async throws -> CompanionMachine {
        try await post(
            "machines/\(name)/probe", body: EmptyBody(), timeout: CompanionClient.longRequestTimeout
        )
    }

    public func machinePlan() async throws -> CompanionPlan {
        try await get("machines/plan")
    }

    public func setMachineProfile(name: String, profile: String) async throws -> [String: String] {
        try await post("machines/\(name)/profile", body: ProfileRequest(profile: profile))
    }

    public func baselines() async throws -> CompanionBaselines {
        try await get("baselines")
    }

    public func syncNotion(full: Bool) async throws -> CompanionNotionOutcome {
        try await post(
            "connectors/notion/sync", body: EmptyBody(), query: ["full": full ? "true" : "false"],
            timeout: 1800)
    }

    public func ingestImage(name: String, data: Data, mtime: String?) async throws
        -> CompanionIngestOutcome
    {
        try await post(
            "ingest/image",
            body: AudioIngestRequest(name: name, dataB64: data.base64EncodedString(), mtime: mtime),
            timeout: 900)
    }

    public func ingestVideo(name: String, data: Data, mtime: String?) async throws
        -> CompanionIngestOutcome
    {
        try await post(
            "ingest/video",
            body: AudioIngestRequest(name: name, dataB64: data.base64EncodedString(), mtime: mtime),
            timeout: 3600)
    }

    public func why(id: String) async throws -> MemoryChain {
        try await get("memory/why/\(id)")
    }

    func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var components = URLComponents(url: url(for: path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return try await request(URLRequest(url: components?.url ?? url(for: path)))
    }

    func post<Body: Encodable, T: Decodable>(
        _ path: String, body: Body, query: [String: String] = [:], timeout: TimeInterval = 30
    ) async throws -> T {
        var components = URLComponents(url: url(for: path), resolvingAgainstBaseURL: false)
        if !query.isEmpty {
            components?.queryItems = query.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components?.url ?? url(for: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        return try await self.request(request, timeout: timeout)
    }

    func get<T: Decodable>(_ path: String, allowing: Set<Int> = []) async throws -> T {
        try await request(URLRequest(url: url(for: path)), allowing: allowing)
    }

    func request<T: Decodable>(
        _ request: URLRequest, allowing: Set<Int> = [], timeout: TimeInterval = defaultTimeout
    ) async throws
        -> T
    {
        var request = request
        request.timeoutInterval = timeout
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CompanionClientError.unreachable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CompanionClientError.unreachable("the server returned no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) || allowing.contains(http.statusCode) else {
            throw CompanionClientError.badResponse(http.statusCode, responseText(data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw CompanionClientError.badResponse(http.statusCode, error.localizedDescription)
        }
    }

    func url(for path: String) -> URL {
        baseURL.appendingPathComponent("v1").appendingPathComponent(path)
    }

    private func responseText(_ data: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ServerError.self, from: data),
            !envelope.error.isEmpty
        {
            return envelope.error
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct ServerError: Decodable {
    let error: String
}

private struct IngestRequest: Encodable {
    let files: [CompanionIngestFile]
}

private struct AudioIngestRequest: Encodable {
    let name: String
    let dataB64: String
    let mtime: String?
}

private struct AskRequest: Encodable {
    let question: String
}

private struct PersonaAskRequest: Encodable {
    let question: String
    let persona: String?
}

private struct CouncilRequest: Encodable {
    let question: String
    let personas: [String]
}

private struct CoreWriteRequest: Encodable {
    let section: String
    let content: String
}

private struct OverrideRequest: Encodable {
    let real: String
}

private struct AnswerRequest: Encodable {
    let answer: String
}

private struct MuteRequest: Encodable {
    let topic: String
}

private struct StandupRequest: Encodable {
    let text: String
    let verify: Bool
}

private struct MachineRequest: Encodable {
    let name: String
    let transport: String
    let endpoint: String
}

private struct ProfileRequest: Encodable {
    let profile: String
}

private struct EmptyBody: Encodable {}

private struct ConnectorTokenRequest: Encodable {
    let github: String?
    let notion: String?
}

private struct CorrectRequest: Encodable {
    let retire: Bool
    let statement: String?
}

private struct RatingRequest: Encodable {
    let rating: Int
}

public struct MuteOutcome: Codable, Equatable, Sendable {
    public let topic: String
    public let suppressed: Int
}

public struct CodableIgnored: Codable, Equatable, Sendable {
    public init(from decoder: Decoder) throws {}
    public func encode(to encoder: Encoder) throws {}
}

public struct MemoryChainEpisode: Codable, Equatable, Sendable {
    public let episodeId: String
    public let occurredAt: String
    public let kind: String
    public let excerpt: String
}

public struct MemoryChainRevision: Codable, Equatable, Sendable {
    public let at: String
    public let posterior: Double
    public let status: String
    public let note: String
}

public struct MemoryChainVerdict: Codable, Equatable, Sendable {
    public let verdict: String
    public let note: String
    public let at: String
}

public struct MemoryChain: Codable, Equatable, Sendable {
    public let kind: String
    public let id: String
    public let statement: String
    public let status: String?
    public let confidence: Double?
    public let stability: Double?
    public let corroboration: String?
    public let promptVersion: String?
    public let mechanism: String?
    public let prior: Double?
    public let posterior: Double?
    public let alternatives: [String]?
    public let evidence: [MemoryChainEpisode]?
    public let counterEvidence: [MemoryChainEpisode]?
    public let episode: [MemoryChainEpisode]?
    public let revisions: [MemoryChainRevision]?
    public let verdicts: [MemoryChainVerdict]?
}
