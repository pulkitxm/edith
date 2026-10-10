import EdithExtensionSupport
import Foundation
import Observation

private struct AgentActivityDefaults: @unchecked Sendable { let store: UserDefaults }

@MainActor @Observable
final class AgentActivityMonitor {
    static let discoveryKey = "surfaceAgentTerminalDiscovery"
    let uiClient: HerdrUIClient?
    var connectionsPresented = false
    private(set) var now = Date()
    private(set) var activity = AgentActivitySnapshot()
    private(set) var deciding: Set<UUID> = []
    private(set) var decisionErrors: [UUID: String] = [:]
    private var observers = 0
    private var surfaceUntil = Date.distantPast
    private var stopped = false
    private var started = false
    let terminals = AgentTerminalActivity()
    let hookFiles: AgentActivityHookFiles
    var hookError: String?
    private let defaults: UserDefaults
    private var serviceValue: AgentActivityService?

    init(
        defaults: UserDefaults = SharedDefaults.store, uiClient: HerdrUIClient? = nil,
        hookFiles: AgentActivityHookFiles = AgentActivityHookFiles()
    ) {
        self.defaults = defaults
        self.uiClient = uiClient
        self.hookFiles = hookFiles
    }

    var settings: AgentActivitySettings { AgentActivitySettings.load(in: defaults) }
    var discoversTerminals: Bool {
        defaults.object(forKey: Self.discoveryKey) as? Bool ?? true
    }
    var stuckMinutes: Int {
        HerdrAttentionSettings(defaults: defaults).stuckMinutes
    }
    var isListening: Bool {
        !stopped && !PresenterState.shared.hidesAgents && (observers > 0 || surfaceUntil > Date())
    }
    var service: AgentActivityService {
        precondition(uiClient == nil && Bundle.main.bundleURL.pathExtension != "appex")
        if let serviceValue { return serviceValue }
        let defaults = AgentActivityDefaults(store: self.defaults)
        let created = AgentActivityService(
            settings: { AgentActivitySettings.load(in: defaults.store) },
            listener: { await self.isListening })
        serviceValue = created
        return created
    }

    func start() async {
        guard !started, !stopped else { return }
        if uiClient != nil { await refresh(); return }
        started = true
        await service.start { [weak self] data in
            guard let value = try? AgentPayload.decode(AgentActivitySnapshot.self, from: data)
            else {
                return
            }
            await self?.receive(value)
        }
    }

    func receive(_ value: AgentActivitySnapshot) {
        guard !stopped else { return }
        now = Date()
        activity = value
        let live = Set(value.approvals.map(\.id))
        decisionErrors = decisionErrors.filter { live.contains($0.key) }
    }

    func observe() async {
        guard !stopped else { return }
        observers += 1
        await refresh()
        defer {
            observers = max(0, observers - 1)
            if uiClient == nil { HerdrWorkOwnership.start { await self.service.tick() } }
        }
        while !Task.isCancelled, !stopped {
            do { try await Task.sleep(for: .seconds(1)) } catch { break }
            now = Date()
        }
    }

    func surfaceSnapshot() async -> AgentActivitySnapshot {
        surfaceUntil = Date().addingTimeInterval(45)
        await refresh()
        return activity
    }

    func refresh() async {
        guard !stopped else { return }
        if let uiClient {
            do {
                receive(
                    try JSONDecoder().decode(
                        AgentActivitySnapshot.self, from: await uiClient.perform("activity.status"))
                )
            } catch { hookError = error.localizedDescription }
            return
        }
        await service.tick()
        receive(await service.snapshot())
    }

    func save(_ settings: AgentActivitySettings) async {
        guard !stopped else { return }
        if let uiClient {
            do {
                let data = try await uiClient.perform(
                    "herdr.ui.activity.settings",
                    payload: JSONEncoder().encode(settings.normalized()))
                if let state = try uiClient.state(data) { adoptUI(state) }
            } catch { hookError = error.localizedDescription }
            return
        }
        defaults.set(settings.normalized().encoded, forKey: AgentActivitySettings.defaultsKey)
        await refresh()
    }

