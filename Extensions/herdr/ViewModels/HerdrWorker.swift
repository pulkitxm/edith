import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
#if SWIFT_PACKAGE
import WorkerFixtureSupport
#endif

@MainActor final class HerdrWorker {
    let activity: AgentActivityMonitor
    let store: HerdrStore
    let catalogs: AgentLaunchCatalogs
    let searchDecider: @MainActor () -> JevDeciding?
    let hooks: AgentHookService
    let terminalSessions = OwnedTerminalSessionRegistry()
    let automaticActions: Bool
    let fixture: WorkerFixtureAdmission?
    var isInertFixture: Bool { fixture != nil }
    let ambientPolicy: ExtensionAmbientPolicy
    private var ambientPolicyApplied = false
    private var tracksAgents = false
    private var trackingVersion: String?
    private let trackingOwnerVersion: @MainActor () -> String?
    private let trackingDemand: @MainActor () async throws -> Bool
    private(set) var trackingDemandError: String?
    private lazy var discoveryAdmission = HerdrDiscoveryAdmission(interval: { [weak self] in
        self?.discoveryInterval
    })
    var discoveryInterval: TimeInterval? {
        guard fixture == nil, ambientPolicyApplied, !isStopped,
            ambientPolicy.subscribers(for: "sessions.discover") > 0
                || HerdrAttentionSettings(defaults: defaults).anyEnabled
                || (tracksAgents && trackingVersion == trackingOwnerVersion())
        else { return nil }
        return ambientPolicy.interval(for: "sessions.discover")
    }
    private let openGuide: @MainActor () throws -> Void
    private let activityInstaller: AgentActivityHookInstaller
    private let notifications: HerdrNotificationService
    private let defaults: UserDefaults
    private let attention: HerdrAttentionBridge
    private let inventory: HerdrInventoryCommands
    private let send: @Sendable (String, HerdrAgent) async -> HerdrPromptOutcome
    private(set) var isStopped = false
    private var started = false
    private var cliStreams: ExtensionCLIStreams?
    private var agentCLIStreams: ExtensionCLIStreams?
    private struct ShellSelection {
        let target: PaneTarget
        let holder: TerminalSessionHolder
    }
    private var shells: [UUID: ShellSelection] = [:]
    private let prepareShell:
        @MainActor (PaneTarget, HerdrStore) async throws -> TerminalLaunchRequest
    private lazy var uiHookPlans = HerdrUIHookPlans(
        files: activity.hookFiles, installer: activityInstaller)
    lazy var spaces = HerdrSpaceSessions(store: store)
    private lazy var uiEngine = HerdrUIEngine(worker: self)
    private var maintenance: Task<Void, Never>?

    private static func openOriginalGuide() throws {
        let url = URL(
            string: "https://github.com/pulkitxm/edith/blob/main/docs/cli/herdr/README.md")!
        guard NSWorkspace.shared.open(url) else {
            throw ExtensionPeerError.rejected("The Herdr setup guide could not be opened.")
        }
    }

    let hostWindowNavigation: HerdrHostWindowNavigationClient?
    let hostFolderChoice: HerdrHostFolderChoiceClient?

