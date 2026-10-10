import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import GhosttyTerminal

@MainActor
@Observable
final class QuinjetTab: Identifiable {
    let id: UUID
    init(id: UUID = UUID()) { self.id = id }
    let holder = TerminalSessionHolder()
    var projectName: String?
    var worktree: QuinjetWorktree?
    var remote: QuinjetRemote?
    var worktrees: [QuinjetWorktree] = []
    var showsWorktrees = false
    let worktreeLoad = ContentLoad()
    var loadingWorktrees: Bool { worktreeLoad.isRunning }
    var errorMessage: String?
    var machineID = QuinjetMachines.localMachineID
    var folderPicker: QuinjetFolderPickerModel?
    var launchConfiguration = QuinjetLaunchConfiguration.default
    var externalLaunchMessage: String?
    var externalWorkspaceID: String?
    var externalLaunchGeneration = 0

    var title: String {
        guard let projectName else { return "New review" }
        guard let branch = worktree?.branch, !branch.isEmpty else { return projectName }
        return "\(projectName) · \(branch)"
    }
}

@MainActor
@Observable
final class QuinjetPageModel {
    typealias ExternalWorkspaceAction = @Sendable (String) async throws -> Void

    private let client: QuinjetClient
    let machines: QuinjetMachines
    var terminalUI: OwnedTerminalUIPresentation?
    private var uiClient: QuinjetUIClient?
    private var uiActions: [UUID: Task<Void, Never>] = [:]
    private var projectedPrivacy = false
    private(set) var cmuxAvailable = false
    var isRemote: Bool { uiClient != nil }
    var hidesReview: Bool { isRemote ? projectedPrivacy : QuinjetPrivacy.shared.hidesReview }
    let usage: LauncherUsage
    private let focusExternalWorkspace: ExternalWorkspaceAction
    private let closeExternalWorkspace: ExternalWorkspaceAction

    private(set) var tabs: [QuinjetTab]
    private(set) var selected: UUID
    private(set) var projects: [QuinjetProject] = []
    private(set) var themes = QuinjetTheme.allCases
    let projectLoad = ContentLoad()
    var loadingProjects: Bool { projectLoad.isRunning }
    var projectError: String?
    var query = ""
    private var remoteProjects: [UUID: [QuinjetProject]] = [:]
    private var remoteProjectLoads: [UUID: ContentLoad] = [:]
    private var remoteProjectErrors: [UUID: String] = [:]
    private var sessionLaunchEnabled = false
    private(set) var stopped = false

    init(
        client: QuinjetClient = .live,
        usage: LauncherUsage? = nil,
        focusExternalWorkspace: @escaping ExternalWorkspaceAction = {
            try await QuinjetCMUXLauncher.focus(workspaceID: $0)
        },
        closeExternalWorkspace: @escaping ExternalWorkspaceAction = {
            try await QuinjetCMUXLauncher.close(workspaceID: $0)
        }
    ) {
        self.client = client
        machines = .shared
        self.usage = usage ?? .shared
        self.focusExternalWorkspace = focusExternalWorkspace
        self.closeExternalWorkspace = closeExternalWorkspace
        let tab = QuinjetTab()
        tabs = [tab]
        selected = tab.id
    }

    init(uiClient: QuinjetUIClient) {
        self.uiClient = uiClient
        client = .init(execute: { _ in throw ExtensionPeerError.unavailable })
        usage = LauncherUsage(defaults: nil)
        machines = QuinjetMachines(renderingOnly: true)
        focusExternalWorkspace = { _ in throw ExtensionPeerError.unavailable }
        closeExternalWorkspace = { _ in throw ExtensionPeerError.unavailable }
        let tab = QuinjetTab()
        tabs = [tab]
        selected = tab.id
    }

    var uiRemoteProjects: [QuinjetUIState.RemoteProjects] {
        remoteProjects.map {
            .init(
                machineID: $0.key, projects: $0.value,
                error: remoteProjectErrors[$0.key])
        }
    }

