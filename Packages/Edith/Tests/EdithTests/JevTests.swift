import EdithKit
import Foundation
import Testing

@testable import EdithCLI

final class JevStubProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest, Data) -> (Int, Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var captured: [String: [(URLRequest, Data)]] = [:]

    static func register(_ handler: @escaping Handler) -> (client: JevClient, host: String) {
        register(host: "\(UUID().uuidString.lowercased()).jev.test", handler)
    }

    @discardableResult
    static func register(host: String, _ handler: @escaping Handler) -> (
        client: JevClient, host: String
    ) {
        lock.withLock { handlers[host] = handler }
        return (client(host: host, key: "test-key"), host)
    }

    static func client(host: String, key: String) -> JevClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JevStubProtocol.self]
        return JevClient(
            apiKey: key, baseURL: URL(string: "https://\(host)")!, retries: 1,
            session: URLSession(configuration: configuration))
    }

    static func requests(for host: String) -> [(URLRequest, Data)] {
        lock.withLock { captured[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        lock.withLock { handlers[request.url?.host() ?? ""] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) ?? Data()
        let handler = Self.lock.withLock { () -> Handler? in
            Self.captured[host, default: []].append((request, body))
            return Self.handlers[host]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (status, data) = handler(request, body)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

func jevJSON(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

func jevChoiceResponse(_ name: String, _ probabilities: [String: Double]) -> Data {
    let best = probabilities.max { $0.value < $1.value }!.key
    return jevJSON([
        "model": "jev-latest",
        "answers": [
            name: [
                "type": "choice", "choice": best, "probabilities": probabilities,
                "confidence": probabilities[best]!,
            ]
        ],
        "usage": ["input_tokens": 42, "output_tokens": 0],
    ])
}

let jevNoulResponse = jevJSON([
    "model": "jev-latest", "answers": ["ok": ["type": "noul", "noul": 0.93]],
])

final class MemoryJevKeyStore: JevKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    private var unreadable: Bool
    private let rejectsWrites: Bool
    private(set) var reads = 0

    init(_ value: String? = nil, unreadable: Bool = false, rejectsWrites: Bool = false) {
        self.value = value
        self.unreadable = unreadable
        self.rejectsWrites = rejectsWrites
    }

    var stored: String? { lock.withLock { value } }

    func read() -> JevKeyRead {
        lock.withLock {
            reads += 1
            if unreadable { return .unreadable }
            return value.map(JevKeyRead.key) ?? .missing
        }
    }

    func write(_ key: String?) -> Bool {
        lock.withLock {
            guard !rejectsWrites else { return false }
            value = key
            unreadable = false
            return true
        }
    }
}

final class JevCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

private let noulRequest = JevRequest(state: .text("x"), questions: ["ok": .noul("Is it ok?")])

@Suite struct JevModelTests {
    @Test func encodesTheDocumentedRequestShape() throws {
        let request = JevRequest(
            state: .fields(["message": "payouts failing"]),
            questions: [
                "urgent": .noul("Is `message` urgent?"),
                "team": .choice(
                    "Which team?",
                    options: [JevOption("billing", "Payments"), JevOption("tech", "Bugs")]),
                "mood": .score("How upset?", levels: ["Calm", "Upset", "Angry"]),
            ])
        let object =
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as! [String: Any]
        #expect(object["model"] as? String == "jev-latest")
        #expect((object["state"] as? [String: String])?["message"] == "payouts failing")
        let questions = object["questions"] as! [String: [String: Any]]
        #expect(questions["urgent"]?["type"] as? String == "noul")
        #expect((questions["team"]?["criteria"] as? [String: String])?["billing"] == "Payments")
        #expect(questions["mood"]?["criteria"] as? [String] == ["Calm", "Upset", "Angry"])
    }

    @Test func requestsAndRepliesSurviveTheAgentPayloadRoundTrip() throws {
        let request = JevRequest(
            state: .text("hello"),
            questions: [
                "pick": .choice(
                    "Pick", options: [JevOption("a", "first"), JevOption("b", "second")]),
                "rate": .score("Rate", levels: ["low", "high"]),
            ])
        let call = JevCall(purpose: "test", request: request)
        #expect(try AgentPayload.decode(JevCall.self, from: AgentPayload.encode(call)) == call)
        let failure = JevReply(error: .noCredits("none left"))
        #expect(
            try AgentPayload.decode(JevReply.self, from: AgentPayload.encode(failure)) == failure)
        #expect(throws: JevError.noCredits("none left")) { try failure.unwrap() }
        let decision = JevDecision(
            response: JevResponse(
                model: "jev-latest", answers: ["ok": JevAnswer(type: "noul", noul: 0.4)]),
            milliseconds: 88)
        let success = JevReply(decision: decision)
        #expect(
            try AgentPayload.decode(JevReply.self, from: AgentPayload.encode(success)).unwrap()
                == decision)
    }

    @Test func rejectsQuestionsOutsideTheModelLimits() {
        let tooMany = (0...JevQuestion.maximumOptions).map { JevOption("o\($0)", "option \($0)") }
        #expect(throws: JevError.self) {
            try JevRequest(state: .text("x"), questions: ["q": .choice("pick", options: tooMany)])
                .validated()
        }
        #expect(throws: JevError.self) {
            try JevRequest(state: .text("x"), questions: ["q": .score("rate", levels: ["only"])])
                .validated()
        }
        #expect(throws: JevError.self) {
            try JevRequest(state: .text("x"), questions: [:]).validated()
        }
    }
}

