import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class UsageUIClient {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    static var current: UsageUIClient?
    private let invokeOperation: Invoke
    private let invalidateClient: @MainActor () -> Void
    private(set) var stopped = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var requests: [UUID: Task<Data, Error>] = [:]
    private var polling: Task<Void, Never>?
    private var preferences: UsageUIPreferences?
    private var preparation: Task<Void, Error>?
    private(set) var prepared = false
    private var preferencesTask: Task<Void, Never>?
    private var preferencesGeneration: UUID?
    private var pendingPreferenceChanges: [String: UsageUIPreferences.Value]?
    private var observer: NSObjectProtocol?
    private(set) var presentationValues: [String: String]?
    private var usageUpdatedAt: Double?
    private var limitsUpdatedAt: Double?
    private var limitsRefreshedAt: Double?
    private(set) var latestLimits: LimitsTopicSnapshot?
    private(set) var refreshing = false
    private(set) var notice: String?
    private(set) var failure: String?

    init(invoke: @escaping Invoke, invalidate: @escaping @MainActor () -> Void = {}) {
        invokeOperation = invoke; invalidateClient = invalidate
    }

    convenience init(client: ExtensionEngineClient) {
        self.init(
            invoke: { try await client.invoke($0, payload: $1) },
            invalidate: { client.invalidate() })
    }

    func invoke(_ command: String, payload: Data = Data("{}".utf8)) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        let id = UUID()
        let operation = Task { try await invokeOperation(command, payload) }
        requests[id] = operation
        defer { requests[id] = nil }
        let data = try await withTaskCancellationHandler {
            try await operation.value
        } onCancel: {
            operation.cancel()
        }
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        return data
    }

    func value<Value: Decodable>(
        _ command: String, object: [String: String] = [:],
        as type: Value.Type = Value.self
    ) async throws -> Value {
        let decoder = JSONDecoder()
        if command == "usage.statusline.status" { decoder.dateDecodingStrategy = .iso8601 }
        return try await decoder.decode(
            type,
            from: invoke(command, payload: JSONSerialization.data(withJSONObject: object)))
    }

    func document() async throws -> DashUsage {
        try await prepare()
        let data = try await checkedPayload("usage.ui.document")
        guard UsageHistory.isValidDocument(data) else { throw ExtensionPeerError.invalidRequest }
        return try JSONDecoder().decode(DashUsage.self, from: data)
    }

    func limits(provider: LimitProvider) async throws -> UsageUILimits {
        try await JSONDecoder().decode(
            UsageUILimits.self,
            from: checkedPayload("usage.ui.limits", object: ["provider": provider.rawValue]))
    }

    private func checkedPayload(_ operation: String, object: [String: String] = [:]) async throws
        -> Data
    {
        struct Receipt: Decodable { let id: UUID; let byteCount: Int; let sha256: String }
        let receipt: Receipt = try await value(operation, object: object)
        do {
            guard (1...67_108_864).contains(receipt.byteCount), receipt.sha256.count == 64 else {
                throw ExtensionPeerError.invalidRequest
            }
            var document = Data()
            while document.count < receipt.byteCount {
                let payload = try JSONSerialization.data(withJSONObject: [
                    "id": receipt.id.uuidString, "offset": document.count,
                ])
                let chunk = try await JSONDecoder().decode(
                    UsageMachinesPeer.Chunk.self,
                    from: invoke("usage.ui.chunk", payload: payload))
                guard chunk.offset == document.count, !chunk.data.isEmpty,
                    chunk.data.count <= 262_144,
                    document.count + chunk.data.count <= receipt.byteCount,
                    chunk.finished == (document.count + chunk.data.count == receipt.byteCount)
                else { throw ExtensionPeerError.invalidRequest }
                document.append(chunk.data)
            }
            guard UsageMachinesPeer.hash(document) == receipt.sha256 else {
                throw ExtensionPeerError.invalidRequest
            }
            return document
        } catch {
            let cleanup = Task {
                _ = try? await self.value(
                    "usage.ui.release",
                    object: ["id": receipt.id.uuidString], as: [String: String].self)
            }
            await cleanup.value
            throw error
        }
    }

    func prepare() async throws {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if preparation == nil {
            preparation = Task { [self] in
                do {
                    let snapshot: UsageUIPreferences = try await value("usage.ui.preferences")
                    try Task.checkCancellation()
                    guard !stopped else { throw ExtensionPeerError.unavailable }
                    snapshot.apply(to: SharedDefaults.store, replacing: true)
                    preferences = UsageUIPreferences.read(SharedDefaults.store)
                    observer = NotificationCenter.default.addObserver(
                        forName: UserDefaults.didChangeNotification, object: nil, queue: .main
                    ) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.syncPreferences() }
                    }
                    prepared = true
                } catch {
                    preparation = nil
                    throw error
                }
            }
        }
        try await preparation?.value
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
    }

    func start() {
        guard !stopped, polling == nil else { return }
        polling = Task { [weak self] in
            guard let self else { return }
            do { try await prepare() } catch {
                if !Task.isCancelled { failure = error.localizedDescription }
            }
            while !Task.isCancelled, !stopped {
                do {
                    if !prepared { try await prepare() }
                    try await refreshState()
                } catch { if !Task.isCancelled { failure = error.localizedDescription } }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func refreshState() async throws {
        try await refreshPreferences()
        presentationValues = try await value("usage.ui.presentation", as: [String: String].self)
        let data = try await invoke("usage.status")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let nextRefreshing = object["refreshing"] as? Bool
        else { throw ExtensionPeerError.invalidRequest }
        let previous = refreshing
        refreshing = nextRefreshing
        notice = object["notice"] as? String
        failure = object["failure"] as? String
        if previous != refreshing {
            UsageEvents.post(refreshing ? UsageEvents.refreshStarted : UsageEvents.refreshFinished)
        }
        let usageDate = object["usageUpdatedAt"] as? Double
        if usageUpdatedAt != usageDate || (previous && !refreshing) {
            usageUpdatedAt = usageDate
            UsageEvents.post(UsageEvents.usageUpdated)
        }
        let limitsDate = object["limitsUpdatedAt"] as? Double
        let refreshedAt = object["limitsRefreshedAt"] as? Double
        if limitsUpdatedAt != limitsDate || limitsRefreshedAt != refreshedAt {
            let snapshot: UsageUILimitsSummary = try await value("usage.ui.limits.latest")
            latestLimits = snapshot.current
            limitsUpdatedAt = limitsDate
            limitsRefreshedAt = refreshedAt
            UsageEvents.post(UsageEvents.limitsUpdated)
        }
    }

    func refreshPreferences() async throws {
        guard prepared, preferencesTask == nil, let previous = preferences else { return }
        let snapshot: UsageUIPreferences = try await value("usage.ui.preferences")
        guard !stopped, preferencesTask == nil else { return }
        let local = UsageUIPreferences.read(SharedDefaults.store)
        if local.values.contains(where: {
            UsageUIPreferences.editableKeys.contains($0.key) && previous.values[$0.key] != $0.value
        }) {
            syncPreferences(); return
        }
        guard snapshot != previous else { return }
        preferences = snapshot
        snapshot.apply(to: SharedDefaults.store, replacing: true)
        preferences = UsageUIPreferences.read(SharedDefaults.store)
    }

    func perform(_ command: String, object: [String: Any] = [:]) {
        guard !stopped else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { tasks[id] = nil }
            do {
                _ = try await invoke(
                    command, payload: JSONSerialization.data(withJSONObject: object))
                failure = nil
            } catch { if !Task.isCancelled, !stopped { failure = error.localizedDescription } }
        }
    }

    private func syncPreferences() {
        guard !stopped, let previous = preferences else { return }
        let next = UsageUIPreferences.read(SharedDefaults.store)
        let changes = next.values.filter {
            UsageUIPreferences.editableKeys.contains($0.key) && previous.values[$0.key] != $0.value
        }
        guard !changes.isEmpty, changes != pendingPreferenceChanges else { return }
        preferencesTask?.cancel()
        pendingPreferenceChanges = changes
        let generation = UUID()
        preferencesGeneration = generation
        preferencesTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if preferencesGeneration == generation {
                    preferencesTask = nil; preferencesGeneration = nil
                    pendingPreferenceChanges = nil
                }
            }
            do {
                _ = try await invoke(
                    "usage.ui.preferences.set",
                    payload: JSONEncoder().encode(UsageUIPreferences(values: changes)))
                preferences = next
            } catch { if !Task.isCancelled, !stopped { failure = error.localizedDescription } }
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        prepared = false
        preparation?.cancel(); preparation = nil
        polling?.cancel(); polling = nil
        preferencesTask?.cancel(); preferencesTask = nil
        preferencesGeneration = nil
        pendingPreferenceChanges = nil
        for task in tasks.values { task.cancel() }
        tasks = [:]
        for request in requests.values { request.cancel() }
        requests = [:]
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        invalidateClient()
    }
}
