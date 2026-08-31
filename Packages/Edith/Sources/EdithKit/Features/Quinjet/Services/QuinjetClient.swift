import Foundation

public struct QuinjetClient: Sendable {
    public typealias Execute = @Sendable ([String]) async throws -> Data

    private let execute: Execute
    private let remoteProbeLimit: Int

    public init(remoteProbeLimit: Int = 4, execute: @escaping Execute) {
        self.remoteProbeLimit = max(1, remoteProbeLimit)
        self.execute = execute
    }

    public func recentProjects() async throws -> [QuinjetProject] {
        try decode(
            [QuinjetProject].self,
            from: await execute(["project", "list", "--json"]))
    }

    public func themes() async throws -> [QuinjetTheme] {
        let capabilities = try decode(
            QuinjetCapabilities.self,
            from: await execute(["capabilities", "--json"]))
        guard
            let values = capabilities.commands.first(where: { $0.path == "quinjet tui" })?
                .arguments.first(where: { $0.id == "theme" })?.possibleValues
        else {
            throw QuinjetClientError.invalidResponse
        }
        var seen = Set<QuinjetTheme>()
        let themes = values.compactMap(QuinjetTheme.init(rawValue:)).filter {
            seen.insert($0).inserted
        }
        guard !themes.isEmpty else { throw QuinjetClientError.invalidResponse }
        return themes
    }

    public func recentProjects(remote: QuinjetRemote) async throws -> [QuinjetProject] {
        let folders = try decode(
            QuinjetRemoteFolders.self, from: await execute(["remote", "list", "--json"]))
        let candidates = folders.remotes.filter {
            $0.target == remote.target && QuinjetPath.isAbsolute($0.folder)
        }
        let probes = try await probeRemoteFolders(candidates, remote: remote)
        var projects: [QuinjetProject] = []
        var identities = Set<String>()
        for probe in probes {
            guard !probe.worktrees.isEmpty else { continue }
            let folder = probe.folder
            let worktrees = probe.worktrees
            let identity = worktrees.map(\.path).sorted().joined(separator: "\u{1F}")
            guard identities.insert(identity).inserted else { continue }
            projects.append(
                QuinjetProject(
                    name: QuinjetPath.name(folder.folder),
                    commonDir: identity, worktrees: worktrees))
        }
        return projects
    }

    private func probeRemoteFolders(
        _ folders: [QuinjetRemoteFolder], remote: QuinjetRemote
    ) async throws -> [RemoteFolderProbe] {
        guard !folders.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: IndexedRemoteFolderProbe.self) { group in
            var nextIndex = 0
            var results = Array<RemoteFolderProbe?>(repeating: nil, count: folders.count)
            let initialCount = min(remoteProbeLimit, folders.count)
            while nextIndex < initialCount {
                let index = nextIndex
                let folder = folders[index]
                group.addTask { try await remoteFolderProbe(index, folder: folder, remote: remote) }
                nextIndex += 1
            }
            while let indexed = try await group.next() {
                results[indexed.index] = indexed.probe
                if nextIndex < folders.count {
                    let index = nextIndex
                    let folder = folders[index]
                    group.addTask {
                        try await remoteFolderProbe(index, folder: folder, remote: remote)
                    }
                    nextIndex += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    private func remoteFolderProbe(
        _ index: Int, folder: QuinjetRemoteFolder, remote: QuinjetRemote
    ) async throws -> IndexedRemoteFolderProbe {
        do {
            try Task.checkCancellation()
            let worktrees = try await worktrees(at: folder.folder, remote: remote)
            try Task.checkCancellation()
            return IndexedRemoteFolderProbe(
                index: index, probe: RemoteFolderProbe(folder: folder, worktrees: worktrees))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return IndexedRemoteFolderProbe(
                index: index, probe: RemoteFolderProbe(folder: folder, worktrees: []))
        }
    }

    public func worktrees(at path: String, remote: QuinjetRemote? = nil) async throws
        -> [QuinjetWorktree]
    {
        var arguments: [String] = []
        if let remote {
            arguments += [
                "--remote", remote.target, "--ssh-control-path", remote.controlPath,
            ]
        }
        arguments += ["-C", remote?.resolve(path) ?? path, "worktree", "list", "--json"]
        return try decode(
            [QuinjetWorktree].self,
            from: await execute(arguments))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw QuinjetClientError.invalidResponse
        }
    }

    public static let live = QuinjetClient { arguments in
        guard let executable = CLIToolEnvironment.executable(named: "quinjet") else {
            throw QuinjetClientError.notInstalled
        }
        let request = CLICommandRequest(
            executableURL: executable, arguments: arguments,
            environment: CLIToolEnvironment.sanitized())
        let result: CLICommandResult
        do {
            result = try await CLICommandRunner.run(request) { _ in }
        } catch {
            throw QuinjetClientError.launchFailed(error.localizedDescription)
        }
        guard result.terminationStatus == 0 else {
            throw QuinjetClientError.commandFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result.standardOutputData
    }
}

private struct QuinjetCapabilities: Decodable {
    let commands: [QuinjetCapabilityCommand]
}

private struct QuinjetCapabilityCommand: Decodable {
    let path: String
    let arguments: [QuinjetCapabilityArgument]
}

private struct QuinjetCapabilityArgument: Decodable {
    let id: String
    let possibleValues: [String]
}

private struct RemoteFolderProbe: Sendable {
    let folder: QuinjetRemoteFolder
    let worktrees: [QuinjetWorktree]
}

private struct IndexedRemoteFolderProbe: Sendable {
    let index: Int
    let probe: RemoteFolderProbe
}