    init(
        hostWindowNavigation: HerdrHostWindowNavigationClient? = nil,
        hostFolderChoice: HerdrHostFolderChoiceClient? = nil,
        openGuide: @escaping @MainActor () throws -> Void = HerdrWorker.openOriginalGuide,
        store: HerdrStore? = nil, activity: AgentActivityMonitor? = nil,
        defaults: UserDefaults = SharedDefaults.store,
        notifications: HerdrNotificationService? = nil,
        ambientPolicy: ExtensionAmbientPolicy? = nil, fixture: WorkerFixtureAdmission? = nil,
        trackingDemand: @escaping @MainActor () async throws -> Bool =
            HerdrWorker.originalTrackingDemand,
        trackingOwnerVersion: @escaping @MainActor () -> String? =
            HerdrWorker.originalTrackingVersion,
        activityInstaller: AgentActivityHookInstaller? = nil,
        hooks: AgentHookService = .shared, catalogs: AgentLaunchCatalogs = AgentLaunchCatalogs(),
        searchDecider: @escaping @MainActor () -> JevDeciding? = { AgentJevDecider.configured() },
        attention: HerdrAttentionBridge? = nil,
        automaticActions: Bool = true, inventory: HerdrInventoryCommands = HerdrInventoryCommands(),
        prepareShell:
            @escaping @MainActor (PaneTarget, HerdrStore) async throws -> TerminalLaunchRequest =
            HerdrShellLaunch.prepare,
        send: @escaping @Sendable (String, HerdrAgent) async -> HerdrPromptOutcome = {
            await HerdrAgentPrompt.send($0, to: $1)
        }
    ) {
        self.hostWindowNavigation = hostWindowNavigation
        self.hostFolderChoice = hostFolderChoice
        let ownedStore = store ?? .shared
        self.defaults = defaults
        self.ambientPolicy =
            ambientPolicy
            ?? ExtensionAmbientPolicy(jobs: [
                "sessions.discover": ExtensionAmbientCadence(ambient: 30, live: 2)
            ])
        self.trackingDemand = trackingDemand
        self.trackingOwnerVersion = trackingOwnerVersion
        self.notifications =
            notifications
            ?? HerdrNotificationService(
                defaults: defaults,
                attention: .init(
                    inspect: { await HerdrPaneReader.inspect($0) },
                    decider: { await MainActor.run { AgentJevDecider.configured() } },
                    appIsRunning: { true }), currentHosts: { ownedStore.hosts },
                open: { request in
                    HerdrWorkOwnership.start {
                        await ownedStore.open(request)
                        guard !Task.isCancelled else { return }
                        ExtensionPresentation.showWindow()
                    }
                })
        self.activity = activity ?? AgentActivityMonitor(defaults: defaults)
        self.activityInstaller =
            activityInstaller
            ?? AgentActivityHookInstaller(
                executable: Bundle.main.executableURL
                    ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        self.openGuide = openGuide
        self.store = ownedStore
        self.hooks = hooks
        self.catalogs = catalogs
        self.searchDecider = searchDecider
        self.attention = attention ?? HerdrAttentionBridge()
        self.fixture = fixture
        self.automaticActions = automaticActions && fixture == nil
        self.inventory = inventory
        self.send = send
        self.prepareShell = prepareShell
        HerdrWorkOwnership.enable()
        HerdrLive.admission = discoveryAdmission
        ownedStore.ownsSpaceAgent = { [weak self] in self?.spaces.holds($0) ?? false }
        ownedStore.prepareNotificationAgent = { [weak self] id in
            guard let self else { return }
            self.spaces.removeAgent(id)
            await self.spaces.drainPendingRetirements()
        }
        spaces.retirePanes = { [weak self] panes in
            guard let self else { return [] }
            var handles: [OwnedTerminalHandle] = []
            for pane in panes {
                if let shell = self.shells.removeValue(forKey: pane) {
                    if let handle = shell.holder.descriptor?.handle { handles.append(handle) }
                    shell.holder.stop()
                }
            }
            return handles
        }
        spaces.drain = { [weak self] handles in await self?.terminalSessions.files.drain(handles) }
        terminalSessions.files.upload = { [weak self] handle, urls in
            guard let self, !self.isStopped, self.terminalSessions.find(handle) != nil else {
                throw ExtensionPeerError.unavailable
            }
            let tabs =
                self.store.sessions
                + self.store.detachedIDs.compactMap { self.store.detachedTab(id: $0) }
                + self.spaces.openedAgents.compactMap { self.spaces.agentTab($0.id) }
            if let tab = tabs.first(where: {
                $0.holder.descriptor?.handle == handle
                    || $0.quinjet.holder.descriptor?.handle == handle
            }) {
                return try await self.store.uploadDroppedFiles(urls, for: tab)
            }
            if let panel = self.store.terminalPanels.terminals.values.first(where: {
                $0.holder.descriptor?.handle == handle
            }) {
                return try await self.store.uploadDroppedFiles(urls, to: panel.host.machine)
            }
            if let shell = self.shells.values.first(where: {
                $0.holder.descriptor?.handle == handle
            }),
                let machine = MachineRegistry.machines().first(where: {
                    $0.id == shell.target.machineID
                })
            {
                return try await self.store.uploadDroppedFiles(urls, to: machine)
            }
            throw ExtensionPeerError.unavailable
        }
    }

    func applyAmbientPolicy(context: NSDictionary) throws {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        try ambientPolicy.apply(context: context)
        if automaticActions {
            try ambientPolicy.start { [weak self] in self?.discoveryAdmission.refresh() }
        }
        ambientPolicyApplied = true
        discoveryAdmission.refresh()
    }

    func refreshDiscoveryDemand() async {
        guard fixture == nil, !isStopped else { return }
        let version = trackingOwnerVersion()
        let next: Bool
        do {
            next = version == nil ? false : try await trackingDemand()
            guard !isStopped, !Task.isCancelled else { return }
            trackingDemandError = nil
        } catch {
            guard !isStopped, !Task.isCancelled else { return }
            next = false
            trackingDemandError = error.localizedDescription
        }
        guard version == trackingOwnerVersion() else {
            tracksAgents = false
            trackingVersion = nil
            discoveryAdmission.refresh()
            return
        }
        if tracksAgents != next || trackingVersion != version {
            tracksAgents = next
            trackingVersion = version
            discoveryAdmission.refresh()
        }
    }

    private static func originalTrackingVersion() -> String? {
        guard let context = SurfaceHostContext.current,
            context.activeIDs.contains("attention")
        else { return nil }
        return context.activeVersions["attention"]
    }

    private static func originalTrackingDemand() async throws -> Bool {
        await HerdrTrackingDemand.read(activeVersion: originalTrackingVersion) { command, payload in
            guard let endpoint = ExtensionPeerEndpoint.current(owner: "attention") else {
                throw ExtensionPeerError.unavailable
            }
            return try await endpoint.invoke(command, payload: payload, timeout: 5)
        }
    }

    func start() async {
        await OwnedTerminalContext.$registry.withValue(terminalSessions) { await startOwned() }
    }

    private func startOwned() async {
        guard fixture == nil, !started, !isStopped, ambientPolicyApplied else { return }
        started = true
        do { try await activity.hookFiles.resume(activityInstaller) } catch {
            activity.hookError = error.localizedDescription
        }
        guard !Task.isCancelled else { return }
        await activity.start()
        PresenterState.shared.start()
        guard automaticActions else { return }
        _ = try? await MachineRegistry.refresh()
        await refreshDiscoveryDemand()
        guard !Task.isCancelled, !isStopped else { return }
        await store.watch()
        await hooks.start { data in HerdrTopicFeed.publish(.hooks, data: data) }
        maintenance = HerdrWorkOwnership.start { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isStopped else { return }
                await self.refreshDiscoveryDemand()
                guard !Task.isCancelled, !self.isStopped else { break }
                self.discoveryAdmission.refresh()
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
        try await OwnedTerminalContext.$registry.withValue(terminalSessions) {
            try await HerdrLaunchCatalogContext.$catalog.withValue(catalogs) {
                try await executeOwned(command, payload: payload)
            }
        }
    }

    private func executeOwned(_ command: String, payload: Data) async throws -> Data {
        guard !isStopped else { throw ExtensionPeerError.unavailable }
        try Task.checkCancellation()
        if command.hasPrefix("herdr.ui.launchSettings.") {
            return try await HerdrUILaunchSettingsEngine.execute(
                command, payload: payload, worker: self)
        }
        if command.hasPrefix("herdr.ui.hook.") {
            return try await uiHookPlans.execute(command, payload: payload)
        }
        if command.hasPrefix("herdr.ui.") {
            return try await uiEngine.execute(command, payload: payload)
        }
        if command == "herdr.agent.cli" {
            return try JSONEncoder().encode(
                await HerdrAgentCLIExecution.run(
                    JSONDecoder().decode(ExtensionCLIRequest.self, from: payload), worker: self))
        }
        if command == "herdr.agent.catalog" {
            guard payload == Data("{}".utf8) else { throw ExtensionPeerError.invalidRequest }
            return try JSONSerialization.data(withJSONObject: try HerdrAgentCLIExecution.catalog())
        }
        if [
            "herdr.agent.cli.start", "herdr.agent.cli.read", "herdr.agent.cli.write",
            "herdr.agent.cli.resize", "herdr.agent.cli.cancel", "herdr.agent.cli.end",
        ].contains(command) {
            if agentCLIStreams == nil { agentCLIStreams = try ExtensionCLIStreams(owner: "herdr") }
            guard let agentCLIStreams else { throw ExtensionPeerError.unavailable }
            return try HerdrAgentCLIExecution.invokeStream(
                command, payload: payload,
                worker: self, streams: agentCLIStreams)
        }
        if command == "herdr.cli.catalog" {
            guard payload.count <= 16384,
                let value = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                value.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
            return try HerdrCLICatalog.data()
        }
        if [
            "herdr.cli.start", "herdr.cli.read", "herdr.cli.cancel", "herdr.cli.end",
            "herdr.cli.write", "herdr.cli.resize",
        ].contains(
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
            "herdr.terminal.close", "herdr.terminal.link.resolve", "herdr.terminal.link.open",
        ].contains(command) || OwnedTerminalFiles.admits(command) {
            guard payload.count <= 32768 else { throw ExtensionPeerError.invalidRequest }
            let request = try JSONDecoder().decode(OwnedTerminalRequest.self, from: payload)
            guard let session = terminalSessions.find(request.session) else {
                throw ExtensionPeerError.invalidRequest
            }
            let result = try await session.execute(command, payload: payload)
            if command == "herdr.terminal.close" {
                let ids = shells.filter { $0.value.holder.descriptor?.handle == request.session }
                    .map(\.key)
                for id in ids { shells.removeValue(forKey: id)?.holder.reset() }
                for holder in store.terminalHolders
                where holder.descriptor?.handle == request.session { holder.reset() }
            }
            return result
        }
        if command == "herdr.settings.sessions" || command == "herdr.settings.guide" {
            guard payload.count <= 4096,
                let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                object.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
            if command == "herdr.settings.sessions" {
                let result = try await inventory.checkSessions()
                guard !isStopped else { throw ExtensionPeerError.unavailable }
                return try JSONEncoder().encode(result)
            }
            try openGuide()
            return Data("{}".utf8)
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
                discoveryAdmission.refresh()
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
                !id.isEmpty, id.utf8.count <= 512
            else { throw ExtensionPeerError.invalidRequest }
            let retained = spaces.agentTab(id) ?? store.detachedTab(id: id) ?? store.session(id)
            if let descriptor = retained?.holder.descriptor,
                terminalSessions.find(descriptor.handle) != nil
            {
                return try JSONEncoder().encode(descriptor)
            }
            guard let agent = currentAgent(id) else { throw ExtensionPeerError.invalidRequest }
            if retained == nil { store.open(agent) }
            guard let tab = retained ?? store.session(id) else {
                throw ExtensionPeerError.unavailable
            }
            try await store.connectTerminal(for: tab)
            try Task.checkCancellation()
            guard !isStopped else { throw ExtensionPeerError.unavailable }
            guard let descriptor = tab.holder.descriptor else {
                throw ExtensionPeerError.unavailable
            }
            return try JSONEncoder().encode(descriptor)
        case "herdr.panel.open":
            guard Set(object.keys) == ["terminalID"], let id = object["terminalID"] as? String,
                let terminal = store.terminalPanels.terminals[id]
            else { throw ExtensionPeerError.invalidRequest }
            try await store.connectTerminal(for: terminal)
            if let pane = terminal.pane {
                terminal.scroll.startWatch(
                    session: terminal.session, pane: pane, machine: terminal.host.machine)
            }
            try Task.checkCancellation()
            guard !isStopped, let descriptor = terminal.holder.descriptor else {
                throw ExtensionPeerError.unavailable
            }
            return try JSONEncoder().encode(descriptor)
        case "herdr.diff.open":
            guard Set(object.keys) == ["agentID", "appearance", "restart"],
                let id = object["agentID"] as? String, let agent = currentAgent(id),
                let text = object["appearance"] as? String,
                let appearance = QuinjetAppearance(rawValue: text),
                let number = object["restart"] as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID()
            else { throw ExtensionPeerError.invalidRequest }
            let retained = spaces.agentTab(id) ?? store.detachedTab(id: id) ?? store.session(id)
            if retained == nil { store.open(agent) }
            guard let tab = retained ?? store.session(id) else {
                throw ExtensionPeerError.unavailable
            }
            await store.prepareDiff(
                for: tab, appearance: appearance,
                restarting: number.boolValue, launchEnabled: true)
            try Task.checkCancellation()
            guard !isStopped, let terminal = tab.quinjet.holder.descriptor else {
                throw ExtensionPeerError.unavailable
            }
            return try JSONEncoder().encode(
                HerdrDiffSessionState(
                    worktree: tab.quinjet.worktree,
                    projectName: tab.quinjet.projectName, terminal: terminal))
        case "herdr.shell.open":
            guard Set(object.keys).isSubset(of: ["paneID", "machineID", "directory"]),
                let pane = object["paneID"] as? String, let paneID = UUID(uuidString: pane),
                let machine = object["machineID"] as? String,
                let machineID = UUID(uuidString: machine),
                machineID == Machine.localID
                    || MachineRegistry.machines().contains(where: { $0.id == machineID })
            else { throw ExtensionPeerError.invalidRequest }
            var directory: String?
            if let supplied = object["directory"] {
                guard let value = supplied as? String, QuinjetPath.isAbsolute(value),
                    value.utf8.count <= 4096, !value.utf8.contains(0)
                else { throw ExtensionPeerError.invalidRequest }
                directory = value
            }
            guard shells[paneID] != nil || shells.count < 64 else {
                throw ExtensionPeerError.unavailable
            }
            let target = PaneTarget(machineID: machineID, screen: .terminal, argument: directory)
            if let existing = shells[paneID], existing.target != target {
                throw ExtensionPeerError.invalidRequest
            }
            let holder = shells[paneID]?.holder ?? TerminalSessionHolder()
            shells[paneID] = .init(target: target, holder: holder)
            if !holder.started {
                try await store.connectShell(
                    holder, paneID: paneID,
                    target: target, prepare: prepareShell)
            }
            try Task.checkCancellation()
            guard !isStopped, let descriptor = holder.descriptor else {
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
            await store.open(.init(agentID: agent.id, hostID: agent.machineID, view: chosen))
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
        if let agent = store.agents.first(where: { $0.id == id }) { return agent }
        guard
            let terminal = store.hosts.map({ HerdrMachineTerminal.agent(for: $0) }).first(where: {
                $0.id == id
            })
        else { return nil }
        return store.session(id)?.agent ?? store.detachedTab(id: id)?.agent ?? terminal
    }

    func prepareDisable() async throws {
        await shutdown()
        try await activity.hookFiles.suspend(activityInstaller)
    }

    func cancelPendingWork() async {
        hostWindowNavigation?.invalidate()
        hostFolderChoice?.invalidate()
        ambientPolicy.stop()
        await discoveryAdmission.stopAndWait()
        await terminalSessions.stopAllAndWait()
        maintenance?.cancel()
        await catalogs.shutdown()
        await cliStreams?.stopAndWait()
        await agentCLIStreams?.stopAndWait()
    }

    func shutdown() async {
        guard !isStopped else { return }
        isStopped = true
        ambientPolicy.stop()
        await discoveryAdmission.stopAndWait()
        if HerdrLive.admission === discoveryAdmission { HerdrLive.admission = nil }
        hostWindowNavigation?.invalidate()
        hostFolderChoice?.invalidate()
        await terminalSessions.stopAllAndWait()
        spaces.stopAll()
        uiHookPlans.shutdown()
        await catalogs.shutdown()
        for selection in shells.values { selection.holder.stop() }
        shells.removeAll()
        await cliStreams?.stopAndWait()
        await agentCLIStreams?.stopAndWait()
        cliStreams = nil
        agentCLIStreams = nil
        do { try await activity.hookFiles.suspend(activityInstaller) } catch {
            activity.hookError = error.localizedDescription
        }
        await activity.shutdown()
        attention.shutdown()
        notifications.shutdown()
        maintenance?.cancel()
        await hooks.stop()
        await store.shutdown()
        await AgentSearchService.shared.shutdown()
        await HerdrWorkOwnership.shutdown()
        maintenance = nil
        HerdrTopicFeed.shutdown()
        PresenterState.shared.shutdown()
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
