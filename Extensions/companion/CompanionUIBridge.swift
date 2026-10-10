import AppKit
import Observation
import EdithExtensionSupport
import Foundation

struct CompanionHTTPCall: Codable, Sendable {
    let path: String
    let method: String
    let query: [String: String]
    let contentType: String?
    let timeout: Double
    let body: Data
}
struct CompanionHTTPResult: Codable, Sendable {
    let status: Int
    let contentType: String
    let data: Data
}
struct CompanionJob: Codable, Sendable {
    let id: UUID
    let offset: Int
}
struct CompanionJobReply: Codable, Sendable {
    let done: Bool
    let error: String?
    let status: Int?
    let contentType: String?
    let data: Data
}
struct CompanionCaptureAction: Codable { let action: String; let note: String }
@MainActor struct CompanionCaptureState: Codable {
    let phase: CompanionCaptureModel.Phase
    let transcript: String
    let level: Double
    let duration: Double
    let remembering: Bool
    let outcome: String?
    let error: String?
    let note: String
    let noteOutcome: String?
    let savingNote: Bool
    let waiting: [CompanionOutboxItem]
    let draining: Bool
    init(_ model: CompanionCaptureModel) {
        phase = model.phase; transcript = model.transcript; level = model.level
        duration = model.duration; remembering = model.remembering; outcome = model.outcome
        error = model.error; note = model.note; noteOutcome = model.noteOutcome
        savingNote = model.savingNote; waiting = model.waiting; draining = model.draining
    }
}
struct CompanionBackendAction: Codable {
    let action: String
    let selectedHostID: UUID?
    let config: CompanionStackConfig
    let secrets: CompanionSecretValues?
    let service: String?
    let kind: CompanionSecretKind?
    let bundle: Data?
}
@MainActor struct CompanionBackendState: Codable {
    let hosts: [CompanionHost]
    let deployment: CompanionDeployment?
    let services: [CompanionServiceStatus]
    let selectedHostID: UUID?
    let config: CompanionStackConfig
    let probing: Bool
    let working: Bool
    let busy: String?
    let error: String?
    let lastLog: String
    let configStatus: String?
    let configStatusIsError: Bool
    let secretsStatus: String?
    let secretHints: [CompanionSecretKind: String]
    init(_ model: CompanionBackendModel, working: Bool = false) {
        self.working = working
        hosts = model.hosts; deployment = model.deployment; services = model.services
        selectedHostID = model.selectedHostID; config = model.config; probing = model.probing
        busy = model.busy; error = model.error; lastLog = model.lastLog
        configStatus = model.configStatus; configStatusIsError = model.configStatusIsError
        secretsStatus = model.secretsStatus; secretHints = model.secretHints
    }
}
struct CompanionChatCall: Codable, Sendable {
    let message: String
    let conversationID: String?
    let persona: String?
}
struct CompanionChatBatch: Codable, Sendable {
    let events: [CompanionChatEvent]
    let done: Bool
    let error: String?
}
struct CompanionUIBridge: Sendable {
    typealias Invoke = @MainActor @Sendable (String, Data) async throws -> Data
    let invoke: Invoke
    init(client: ExtensionEngineClient) {
        invoke = { try await client.invoke($0, payload: $1) }
    }
    init(invoke: @escaping Invoke) { self.invoke = invoke }
    @MainActor func setup(_ action: CompanionSetupAction) async throws -> CompanionSetupState {
        try JSONDecoder().decode(
            CompanionSetupState.self,
            from: await invoke("companion.ui.setup", JSONEncoder().encode(action)))
    }
    @MainActor func capture(_ action: String, note: String) async throws -> CompanionCaptureState {
        try JSONDecoder().decode(
            CompanionCaptureState.self,
            from: await invoke(
                "companion.ui.capture",
                JSONEncoder().encode(CompanionCaptureAction(action: action, note: note))))
    }
    @MainActor func backend(_ action: CompanionBackendAction) async throws -> CompanionBackendState
    {
        try JSONDecoder().decode(
            CompanionBackendState.self,
            from: await invoke("companion.ui.backend", JSONEncoder().encode(action)))
    }
    func http(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let url = request.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let marker = components.path.range(of: "/v1/")
        else { throw ExtensionPeerError.invalidRequest }
        let call = CompanionHTTPCall(
            path: String(components.path[marker.upperBound...]),
            method: request.httpMethod ?? "GET",
            query: Dictionary(
                (components.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                uniquingKeysWith: { _, last in last }),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            timeout: request.timeoutInterval, body: request.httpBody ?? Data())
        let upload = try JSONDecoder().decode(
            CompanionJob.self, from: await invoke("companion.ui.upload", Data("{}".utf8)))
        var canceled = true
        defer {
            if canceled {
                Task { _ = try? await invoke("companion.ui.cancel", JSONEncoder().encode(upload)) }
            }
        }
        let encoded = try JSONEncoder().encode(call)
        guard encoded.count <= CompanionUIEngine.maximumTransferBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        var offset = 0
        while offset < encoded.count {
            try Task.checkCancellation()
            let chunk = CompanionUploadChunk(
                id: upload.id, offset: offset,
                data: encoded.subdata(in: offset..<min(offset + 65_536, encoded.count)))
            _ = try await invoke("companion.ui.uploadChunk", JSONEncoder().encode(chunk))
            offset += chunk.data.count
        }
        _ = try await invoke("companion.ui.http", JSONEncoder().encode(upload))
        var output = Data()
        while true {
            try Task.checkCancellation()
            let value = try JSONDecoder().decode(
                CompanionJobReply.self,
                from: await invoke(
                    "companion.ui.result",
                    JSONEncoder().encode(CompanionJob(id: upload.id, offset: output.count))))
            if let error = value.error { throw CompanionClientError.unreachable(error) }
            output.append(value.data)
            guard output.count <= CompanionUIEngine.maximumTransferBytes else {
                throw ExtensionPeerError.invalidRequest
            }
            if value.done {
                guard let status = value.status,
                    let response = HTTPURLResponse(
                        url: url, statusCode: status, httpVersion: nil,
                        headerFields: [
                            "Content-Type": value.contentType ?? "application/octet-stream"
                        ])
                else { throw ExtensionPeerError.invalidRequest }
                _ = try await invoke("companion.ui.cancel", JSONEncoder().encode(upload));
                canceled = false
                return (output, response)
            }
            if value.data.isEmpty { try await Task.sleep(for: .milliseconds(150)) }
        }
    }
    func chat(message: String, conversationID: String?, persona: String?) -> AsyncThrowingStream<
        CompanionChatEvent, Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task {
                var job: CompanionJob?
                defer {
                    if let job {
                        Task {
                            _ = try? await invoke("companion.ui.cancel", JSONEncoder().encode(job))
                        }
                    }
                }
                do {
                    let call = CompanionChatCall(
                        message: message, conversationID: conversationID, persona: persona)
                    let id = try JSONDecoder().decode(
                        CompanionJob.self,
                        from: await invoke("companion.ui.chat", JSONEncoder().encode(call)))
                    job = id
                    while !Task.isCancelled {
                        let batch = try JSONDecoder().decode(
                            CompanionChatBatch.self,
                            from: await invoke("companion.ui.chatEvents", JSONEncoder().encode(id)))
                        for event in batch.events { continuation.yield(event) }
                        if let error = batch.error { throw CompanionClientError.unreachable(error) }
                        if batch.done { continuation.finish(); return }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    throw CancellationError()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
struct CompanionUploadChunk: Codable { let id: UUID; let offset: Int; let data: Data }

@MainActor final class CompanionUIEngine {
    nonisolated static let maximumTransferBytes = 67_108_864
    private let worker: CompanionWorker
    private let read: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let endpoint: @MainActor () -> URL
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var uploads: [UUID: Data] = [:]
    private var replies: [UUID: CompanionHTTPResult] = [:]
    private var errors: [UUID: String] = [:]
    private var events: [UUID: [CompanionChatEvent]] = [:]
    private var finished: Set<UUID> = []
    private var stopped = false
    private var backendTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private lazy var setupModel = CompanionSetupModel(onFinish: { _ in })
    init(
        worker: CompanionWorker,
        endpoint: @escaping @MainActor () -> URL = { CompanionClient.endpoint(override: nil) },
        read: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = {
            try await CompanionTransport.shared.data(for: $0)
        }
    ) {
        self.worker = worker; self.endpoint = endpoint; self.read = read
    }
    nonisolated static func checked(_ call: CompanionHTTPCall) throws {
        let parts = call.path.split(separator: "/", omittingEmptySubsequences: false).map(
            String.init)
        guard !parts.isEmpty,
            parts.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 256 && !$0.contains("\\")
                    && !$0.contains("%")
            }), call.query.count <= 16,
            call.query.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 16_384 }),
            (0...3600).contains(call.timeout), call.body.count <= maximumTransferBytes
        else { throw ExtensionPeerError.invalidRequest }
        let reads: Set<String> = [
            "health", "status", "episodes", "search", "runs", "claims", "beliefs", "observations",
            "facts", "personas", "core", "hypotheses", "predictions", "commitments",
            "discrepancies", "calibration", "questions", "entities", "lenses", "evals", "machines",
            "baselines", "conversations", "signals", "settings/reason", "settings/connectors",
            "standup/aggregate", "machines/plan",
        ]
        let writes: Set<String> = [
            "index", "ingest", "ingest/pdf", "ingest/audio", "claims/extract", "corroborate", "ask",
            "reflect", "reflect/weekly", "connectors/github/sync", "settings/connectors",
            "settings/reason", "settings/reason/test", "nightly/run", "core", "hypotheses/run",
            "questions/next", "questions/mute", "evals/run", "standup", "machines", "machines/sync",
            "baselines", "personas", "memory/forget", "memory/remember", "memory/recall",
            "db/reindex", "db/rebuild-derived", "db/verify", "council", "connectors/notion/sync",
            "ingest/image", "ingest/video",
        ]
        let dynamicRead =
            parts.count == 2 && ["episodes", "conversations"].contains(parts[0])
            || parts.count == 3
                && (parts[0] == "episodes" && parts[2] == "media"
                    || parts[0] == "memory" && parts[1] == "why")
        let dynamicWrite =
            parts.count == 3
            && (["questions"].contains(parts[0]) && ["answer", "skip"].contains(parts[2])
                || parts[0] == "discrepancies" && parts[2] == "override"
                || parts[0] == "turns" && parts[2] == "feedback"
                || parts[0] == "machines" && ["profile", "probe"].contains(parts[2])
                || parts[0] == "connectors"
                    && ["github", "notion", "obsidian", "files"].contains(parts[1])
                    && parts[2] == "import")
        let allowed =
            call.method == "GET" && (reads.contains(call.path) || dynamicRead)
            || call.method == "POST" && (writes.contains(call.path) || dynamicWrite)
            || call.method == "DELETE" && parts.count == 2 && parts[0] == "conversations"
        guard allowed else { throw ExtensionPeerError.invalidRequest }
    }
    func execute(_ operation: String, payload: Data) async throws -> Data {
        guard !stopped, !worker.isStopped, payload.count <= 1_048_576 else {
            throw ExtensionPeerError.invalidRequest
        }
        switch operation {
        case "companion.ui.preferences":
            return try encode(CompanionUIPreferences.snapshot())
        case "companion.ui.preference":
            let change = try JSONDecoder().decode(CompanionPreferenceChange.self, from: payload)
            try CompanionUIPreferences.apply(change)
        case "companion.ui.openMedia":
            guard ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil else {
                throw ExtensionPeerError.invalidRequest
            }
            let id = try JSONDecoder().decode(String.self, from: payload)
            guard !id.isEmpty, id.utf8.count <= 256, !id.contains("/") else {
                throw ExtensionPeerError.invalidRequest
            }
            let client = CompanionClient(baseURL: endpoint())
            let detail = try await client.episodeDetail(id: id)
            let (data, type) = try await client.media(episodeId: id)
            let url = try CompanionMedia.temporaryFile(
                title: detail.title, contentType: type, data: data)
            NSWorkspace.shared.open(url)
        case "companion.ui.upload":
            guard uploads.count + events.count < 8 else { throw ExtensionPeerError.unavailable }
            let id = UUID(); uploads[id] = Data();
            return try encode(CompanionJob(id: id, offset: 0))
        case "companion.ui.uploadChunk":
            let chunk = try JSONDecoder().decode(CompanionUploadChunk.self, from: payload)
            guard let bytes = uploads[chunk.id], bytes.count == chunk.offset,
                chunk.data.count <= 65_536,
                bytes.count + chunk.data.count <= Self.maximumTransferBytes, jobs[chunk.id] == nil
            else { throw ExtensionPeerError.invalidRequest }
            uploads[chunk.id]?.append(chunk.data)
        case "companion.ui.http":
            let job = try JSONDecoder().decode(CompanionJob.self, from: payload)
            guard let bytes = uploads[job.id], jobs[job.id] == nil, !finished.contains(job.id)
            else { throw ExtensionPeerError.invalidRequest }
            let call = try JSONDecoder().decode(CompanionHTTPCall.self, from: bytes)
            try Self.checked(call)
            var components = URLComponents(
                url: endpoint().appendingPathComponent("v1").appendingPathComponent(call.path),
                resolvingAgainstBaseURL: false)
            components?.queryItems = call.query.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = components?.url else { throw ExtensionPeerError.invalidRequest }
            var request = URLRequest(url: url); request.httpMethod = call.method;
            request.timeoutInterval = call.timeout
            request.httpBody = call.body.isEmpty ? nil : call.body
            if let type = call.contentType {
                request.setValue(type, forHTTPHeaderField: "Content-Type")
            }
            let read = read
            uploads[job.id] = Data()
            jobs[job.id] = Task { [weak self] in
                do {
                    let (data, response) = try await read(request)
                    try Task.checkCancellation()
                    guard let self, !self.stopped, let http = response as? HTTPURLResponse,
                        data.count <= Self.maximumTransferBytes
                    else { throw ExtensionPeerError.invalidRequest }
                    self.replies[job.id] = CompanionHTTPResult(
                        status: http.statusCode,
                        contentType: response.mimeType ?? "application/octet-stream", data: data)
                } catch {
                    if let self, !self.stopped, self.uploads[job.id] != nil {
                        self.errors[job.id] = error.localizedDescription
                    }
                }
                if let self, !self.stopped, self.uploads[job.id] != nil {
                    self.finished.insert(job.id); self.jobs[job.id] = nil
                }
            }
        case "companion.ui.result":
            let job = try JSONDecoder().decode(CompanionJob.self, from: payload)
            guard uploads[job.id] != nil else { throw ExtensionPeerError.invalidRequest }
            let result = replies[job.id]; let count = result?.data.count ?? 0
            guard job.offset >= 0, job.offset <= count else {
                throw ExtensionPeerError.invalidRequest
            }
            let end = min(count, job.offset + 65_536)
            return try encode(
                CompanionJobReply(
                    done: finished.contains(job.id) && end == count, error: errors[job.id],
                    status: result?.status, contentType: result?.contentType,
                    data: result?.data.subdata(in: job.offset..<end) ?? Data()))
        case "companion.ui.cancel":
            let job = try JSONDecoder().decode(CompanionJob.self, from: payload); cancel(job.id)
        case "companion.ui.chat":
            let call = try JSONDecoder().decode(CompanionChatCall.self, from: payload)
            guard call.message.utf8.count <= 131_072, uploads.count + events.count < 8 else {
                throw ExtensionPeerError.invalidRequest
            }
            let id = UUID(); events[id] = []
            let client = CompanionClient(baseURL: endpoint())
            jobs[id] = Task { [weak self] in
                do {
                    for try await event in client.chat(
                        message: call.message, conversationId: call.conversationID,
                        persona: call.persona)
                    {
                        try Task.checkCancellation()
                        guard let self, !self.stopped, let buffer = self.events[id],
                            buffer.count < 4096
                        else { throw ExtensionPeerError.unavailable }
                        self.events[id]?.append(event)
                    }
                } catch {
                    if let self, !self.stopped, self.events[id] != nil, !self.finished.contains(id)
                    {
                        self.errors[id] = error.localizedDescription
                    }
                }
                if let self, !self.stopped, self.events[id] != nil {
                    self.finished.insert(id); self.jobs[id] = nil
                }
            }
            return try encode(CompanionJob(id: id, offset: 0))
        case "companion.ui.chatEvents":
            let job = try JSONDecoder().decode(CompanionJob.self, from: payload)
            guard let buffer = events[job.id] else { throw ExtensionPeerError.invalidRequest }
            events[job.id] = Array(buffer.dropFirst(64))
            return try encode(
                CompanionChatBatch(
                    events: Array(buffer.prefix(64)),
                    done: finished.contains(job.id) && buffer.count <= 64, error: errors[job.id]))
        case "companion.ui.setup":
            let action = try JSONDecoder().decode(CompanionSetupAction.self, from: payload)
            let model = setupModel
            if action.action != "snapshot",
                ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil
            {
                throw ExtensionPeerError.invalidRequest
            }
            switch action.action {
            case "snapshot": break
            case "begin":
                model.begin(
                    home: worker.workspace.home,
                    reasonerConfigured: action.reasonerConfigured ?? false)
            case "probe", "deploy":
                guard setupTask == nil else { throw ExtensionPeerError.unavailable }
                if let id = action.selectedHostID {
                    guard model.hosts.contains(where: { $0.id == id }) else {
                        throw ExtensionPeerError.invalidRequest
                    }; model.selectedHostID = id
                }
                setupTask = Task { [weak self] in
                    defer { self?.setupTask = nil }
                    if action.action == "probe" {
                        await model.probeHosts()
                    } else {
                        await model.runDeploy()
                    }
                }
                await Task.yield()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try encode(CompanionSetupState(model))
        case "companion.ui.capture":
            let action = try JSONDecoder().decode(CompanionCaptureAction.self, from: payload)
            let model = worker.workspace.capture
            guard action.note.utf8.count <= 131_072 else { throw ExtensionPeerError.invalidRequest }
            if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil,
                !["snapshot", "discard", "deactivate"].contains(action.action)
            {
                throw ExtensionPeerError.invalidRequest
            }
            switch action.action {
            case "snapshot": break
            case "toggle": await model.toggleRecording()
            case "activate": model.setCaptureActive(true)
            case "deactivate": model.setCaptureActive(false)
            case "discard": model.discard()
            case "remember": await model.remember()
            case "drain": await model.drainOutbox()
            case "note": model.note = action.note; await model.rememberNote()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try encode(CompanionCaptureState(model))
        case "companion.ui.backend":
            let action = try JSONDecoder().decode(CompanionBackendAction.self, from: payload)
            if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] != nil,
                !["snapshot", "config", "import"].contains(action.action)
            {
                throw ExtensionPeerError.invalidRequest
            }
            let model = worker.workspace.backend
            if action.action == "snapshot" {
                if ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil {
                    model.load()
                }
            } else {
                if let id = action.selectedHostID {
                    guard model.hosts.contains(where: { $0.id == id }) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                }
                model.selectedHostID = action.selectedHostID
                if ["deploy", "config"].contains(action.action) { model.config = action.config }
            }
            let asynchronous = [
                "refresh", "probe", "services", "deploy", "destroy", "start", "stop", "restart",
                "logs",
            ]
            if asynchronous.contains(action.action) {
                guard backendTask == nil else { throw ExtensionPeerError.unavailable }
                if let service = action.service {
                    guard model.services.contains(where: { $0.service == service }) else {
                        throw ExtensionPeerError.invalidRequest
                    }
                }
                backendTask = Task { [weak self] in
                    defer { self?.backendTask = nil }
                    switch action.action {
                    case "refresh": await model.refresh()
                    case "probe": await model.probeHosts()
                    case "services": await model.refreshServices()
                    case "deploy": await model.deploy()
                    case "destroy": await model.destroy()
                    case "start": await model.start()
                    case "stop": await model.stop()
                    case "restart": await model.restart()
                    case "logs": await model.readLogs(action.service)
                    default: break
                    }
                }
                await Task.yield()
                return try encode(CompanionBackendState(model, working: backendTask != nil))
            }
            switch action.action {
            case "snapshot": break
            case "forget": model.forgetDeployment()
            case "config": model.saveConfig()
            case "secrets":
                guard let values = action.secrets else { throw ExtensionPeerError.invalidRequest };
                model.secrets = values; model.saveSecrets()
            case "clearSecret":
                guard let kind = action.kind else { throw ExtensionPeerError.invalidRequest };
                model.clearSecret(kind)
            case "import":
                guard let bundle = action.bundle, bundle.count <= 1_048_576 else {
                    throw ExtensionPeerError.invalidRequest
                }; model.importBundle(bundle)
            default: throw ExtensionPeerError.invalidRequest
            }
            return try encode(CompanionBackendState(model, working: backendTask != nil))
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }
    private func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }
    private func cancel(_ id: UUID) {
        jobs.removeValue(forKey: id)?.cancel(); uploads[id] = nil; replies[id] = nil
        errors[id] = nil; events[id] = nil; finished.remove(id)
    }
    func stopGenerations() -> Int {
        let ids = events.keys.filter { !finished.contains($0) }
        for id in ids {
            jobs.removeValue(forKey: id)?.cancel(); events[id] = []; errors[id] = nil;
            finished.insert(id)
        }
        return ids.count
    }
    func shutdown() async {
        let active = Array(jobs.values) + [backendTask, setupTask].compactMap { $0 }
        backendTask?.cancel(); setupTask?.cancel()
        stopped = true
        for id in Array(jobs.keys) + Array(uploads.keys) + Array(events.keys) { cancel(id) }
        worker.workspace.capture.setCaptureActive(false)
        for task in active { task.cancel(); await task.value }
        backendTask = nil; setupTask = nil

    }
}

struct CompanionSetupAction: Codable {
    let action: String; var selectedHostID: UUID? = nil; var reasonerConfigured: Bool? = nil
}
@MainActor struct CompanionSetupState: Codable {
    let step: CompanionSetupStep
    let hosts: [CompanionHost]
    let probing: Bool
    let selectedHostID: UUID?
    let stages: [CompanionDeployStage: CompanionStageState]
    let deploying: Bool
    let deployError: String?
    let deployed: CompanionDeployment?
    init(_ model: CompanionSetupModel) {
        step = model.step; hosts = model.hosts; probing = model.probing
        selectedHostID = model.selectedHostID; stages = model.stages; deploying = model.deploying
        deployError = model.deployError; deployed = model.deployed
    }
}

struct CompanionPreferenceChange: Codable { let key: String; let value: String }
@MainActor @Observable final class CompanionUIPreferences {
    private(set) var loaded = false
    private(set) var error: String?
    private var task: Task<Void, Never>?
    private var observation: NSObjectProtocol?
    private var previous: [String: String] = [:]
    private var applying = false
    private var stopped = false
    private let bridge: CompanionUIBridge
    static var keys: [String] {
        [
            AppStorageKeys.Companion.endpoint, AppStorageKeys.Companion.tab,
            AppStorageKeys.Companion.setupDeclined,
        ]
    }
    init(_ bridge: CompanionUIBridge) {
        self.bridge = bridge
        observation = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: SharedDefaults.store, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.changed() } }
        refresh()
    }
    func refresh() {
        guard !stopped else { return }
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let values = try JSONDecoder().decode(
                    [String: String].self,
                    from: await bridge.invoke("companion.ui.preferences", Data("{}".utf8)))
                guard !stopped, !Task.isCancelled else { return }
                applying = true; defer { applying = false }
                for (key, value) in values { try Self.apply(.init(key: key, value: value)) }
                previous = values; loaded = true; error = nil
            } catch { if !stopped, !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    private func changed() {
        guard loaded, !stopped, !applying else { return }
        let values = Self.snapshot()
        let changes = values.filter { previous[$0.key] != $0.value }
        guard !changes.isEmpty else { return }
        previous = values
        task?.cancel()
        task = Task {
            do {
                for (key, value) in changes {
                    _ = try await bridge.invoke(
                        "companion.ui.preference",
                        JSONEncoder().encode(CompanionPreferenceChange(key: key, value: value)))
                }
            } catch { if !stopped, !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
    static func snapshot() -> [String: String] {
        [
            AppStorageKeys.Companion.endpoint: SharedDefaults.store.string(
                forKey: AppStorageKeys.Companion.endpoint) ?? CompanionClient.defaultEndpointString,
            AppStorageKeys.Companion.tab: SharedDefaults.store.string(
                forKey: AppStorageKeys.Companion.tab) ?? CompanionTab.chat.rawValue,
            AppStorageKeys.Companion.setupDeclined: SharedDefaults.store.bool(
                forKey: AppStorageKeys.Companion.setupDeclined) ? "true" : "false",
        ]
    }
    static func apply(_ change: CompanionPreferenceChange) throws {
        guard keys.contains(change.key), change.value.utf8.count <= 2048 else {
            throw ExtensionPeerError.invalidRequest
        }
        if change.key == AppStorageKeys.Companion.setupDeclined {
            guard ["true", "false"].contains(change.value) else {
                throw ExtensionPeerError.invalidRequest
            }
            SharedDefaults.store.set(change.value == "true", forKey: change.key)
        } else {
            if change.key == AppStorageKeys.Companion.tab {
                guard CompanionTab(rawValue: change.value) != nil else {
                    throw ExtensionPeerError.invalidRequest
                }
            } else if !change.value.isEmpty {
                guard let url = URL(string: change.value),
                    ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil,
                    url.password == nil, url.query == nil, url.fragment == nil
                else { throw ExtensionPeerError.invalidRequest }
            }
            SharedDefaults.store.set(change.value, forKey: change.key)
            CompanionClient.invalidateEndpointCache()
        }
    }
    func shutdown() {
        stopped = true; task?.cancel(); task = nil
        if let observation { NotificationCenter.default.removeObserver(observation) };
        observation = nil
    }
}
