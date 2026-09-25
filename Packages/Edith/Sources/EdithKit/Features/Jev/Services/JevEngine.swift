import Foundation

public protocol JevDeciding: Sendable {
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision
}

public enum JevKeyRead: Equatable, Sendable {
    case missing
    case key(String)
    case unreadable
}

public protocol JevKeyStore: Sendable {
    func read() -> JevKeyRead
    func write(_ key: String?) -> Bool
}

public struct JevStatus: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable {
        case notConfigured
        case ready
        case noCredits
        case keyRejected
        case keyUnreadable
        case paused
        case unreachable
    }

    public var state: State
    public var keyHint: String?
    public var models: [String]
    public var message: String?
    public var decisions: Int
    public var medianMilliseconds: Int?
    public var checkedAt: Date?

    public init(
        state: State, keyHint: String? = nil, models: [String] = [], message: String? = nil,
        decisions: Int = 0, medianMilliseconds: Int? = nil, checkedAt: Date? = nil
    ) {
        self.state = state
        self.keyHint = keyHint
        self.models = models
        self.message = message
        self.decisions = decisions
        self.medianMilliseconds = medianMilliseconds
        self.checkedAt = checkedAt
    }

    public var isConfigured: Bool { state != .notConfigured && state != .keyUnreadable }

    public var hasSavedKey: Bool { state != .notConfigured }

    public var summary: String {
        switch state {
        case .notConfigured: "Not configured"
        case .ready: "Ready"
        case .noCredits: "No credits"
        case .keyRejected: "Key rejected"
        case .keyUnreadable: "Key unreadable"
        case .paused: "Paused"
        case .unreachable: "Unreachable"
        }
    }
}

public actor JevEngine: JevDeciding {
    public typealias ClientFactory = @Sendable (String) -> JevClient

    public static let cacheLifetime: TimeInterval = 600
    public static let perMinuteLimit = 120
    public static let creditPause: TimeInterval = 600
    public static let latencyWindow = 50
    public static let unreadableMessage =
        "Edith can't read the saved TypeSafe key. Save it again in Settings > Jev."
    public static let unsavedMessage =
        "Edith couldn't save the key to the Keychain. Remove the Edith Jev item in Keychain Access, then save it again."

    private let store: JevKeyStore
    private let makeClient: ClientFactory
    private let now: @Sendable () -> Date
    private let onKeyChange: @Sendable (Bool) -> Void
    private var key: String?
    private var loaded = false
    private var keyProblem: String?
    private var pausedUntil: Date?
    private var pauseError: JevError?
    private var cache: [Data: (decision: JevDecision, at: Date)] = [:]
    private var latencies: [Int] = []
    private var decisions = 0
    private var windowStart = Date.distantPast
    private var windowCount = 0
    private var lastModels: [String] = []
    private var lastChecked: Date?

    public init(
        store: JevKeyStore, makeClient: @escaping ClientFactory = { JevClient(apiKey: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        onKeyChange: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.store = store
        self.makeClient = makeClient
        self.now = now
        self.onKeyChange = onKeyChange
    }

    public var isConfigured: Bool { currentKey() != nil }

    public func setKey(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed?.isEmpty == false ? trimmed : nil
        let saved = store.write(next)
        key = saved ? next : nil
        keyProblem = saved ? nil : Self.unsavedMessage
        loaded = true
        pausedUntil = nil
        pauseError = nil
        cache.removeAll()
        lastModels = []
        lastChecked = nil
        onKeyChange(key != nil)
    }

    public func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        guard let key = currentKey() else { throw JevError.missingKey }
        let moment = now()
        if let pausedUntil, moment < pausedUntil { throw pauseError ?? .paused(until: pausedUntil) }
        let fingerprint = try Self.fingerprint(request)
        if let hit = cache[fingerprint], moment.timeIntervalSince(hit.at) < Self.cacheLifetime {
            return hit.decision
        }
        if moment.timeIntervalSince(windowStart) >= 60 {
            windowStart = moment
            windowCount = 0
        }
        guard windowCount < Self.perMinuteLimit else {
            throw JevError.rateLimited(after: 60 - moment.timeIntervalSince(windowStart))
        }
        windowCount += 1
        do {
            let decision = try await makeClient(key).decide(request)
            record(decision, fingerprint: fingerprint)
            return decision
        } catch let error as JevError {
            pause(for: error)
            throw error
        }
    }

    public func status(probe: Bool) async -> JevStatus {
        guard let key = currentKey() else {
            guard let keyProblem else { return JevStatus(state: .notConfigured) }
            return JevStatus(state: .keyUnreadable, message: keyProblem)
        }
        let hint = Self.hint(key)
        if probe {
            let client = makeClient(key)
            do {
                lastModels = try await client.models().map(\.name)
                _ = try await client.decide(Self.probeRequest)
                pausedUntil = nil
                pauseError = nil
            } catch let error as JevError {
                pause(for: error)
            } catch {
                pauseError = .unavailable(error.localizedDescription)
            }
            lastChecked = now()
        }
        let state: JevStatus.State
        switch pauseError {
        case .none: state = .ready
        case .noCredits: state = .noCredits
        case .unauthorized: state = .keyRejected
        case .unavailable: state = .unreachable
        default: state = .paused
        }
        return JevStatus(
            state: state, keyHint: hint, models: lastModels,
            message: pauseError?.localizedDescription, decisions: decisions,
            medianMilliseconds: median(), checkedAt: lastChecked)
    }

    static let probeRequest = JevRequest(
        state: .text("Edith is checking that this key can make decisions."),
        questions: ["ok": .noul("The text says a key is being checked.")])

    public static func hint(_ key: String) -> String {
        key.count >= 4 ? "ending \(key.suffix(4))" : "set"
    }

    static func fingerprint(_ request: JevRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    private func currentKey() -> String? {
        if !loaded {
            switch store.read() {
            case .key(let value):
                key = value
                keyProblem = nil
            case .missing:
                key = nil
                keyProblem = nil
            case .unreadable:
                key = nil
                keyProblem = Self.unreadableMessage
            }
            loaded = true
            onKeyChange(key != nil)
        }
        return key
    }

    private func record(_ decision: JevDecision, fingerprint: Data) {
        decisions += 1
        latencies.append(decision.milliseconds)
        if latencies.count > Self.latencyWindow {
            latencies.removeFirst(latencies.count - Self.latencyWindow)
        }
        let moment = now()
        cache = cache.filter { moment.timeIntervalSince($0.value.at) < Self.cacheLifetime }
        cache[fingerprint] = (decision, moment)
        pausedUntil = nil
        pauseError = nil
    }

    private func pause(for error: JevError) {
        switch error {
        case .noCredits:
            pausedUntil = now().addingTimeInterval(Self.creditPause)
            pauseError = error
        case .unauthorized:
            pausedUntil = .distantFuture
            pauseError = error
        case .unavailable:
            pauseError = error
        default:
            break
        }
    }

    private func median() -> Int? {
        guard !latencies.isEmpty else { return nil }
        return latencies.sorted()[latencies.count / 2]
    }
}
