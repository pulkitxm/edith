import EdithExtensionSupport
import EdithExtensionUI
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
    private var preparations: [UUID: Task<Void, Never>] = [:]

    init(client: QuinjetClient = .live) {
        self.client = client
    }

    var live: Bool { holder.started && holder.exitMessage == nil }

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

    func cancelPendingWork() {
        generation += 1
        preparing = false
        for task in preparations.values { task.cancel() }
    }

    func cancelPendingWorkAndWait() async {
        cancelPendingWork()
        for task in Array(preparations.values) { await task.value }
    }

    func stopAndWait() async {
        stop()
        await cancelPendingWorkAndWait()
        await holder.stopAndWait()
    }

    func stop() {
        cancelPendingWork()
        launched = nil
        holder.stop()
    }

    func adopt(_ state: HerdrDiffSessionState, invoke: @escaping OwnedTerminalClient.Invoke) throws
    {
        if holder.descriptor != state.terminal {
            holder.reset()
            holder.bind(try OwnedTerminalClient(descriptor: state.terminal, invoke: invoke))
        }
        worktree = state.worktree
        projectName = state.projectName
        errorMessage = nil
    }

    private func launch(
        directory: String, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, launchEnabled: Bool
    ) async {
        generation += 1
        let attempt = generation
        let id = UUID()
        let task = HerdrWorkOwnership.start { [self] in
            await prepareLaunch(
                directory: directory, remote: remote, configuration: configuration,
                launchEnabled: launchEnabled, attempt: attempt)
        }
        preparations[id] = task
        defer { preparations[id] = nil }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func prepareLaunch(
        directory: String, remote: QuinjetRemote?,
        configuration: QuinjetLaunchConfiguration, launchEnabled: Bool, attempt: Int
    ) async {
        guard attempt == generation, !Task.isCancelled else { return }
        guard !ExtensionHostRole.isInterfaceProcess else {
            errorMessage = "Only the owning engine can prepare a diff."
            return
        }
        errorMessage = nil
        guard !directory.isEmpty else {
            errorMessage = "This agent does not report a working directory."
            return
        }
        guard launchEnabled else { return }
        preparing = true
        defer { if attempt == generation { preparing = false } }
        do {
            guard let executable = HerdrQuinjetExecutable.local() else {
                throw QuinjetClientError.notInstalled
            }
            let request: QuinjetLaunchRequest
            do {
                let selection = try await QuinjetOperationExecution.openSelection(
                    at: directory, remote: remote, using: client)
                guard attempt == generation else { return }
                worktree = selection.worktree
                projectName = selection.projectName
                request = try QuinjetLaunchRequest(
                    executableURL: executable, worktreePath: selection.worktree.path,
                    remote: remote,
                    configuration: configuration, managedByEdith: false,
                    localHomeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            } catch let error as QuinjetClientError where error.isNotGitRepository {
                guard attempt == generation else { return }
                worktree = nil
                projectName = nil
                request = try QuinjetLaunchRequest(
                    executableURL: executable, worktreePath: directory, remote: remote,
                    configuration: configuration, managedByEdith: false,
                    localHomeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            }
            guard attempt == generation else { return }
            holder.reset()
            holder.start(
                executable: request.executableURL.path, arguments: request.arguments,
                environment: QuinjetOperationExecution.terminalEnvironment(
                    overrides: request.environment),
                currentDirectory: request.currentDirectory, allowsLocalFileLinks: remote == nil)
            try await holder.waitForCreation()
            try Task.checkCancellation()
            guard attempt == generation else { return }
            launched = configuration
        } catch {
            guard attempt == generation else { return }
            errorMessage = error.localizedDescription
        }
    }
}
