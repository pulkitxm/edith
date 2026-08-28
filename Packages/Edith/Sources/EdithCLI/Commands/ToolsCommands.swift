import ArgumentParser
import EdithKit
import Foundation

struct ToolsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tools",
        abstract: "The command line tools Edith's extensions rely on.",
        discussion: """
            These are the tools extensions need for downloads, agent usage and workspace
            review. `ls` checks what is on PATH; `install` fetches the one you name the same
            way the extension sheet does.
            """,
        subcommands: [ToolsListCommand.self, ToolsInstallCommand.self],
        defaultSubcommand: ToolsListCommand.self)
}

enum ToolsBridge {
    struct Status: Sendable {
        let spec: CLIToolSpec
        let path: URL?
        let version: String?

        var installed: Bool { path != nil && version != nil }
        var state: String {
            if path == nil { return "missing" }
            return installed ? "installed" : "broken"
        }
    }

    static let all: [CLIToolSpec] = ToolProvisioning.all
    static var ids: String { all.map(\.id).joined(separator: ", ") }

    static func resolve(_ id: String) throws -> CLIToolSpec {
        let needle = id.lowercased()
        if let exact = all.first(where: { $0.id.lowercased() == needle }) { return exact }
        if let byName = all.first(where: { $0.displayName.lowercased() == needle }) {
            return byName
        }
        throw CLIFailure.notFound(
            "no tool called \(id)",
            hint: "tools: " + all.map(\.id).joined(separator: ", "))
    }

    static func found(_ spec: CLIToolSpec) -> URL? {
        guard case let .executable(name, _) = spec.presenceStrategy else { return nil }
        return CLIEnvironment.executableNamed(name)
    }

    static func status(_ spec: CLIToolSpec) async -> Status {
        guard case let .executable(_, arguments) = spec.presenceStrategy,
            let executable = found(spec)
        else { return Status(spec: spec, path: nil, version: nil) }
        if let remembered = ToolVersionCache.cached(for: executable) {
            return Status(spec: spec, path: executable, version: remembered)
        }
        let request = CLICommandRequest(
            executableURL: executable, arguments: arguments,
            environment: CLIToolEnvironment.sanitized(), timeout: spec.versionProbeTimeout)
        let version = await ToolVersionProbe.version(request)
        if let version { ToolVersionCache.remember(version, for: executable) }
        return Status(spec: spec, path: executable, version: version)
    }
}

struct ToolsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the tools and whether they are installed.",
        aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let progress = CLIProgress.forCommand(json: json)
            progress.begin("probing \(ToolsBridge.all.count) tools")
            let rows = await withTaskGroup(of: (Int, ToolsBridge.Status).self) { group in
                for (index, spec) in ToolsBridge.all.enumerated() {
                    group.addTask {
                        (index, await ToolsBridge.status(spec))
                    }
                }
                var probed: [(Int, ToolsBridge.Status)] = []
                for await probe in group { probed.append(probe) }
                return probed.sorted { $0.0 < $1.0 }.map(\.1)
            }
            progress.end()
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { status in
                            .object([
                                "id": .string(status.spec.id),
                                "name": .string(status.spec.displayName),
                                "why": .string(status.spec.why),
                                "installed": .bool(status.installed),
                                "path": .optional(status.path?.path),
                                "version": .optional(status.version),
                            ])
                        }))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "STATE", "VERSION", "WHY"],
                    rows: rows.map { status in
                        [
                            status.spec.id, status.state, status.version ?? "", status.spec.why,
                        ]
                    }))
        }
    }
}

struct ToolsInstallCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Install one of the tools.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "The tool id: \(ToolsBridge.ids).")
    var tool: String

    func run() async throws {
        try await execute {
            let spec = try ToolsBridge.resolve(tool)
            let status = await ToolsBridge.status(spec)
            if status.installed, let existing = status.path {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "id": .string(spec.id), "installed": .bool(true),
                            "path": .string(existing.path), "changed": .bool(false),
                        ]))
                    return
                }
                CLIOut.note("\(spec.id) is already at \(existing.path)")
                return
            }
            let progress = CLIProgress.forCommand(json: json)
            progress.header("EDITH · install " + spec.displayName)
            progress.begin("installing " + spec.id)
            do {
                let version = try await ExtensionLookup.mutationCenter().install(
                    spec, log: { line in progress.note(line) })
                progress.end()
                progress.done("\(spec.id) is ready")
                guard !json else {
                    CLIOut.json(
                        .object([
                            "id": .string(spec.id), "installed": .bool(true),
                            "version": .string(version), "changed": .bool(true),
                        ]))
                    return
                }
                CLIOut.out("installed \(spec.id) (\(version))")
            } catch {
                progress.end()
                let reason =
                    (error as? ToolInstallFailure)?.description
                    ?? error.localizedDescription
                progress.failure(reason)
                throw CLIFailure.unavailable(reason, hint: spec.installStrategy.instruction)
            }
        }
    }
}
