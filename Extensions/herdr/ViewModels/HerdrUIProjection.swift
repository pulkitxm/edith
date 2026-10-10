import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct HerdrUILayoutState: Codable, Equatable {
    var tabs: [HerdrTab]
    var selected: String
    var views: [String: HerdrAgentView]
    var arrangements: [HerdrSavedArrangement]

    func validate(allowed: Set<String>) throws {
        guard tabs.count <= 64, Set(tabs.map(\.id)).count == tabs.count,
            selected == HerdrStore.boardID || tabs.contains(where: { $0.id == selected }),
            arrangements.count <= 256, Set(arrangements.map(\.id)).count == arrangements.count
        else { throw ExtensionPeerError.invalidRequest }
        var used = Set<String>()
        for tab in tabs {
            guard UUID(uuidString: tab.id) != nil, try tab.layout.checked(depth: 0),
                tab.agentIDs.count <= 32, tab.agentIDs.contains(tab.focused),
                tab.zoomed == nil || tab.agentIDs.contains(tab.zoomed!),
                Set(tab.agentIDs).isSubset(of: allowed), used.isDisjoint(with: tab.agentIDs)
            else { throw ExtensionPeerError.invalidRequest }
            used.formUnion(tab.agentIDs)
        }
        guard Set(views.keys) == used else { throw ExtensionPeerError.invalidRequest }
        for arrangement in arrangements {
            guard !arrangement.name.isEmpty, arrangement.name.utf8.count <= 256,
                try arrangement.shape.checked(depth: 0)
            else { throw ExtensionPeerError.invalidRequest }
        }
    }
}

struct HerdrUILayoutMutation: Codable {
    let baseline: HerdrUILayoutState
    let layout: HerdrUILayoutState
}

struct HerdrUIPreferencesMutation: Codable {
    let baseline: [String: HerdrUIPreference]
    let preferences: [String: HerdrUIPreference]
}

extension HerdrLayout {
    fileprivate func checked(depth: Int) throws -> Bool {
        guard depth <= 16 else { throw ExtensionPeerError.invalidRequest }
        switch self {
        case .pane(let id): return !id.isEmpty && id.utf8.count <= 512
        case .split(let split):
            guard (2...32).contains(split.children.count),
                split.children.count == split.ratios.count,
                split.ratios.allSatisfy({ $0.isFinite && $0 > 0 && $0 < 1 }),
                abs(split.ratios.reduce(0, +) - 1) < 0.000001
            else { return false }
            for child in split.children where try !child.checked(depth: depth + 1) { return false }
            return true
        }
    }
}

struct HerdrUIState: Codable {
    let owner: String
    let generation: UUID
    let sequence: UInt64
    let hosts: [HerdrHostSnapshot]
    let openedAgents: [HerdrAgent]
    let spaces: [HerdrUISpace]
    let presentations: [HerdrUIPresentation]
    let detachedViews: [String: HerdrAgentView]
    let panels: HerdrUIPanelState
    let layout: HerdrUILayoutState
    let hooks: HerdrHooksSnapshot
    let startupMessages: [String: String]
    let preferences: [String: HerdrUIPreference]
    let activity: AgentActivitySnapshot
    let activitySettings: AgentActivitySettings
    let attention: HerdrAttentionSettings
    let discovery: Bool