    func terminalAvailable(_ terminal: QuinjetTerminal) -> Bool {
        if isRemote { return terminal == .embedded || cmuxAvailable }
        return terminal.isAvailable
    }

    func refreshUI() async {
        guard let uiClient, !stopped else { return }
        do {
            if let state = try await uiClient.state("quinjet.ui.read") { try adoptUI(state) }
        } catch is CancellationError {} catch { projectError = error.localizedDescription }
    }

    func selectMachine(_ machine: Machine, in tab: QuinjetTab) {
        guard isRemote else { return }
        enqueueUI(
            "quinjet.ui.machine",
            object: [
                "tabID": tab.id.uuidString,
                "machineID": machine.id.uuidString,
            ])
    }

    func makeFolderPicker(for tab: QuinjetTab) -> QuinjetFolderPickerModel {
        if let uiClient {
            return .init(
                resolveHome: {
                    let data = try await uiClient.request(
                        "quinjet.ui.folder.home",
                        object: ["tabID": tab.id.uuidString])
                    guard data.count <= 8192 else { throw ExtensionPeerError.invalidRequest }
                    let path = try JSONDecoder().decode(String.self, from: data)
                    guard QuinjetPath.isAbsolute(path), path.utf8.count <= 4096,
                        !path.utf8.contains(0)
                    else { throw ExtensionPeerError.invalidRequest }
                    return path
                },
                listDirectory: { path in
                    let data = try await uiClient.request(
                        "quinjet.ui.folder.list",
                        object: ["tabID": tab.id.uuidString, "path": path])
                    guard data.count <= 1_048_576 else { throw ExtensionPeerError.invalidRequest }
                    let entries = try JSONDecoder().decode([RemoteFileEntry].self, from: data)
                    guard entries.count <= 10000,
                        entries.allSatisfy({
                            $0.path.utf8.count <= 4096 && $0.name.utf8.count <= 1024
                        })
                    else { throw ExtensionPeerError.invalidRequest }
                    return entries
                })
        }
        return .init(session: machines.session(for: tab.machineID))
    }

    private func adoptUI(_ state: QuinjetUIState) throws {
        guard !stopped, let uiClient else { throw ExtensionPeerError.unavailable }
        try state.validate()
        let existing = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        let retained = Set(state.tabs.map(\.id))
        for tab in tabs where !retained.contains(tab.id) { tab.holder.stopRendering() }
        tabs = try state.tabs.map { projection in
            let tab = existing[projection.id] ?? QuinjetTab(id: projection.id)
            tab.projectName = projection.projectName
            tab.worktree = projection.worktree
            tab.worktrees = projection.worktrees
            tab.remote = projection.remote?.renderingValue
            if tab.machineID != projection.machineID { tab.folderPicker = nil }
            tab.machineID = projection.machineID
            tab.errorMessage = projection.errorMessage
            tab.launchConfiguration = projection.configuration
            tab.externalLaunchMessage = projection.externalLaunchMessage
            if let terminal = projection.terminal {
                if tab.holder.descriptor != terminal {
                    tab.holder.reset()
                    tab.holder.bind(try uiClient.terminal(terminal))
                }
            } else if tab.holder.descriptor != nil {
                tab.holder.reset()
            }
            if tab.remote != nil, tab.folderPicker == nil {
                tab.folderPicker = makeFolderPicker(for: tab)
            }
            return tab
        }
        selected = state.selected
        projects = state.projects
        remoteProjects = Dictionary(
            uniqueKeysWithValues:
                state.remoteProjects.map { ($0.machineID, $0.projects) })
        remoteProjectErrors = Dictionary(
            uniqueKeysWithValues:
                state.remoteProjects.compactMap { value in value.error.map { (value.machineID, $0) }
                })
        themes = state.themes.compactMap(QuinjetTheme.init(rawValue:))
        usage.adopt(state.usage)
        machines.adopt(state.machines, states: state.machineStates)
        projectedPrivacy = state.hidesReview
        cmuxAvailable = state.cmuxAvailable
        projectError = state.projectError
        terminalUI?.refresh()
    }

