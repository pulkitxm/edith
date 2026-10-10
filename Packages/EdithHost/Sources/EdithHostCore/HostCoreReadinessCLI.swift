import EdithExtensionSupport
import Foundation

public struct HostCoreReadinessCLIBackend {
    public struct Entry: Sendable {
        public let id: String; public let title: String
        public init(id: String, title: String) { self.id = id; self.title = title }
    }
    public let entries: @MainActor () -> [Entry]
    public let inspect: @MainActor (String, String) async throws -> HostCoreReadinessReport
    public let setup: @MainActor (String, Bool, Bool) async throws -> HostCoreReadinessSetup
    public init(
        entries: @escaping @MainActor () -> [Entry],
        inspect: @escaping @MainActor (String, String) async throws -> HostCoreReadinessReport,
        setup: @escaping @MainActor (String, Bool, Bool) async throws -> HostCoreReadinessSetup
    ) {
        self.entries = entries; self.inspect = inspect; self.setup = setup
    }
}

@MainActor public struct HostCoreReadinessCLI {
    private let backend: HostCoreReadinessCLIBackend
    public init(backend: HostCoreReadinessCLIBackend) { self.backend = backend }
    public func execute(_ arguments: [String]) async throws -> ExtensionCLIReply {
        do { return try await perform(arguments) } catch let error as HostCoreCommandFailure {
            return try error.reply()
        }
    }

    private func perform(_ arguments: [String]) async throws -> ExtensionCLIReply {
        guard let command = arguments.first,
            ["status", "verify", "doctor", "setup"].contains(command)
        else { throw HostCLIError.usage("Unknown extension readiness command.") }
        let flags: Set<String> =
            command == "setup" ? ["--json", "--dry-run", "--install-tools"] : ["--json"]
        let args = try HostCLIArguments(Array(arguments.dropFirst()), flags: flags)
        try args.require(
            words: ["verify", "setup"].contains(command) ? 1...1 : 0...1, flags: flags)
        let entries = backend.entries()
        guard entries.count <= 39, Set(entries.map(\.id)).count == entries.count else {
            throw HostCLIError.rejected("Invalid extension readiness registry.")
        }
        let selected: [HostCoreReadinessCLIBackend.Entry]
        if let id = args.words.first {
            guard let entry = entries.first(where: { $0.id == id }) else {
                throw HostCoreCommandFailure(
                    "no extension named " + id,
                    hint: "known ids: " + entries.map(\.id).joined(separator: ", "), code: 3)
            }
            selected = [entry]
        } else {
            selected = entries
        }
        let json = args.flags.contains("--json")
        if command == "setup" {
            let dryRun = args.flags.contains("--dry-run")
            let installTools = args.flags.contains("--install-tools")
            let result = try await backend.setup(selected[0].id, dryRun, installTools)
            try result.validate(owner: selected[0].id, dryRun: dryRun, installTools: installTools)
            if json {
                return try HostCoreAgentCLI.json(
                    .object([
                        "id": .string(result.id), "dryRun": .bool(result.dryRun),
                        "changed": .bool(result.changed),
                        "plannedTools": .strings(result.plannedTools),
                        "installedTools": .strings(result.installedTools),
                        "installFailures": .array(
                            result.installFailures.map {
                                .object(["id": .string($0.id), "detail": .string($0.detail)])
                            }),
                        "report": try Self.json(result.report),
                    ]))
            }
            let message =
                dryRun
                ? "would enable " + result.id
                : result.changed ? result.id + " enabled" : result.id + " already enabled"
            return try ExtensionCLIReply(
                stdout: message + "\n" + Self.printReport(result.report),
                stderr: result.installFailures.map {
                    "could not install " + $0.id + ": " + $0.detail + "\n"
                }.joined(), exitCode: 0)
        }
        var reports: [HostCoreReadinessReport] = []
        for entry in selected {
            try Task.checkCancellation()
            let report = try await backend.inspect(entry.id, command)
            try report.validate(owner: entry.id)
            reports.append(report)
        }
        if json {
            let values = try reports.map(Self.json)
            return try HostCoreAgentCLI.json(args.words.isEmpty ? .array(values) : values[0])
        }
        if command == "status" {
            return try HostCLIOutput.text(
                HostCoreAgentCLI.table(
                    headers: ["ID", "READINESS", "RUNTIME", "DETAIL"],
                    rows: reports.map {
                        [
                            $0.id, $0.state.phase.title, $0.state.runtimePhase.title,
                            $0.state.summary,
                        ]
                    }))
        }
        return try ExtensionCLIReply(
            stdout: reports.map(Self.printReport).joined(), stderr: "", exitCode: 0)
    }

    static func json(_ report: HostCoreReadinessReport) throws -> HostCLIJSON {
        try report.validate(owner: report.id)
        let encoded = try JSONDecoder().decode(HostCLIJSON.self, from: JSONEncoder().encode(report))
        var fields = encoded.object!; fields.removeValue(forKey: "owner")
        if var state = fields["state"]?.object,
            let issues = state["issues"]?.array
        {
            state["issues"] = .array(
                issues.map { issue in
                    var fields = issue.object!;
                    fields["recoveryCommand"] = fields["recoveryCommand"] ?? .null
                    return .object(fields)
                });
            fields["state"] = .object(state)
        }
        fields["checks"] = .array(
            (fields["checks"]?.array ?? []).map { check in
                var value = check.object!;
                value["recoveryCommand"] = value["recoveryCommand"] ?? .null
                value["runtimePhase"] = value["runtimePhase"] ?? .null; return .object(value)
            })
        return .object(fields)
    }

    private static func printReport(_ report: HostCoreReadinessReport) -> String {
        var lines = [
            report.id + "  " + report.state.phase.title + "  " + report.state.runtimePhase.title
                + "  " + report.state.summary
        ]
        for check in report.checks {
            lines.append("  " + check.status.rawValue + "  " + check.title + ": " + check.detail)
            if let recovery = check.recoveryCommand { lines.append("    " + recovery) }
        }
        return lines.map { $0 + "\n" }.joined()
    }
}