    func decide(_ request: AgentApprovalRequest, choice: AgentApprovalChoice) async {
        guard !stopped, !PresenterState.shared.hidesAgents,
            activity.approvals.contains(where: { $0.id == request.id && $0.nonce == request.nonce }
            ),
            deciding.insert(request.id).inserted
        else { return }
        defer { deciding.remove(request.id) }
        if let uiClient {
            do {
                let payload = try JSONEncoder().encode(
                    AgentApprovalDecision(token: .init(request), choice: choice))
                let result = try JSONDecoder().decode(
                    Bool.self,
                    from: await uiClient.perform(AgentActivityOperation.decide, payload: payload))
                if !result {
                    decisionErrors[request.id] = "This request expired or was already answered."
                }
            } catch { decisionErrors[request.id] = error.localizedDescription }
            await refresh()
            return
        }
        if !(await service.decide(.init(token: .init(request), choice: choice))) {
            decisionErrors[request.id] = "This request expired or was already answered."
        }
        await refresh()
    }

    func adoptUI(_ state: HerdrUIState) {
        guard !stopped else { return }
        defaults.set(state.activitySettings.encoded, forKey: AgentActivitySettings.defaultsKey)
        state.attention.save(in: defaults)
        defaults.set(state.discovery, forKey: Self.discoveryKey)
        receive(state.activity)
    }

    func saveMonitoring(discovery: Bool, stuckMinutes: Int) async {
        guard !stopped else { return }
        let minutes = min(120, max(2, stuckMinutes))
        if let uiClient {
            do {
                let data = try await uiClient.perform(
                    "herdr.ui.activity.monitoring",
                    object: ["discovery": discovery, "stuckMinutes": minutes])
                if let state = try uiClient.state(data) { adoptUI(state) }
            } catch { hookError = error.localizedDescription }
            return
        }
        defaults.set(discovery, forKey: Self.discoveryKey)
        defaults.set(minutes, forKey: HerdrAttentionSettings.Keys.stuckMinutes)
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        surfaceUntil = .distantPast
        observers = 0
        await serviceValue?.stop()
        terminals.shutdown()
        activity = AgentActivitySnapshot()
        deciding = []
        decisionErrors = [:]
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopped, payload.count <= AgentActivityParser.maximumInputBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        if command != AgentActivityOperation.cancel { try Task.checkCancellation() }
        let result: Data
        if command.hasPrefix("activity.hook.") {
            guard let provider = AgentActivityProvider(rawValue: String(command.dropFirst(14)))
            else {
                throw ExtensionPeerError.invalidRequest
            }
            let choice: AgentApprovalChoice?
            if let event = try AgentActivityParser.parse(payload, provider: provider) {
                choice = await AgentActivityHookRunner { [weak self] command, input in
                    guard let self else { throw ExtensionPeerError.unavailable }
                    return try await self.execute(command, payload: input)
                }.run(event)
            } else {
                choice = nil
            }
            return try AgentActivityHookOutput.data(provider: provider, choice: choice)
        }
        let allowed: Set<String>
        switch command {
        case "activity.status": allowed = []
        case AgentActivityOperation.ingest:
            allowed = [
                "id", "provider", "sessionID", "parentSessionID", "eventName", "phase", "project",
                "model", "tool", "detail", "pane", "permissionID", "permissionInput",
                "permissionRequest", "receivedAt",
            ]
        case AgentActivityOperation.poll, AgentActivityOperation.cancel: allowed = ["id", "nonce"]
        case AgentActivityOperation.decide: allowed = ["token", "choice"]
        default: throw ExtensionPeerError.invalidRequest
        }
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: allowed)
        else { throw ExtensionPeerError.invalidRequest }
        if command == AgentActivityOperation.decide {
            guard let token = object["token"] as? [String: Any], Set(token.keys) == ["id", "nonce"]
            else { throw ExtensionPeerError.invalidRequest }
        }
        switch command {
        case "activity.status":
            guard try JSONSerialization.jsonObject(with: payload) as? [String: String] == [:] else {
                throw ExtensionPeerError.invalidRequest
            }
            await refresh()
            result = try AgentPayload.encode(activity)
        case AgentActivityOperation.ingest:
            result = try AgentPayload.encode(
                await service.ingest(
                    AgentPayload.decode(AgentActivityEvent.self, from: payload)))
        case AgentActivityOperation.poll:
            result = try AgentPayload.encode(
                await service.poll(
                    AgentPayload.decode(AgentApprovalToken.self, from: payload)))
        case AgentActivityOperation.decide:
            guard !PresenterState.shared.hidesAgents else {
                throw ExtensionPeerError.invalidRequest
            }
            result = try AgentPayload.encode(
                await service.decide(
                    AgentPayload.decode(AgentApprovalDecision.self, from: payload)))
        case AgentActivityOperation.cancel:
            await service.cancel(try AgentPayload.decode(AgentApprovalToken.self, from: payload))
            result = Data("{}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
        if command != AgentActivityOperation.cancel { try Task.checkCancellation() }
        guard result.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        return result
    }
}
