import AppKit
import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct JSONOutputOptions: ParsableArguments {
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false
}

enum CLIEnvironment {
    nonisolated(unsafe) static var sharedDefaults = SharedDefaults.store
    nonisolated(unsafe) static var standardDefaults = SharedDefaults.store
    nonisolated(unsafe) static var homeDirectory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path)
    nonisolated(unsafe) static var executableNamed: @Sendable (String) -> URL? = {
        CLIToolEnvironment.executable(named: $0)
    }
}

enum MachineResolver {
    static func machine(_ query: String, in values: [Machine] = MachineRegistry.machines()) throws
        -> Machine
    {
        guard !values.isEmpty else {
            throw CLIFailure.notFound("no machines are configured", hint: "run `ed machines ls`")
        }
        if let exact = values.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(query) == .orderedSame
        }) {
            return exact
        }
        let exact = values.filter {
            $0.name.caseInsensitiveCompare(query) == .orderedSame
                || $0.sshTarget.caseInsensitiveCompare(query) == .orderedSame
                || ($0.aliases?.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
                    ?? false)
        }
        if exact.count == 1 { return exact[0] }
        let matches =
            exact.isEmpty
            ? values.filter {
                $0.id.uuidString.lowercased().hasPrefix(query.lowercased())
                    || $0.name.lowercased().hasPrefix(query.lowercased())
                    || $0.sshTarget.lowercased().hasPrefix(query.lowercased())
                    || ($0.aliases?.contains { $0.lowercased().hasPrefix(query.lowercased()) }
                        ?? false)
            } : exact
        guard !query.isEmpty, matches.count == 1 else {
            throw CLIFailure.notFound(
                matches.isEmpty
                    ? "no machine matches \(query)" : "more than one machine matches \(query)",
                hint: "run `ed machines ls` and use a machine ID")
        }
        return matches[0]
    }

    struct Runner: Sendable { let machine: Machine; let ssh: SSHConnection }
    static func runner(_ query: String) async throws -> Runner {
        let machine = try machine(query)
        let connection = SSHConnection(machine: machine)
        try await connection.connect()
        return Runner(machine: machine, ssh: connection)
    }
}