@Suite struct JevClientTests {
    @Test func sendsBearerAuthAndDecodesAnswers() async throws {
        let (client, host) = JevStubProtocol.register { _, _ in
            (200, jevChoiceResponse("team", ["billing": 0.91, "tech": 0.09]))
        }
        let decision = try await client.decide(
            JevRequest(
                state: .text("charged twice"),
                questions: [
                    "team": .choice(
                        "Which team?",
                        options: [JevOption("billing", "Payments"), JevOption("tech", "Bugs")])
                ]))
        #expect(decision.choice("team") == "billing")
        #expect(decision.answer("team")?.chosenProbability == 0.91)
        #expect(decision.response.usage?.inputTokens == 42)
        let (sent, body) = try #require(JevStubProtocol.requests(for: host).first)
        #expect(sent.url?.path() == "/v1/systemone")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        #expect(!body.isEmpty)
    }

    @Test func mapsBillingValidationAndRateLimitErrors() async {
        #expect(
            JevClient.error(
                status: 402,
                data: jevJSON(["detail": ["error_type": "billing_error", "message": "no credits"]]))
                == .noCredits("no credits"))
        #expect(JevClient.error(status: 401, data: Data()) == .unauthorized)
        #expect(
            JevClient.error(status: 422, data: jevJSON(["detail": [["msg": "bad criteria"]]]))
                == .rejected("bad criteria"))
        #expect(JevClient.error(status: 529, data: Data()) == .overloaded)
        let (client, host) = JevStubProtocol.register { _, _ in (429, Data()) }
        await #expect(throws: JevError.rateLimited(after: nil)) {
            try await client.decide(noulRequest)
        }
        #expect(JevStubProtocol.requests(for: host).count == 2)
    }

    @Test func baseURLOverrideIsForDevelopmentOnly() {
        #expect(JevClient.resolvedBaseURL(environment: [:]) == JevClient.defaultBaseURL)
        #expect(
            JevClient.resolvedBaseURL(environment: [
                JevClient.baseURLOverrideKey: "http://127.0.0.1:9"
            ])
            .absoluteString == "http://127.0.0.1:9")
    }
}

@Suite struct JevEngineTests {
    private func engine(
        store: MemoryJevKeyStore, calls: JevCallCounter = JevCallCounter(),
        status: Int = 200, body: Data = jevNoulResponse,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> JevEngine {
        let host = "\(UUID().uuidString.lowercased()).jev.test"
        _ = JevStubProtocol.register(host: host) { _, _ in
            calls.increment()
            return (status, body)
        }
        return JevEngine(
            store: store, makeClient: { JevStubProtocol.client(host: host, key: $0) }, now: clock)
    }

    @Test func withoutAKeyNothingReachesTypeSafe() async throws {
        let calls = JevCallCounter()
        let engine = engine(store: MemoryJevKeyStore(), calls: calls)
        await #expect(throws: JevError.missingKey) {
            try await engine.decide(noulRequest, purpose: "test")
        }
        let status = await engine.status(probe: true)
        #expect(status.state == .notConfigured)
        #expect(!status.isConfigured)
        #expect(calls.count == 0)
    }

