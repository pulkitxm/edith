import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

@MainActor final class HerdrWorker {
    let activity: AgentActivityMonitor
    let store: HerdrStore
    let hooks: AgentHookService
    let automaticActions: Bool
    private let activityInstaller: AgentActivityHookInstaller
    private let notifications: HerdrNotificationService
    private let defaults: UserDefaults
    private let attention: HerdrAttentionBridge
    private let inventory: HerdrInventoryCommands
    private let send: @Sendable (String, HerdrAgent) async -> HerdrPromptOutcome
    private(set) var isStopped = false
    private var started = false
    private var cliStreams: ExtensionCLIStreams?
    private var maintenance: Task<Void, Never>?

    init(
        store: HerdrStore? = nil, activity: AgentActivityMonitor? = nil,
        defaults: UserDefaults = SharedDefaults.store,
        notifications: HerdrNotificationService? = nil,
        activityInstaller: AgentActivityHookInstaller? = nil,
        hooks: AgentHookService = .shared,
        attention: HerdrAttentionBridge? = nil,
        automaticActions: Bool = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            == nil, inventory: HerdrInventoryCommands = HerdrInventoryCommands(),
        send: @escaping @Sendable (String, HerdrAgent) async -> HerdrPromptOutcome = {
            await HerdrAgentPrompt.send($0, to: $1)
        }
    ) {
        let ownedStore = store ?? .shared
        self.defaults = defaults
        self.notifications =
            notifications
            ?? HerdrNotificationService(
                defaults: defaults,
                attention: .init(
                    inspect: { await HerdrPaneReader.inspect($0) },
                    decider: { await MainActor.run { AgentJevDecider.configured() } },
                    appIsRunning: { true }), currentHosts: { ownedStore.hosts })
        self.activity = activity ?? AgentActivityMonitor(defaults: defaults)
        self.activityInstaller =
            activityInstaller
            ?? AgentActivityHookInstaller(
                executable: Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        self.store = ownedStore
        self.hooks = hooks
        self.attention = attention ?? HerdrAttentionBridge()
        self.automaticActions = automaticActions
        self.inventory = inventory
        self.send = send
        HerdrWorkOwnership.enable()
    }

    func start() async {
        guard !started, !isStopped else { return }
        started = true
        do { try await activity.hookFiles.resume(activityInstaller) } catch {
            activity.hookError = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        await activity.start()
        PresenterState.shared.start()
        TextEditingCommands.install()
        HerdrOpenBridge.install()
        HerdrLayoutBridge.install()
        HerdrSpaceBridge.install()
        guard automaticActions else { return }
        _ = try? await MachineRegistry.refresh()
        await store.watch()
        await hooks.start { data in HerdrTopicFeed.publish(.hooks, data: data) }
        maintenance = HerdrWorkOwnership.start { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                await self.recordAttention()
                await self.notifications.evaluate(
                    self.store.hosts, hidden: PresenterState.shared.hidesAgents)
                await self.activity.terminals.refresh(
                    hosts: self.store.hosts,
                    enabled: self.activity.discoversTerminals
                        && self.activity.settings.monitorTerminalAttention
                        && !PresenterState.shared.hidesAgents,
                    stuckMinutes: self.activity.stuckMinutes)
                try? await Task.sleep(for: .seconds(25))
                guard !Task.isCancelled else { return }
                let before = MachineRegistry.machines()
                do { try await MachineRegistry.refresh() } catch { MachineRegistry.shutdown() }
                if before != MachineRegistry.machines() {
                    HerdrIPC.post(HerdrIPC.Name.machinesChanged)
                }
            }
        }
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        if ["herdr.cli.start", "herdr.cli.read", "herdr.cli.cancel", "herdr.cli.end"].contains(
            command)
        {
            if cliStreams == nil { cliStreams = try ExtensionCLIStreams(owner: "herdr") }
            guard let cliStreams else { throw ExtensionPeerError.unavailable }
            return try HerdrCLIExecution.invokeStream(
                command, payload: payload,
                worker: self, streams: cliStreams)
        }
        if [
            "herdr.terminal.read", "herdr.terminal.input", "herdr.terminal.resize",
            "herdr.terminal.close",
        ].contains(command) {
            guard payload.count <= 32768 else { throw ExtensionPeerError.invalidRequest }
            let request = try JSONDecoder().decode(OwnedTerminalRequest.self, from: payload)
            guard
                let holder = store.terminalHolders.first(where: {
                    $0.descriptor?.handle == request.session
                })
            else {
                throw ExtensionPeerError.invalidRequest
            }
            return try await holder.executeTerminal(command, payload: payload)
        }
        if command == "herdr.settings.read" || command == "herdr.settings.save" {
            guard payload.count <= 4096,
                let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { throw ExtensionPeerError.invalidRequest }
            if command == "herdr.settings.save" {
                guard
                    Set(object.keys) == [
                        "blocked", "finished", "errors", "stuck", "openDiff", "monitoring",
                        "stuckMinutes",
                    ],
                    ["blocked", "finished", "errors", "stuck", "openDiff", "monitoring"].allSatisfy(
                        {
                            (object[$0] as? NSNumber).map {
                                CFGetTypeID($0) == CFBooleanGetTypeID()
                            } == true
                        }), let minutes = object["stuckMinutes"] as? NSNumber,
                    CFGetTypeID(minutes) != CFBooleanGetTypeID(),
                    minutes.doubleValue == Double(minutes.intValue),
                    (2...120).contains(minutes.intValue)
                else { throw ExtensionPeerError.invalidRequest }
                let settings = try AgentPayload.decode(HerdrAttentionSettings.self, from: payload)
                settings.save(in: defaults)
                var providers = AgentActivitySettings.load(in: defaults)
                providers.monitorTerminalAttention = settings.monitoring
                defaults.set(providers.encoded, forKey: AgentActivitySettings.defaultsKey)
                notifications.reconcile(settings)
            } else if !object.isEmpty {
                throw ExtensionPeerError.invalidRequest
            }
            return try AgentPayload.encode(HerdrAttentionSettings(defaults: defaults))
        }
        if command.hasPrefix("activity.") {
            return try await activity.execute(command, payload: payload)
        }
        if command == "herdr.list" || command == "herdr.command" {
            return try await inventory.execute(command, payload: payload)
        }
        guard payload.count <= 32_768,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        switch command {
        case "herdr.refresh":
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            let snapshots = await HerdrCollector.collect(.local)
            try Task.checkCancellation()
            guard !isStopped else { throw ExtensionPeerError.unavailable }
            store.hosts = snapshots
            return try AgentPayload.encode(snapshots)
        case "herdr.terminal.status":
            guard Set(object.keys) == ["agentID"], let id = object["agentID"] as? String,
                currentAgent(id) != nil, let tab = store.session(id)
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONSerialization.data(withJSONObject: [
                "started": tab.holder.started, "nativeView": tab.holder.ghosttyView != nil,
                "exitMessage": tab.holder.exitMessage ?? "",
            ])
        case "herdr.terminal.open":
            guard Set(object.keys) == ["agentID"], let id = object["agentID"] as? String,
                let agent = currentAgent(id)
            else { throw ExtensionPeerError.invalidRequest }
            store.open(agent)
            guard let tab = store.session(id) else { throw ExtensionPeerError.unavailable }
            let request = try await store.attachRequest(
                for: tab, environment: QuinjetOperationExecution.terminalEnvironment())
            try Task.checkCancellation()
            guard !isStopped else { throw ExtensionPeerError.unavailable }
            tab.holder.start(
                executable: request.executable, arguments: request.arguments,
                environment: request.environment, allowsLocalFileLinks: agent.machineIsLocal)
            guard let descriptor = tab.holder.descriptor else {
                throw ExtensionPeerError.unavailable
            }
            return try JSONEncoder().encode(descriptor)
        case "herdr.open":
            guard Set(object.keys).isSubset(of: ["agentID", "view"]),
                let id = object["agentID"] as? String, let agent = currentAgent(id)
            else { throw ExtensionPeerError.invalidRequest }
            if let supplied = object["view"], !(supplied is String) {
                throw ExtensionPeerError.invalidRequest
            }
            let view = object["view"] as? String ?? HerdrAgentView.agent.rawValue
            guard let chosen = HerdrAgentView(rawValue: view) else {
                throw ExtensionPeerError.invalidRequest
            }
            store.open(agent, showing: chosen)
            ExtensionPresentation.showWindow()
            return Data("{\"opened\":true}".utf8)
        case "herdr.message":
            guard Set(object.keys) == ["agentID", "text"], let id = object["agentID"] as? String,
                let agent = currentAgent(id), !agent.isTerminal,
                let text = object["text"] as? String, text.utf8.count <= 16_384,
                HerdrAgentPrompt.normalized(text) != nil
            else { throw ExtensionPeerError.invalidRequest }
            return try AgentPayload.encode(await send(text, agent))
        case "herdr.hooks.list":
            guard object.isEmpty else { throw ExtensionPeerError.invalidRequest }
            return try AgentPayload.encode(await hooks.list())
        case "herdr.hooks.arm":
            guard Set(object.keys).isSubset(of: ["agent", "message", "schedule"]) else {
                throw ExtensionPeerError.invalidRequest
            }
            var request = try AgentPayload.decode(HerdrHookArmRequest.self, from: payload)
            guard let agent = currentAgent(request.agent.id),
                agent.machineID == request.agent.machineID, !agent.isTerminal,
                request.message.utf8.count <= 16_384
            else { throw ExtensionPeerError.invalidRequest }
            request.agent = agent
            return try AgentPayload.encode(await hooks.arm(request))
        case "herdr.hooks.remove":
            guard Set(object.keys) == ["id"], let value = object["id"] as? String,
                let id = UUID(uuidString: value),
                await hooks.list().hooks.contains(where: { $0.id == id })
            else { throw ExtensionPeerError.invalidRequest }
            return try AgentPayload.encode(await hooks.remove(id))
        case "herdr.layout":
            guard
                Set(object.keys) == [
                    HerdrLayoutIPC.requestKey, HerdrLayoutIPC.requestIDKey,
                    HerdrLayoutIPC.deadlineKey,
                ], let request = HerdrLayoutRuntimeRequest(payload: object), request.isLive(),
                request.deadline.timeIntervalSinceNow <= 120,
                let reply = HerdrLayoutBridge.reply(to: object, store: store)
            else { throw ExtensionPeerError.invalidRequest }
            return try JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func currentAgent(_ id: String) -> HerdrAgent? {
        guard !isStopped, !id.isEmpty, id.utf8.count <= 512 else { return nil }
        return store.agents.first { $0.id == id }
    }

    func prepareDisable() async throws {
        await shutdown()
        try await activity.hookFiles.suspend(activityInstaller)
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        await cliStreams?.stopAndWait()
        cliStreams = nil
        do { try await activity.hookFiles.suspend(activityInstaller) } catch {
            activity.hookError = error.localizedDescription
        }
        await activity.shutdown()
        attention.shutdown()
        notifications.shutdown()
        maintenance?.cancel()
        HerdrOpenBridge.shutdown()
        HerdrLayoutBridge.shutdown()
        HerdrSpaceBridge.shutdown()
        HerdrAgentWindow.shutdown()
        HerdrSpaceWindow.shutdown()
        await hooks.stop()
        await store.shutdown()
        await AgentSearchService.shared.shutdown()
        await HerdrWorkOwnership.shutdown()
        maintenance = nil
        HerdrTopicFeed.shutdown()
        PresenterState.shared.shutdown()
        TextEditingCommands.shutdown()
        MachineRegistry.shutdown()
    }

    private func recordAttention() async {
        let focused = store.focusedSession?.agent
        try? await attention.forward(
            hosts: store.hosts, focused: focused,
            view: focused.map { store.view(for: $0.id).rawValue } ?? "board",
            bundleID: ProcessInfo.processInfo.environment["EDITH_APPLICATION_IDENTIFIER"]
                ?? "com.pulkit.edith")
    }

    static func bounded(_ value: String, _ bytes: Int) -> String {
        var result = ""
        var count = 0
        for character in value where character != "\u{0}" {
            let size = String(character).utf8.count
            guard count + size <= bytes else { break }
            result.append(character)
            count += size
        }
        return result
    }
}
