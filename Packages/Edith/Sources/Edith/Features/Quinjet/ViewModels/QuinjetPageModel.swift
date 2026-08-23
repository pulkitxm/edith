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
    private let client: QuinjetClient

    private(set) var tabs: [QuinjetTab]
    var selected: UUID
    private(set) var projects: [QuinjetProject] = []
    private(set) var loadingProjects = false
    var projectError: String?
    var query = ""
    private var remoteProjects: [UUID: [QuinjetProject]] = [:]
    private var loadingRemoteProjects: Set<UUID> = []
    private var remoteProjectErrors: [UUID: String] = [:]
    private var projectRefreshGeneration = 0
    private var remoteProjectRefreshGenerations: [UUID: Int] = [:]

    init(client: QuinjetClient = .live) {
        self.client = client
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
            let refreshed = try await client.recentProjects()
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
            let refreshed = try await client.recentProjects(remote: remote)
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

    func close(_ tab: QuinjetTab) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }
        tab.holder.stop()
        tab.externalLaunchGeneration += 1
        if let workspaceID = tab.externalWorkspaceID {
            Task { try? await QuinjetCMUXLauncher.close(workspaceID: workspaceID) }
        }
        tabs.remove(at: index)
        if selected == tab.id { selected = tabs[min(index, tabs.count - 1)].id }
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
        if configuration.terminal == .cmux {
            tab.holder.stop()
            let arguments = launchArguments(
                worktree: worktree, remote: remote, configuration: configuration, managed: false)
            let currentDirectory =
                remote == nil ? worktree.path : FileManager.default.homeDirectoryForCurrentUser.path
            let replacing = tab.externalWorkspaceID
            Task { [weak tab] in
                do {
                    let workspaceID = try await QuinjetCMUXLauncher.launch(
                        quinjet: executable, arguments: arguments,
                        currentDirectory: currentDirectory, replacing: replacing)
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
        let arguments = launchArguments(
            worktree: worktree, remote: remote, configuration: configuration, managed: true)
        let currentDirectory = remote == nil ? worktree.path : nil
        tab.holder.reset()
        tab.holder.start(
            executable: executable.path, arguments: arguments, environment: environment,
            currentDirectory: currentDirectory)
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
            let worktrees = try await client.worktrees(at: path, remote: remote).filter(\.canOpen)
            guard let worktree = worktrees.first(where: { $0.path == path }) ?? worktrees.first
            else {
                let message = "No open worktree was found in this folder."
                if remote == nil { projectError = message } else { tab.errorMessage = message }
                return
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            open(
                worktree, projectName: name, available: worktrees, remote: remote, in: tab,
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
            tab.worktrees = try await client.worktrees(at: path, remote: tab.remote).filter(
                \.canOpen)
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

    func showInCMUX(_ tab: QuinjetTab, launchEnabled: Bool) {
        guard let workspaceID = tab.externalWorkspaceID else {
            guard let worktree = tab.worktree else { return }
            open(
                worktree, projectName: tab.projectName ?? "Project", available: tab.worktrees,
                remote: tab.remote, in: tab, launchEnabled: launchEnabled,
                configuration: tab.launchConfiguration)
            return
        }
        Task { [weak tab] in
            do {
                try await QuinjetCMUXLauncher.focus(workspaceID: workspaceID)
            } catch {
                guard let tab, tab.externalWorkspaceID == workspaceID else { return }
                tab.errorMessage = error.localizedDescription
            }
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

    func launchArguments(
        worktree: QuinjetWorktree, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, managed: Bool
    ) -> [String] {
        var arguments: [String] = []
        if managed { arguments += ["--client", "edith"] }
        if let remote {
            arguments += [
                "--remote", remote.target, "--ssh-control-path", remote.controlPath,
            ]
        }
        arguments += ["-C", worktree.path, "tui"]
        arguments += [
            "--theme", configuration.theme.rawValue,
            "--appearance", configuration.appearance.rawValue,
        ]
        return arguments
    }
}