    @Test func identicalRequestsAreAnsweredFromTheCache() async throws {
        let calls = JevCallCounter()
        let engine = engine(store: MemoryJevKeyStore("typesafe-test-key"), calls: calls)
        let first = try await engine.decide(noulRequest, purpose: "test")
        let second = try await engine.decide(noulRequest, purpose: "test")
        #expect(first == second)
        #expect(calls.count == 1)
        let status = await engine.status(probe: false)
        #expect(status.decisions == 1)
        #expect(status.keyHint == "ending -key")
    }

    @Test func runningOutOfCreditsPausesInsteadOfRetryingEveryCall() async throws {
        let calls = JevCallCounter()
        let engine = engine(
            store: MemoryJevKeyStore("typesafe-test-key"), calls: calls, status: 402,
            body: jevJSON(["detail": ["message": "no credits"]]))
        await #expect(throws: JevError.noCredits("no credits")) {
            try await engine.decide(noulRequest, purpose: "test")
        }
        let other = JevRequest(state: .text("y"), questions: ["ok": .noul("Still ok?")])
        await #expect(throws: JevError.noCredits("no credits")) {
            try await engine.decide(other, purpose: "test")
        }
        #expect(calls.count == 1)
        #expect(await engine.status(probe: false).state == .noCredits)
    }

    @Test func aRejectedKeyStaysOffUntilItChanges() async throws {
        let store = MemoryJevKeyStore("typesafe-test-key")
        let engine = engine(store: store, status: 401, body: Data())
        await #expect(throws: JevError.unauthorized) {
            try await engine.decide(noulRequest, purpose: "test")
        }
        #expect(await engine.status(probe: false).state == .keyRejected)
        await engine.setKey("typesafe-other-key")
        #expect(store.stored == "typesafe-other-key")
        #expect(await engine.status(probe: false).state == .ready)
    }

    @Test func clearingTheKeyTurnsJevOffAndReportsIt() async throws {
        let store = MemoryJevKeyStore("typesafe-test-key")
        let changes = JevCallCounter()
        let host = "\(UUID().uuidString.lowercased()).jev.test"
        _ = JevStubProtocol.register(host: host) { _, _ in (200, jevNoulResponse) }
        let engine = JevEngine(
            store: store, makeClient: { JevStubProtocol.client(host: host, key: $0) },
            onKeyChange: { if !$0 { changes.increment() } })
        #expect(await engine.isConfigured)
        await engine.setKey("   ")
        #expect(store.stored == nil)
        #expect(!(await engine.isConfigured))
        #expect(changes.count == 1)
        await #expect(throws: JevError.missingKey) {
            try await engine.decide(noulRequest, purpose: "test")
        }
    }

    @Test func anUnreadableKeyIsReportedAndNeverUsed() async throws {
        let calls = JevCallCounter()
        let engine = engine(store: MemoryJevKeyStore(unreadable: true), calls: calls)
        await #expect(throws: JevError.missingKey) {
            try await engine.decide(noulRequest, purpose: "test")
        }
        let status = await engine.status(probe: true)
        #expect(status.state == .keyUnreadable)
        #expect(!status.isConfigured)
        #expect(status.hasSavedKey)
        #expect(status.message == JevEngine.unreadableMessage)
        #expect(calls.count == 0)
        await engine.setKey("typesafe-test-key")
        #expect(await engine.status(probe: false).state == .ready)
    }

    @Test func aKeyTheKeychainRefusesLeavesJevOffWithAReason() async throws {
        let engine = engine(store: MemoryJevKeyStore(rejectsWrites: true))
        await engine.setKey("typesafe-test-key")
        let status = await engine.status(probe: false)
        #expect(status.state == .keyUnreadable)
        #expect(status.message == JevEngine.unsavedMessage)
        #expect(!(await engine.isConfigured))
    }

    @Test func theRateWindowCapsRunawayCallers() async throws {
        let engine = engine(store: MemoryJevKeyStore("typesafe-test-key"))
        for index in 0..<JevEngine.perMinuteLimit {
            _ = try await engine.decide(
                JevRequest(state: .text("\(index)"), questions: ["ok": .noul("ok?")]),
                purpose: "test")
        }
        await #expect(throws: JevError.self) {
            try await engine.decide(
                JevRequest(state: .text("one more"), questions: ["ok": .noul("ok?")]),
                purpose: "test")
        }
    }

    @Test func availabilityFlagFollowsTheKey() {
        let defaults = UserDefaults(suiteName: "test.jev.\(UUID().uuidString)")!
        #expect(!JevAvailability.isConfigured(defaults))
        #expect(AgentJevDecider.configured(defaults: defaults) == nil)
        JevAvailability.record(configured: true, in: defaults)
        #expect(JevAvailability.isConfigured(defaults))
        #expect(AgentJevDecider.configured(defaults: defaults) != nil)
    }
}