    func validate() throws {
        guard owner == "herdr", sequence > 0, hosts.count <= 1025,
            Set(hosts.map(\.id)).count == hosts.count,
            hosts.reduce(0, { $0 + $1.agents.count }) <= 4096,
            startupMessages.count <= 4096,
            Set(preferences.keys).isSubset(of: HerdrUIEngine.preferenceKeys)
        else { throw ExtensionPeerError.invalidRequest }
        let agents = hosts.flatMap(\.agents)
        guard Set(agents.map(\.id)).count == agents.count else {
            throw ExtensionPeerError.invalidRequest
        }
        for (key, value) in preferences { try HerdrUIEngine.validatePreference(key, value) }
        guard spaces.count <= 64, Set(spaces.map(\.id)).count == spaces.count,
            presentations.count <= 64, Set(presentations.map(\.token)).count == presentations.count,
            presentations.allSatisfy({
                $0.owner == "herdr" && $0.version == 1
                    && ["herdr.agent", "herdr.space"].contains($0.location)
            })
        else { throw ExtensionPeerError.invalidRequest }
        for presentation in presentations { try presentation.validate() }
        let known = Set(agents.map(\.id) + openedAgents.map(\.id))
        guard
            Set(detachedViews.keys)
                == Set(presentations.filter { $0.location == "herdr.agent" }.map(\.target)),
            Set(detachedViews.keys).isSubset(
                of: known.union(hosts.map { HerdrMachineTerminal.agent(for: $0).id }))
        else { throw ExtensionPeerError.invalidRequest }
        for space in spaces {
            try space.validate()
            guard Set(space.tabs.flatMap { $0.agents.values }).isSubset(of: known) else {
                throw ExtensionPeerError.invalidRequest
            }
        }
        try panels.validate()
        try layout.validate(
            allowed: Set(
                agents.map(\.id) + openedAgents.map(\.id)
                    + hosts.map { HerdrMachineTerminal.agent(for: $0).id }))
    }
}

enum HerdrUIPreference: Codable, Equatable {
    case flag(Bool)
    case number(Double)
    case text(String)
    case strings([String])
    case numbers([String: Double])

    var value: Any {
        switch self {
        case .flag(let value): return value
        case .number(let value): return value
        case .text(let value): return value
        case .strings(let value): return value
        case .numbers(let value): return value
        }
    }

    init?(_ value: Any) {
        if let number = value as? NSNumber {
            self =
                CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .flag(number.boolValue) : .number(number.doubleValue)
        } else if let value = value as? String {
            self = .text(value)
        } else if let value = value as? [String] {
            self = .strings(value)
        } else if let value = value as? [String: NSNumber] {
            self = .numbers(value.mapValues(\.doubleValue))
        } else {
            return nil
        }
    }
}