    func terminalUIAction(_ action: OwnedTerminalUIEvent.Action) -> Bool {
        guard !stopped, isRemote else { return false }
        switch action {
        case .newTab: enqueueUI("quinjet.ui.session", object: ["operation": "create"])
        case .closeTab:
            guard let selectedTab else { return false }
            enqueueUI(
                "quinjet.ui.session",
                object: ["operation": "close", "session": selectedTab.id.uuidString])
        case .nextTab, .previousTab:
            guard !tabs.isEmpty, let index = tabs.firstIndex(where: { $0.id == selected }) else {
                return false
            }
            let delta = action == .previousTab ? tabs.count - 1 : 1
            return selectSession(tabs[(index + delta) % tabs.count].id)
        default: return false
        }
        return true
    }

    func terminalPaneAction(_ action: GhosttyPaneAction) {
        switch action {
        case .newTab: _ = terminalUIAction(.newTab)
        case .selectTab(let index):
            if index == -1 {
                _ = terminalUIAction(.previousTab)
            } else if index == -2 {
                _ = terminalUIAction(.nextTab)
            } else if index == -3, let last = tabs.last {
                _ = selectSession(last.id)
            } else if index > 0, Int(index) <= tabs.count {
                _ = selectSession(tabs[Int(index) - 1].id)
            }
        default: break
        }
        terminalUI?.refresh()
    }