@Suite struct JevRouterTests {
    struct ScriptedDecider: JevDeciding {
        let answer: @Sendable (JevRequest) -> JevDecision
        func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
            answer(request)
        }
    }

    static func decision(_ name: String, _ probabilities: [String: Double]) -> JevDecision {
        let best = probabilities.max { $0.value < $1.value }!.key
        return JevDecision(
            response: JevResponse(
                model: "jev-latest",
                answers: [
                    name: JevAnswer(type: "choice", choice: best, probabilities: probabilities)
                ]),
            milliseconds: 50)
    }

    @Test func combinesAreaAndCommandProbabilities() async throws {
        let groups = [
            JevRouteGroup(
                id: "music", summary: "Playback",
                members: [
                    JevRouteCandidate(id: "music pause", summary: "Pause"),
                    JevRouteCandidate(id: "music next", summary: "Skip"),
                ]),
            JevRouteGroup(
                id: "usage", summary: "Agent usage",
                members: [
                    JevRouteCandidate(id: "usage limits", summary: "Limits"),
                    JevRouteCandidate(id: "usage summary", summary: "Cost"),
                ]),
        ]
        let decider = ScriptedDecider { request in
            if request.questions["area"] != nil {
                return Self.decision("area", ["music": 0.8, "usage": 0.2])
            }
            guard case .fields(let state) = request.state, state["area"] == "music" else {
                return Self.decision("command", ["usage limits": 0.5, "usage summary": 0.5])
            }
            return Self.decision("command", ["music pause": 0.9, "music next": 0.1])
        }
        let result = try await JevRouter(groups: groups).route(
            "stop the song", using: decider, purpose: "test")
        #expect(result.picks.first?.id == "music pause")
        #expect(abs((result.picks.first?.probability ?? 0) - 0.72) < 0.0001)
        #expect(result.picks.count == 4)
        #expect(result.milliseconds == 100)
    }
}

@Suite struct JevCommandLineTests {
    @Test func askParsesRawRequestsAndDefaultsTheModel() throws {
        let request = try JevAskCommand.parse(
            jevJSON([
                "state": ["ticket": "refund please"],
                "questions": [
                    "team": [
                        "type": "choice", "instructions": "Which team?",
                        "criteria": ["billing": "Money", "tech": "Bugs"],
                    ],
                    "urgent": ["type": "noul", "instructions": "Urgent?"],
                ],
            ]))
        #expect(request.model == JevRequest.defaultModel)
        #expect(request.questions.count == 2)
        #expect(throws: CLIFailure.self) {
            try JevAskCommand.parse(jevJSON(["state": "x", "questions": ["q": ["type": "poem"]]]))
        }
    }

    @Test func failuresPointAtTheSettingsPaneOrBilling() {
        #expect(JevCLI.failure(.missingKey).kind == .unavailable)
        #expect(JevCLI.failure(.missingKey).hint?.contains("Settings > Jev") == true)
        #expect(JevCLI.failure(.noCredits("none")).hint?.contains("billing") == true)
        #expect(JevCLI.failure(.rejected("bad")).kind == .usage)
    }

    @Test func edithFindIsListedOnlyWithAKey() {
        let without = Set(OperationMCPServer.listedTools(jevConfigured: false).map(\.name))
        let with = Set(OperationMCPServer.listedTools(jevConfigured: true).map(\.name))
        #expect(!without.contains(OperationMCPServer.findToolName))
        #expect(with.contains(OperationMCPServer.findToolName))
        #expect(with.count == without.count + 1)
    }

    @Test func findGroupsFitJevChoiceLimits() {
        let groups = OperationMCPServer.findGroups()
        #expect(groups.count <= JevQuestion.maximumOptions)
        #expect(groups.allSatisfy { $0.members.count <= JevQuestion.maximumOptions })
        #expect(groups.flatMap(\.members).count == OperationMCPCatalog.tools.count)
    }
}