final class HerdrUIDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func array(forKey key: String) -> [Any]? { values[key] as? [Any] }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func bool(forKey key: String) -> Bool {
        (values[key] as? NSNumber)?.boolValue ?? false
    }
    override func integer(forKey key: String) -> Int { (values[key] as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double {
        (values[key] as? NSNumber)?.doubleValue ?? 0
    }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

@MainActor final class HerdrUIClient {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private let requests: OwnedEngineRequests
    private var pending: [UUID: Task<Data, Error>] = [:]
    private var generation: UUID?
    private var sequence: UInt64 = 0
    private var stopped = false

    init(invoke: @escaping Invoke) { requests = OwnedEngineRequests(invoke: invoke) }

    convenience init(client: ExtensionEngineClient) {
        self.init { operation, payload in try await client.invoke(operation, payload: payload) }
    }

    func perform(_ operation: String, object: [String: Any] = [:]) async throws -> Data {
        guard !stopped, pending.count < 520 else { throw ExtensionPeerError.unavailable }
        let payload = try JSONSerialization.data(withJSONObject: object)
        return try await perform(operation, payload: payload)
    }

    func perform(_ operation: String, payload: Data) async throws -> Data {
        guard !stopped, pending.count < 520, payload.count <= 131072,
            operation.hasPrefix("herdr.") || operation.hasPrefix("activity.")
        else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task { try await requests.perform(operation, payload: payload) }
        pending[id] = task
        defer { pending[id] = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !stopped, !task.isCancelled else { throw CancellationError() }
        guard result.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        return result
    }

    func state(_ data: Data) throws -> HerdrUIState? {
        guard !stopped else { throw CancellationError() }
        let value = try JSONDecoder().decode(HerdrUIState.self, from: data)
        try value.validate()
        if let generation, generation != value.generation { throw ExtensionPeerError.unavailable }
        guard value.sequence > sequence else { return nil }
        generation = value.generation
        sequence = value.sequence
        return value
    }

    func stop() {
        stopped = true
        requests.stop()
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }
}

@MainActor final class HerdrUIEngine {
    nonisolated static let preferenceKeys: Set<String> = [
        AppStorageKeys.Herdr.railOpen, AppStorageKeys.Herdr.detailOpen,
        AppStorageKeys.Herdr.animatesLayout, AppStorageKeys.Herdr.railWidth,
        AppStorageKeys.Herdr.detailWidth, AppStorageKeys.Herdr.agentsCollapsed,
        AppStorageKeys.Herdr.terminalsCollapsed, AppStorageKeys.Herdr.spaceGroupingEnabled,
        AppStorageKeys.Herdr.sidebarAgentOrder, AppStorageKeys.Herdr.sidebarSpaceOrder,
        AppStorageKeys.Herdr.collapsedSpaces, AppStorageKeys.Herdr.terminalPanelHeight,
        AppStorageKeys.Herdr.terminalMouse, AppStorageKeys.Herdr.terminalFontSize,
        AppStorageKeys.Herdr.terminalStartFolder, AppStorageKeys.Herdr.terminalStartupCommand,
        AppStorageKeys.Herdr.terminalConfirmClose, AppStorageKeys.Herdr.agentsCollapsedCount,
        AppStorageKeys.Herdr.terminalsCollapsedCount, AppStorageKeys.Herdr.collapsedSpaceCounts,
        AppStorageKeys.Herdr.splitFraction,
    ]
    private unowned let worker: HerdrWorker
    private let generation = UUID()
    private var sequence: UInt64 = 0
    private var searchHits: [String: [String: AgentSearchHit]] = [:]

    init(worker: HerdrWorker) { self.worker = worker }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        guard !worker.isStopped, payload.count <= 131072,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        let store = worker.store
        switch operation {
        case "herdr.ui.folder.choose":
            guard Set(object.keys) == ["presentationID"],
                let raw = object["presentationID"] as? String,
                let presentationID = UUID(uuidString: raw), let chooser = worker.hostFolderChoice
            else { throw ExtensionPeerError.invalidRequest }
            let path = try await chooser.choose(presentationID: presentationID)
            try Task.checkCancellation()
            guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
            return try JSONSerialization.data(
                withJSONObject: path.map { ["selectedPath": $0] } ?? ["cancelled": true])
        case "herdr.ui.presentation.open":
            guard Set(object.keys) == ["presentationID", "token"],
                let origin = object["presentationID"] as? String,
                let presentationID = UUID(uuidString: origin),
                let raw = object["token"] as? String, let token = UUID(uuidString: raw),
                let retained = worker.spaces.presentations.first(where: { $0.token == token }),
                let navigation = worker.hostWindowNavigation
            else { throw ExtensionPeerError.invalidRequest }
            do {
                try await navigation.open(retained, presentationID: presentationID)
                try Task.checkCancellation()
                guard !worker.isStopped,
                    let admitted = worker.spaces.presentations.first(where: { $0.token == token }),
                    admitted.presented,
                    admitted.matches(
                        location: retained.location, target: retained.target, token: retained.token)
                else { throw ExtensionPeerError.unavailable }
                return try JSONEncoder().encode(admitted)
            } catch {
                try? await worker.spaces.closeAndWait(token)
                throw error
            }
        case "herdr.ui.presentation.view":
            guard Set(object.keys) == ["token", "view"], let raw = object["token"] as? String,
                let token = UUID(uuidString: raw), let value = object["view"] as? String,
                let view = HerdrAgentView(rawValue: value)
            else { throw ExtensionPeerError.invalidRequest }
            try worker.spaces.setAgentView(view, token: token)
        case "herdr.ui.navigate":
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            ExtensionPresentation.showWindow()
        case "herdr.ui.space.layout":
            guard Set(object.keys) == ["baseline", "space"] else {
                throw ExtensionPeerError.invalidRequest
            }
            try worker.spaces.apply(JSONDecoder().decode(HerdrUISpaceMutation.self, from: payload))
        case "herdr.ui.present":
            let presentation = try worker.spaces.present(object)
            await worker.spaces.drainPendingRetirements()
            return try JSONEncoder().encode(presentation)
        case "herdr.ui.presentation.admit", "herdr.ui.presentation.close",
            "herdr.ui.presentation.focus":
            let fields: Set<String> = operation.hasSuffix(".focus") ? ["token", "key"] : ["token"]
            guard Set(object.keys) == fields, let raw = object["token"] as? String,
                let token = UUID(uuidString: raw)
            else { throw ExtensionPeerError.invalidRequest }
            if operation.hasSuffix(".admit") {
                try worker.spaces.admit(token)
            } else if operation.hasSuffix(".close") {
                try await worker.spaces.closeAndWait(token)
            } else {
                guard let key = object["key"] as? NSNumber, CFGetTypeID(key) == CFBooleanGetTypeID()
                else { throw ExtensionPeerError.invalidRequest }
                try worker.spaces.focus(token, key: key.boolValue)
            }
        case "herdr.ui.activity.settings":
            guard Set(object.keys) == ["providers", "quietMinutes", "monitorTerminalAttention"]
            else { throw ExtensionPeerError.invalidRequest }
            let settings = try JSONDecoder().decode(AgentActivitySettings.self, from: payload)
            guard settings == settings.normalized() else { throw ExtensionPeerError.invalidRequest }
            await worker.activity.save(settings)
        case "herdr.ui.activity.monitoring":
            guard Set(object.keys) == ["discovery", "stuckMinutes"],
                let discovery = object["discovery"] as? NSNumber,
                CFGetTypeID(discovery) == CFBooleanGetTypeID(),
                let minutes = object["stuckMinutes"] as? NSNumber,
                CFGetTypeID(minutes) != CFBooleanGetTypeID(),
                minutes.doubleValue == Double(minutes.intValue),
                (2...120).contains(minutes.intValue)
            else { throw ExtensionPeerError.invalidRequest }
            await worker.activity.saveMonitoring(
                discovery: discovery.boolValue, stuckMinutes: minutes.intValue)
        case "herdr.ui.panel":
            try await HerdrUIPanelActions.execute(object, store: store)
        case "herdr.ui.read":
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            _ = await worker.activity.surfaceSnapshot()
        case "herdr.ui.refresh":
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            await store.refresh()
        case "herdr.ui.layout":
            guard Set(object.keys) == ["baseline", "layout"] else {
                throw ExtensionPeerError.invalidRequest
            }
            let mutation = try JSONDecoder().decode(HerdrUILayoutMutation.self, from: payload)
            guard mutation.baseline == store.uiLayout else {
                throw ExtensionPeerError.rejected(
                    "The layout changed in another view. Refresh and try again.")
            }
            let layout = mutation.layout
            let agents = store.agents + store.hosts.map { HerdrMachineTerminal.agent(for: $0) }
            try layout.validate(allowed: Set((agents + store.sessions.map(\.agent)).map(\.id)))
            for id in layout.views.keys { worker.spaces.removeAgent(id) }
            store.applyUILayout(layout)
        case "herdr.ui.preferences":
            guard Set(object.keys) == ["baseline", "preferences"] else {
                throw ExtensionPeerError.invalidRequest
            }
            let mutation = try JSONDecoder().decode(HerdrUIPreferencesMutation.self, from: payload)
            guard mutation.baseline == store.uiPreferences else {
                throw ExtensionPeerError.rejected(
                    "The settings changed in another view. Refresh and try again.")
            }
            let preferences = mutation.preferences
            guard Set(preferences.keys).isSubset(of: Self.preferenceKeys) else {
                throw ExtensionPeerError.invalidRequest
            }
            for (key, value) in preferences { try Self.validatePreference(key, value) }
            store.applyUIPreferences(preferences)
        case "herdr.ui.closeAgent":
            guard Set(object.keys) == ["agentID"], let id = object["agentID"] as? String,
                let agent = worker.currentAgent(id)
            else { throw ExtensionPeerError.invalidRequest }
            try await store.closeAgent(agent)
        case "herdr.ui.focusAgent":
            guard Set(object.keys) == ["agentID"], let id = object["agentID"] as? String,
                let agent = worker.currentAgent(id)
            else { throw ExtensionPeerError.invalidRequest }
            try await store.openInHerdrTerminal(agent)
        case "herdr.ui.workspaces":
            guard Set(object.keys) == ["machineID"], let id = object["machineID"] as? String,
                let host = store.hosts.first(where: { $0.id == id })
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONEncoder().encode(try await store.listWorkspaces(for: host))
        case "herdr.ui.launch":
            guard
                Set(object.keys).isSubset(of: [
                    "kind", "machineID", "workspaceID", "label", "beside",
                ]),
                let kind = object["kind"] as? String, HerdrKind.filterLabels.contains(kind),
                let id = object["machineID"] as? String,
                let host = store.hosts.first(where: {
                    $0.id == id && $0.reachable && $0.herdrPresent
                }),
                let beside = object["beside"] as? NSNumber,
                CFGetTypeID(beside) == CFBooleanGetTypeID()
            else { throw ExtensionPeerError.invalidRequest }
            var workspace: HerdrWorkspaceSummary?
            if let value = object["workspaceID"] {
                guard let id = value as? String else { throw ExtensionPeerError.invalidRequest }
                workspace = try await store.listWorkspaces(for: host).first(where: { $0.id == id })
                guard workspace != nil else { throw ExtensionPeerError.invalidRequest }
            }
            let label = object["label"] as? String
            guard
                object["label"] == nil
                    || label.map({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.utf8.contains(0) })
                        == true
            else { throw ExtensionPeerError.invalidRequest }
            try await store.launchNewAgent(
                kind: kind, host: host, existingSpace: workspace, newSpaceLabel: label,
                openBeside: beside.boolValue)
        case "herdr.ui.search":
            guard Set(object.keys) == ["query", "machineID", "agentIDs"],
                let query = object["query"] as? String, query.utf8.count <= 4096,
                let machineID = object["machineID"] as? String,
                let ids = object["agentIDs"] as? [String], ids.count <= 4096,
                Set(ids).count == ids.count
            else { throw ExtensionPeerError.invalidRequest }
            let agents = ids.compactMap(worker.currentAgent)
            guard agents.count == ids.count,
                agents.allSatisfy({ $0.machineID == machineID && !$0.isTerminal })
            else { throw ExtensionPeerError.invalidRequest }
            let reply = await AgentSearchService.shared.search(
                .init(
                    query: query, machineID: machineID,
                    targets: agents.map(AgentSearchTarget.init(agent:))))
            if searchHits[query] == nil, searchHits.count >= 16 { searchHits.removeAll() }
            var hits = searchHits[query] ?? [:]
            for hit in reply.hits where ids.contains(hit.id) { hits[hit.id] = hit }
            searchHits[query] = hits
            return try JSONEncoder().encode(reply)
        case "herdr.ui.rank":
            guard Set(object.keys) == ["query", "agentIDs"],
                let query = object["query"] as? String, query.utf8.count <= 4096,
                let ids = object["agentIDs"] as? [String],
                ids.count <= AgentSearchJev.maximumCandidates,
                Set(ids).count == ids.count
            else { throw ExtensionPeerError.invalidRequest }
            let agents = ids.compactMap(worker.currentAgent)
            guard agents.count == ids.count, agents.allSatisfy({ !$0.isTerminal }) else {
                throw ExtensionPeerError.invalidRequest
            }
            guard let decider = worker.searchDecider() else {
                return try JSONEncoder().encode(Optional<[String]>.none)
            }
            let rows = agents.map { HerdrSearchRow(agent: $0, hit: searchHits[query]?[$0.id]) }
            let picks = try await AgentSearchJev.rank(
                query, candidates: HerdrSearchPlan.jevOptions(rows), using: decider)
            try Task.checkCancellation()
            guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(picks)
        default: throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        guard !worker.isStopped else { throw ExtensionPeerError.unavailable }
        await worker.spaces.drainPendingRetirements()
        await worker.terminalSessions.files.drainRetired { worker.terminalSessions.find($0) != nil }
        return try await snapshot()
    }

    nonisolated static func validatePreference(_ key: String, _ value: HerdrUIPreference) throws {
        let flags: Set<String> = [
            AppStorageKeys.Herdr.railOpen, AppStorageKeys.Herdr.detailOpen,
            AppStorageKeys.Herdr.animatesLayout, AppStorageKeys.Herdr.agentsCollapsed,
            AppStorageKeys.Herdr.terminalsCollapsed, AppStorageKeys.Herdr.spaceGroupingEnabled,
            AppStorageKeys.Herdr.terminalConfirmClose,
        ]
        let arrays: Set<String> = [
            AppStorageKeys.Herdr.sidebarAgentOrder,
            AppStorageKeys.Herdr.sidebarSpaceOrder, AppStorageKeys.Herdr.collapsedSpaces,
        ]
        switch value {
        case .flag: guard flags.contains(key) else { throw ExtensionPeerError.invalidRequest }
        case .number(let number):
            guard number.isFinite else { throw ExtensionPeerError.invalidRequest }
            switch key {
            case AppStorageKeys.Herdr.railWidth, AppStorageKeys.Herdr.detailWidth,
                AppStorageKeys.Herdr.terminalPanelHeight:
                guard (0...2048).contains(number) else { throw ExtensionPeerError.invalidRequest }
            case AppStorageKeys.Herdr.terminalFontSize:
                guard HerdrTerminalSettings.fontSizeRange.contains(number),
                    number.rounded() == number
                else { throw ExtensionPeerError.invalidRequest }
            case AppStorageKeys.Herdr.agentsCollapsedCount,
                AppStorageKeys.Herdr.terminalsCollapsedCount:
                guard (0...4096).contains(number), number.rounded() == number
                else { throw ExtensionPeerError.invalidRequest }
            default: throw ExtensionPeerError.invalidRequest
            }
        case .text(let text):
            switch key {
            case AppStorageKeys.Herdr.terminalMouse:
                guard HerdrTerminalMouse(rawValue: text) != nil else {
                    throw ExtensionPeerError.invalidRequest
                }
            case AppStorageKeys.Herdr.terminalStartFolder:
                guard HerdrTerminalSettings.StartFolder(rawValue: text) != nil else {
                    throw ExtensionPeerError.invalidRequest
                }
            case AppStorageKeys.Herdr.terminalStartupCommand:
                guard text.utf8.count <= 4096, !text.utf8.contains(0) else {
                    throw ExtensionPeerError.invalidRequest
                }
            default: throw ExtensionPeerError.invalidRequest
            }
        case .strings(let strings):
            guard arrays.contains(key), strings.count <= 4096,
                Set(strings).count == strings.count,
                strings.allSatisfy({ $0.utf8.count <= 512 && !$0.utf8.contains(0) })
            else { throw ExtensionPeerError.invalidRequest }
        case .numbers(let values):
            guard values.count <= 4096,
                values.keys.allSatisfy({ $0.utf8.count <= 512 && !$0.utf8.contains(0) })
            else { throw ExtensionPeerError.invalidRequest }
            if key == AppStorageKeys.Herdr.splitFraction {
                guard
                    values.values.allSatisfy({
                        $0.isFinite
                            && (HerdrSplitFraction.minimum...HerdrSplitFraction.maximum).contains(
                                $0)
                    })
                else { throw ExtensionPeerError.invalidRequest }
            } else if key == AppStorageKeys.Herdr.collapsedSpaceCounts {
                guard
                    values.values.allSatisfy({
                        $0.isFinite && (0...4096).contains($0) && $0.rounded() == $0
                    })
                else { throw ExtensionPeerError.invalidRequest }
            } else {
                throw ExtensionPeerError.invalidRequest
            }
        }
    }

    private func snapshot() async throws -> Data {
        sequence += 1
        let store = worker.store
        let value = HerdrUIState(
            owner: "herdr", generation: generation, sequence: sequence,
            hosts: store.hosts,
            openedAgents: Array(
                Dictionary(
                    (store.sessions.map(\.agent)
                        + store.detachedIDs.compactMap { store.detachedTab(id: $0)?.agent }
                        + worker.spaces.openedAgents).map { ($0.id, $0) },
                    uniquingKeysWith: { first, _ in first }
                ).values),
            spaces: worker.spaces.uiSpaces, presentations: worker.spaces.presentations,
            detachedViews: Dictionary(
                uniqueKeysWithValues: store.detachedIDs.map { ($0, store.view(for: $0)) }),
            panels: store.terminalPanels.uiState, layout: store.uiLayout,
            hooks: await worker.hooks.list(), startupMessages: store.agentStartupMessages,
            preferences: store.uiPreferences, activity: worker.activity.activity,
            activitySettings: worker.activity.settings,
            attention: HerdrAttentionSettings(defaults: store.uiDefaults),
            discovery: worker.activity.discoversTerminals)
        try value.validate()
        let data = try JSONEncoder().encode(value)
        guard data.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
        return data
    }
}

@MainActor extension HerdrStore {
    convenience init(uiClient: HerdrUIClient) {
        let defaults = HerdrUIDefaults()
        let messaging = HerdrMessaging(
            broadcaster: { text, agents in
                var result: [String: HerdrPromptOutcome] = [:]
                for agent in agents {
                    do {
                        let data = try await uiClient.perform(
                            "herdr.message", object: ["agentID": agent.id, "text": text])
                        result[agent.id] = try JSONDecoder().decode(
                            HerdrPromptOutcome.self, from: data)
                    } catch { result[agent.id] = .failed(error.localizedDescription) }
                }
                return result
            },
            arm: { text, agent, schedule in
                let payload = try JSONEncoder().encode(
                    HerdrHookArmRequest(agent: agent, message: text, schedule: schedule))
                return try JSONDecoder().decode(
                    HerdrHooksSnapshot.self,
                    from: await uiClient.perform("herdr.hooks.arm", payload: payload))
            },
            remove: { id in
                return try JSONDecoder().decode(
                    HerdrHooksSnapshot.self,
                    from: await uiClient.perform(
                        "herdr.hooks.remove", object: ["id": id.uuidString]))
            })
        self.init(
            defaults: defaults, liveWatcher: { _ in },
            agentCloser: { _ in throw ExtensionPeerError.unavailable },
            newAgentPaneCreator: { _, _, _, _ in throw ExtensionPeerError.unavailable },
            agentStarter: { _, _, _ in throw ExtensionPeerError.unavailable },
            terminalIDResolver: { _, _, _ in throw ExtensionPeerError.unavailable },
            agentFocuser: { _, _, _ in throw ExtensionPeerError.unavailable },
            machinesProvider: { [] }, messaging: messaging)
        self.uiClient = uiClient
        configureRenderingOnly()
        terminalPanels.uiAction = { [weak self] operation, object in
            guard let self else { throw ExtensionPeerError.unavailable }
            var object = object
            object["operation"] = operation
            try await self.performUI("herdr.ui.panel", object: object)
        }
        terminalClient = { operation, payload in
            try await uiClient.perform(operation, payload: payload)
        }
    }
}
