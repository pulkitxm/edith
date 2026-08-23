import EdithKit
import Foundation

struct QuinjetClient: Sendable {
    typealias Execute = @Sendable ([String]) async throws -> Data

    private let execute: Execute
    private let remoteProbeLimit: Int

    init(remoteProbeLimit: Int = 4, execute: @escaping Execute) {
        self.remoteProbeLimit = max(1, remoteProbeLimit)
        self.execute = execute
    }

    func recentProjects() async throws -> [QuinjetProject] {
        return try decode(
            [QuinjetProject].self,
            from: await execute(["project", "list", "--json"]))
    }

    func recentProjects(remote: QuinjetRemote) async throws -> [QuinjetProject] {
        let folders = try decode(
            QuinjetRemoteFolders.self, from: await execute(["remote", "list", "--json"]))
        let candidates = folders.remotes.filter {
            $0.target == remote.target && $0.accessible && $0.folder.hasPrefix("/")
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
                    name: URL(fileURLWithPath: folder.folder).lastPathComponent,
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

    func worktrees(at path: String, remote: QuinjetRemote? = nil) async throws
        -> [QuinjetWorktree]
    {
        var arguments: [String] = []
        if let remote {
            arguments += [
                "--remote", remote.target, "--ssh-control-path", remote.controlPath,
            ]
        }
        arguments += ["-C", path, "worktree", "list", "--json"]
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

    static let live = QuinjetClient { arguments in
        guard let executable = CLIToolEnvironment.executable(named: "quinjet") else {
            throw QuinjetClientError.notInstalled
        }
        let request = CLICommandRequest(
            executableURL: executable, arguments: arguments,
            environment: CLIToolEnvironment.sanitized())
        let result = try await CLICommandRunner.run(request) { _ in }
        guard result.terminationStatus == 0 else {
            throw QuinjetClientError.commandFailed(
                result.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return Data(result.output.utf8)
    }
}

private struct RemoteFolderProbe: Sendable {
    let folder: QuinjetRemoteFolder
    let worktrees: [QuinjetWorktree]
}

private struct IndexedRemoteFolderProbe: Sendable {
    let index: Int
    let probe: RemoteFolderProbe
}
