import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class HerdrQuinjetSession {
    let holder = TerminalSessionHolder()
    private(set) var preparing = false
    private(set) var worktree: QuinjetWorktree?
    private(set) var projectName: String?
    var errorMessage: String?

    private let client: QuinjetClient
    private var launched: QuinjetLaunchConfiguration?
    private var generation = 0

    init(client: QuinjetClient = .live) {
        self.client = client
    }

    var live: Bool { holder.started }

    var branch: String? {
        guard let worktree else { return nil }
        return worktree.displayName
    }

    func prepare(
        directory: String, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, launchEnabled: Bool
    ) async {
        guard launched != configuration || !live else { return }
        await launch(
            directory: directory, remote: remote, configuration: configuration,
            launchEnabled: launchEnabled)
    }

    func restart(
        directory: String, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, launchEnabled: Bool
    ) async {
        launched = nil
        await launch(
            directory: directory, remote: remote, configuration: configuration,
            launchEnabled: launchEnabled)
    }

    func stop() {
        generation += 1
        launched = nil
        holder.stop()
    }

    private func launch(
        directory: String, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, launchEnabled: Bool
    ) async {
        generation += 1
        let attempt = generation
        errorMessage = nil
        guard !directory.isEmpty else {
            errorMessage = "This agent does not report a working directory."
            return
        }
        guard launchEnabled else { return }
        preparing = true
        defer { if attempt == generation { preparing = false } }
        do {
            guard let executable = CLIToolEnvironment.executable(named: "quinjet") else {
                throw QuinjetClientError.notInstalled
            }
            let selection = try await QuinjetOperationExecution.openSelection(
                at: directory, remote: remote, using: client)
            guard attempt == generation else { return }
            worktree = selection.worktree
            projectName = selection.projectName
            let request = QuinjetLaunchRequest(
                executableURL: executable, worktreePath: selection.worktree.path, remote: remote,
                configuration: configuration, managedByEdith: false,
                localHomeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            holder.reset()
            holder.start(
                executable: request.executableURL.path, arguments: request.arguments,
                environment: QuinjetOperationExecution.terminalEnvironment(),
                currentDirectory: request.currentDirectory,
                allowsLocalFileLinks: remote == nil)
            launched = configuration
        } catch {
            guard attempt == generation else { return }
            errorMessage = error.localizedDescription
        }
    }
}
