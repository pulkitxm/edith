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
    var worktrees: [QuinjetWorktree] = []
    var showsWorktrees = false
    var loadingWorktrees = false
    var errorMessage: String?

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
        loadingProjects = true
        projectError = nil
        defer { loadingProjects = false }
        do {
            projects = try await client.recentProjects()
        } catch {
            projectError = error.localizedDescription
        }
    }

    @discardableResult
    func addPickerTab() -> QuinjetTab {
        let tab = QuinjetTab()
        tabs.append(tab)
        selected = tab.id
        return tab
    }

    func close(_ tab: QuinjetTab) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tab.id }) else {
            return
        }
        tab.holder.stop()
        tabs.remove(at: index)
        if selected == tab.id { selected = tabs[min(index, tabs.count - 1)].id }
    }

    func open(
        _ worktree: QuinjetWorktree, projectName: String, available: [QuinjetWorktree],
        in tab: QuinjetTab, launchEnabled: Bool
    ) {
        tab.projectName = projectName
        tab.worktree = worktree
        tab.worktrees = available.filter(\.canOpen)
        tab.showsWorktrees = false
        tab.errorMessage = nil
        selected = tab.id
        guard launchEnabled else { return }
        guard let executable = CLIToolEnvironment.executable(named: "quinjet") else {
            tab.errorMessage = QuinjetClientError.notInstalled.localizedDescription
            return
        }
        tab.holder.registerOSCHandler(code: QuinjetHostAction.oscCode) {
            [weak self, weak tab] payload in
            guard let self, let tab else { return }
            self.handleHostPayload(payload, from: tab)
        }
        let environment = terminalEnvironment()
        let arguments = ["--client", "edith", "-C", worktree.path]
        if tab.holder.started {
            tab.holder.restart(
                executable: executable.path, arguments: arguments, environment: environment,
                currentDirectory: worktree.path)
        } else {
            tab.holder.start(
                executable: executable.path, arguments: arguments, environment: environment,
                currentDirectory: worktree.path)
        }
    }

    func openFolder(_ path: String, in tab: QuinjetTab, launchEnabled: Bool) async {
        projectError = nil
        do {
            let worktrees = try await client.worktrees(at: path).filter(\.canOpen)
            guard let worktree = worktrees.first(where: { $0.path == path }) ?? worktrees.first
            else {
                projectError = "No open worktree was found in this folder."
                return
            }
            let name = URL(fileURLWithPath: path).lastPathComponent
            open(
                worktree, projectName: name, available: worktrees, in: tab,
                launchEnabled: launchEnabled)
            await refreshProjects()
        } catch {
            projectError = error.localizedDescription
        }
    }

    func presentWorktrees(for tab: QuinjetTab) async {
        guard let path = tab.worktree?.path else { return }
        tab.showsWorktrees = true
        tab.loadingWorktrees = true
        tab.errorMessage = nil
        defer { tab.loadingWorktrees = false }
        do {
            tab.worktrees = try await client.worktrees(at: path).filter(\.canOpen)
        } catch {
            tab.errorMessage = error.localizedDescription
        }
    }

    func handleHostPayload(_ payload: String, from tab: QuinjetTab) {
        guard let action = QuinjetHostAction(payload: payload) else { return }
        switch action {
        case .openNewTab:
            addPickerTab()
        case .openWorktree:
            Task { await presentWorktrees(for: tab) }
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
}
