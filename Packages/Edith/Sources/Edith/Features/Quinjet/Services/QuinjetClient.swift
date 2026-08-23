import EdithKit
import Foundation

struct QuinjetClient: Sendable {
    typealias Execute = @Sendable ([String]) async throws -> Data

    private let execute: Execute

    init(execute: @escaping Execute) {
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
        var projects: [QuinjetProject] = []
        var identities = Set<String>()
        for folder in folders.remotes
        where folder.target == remote.target && folder.accessible && folder.folder.hasPrefix("/") {
            guard let worktrees = try? await worktrees(at: folder.folder, remote: remote),
                !worktrees.isEmpty
            else { continue }
            let identity = worktrees.map(\.path).sorted().joined(separator: "\u{1F}")
            guard identities.insert(identity).inserted else { continue }
            projects.append(
                QuinjetProject(
                    name: URL(fileURLWithPath: folder.folder).lastPathComponent,
                    commonDir: identity, worktrees: worktrees))
        }
        return projects
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
