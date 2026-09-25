import Foundation

public enum HerdrTerminalSpace {
    public static let label = "Edith-terminals"
    public static let defaultSession = "default"
    private static let timeout: TimeInterval = 15

    public static func openArguments(
        session: String, cwd: String?, existing workspaces: [HerdrWorkspaceSummary]
    ) -> [String] {
        let arguments: [String]
        if let space = workspaces.first(where: { $0.label == label }) {
            arguments = HerdrTabCreateCommand.arguments(workspaceID: space.id, cwd: cwd)
        } else {
            arguments = HerdrWorkspaceCreateCommand.arguments(label: label, cwd: cwd)
        }
        return HerdrSessionCommand.scoped(arguments, session: session)
    }

    public static func openTerminal(
        session: String, cwd: String?, on machine: Machine?
    ) async throws -> HerdrCreatedPane {
        let key = "\(machine?.id.uuidString ?? HerdrHostSnapshot.localID)|\(session)"
        return try await HerdrTerminalSpaceGate.shared.run(key) {
            do {
                return try await open(session: session, cwd: cwd, on: machine)
            } catch HerdrCommandError.commandFailed where cwd != nil {
                return try await open(session: session, cwd: nil, on: machine)
            }
        }
    }

    private static func open(
        session: String, cwd: String?, on machine: Machine?
    ) async throws -> HerdrCreatedPane {
        let listing = try await HerdrCommand.run(
            HerdrSessionCommand.scoped(HerdrWorkspaceListCommand.arguments, session: session),
            timeout: timeout, on: machine)
        let output = try await HerdrCommand.run(
            openArguments(
                session: session, cwd: cwd,
                existing: HerdrListParser.workspaces(from: listing)),
            timeout: timeout, on: machine)
        guard let created = HerdrListParser.createdPane(from: output) else {
            throw HerdrCommandError.malformedResponse
        }
        return created
    }
}

actor HerdrTerminalSpaceGate {
    static let shared = HerdrTerminalSpaceGate()

    private var tails: [String: Task<Void, Never>] = [:]

    func run<Value: Sendable>(
        _ key: String, _ body: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = tails[key]
        let work = Task { () async throws -> Value in
            await previous?.value
            return try await body()
        }
        tails[key] = Task { _ = try? await work.value }
        return try await work.value
    }
}
