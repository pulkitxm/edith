import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class QuinjetTab: Identifiable {
    let id = UUID()
    let holder = TerminalSessionHolder()
    var projectName: String?
    var worktree: QuinjetWorktree?
    var remote: QuinjetRemote?
    var worktrees: [QuinjetWorktree] = []
    var showsWorktrees = false
    var loadingWorktrees = false
    var errorMessage: String?
    var machineID = MachinesModel.localMachineID
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
    private let focusExternalWorkspace: ExternalWorkspaceAction
    private let closeExternalWorkspace: ExternalWorkspaceAction

    private(set) var tabs: [QuinjetTab]
    private(set) var selected: UUID
    private(set) var projects: [QuinjetProject] = []
    private(set) var loadingProjects = false
    var projectError: String?
    var query = ""
    private var remoteProjects: [UUID: [QuinjetProject]] = [:]
    private var loadingRemoteProjects: Set<UUID> = []
    private var remoteProjectErrors: [UUID: String] = [:]
    private var projectRefreshGeneration = 0
    private var remoteProjectRefreshGenerations: [UUID: Int] = [:]
    private var sessionLaunchEnabled = false

    init(
        client: QuinjetClient = .live,
        focusExternalWorkspace: @escaping ExternalWorkspaceAction = {
            try await QuinjetCMUXLauncher.focus(workspaceID: $0)
        },
        closeExternalWorkspace: @escaping ExternalWorkspaceAction = {
            try await QuinjetCMUXLauncher.close(workspaceID: $0)
        }
    ) {
        self.client = client
        self.focusExternalWorkspace = focusExternalWorkspace
        self.closeExternalWorkspace = closeExternalWorkspace
        let tab = QuinjetTab()
        tabs = [tab]
        selected = tab.id
    }

    var selectedTab: QuinjetTab? {
        tabs.first { $0.id == selected }
    }

    var filteredProjects: [QuinjetProject] {
        filtered(projects)
    }

    func projects(for remote: QuinjetRemote) -> [QuinjetProject] {
        remoteProjects[remote.machineID] ?? []
    }

    func filteredProjects(for remote: QuinjetRemote) -> [QuinjetProject] {
        filtered(projects(for: remote))
    }

    func isLoadingProjects(for remote: QuinjetRemote) -> Bool {
        loadingRemoteProjects.contains(remote.machineID)
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

    func refreshProjects() async {
        projectRefreshGeneration += 1
        let generation = projectRefreshGeneration
        loadingProjects = true
        projectError = nil
        defer {
            if generation == projectRefreshGeneration { loadingProjects = false }
        }
        do {
            let refreshed = try await QuinjetOperationExecution.projects(using: client)
            try Task.checkCancellation()
            guard generation == projectRefreshGeneration else { return }
            projects = refreshed
        } catch is CancellationError {
        } catch {
            guard generation == projectRefreshGeneration else { return }
            projectError = error.localizedDescription
        }
    }

    func refreshProjects(for remote: QuinjetRemote) async {
        let machineID = remote.machineID
        let generation = (remoteProjectRefreshGenerations[machineID] ?? 0) + 1
        remoteProjectRefreshGenerations[machineID] = generation
        loadingRemoteProjects.insert(machineID)
        remoteProjectErrors[machineID] = nil
        defer {
            if generation == remoteProjectRefreshGenerations[machineID] {
                loadingRemoteProjects.remove(machineID)
            }
        }
        do {
            let refreshed = try await QuinjetOperationExecution.projects(
                remote: remote, using: client)
            try Task.checkCancellation()
            guard generation == remoteProjectRefreshGenerations[machineID] else { return }
            remoteProjects[machineID] = refreshed
        } catch is CancellationError {
        } catch {
            guard generation == remoteProjectRefreshGenerations[machineID] else { return }
            remoteProjectErrors[machineID] = error.localizedDescription
        }
    }

    @discardableResult
    func addPickerTab(machineID: UUID? = nil) -> QuinjetTab {
        let tab = QuinjetTab()
        tab.machineID = machineID ?? MachinesModel.localMachineID
        tabs.append(tab)
        selected = tab.id
        return tab
    }

    func open(
        _ worktree: QuinjetWorktree, projectName: String, available: [QuinjetWorktree],
        remote: QuinjetRemote? = nil, in tab: QuinjetTab, launchEnabled: Bool,
        configuration: QuinjetLaunchConfiguration = .default
    ) {
        tab.projectName = projectName
        tab.worktree = worktree
        tab.remote = remote
        tab.worktrees = available.filter(\.canOpen)
        tab.launchConfiguration = configuration
        tab.showsWorktrees = false
        tab.errorMessage = nil
        tab.externalLaunchMessage = nil
        selected = tab.id
        tab.externalLaunchGeneration += 1
        let externalLaunchGeneration = tab.externalLaunchGeneration
        guard launchEnabled else { return }
        guard let executable = CLIToolEnvironment.executable(named: "quinjet") else {
            tab.errorMessage = QuinjetClientError.notInstalled.localizedDescription
            return
        }
        let request = QuinjetOperationExecution.launchRequest(
            executableURL: executable, worktreePath: worktree.path, remote: remote,
            configuration: configuration, managedByEdith: configuration.terminal == .embedded,
            localHomeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        if configuration.terminal == .cmux {
            tab.holder.stop()
            let replacing = tab.externalWorkspaceID
            Task { [weak tab] in
                do {
                    let workspaceID = try await QuinjetCMUXLauncher.launch(
                        quinjet: request.executableURL, arguments: request.arguments,
                        currentDirectory: request.currentDirectory, replacing: replacing)
                    guard
                        let tab,
                        tab.externalLaunchGeneration == externalLaunchGeneration
                    else {
                        try? await QuinjetCMUXLauncher.close(workspaceID: workspaceID)
                        return
                    }
                    tab.externalWorkspaceID = workspaceID
                    tab.externalLaunchMessage = "Opened in cmux"
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
            Task { try? await QuinjetCMUXLauncher.close(workspaceID: workspaceID) }
        }
        tab.holder.registerOSCHandler(code: QuinjetHostAction.oscCode) {
            [weak self, weak tab] payload in
            guard let self, let tab else { return }
            self.handleHostPayload(payload, from: tab)
        }
        let environment = terminalEnvironment()
        tab.holder.reset()
        tab.holder.start(
            executable: request.executableURL.path, arguments: request.arguments,
            environment: environment, currentDirectory: request.currentDirectory)
    }

    func openFolder(
        _ path: String, remote: QuinjetRemote? = nil, in tab: QuinjetTab,
        launchEnabled: Bool, configuration: QuinjetLaunchConfiguration = .default
    ) async {
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
        guard let path = tab.worktree?.path else { return }
        tab.showsWorktrees = true
        tab.loadingWorktrees = true
        tab.errorMessage = nil
        defer { tab.loadingWorktrees = false }
        do {
            tab.worktrees = try await QuinjetOperationExecution.worktrees(
                at: path, remote: tab.remote, using: client
            ).filter(\.canOpen)
        } catch {
            tab.errorMessage = error.localizedDescription
        }
    }

    func handleHostPayload(_ payload: String, from tab: QuinjetTab) {
        guard let action = QuinjetHostAction(payload: payload) else { return }
        switch action {
        case .openNewTab:
            addPickerTab(machineID: tab.remote?.machineID ?? MachinesModel.localMachineID)
        case .openWorktree:
            Task { await presentWorktrees(for: tab) }
        }
    }

    func apply(
        _ configuration: QuinjetLaunchConfiguration, launchEnabled: Bool
    ) {
        guard let tab = selectedTab, let worktree = tab.worktree,
            tab.launchConfiguration != configuration
        else { return }
        open(
            worktree, projectName: tab.projectName ?? "Project", available: tab.worktrees,
            remote: tab.remote, in: tab, launchEnabled: launchEnabled,
            configuration: configuration)
    }

    func setSessionLaunchEnabled(_ enabled: Bool) {
        sessionLaunchEnabled = enabled
    }

    func performSessionOperation(
        _ request: QuinjetSessionRequest
    ) async throws -> QuinjetSessionResult {
        switch request.operation {
        case .status:
            let tab = try session(matching: request.session)
            return sessionResult(for: .status, affected: tab.id)
        case .sessions:
            return sessionResult(for: request.operation)
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

    func stopAll() {
        for tab in tabs { tab.holder.stop() }
    }

    private func terminalEnvironment() -> [String] {
        var environment = CLIToolEnvironment.sanitized()
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        return environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
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
        tab.holder.stop()
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
        } else if tab.holder.started {
            state = "running"
        } else if tab.holder.exitMessage != nil {
            state = "ended"
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