    private func enqueueUI(_ operation: String, object: [String: Any]) {
        guard !stopped, uiActions.count < 8 else { return }
        let id = UUID()
        uiActions[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.uiActions[id] = nil }
            await self.performUI(operation, object: object)
        }
    }

    private func performUI(_ operation: String, object: [String: Any]) async {
        guard !stopped, let uiClient else { return }
        do {
            if let state = try await uiClient.state(operation, object: object) {
                try adoptUI(state)
            }
        } catch is CancellationError {} catch { projectError = error.localizedDescription }
    }

    private func configurationObject(_ configuration: QuinjetLaunchConfiguration) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)))
            as? [String: Any] ?? [:]
    }

    var selectedTab: QuinjetTab? {
        tabs.first { $0.id == selected }
    }

    @discardableResult
    func selectSession(_ id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        if isRemote {
            enqueueUI(
                "quinjet.ui.session", object: ["operation": "focus", "session": id.uuidString])
            return true
        }
        selected = id
        return true
    }

    var filteredProjects: [QuinjetProject] {
        filtered(recentProjects(projects, machineID: "local"))
    }

    func projects(for remote: QuinjetRemote) -> [QuinjetProject] {
        remoteProjects[remote.machineID] ?? []
    }

    func filteredProjects(for remote: QuinjetRemote) -> [QuinjetProject] {
        filtered(recentProjects(projects(for: remote), machineID: remote.machineID.uuidString))
    }

    func isLoadingProjects(for remote: QuinjetRemote) -> Bool {
        remoteProjectLoads[remote.machineID]?.isRunning == true
    }

    func projectError(for remote: QuinjetRemote) -> String? {
        remoteProjectErrors[remote.machineID]
    }

    private func filtered(_ projects: [QuinjetProject]) -> [QuinjetProject] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return projects }
        return projects.filter { project in
            project.name.localizedCaseInsensitiveContains(search)
                || project.availableWorktrees.contains {
                    $0.path.localizedCaseInsensitiveContains(search)
                        || $0.displayName.localizedCaseInsensitiveContains(search)
                }
        }
    }

    private func recentProjects(_ projects: [QuinjetProject], machineID: String) -> [QuinjetProject]
    {
        usage.history.projects(projects, machineID: machineID)
    }

    func recentWorktrees(for tab: QuinjetTab) -> [QuinjetWorktree] {
        let machineID = tab.remote?.machineID.uuidString ?? "local"
        return usage.ordered(tab.worktrees) { ["worktree", machineID, $0.path] }
    }

    private func recordUse(of tab: QuinjetTab) {
        guard let worktree = tab.worktree else { return }
        let machineID = tab.remote?.machineID.uuidString ?? "local"
        usage.record([["machine", machineID], ["worktree", machineID, worktree.path]])
    }

    func refreshProjects() async {
        if isRemote { await performUI("quinjet.ui.projects", object: [:]); return }
        projectError = nil
        let client = client
        await projectLoad.perform(operation: {
            try await QuinjetOperationExecution.projects(using: client)
        }) { projects = $0 }
        projectError = projectLoad.errorMessage
    }

    func refreshThemes() async {
        if isRemote { await performUI("quinjet.ui.themes", object: [:]); return }
        do {
            let refreshed = try await client.themes()
            try Task.checkCancellation()
            themes = refreshed
        } catch is CancellationError {
        } catch {
            themes = QuinjetTheme.allCases
        }
    }

    func refreshProjects(for remote: QuinjetRemote) async {
        if isRemote {
            await performUI(
                "quinjet.ui.projects", object: ["machineID": remote.machineID.uuidString])
            return
        }
        let machineID = remote.machineID
        let loading = remoteProjectLoads[machineID] ?? ContentLoad()
        remoteProjectLoads[machineID] = loading
        remoteProjectErrors[machineID] = nil
        let client = client
        await loading.perform(operation: {
            try await QuinjetOperationExecution.projects(remote: remote, using: client)
        }) { remoteProjects[machineID] = $0 }
        remoteProjectErrors[machineID] = loading.errorMessage
    }

    @discardableResult
    func addPickerTab(machineID: UUID? = nil) -> QuinjetTab {
        let tab = QuinjetTab()
        tab.machineID = machineID ?? QuinjetMachines.localMachineID
        tabs.append(tab)
        selected = tab.id
        return tab
    }

    func open(
        _ worktree: QuinjetWorktree, projectName: String, available: [QuinjetWorktree],
        remote: QuinjetRemote? = nil, in tab: QuinjetTab, launchEnabled: Bool,
        configuration: QuinjetLaunchConfiguration = .default, select: Bool = true
    ) {
        if isRemote {
            enqueueUI(
                "quinjet.ui.open",
                object: [
                    "tabID": tab.id.uuidString, "path": worktree.path,
                    "configuration": configurationObject(configuration),
                ])
            return
        }
        tab.projectName = projectName
        tab.worktree = worktree
        tab.remote = remote
        tab.worktrees = available.filter(\.canOpen)
        tab.launchConfiguration = configuration
        tab.showsWorktrees = false
        tab.errorMessage = nil
        tab.externalLaunchMessage = nil
        if select { selected = tab.id }
        tab.externalLaunchGeneration += 1
        let externalLaunchGeneration = tab.externalLaunchGeneration
        guard launchEnabled else {
            if select { recordUse(of: tab) }
            return
        }
        guard let executable = QuinjetExecutable.local() else {
            tab.errorMessage = QuinjetClientError.notInstalled.localizedDescription
            return
        }
        let request: QuinjetLaunchRequest
        do {
            request = try QuinjetOperationExecution.launchRequest(
                executableURL: executable, worktreePath: worktree.path, remote: remote,
                configuration: configuration,
                managedByEdith: configuration.terminal == .embedded,
                localHomeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        } catch {
            tab.errorMessage = error.localizedDescription
            return
        }
        if configuration.terminal == .cmux {
            tab.holder.stop()
            let replacing = tab.externalWorkspaceID
            QuinjetWorkOwnership.start { [weak tab] in
                do {
                    let workspaceID = try await QuinjetCMUXLauncher.launch(
                        request: request, replacing: replacing)
                    guard
                        let tab,
                        tab.externalLaunchGeneration == externalLaunchGeneration
                    else {
                        try? await QuinjetCMUXLauncher.close(workspaceID: workspaceID)
                        return
                    }
                    tab.externalWorkspaceID = workspaceID
                    tab.externalLaunchMessage = "Opened in cmux"
                    if select { self.recordUse(of: tab) }
                } catch {
                    guard
                        let tab,
                        tab.externalLaunchGeneration == externalLaunchGeneration
                    else { return }
                    tab.errorMessage = error.localizedDescription
                }
            }
            return
        }
        if let workspaceID = tab.externalWorkspaceID {
            tab.externalWorkspaceID = nil
            QuinjetWorkOwnership.start {
                try? await QuinjetCMUXLauncher.close(workspaceID: workspaceID)
            }
        }
        tab.holder.registerOSCHandler(code: QuinjetHostAction.oscCode) {
            [weak self, weak tab] payload in
            guard let self, let tab else { return }
            self.handleHostPayload(payload, from: tab)
        }
        let environment = QuinjetOperationExecution.terminalEnvironment(
            overrides: request.environment)
        tab.holder.reset()
        tab.holder.start(
            executable: request.executableURL.path, arguments: request.arguments,
            environment: environment + ["EDITH_QUINJET_TAB_ID=" + tab.id.uuidString],
            currentDirectory: request.currentDirectory, allowsLocalFileLinks: remote == nil)
        if !tab.holder.started { tab.errorMessage = tab.holder.exitMessage }
        if select { recordUse(of: tab) }
    }

    func openFolder(
        _ path: String, remote: QuinjetRemote? = nil, in tab: QuinjetTab,
        launchEnabled: Bool, configuration: QuinjetLaunchConfiguration = .default
    ) async {
        if isRemote {
            await performUI(
                "quinjet.ui.open",
                object: [
                    "tabID": tab.id.uuidString, "path": path,
                    "configuration": configurationObject(configuration),
                ])
            return
        }
        if remote == nil {
            projectError = nil
        } else {
            tab.errorMessage = nil
        }
        do {
            let selection = try await QuinjetOperationExecution.openSelection(
                at: path, remote: remote, using: client)
            open(
                selection.worktree, projectName: selection.projectName,
                available: selection.worktrees, remote: remote, in: tab,
                launchEnabled: launchEnabled, configuration: configuration)
            if remote == nil { await refreshProjects() }
        } catch {
            if remote == nil {
                projectError = error.localizedDescription
            } else {
                tab.errorMessage = error.localizedDescription
            }
        }
    }

    func presentWorktrees(for tab: QuinjetTab) async {
        if isRemote {
            tab.showsWorktrees = true
            await performUI("quinjet.ui.worktrees", object: ["tabID": tab.id.uuidString])
            return
        }
        guard let path = tab.worktree?.path else { return }
        tab.showsWorktrees = true
        tab.errorMessage = nil
        let client = client
        let remote = tab.remote
        await tab.worktreeLoad.perform(operation: {
            try await QuinjetOperationExecution.worktrees(at: path, remote: remote, using: client)
        }) { worktrees in
            tab.worktrees = worktrees.filter(\.canOpen)
        }
        tab.errorMessage = tab.worktreeLoad.errorMessage
    }

    func handleHostPayload(_ payload: String, from tab: QuinjetTab) {
        guard !stopped, tabs.contains(where: { $0 === tab }), tabs.count < 32,
            let action = QuinjetHostAction(payload: payload)
        else { return }
        switch action {
        case .openNewTab:
            QuinjetWorkOwnership.start {
                try? await self.performSessionOperation(
                    QuinjetSessionRequest(operation: .create, session: tab.id.uuidString))
            }
        case .openWorktree:
            QuinjetWorkOwnership.start { await self.presentWorktrees(for: tab) }
        }
    }

    func apply(
        _ configuration: QuinjetLaunchConfiguration, launchEnabled: Bool
    ) {
        if isRemote {
            enqueueUI(
                "quinjet.ui.configuration",
                object: ["configuration": configurationObject(configuration)])
            return
        }
        for tab in tabs {
            guard let worktree = tab.worktree, tab.launchConfiguration != configuration else {
                continue
            }
            open(
                worktree, projectName: tab.projectName ?? "Project", available: tab.worktrees,
                remote: tab.remote, in: tab, launchEnabled: launchEnabled,
                configuration: configuration, select: false)
        }
    }

    func setSessionLaunchEnabled(_ enabled: Bool) {
        sessionLaunchEnabled = enabled
    }

    func performSessionOperation(
        _ request: QuinjetSessionRequest
    ) async throws -> QuinjetSessionResult {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if let uiClient {
            let data = try JSONEncoder().encode(request)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            if let state = try await uiClient.state("quinjet.ui.session", object: object) {
                try adoptUI(state)
            }
            return sessionResult(for: request.operation, affected: selected)
        }
        if request.operation == .create, tabs.count >= 32 {
            throw ExtensionPeerError.invalidRequest
        }
        switch request.operation {
        case .status:
            let tab = try session(matching: request.session)
            return sessionResult(for: .status, affected: tab.id)
        case .sessions:
            return sessionResult(for: request.operation)
        case .create:
            let source = try request.session.map { try session(matching: $0) }
            let tab = addPickerTab(
                machineID: source?.remote?.machineID ?? QuinjetMachines.localMachineID)
            return sessionResult(for: .create, affected: tab.id)
        case .focus:
            let tab = try session(matching: request.session)
            selected = tab.id
            if let workspaceID = tab.externalWorkspaceID {
                do {
                    try await focusExternalWorkspace(workspaceID)
                } catch {
                    tab.errorMessage = error.localizedDescription
                    throw QuinjetSessionError.operationFailed(error.localizedDescription)
                }
            }
            recordUse(of: tab)
            return sessionResult(for: .focus, affected: tab.id)
        case .close:
            let tab = try session(matching: request.session)
            try await closeSession(tab)
            return sessionResult(for: .close, affected: tab.id)
        case .restart:
            let tab = try session(matching: request.session)
            try restartSession(tab)
            return sessionResult(for: .restart, affected: tab.id)
        case .switchWorktree:
            let tab = try session(matching: request.session)
            guard let path = request.worktreePath, !path.isEmpty else {
                throw QuinjetSessionError.worktreeRequired
            }
            try await switchSession(tab, to: path)
            return sessionResult(for: .switchWorktree, affected: tab.id)
        }
    }

    func stopRendering() {
        terminalUI?.invalidate()
        guard let uiClient else { return }
        stopped = true
        uiClient.stop()
        for task in uiActions.values { task.cancel() }
        for tab in tabs { tab.holder.stopRendering() }
    }

    func shutdown() async {
        stopped = true
        if let uiClient {
            stopRendering()
            let actions = Array(uiActions.values)
            for task in actions { task.cancel() }
            uiActions.removeAll()
            for tab in tabs { tab.holder.stopRendering(); await tab.folderPicker?.shutdown() }
            for task in actions { await task.value }
            return
        }
        cancelDiscovery()
        stopAll()
        for tab in tabs {
            tab.externalLaunchGeneration += 1
            await tab.folderPicker?.shutdown()
            if let workspaceID = tab.externalWorkspaceID {
                tab.externalWorkspaceID = nil
                try? await closeExternalWorkspace(workspaceID)
            }
        }
    }

    func stopAll() {
        for tab in tabs { tab.holder.stop() }
    }

    func cancelDiscovery() {
        uiClient?.cancel()
        for task in uiActions.values { task.cancel() }
        projectLoad.cancel()
        for loading in remoteProjectLoads.values { loading.cancel() }
        for tab in tabs {
            tab.worktreeLoad.cancel()
            tab.showsWorktrees = false
        }
    }

    private func session(matching selector: String?) throws -> QuinjetTab {
        let query = selector?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if query.isEmpty {
            guard let selectedTab else { throw QuinjetSessionError.sessionNotFound("selected") }
            return selectedTab
        }
        if let id = UUID(uuidString: query), let tab = tabs.first(where: { $0.id == id }) {
            return tab
        }
        if let index = Int(query), tabs.indices.contains(index - 1) { return tabs[index - 1] }
        let matches = tabs.filter {
            $0.title.caseInsensitiveCompare(query) == .orderedSame
                || $0.worktree?.path == query
                || $0.worktree?.branch?.caseInsensitiveCompare(query) == .orderedSame
        }
        guard matches.count == 1, let tab = matches.first else {
            throw QuinjetSessionError.sessionNotFound(query)
        }
        return tab
    }

    private func closeSession(_ tab: QuinjetTab) async throws {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            throw QuinjetSessionError.lastSession
        }
        tab.externalLaunchGeneration += 1
        if let workspaceID = tab.externalWorkspaceID {
            do {
                try await closeExternalWorkspace(workspaceID)
            } catch {
                tab.errorMessage = error.localizedDescription
                throw QuinjetSessionError.operationFailed(error.localizedDescription)
            }
        }
        let retired = tab.holder.descriptor?.handle
        tab.holder.stop()
        if let retired { await OwnedTerminalContext.registry?.files.drain([retired]) }
        tab.worktreeLoad.cancel()
        tabs.remove(at: index)
        if selected == tab.id { selected = tabs[min(index, tabs.count - 1)].id }
    }

    private func restartSession(_ tab: QuinjetTab) throws {
        guard let worktree = tab.worktree else {
            throw QuinjetSessionError.reviewUnavailable(tab.title)
        }
        open(
            worktree, projectName: tab.projectName ?? "Project", available: tab.worktrees,
            remote: tab.remote, in: tab, launchEnabled: sessionLaunchEnabled,
            configuration: tab.launchConfiguration)
    }

    private func switchSession(_ tab: QuinjetTab, to path: String) async throws {
        do {
            let selection = try await QuinjetOperationExecution.openSelection(
                at: path, remote: tab.remote, using: client)
            open(
                selection.worktree, projectName: tab.projectName ?? selection.projectName,
                available: selection.worktrees, remote: tab.remote, in: tab,
                launchEnabled: sessionLaunchEnabled, configuration: tab.launchConfiguration)
        } catch let error as QuinjetOperationError {
            tab.errorMessage = error.localizedDescription
            throw QuinjetSessionError.worktreeNotFound(error.localizedDescription)
        } catch {
            tab.errorMessage = error.localizedDescription
            throw QuinjetSessionError.operationFailed(error.localizedDescription)
        }
    }

    private func sessionResult(
        for operation: QuinjetSessionOperation, affected: UUID? = nil
    ) -> QuinjetSessionResult {
        QuinjetSessionResult(
            operation: operation, selectedSessionID: selected.uuidString,
            affectedSessionID: affected?.uuidString,
            sessions: tabs.enumerated().map { offset, tab in
                sessionState(tab, index: offset + 1)
            })
    }

    private func sessionState(_ tab: QuinjetTab, index: Int) -> QuinjetSessionState {
        let state: String
        if tab.worktree == nil {
            state = "picker"
        } else if tab.launchConfiguration.terminal == .cmux {
            state = tab.externalWorkspaceID == nil ? "ready" : "running"
        } else if tab.holder.exitMessage != nil {
            state = "ended"
        } else if tab.holder.started {
            state = "running"
        } else {
            state = "ready"
        }
        let terminal =
            tab.worktree == nil ? nil : tab.launchConfiguration.terminal.rawValue
        return QuinjetSessionState(
            id: tab.id.uuidString, index: index, title: tab.title, selected: tab.id == selected,
            state: state, terminal: terminal,
            project: tab.projectName, worktreePath: tab.worktree?.path,
            branch: tab.worktree?.branch, machine: tab.remote?.machineName ?? "This Mac",
            canClose: tabs.count > 1, canRestart: tab.worktree != nil,
            exitMessage: tab.holder.exitMessage)
    }

}
