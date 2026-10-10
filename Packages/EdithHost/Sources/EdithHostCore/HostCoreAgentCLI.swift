import EdithExtensionSupport
import Foundation

public struct HostCoreCommandFailure: Error, LocalizedError, Sendable {
    public let message: String
    public let hint: String?
    public let code: Int32
    public var errorDescription: String? { message }
    public init(_ message: String, hint: String? = nil, code: Int32 = 4) {
        self.message = message; self.hint = hint; self.code = code
    }
    public func reply() throws -> ExtensionCLIReply {
        try ExtensionCLIReply(
            stdout: "",
            stderr: "error: " + message + "\n"
                + (hint.map { "hint: " + $0 + "\n" } ?? ""), exitCode: code)
    }
}

public struct HostCoreAgentCLIBackend {
    public var ownedJobs: @MainActor () -> Set<String>
    public var status: @MainActor () async throws -> HostCoreAgentStatus
    public var jobs: @MainActor () async throws -> [HostCoreJobSnapshot]
    public var restart: @MainActor () async throws -> Void
    public var logs: @MainActor (String) async throws -> [String]
    public var events: @MainActor () async throws -> [HostCoreAgentEvent]
    public var run: @MainActor (String) async throws -> Void
    public var cancel: @MainActor (String) async throws -> Void
    public init(
        ownedJobs: @escaping @MainActor () -> Set<String> = { [] },
        status: @escaping @MainActor () async throws -> HostCoreAgentStatus,
        jobs: @escaping @MainActor () async throws -> [HostCoreJobSnapshot],
        restart: @escaping @MainActor () async throws -> Void,
        logs: @escaping @MainActor (String) async throws -> [String],
        events: @escaping @MainActor () async throws -> [HostCoreAgentEvent],
        run: @escaping @MainActor (String) async throws -> Void,
        cancel: @escaping @MainActor (String) async throws -> Void
    ) {
        self.ownedJobs = ownedJobs
        self.status = status; self.jobs = jobs; self.restart = restart; self.logs = logs
        self.events = events; self.run = run; self.cancel = cancel
    }
}

@MainActor public struct HostCoreAgentCLI {
    private let backend: HostCoreAgentCLIBackend
    public init(backend: HostCoreAgentCLIBackend) { self.backend = backend }

    public func execute(_ arguments: [String]) async throws -> ExtensionCLIReply {
        do { return try await perform(arguments) } catch let error as HostCoreCommandFailure {
            return try error.reply()
        }
    }

    private func perform(_ arguments: [String]) async throws -> ExtensionCLIReply {
        let command = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "status"
        let remainder = command == arguments.first ? Array(arguments.dropFirst()) : arguments
        let args = try HostCLIArguments(
            remainder, flags: ["--json"],
            options: command == "logs" ? ["--last"] : [])
        try args.require(
            words: ["run", "cancel"].contains(command) ? 1...1 : 0...0,
            flags: ["--json"], options: command == "logs" ? ["--last"] : [])
        let json = args.flags.contains("--json")
        try Task.checkCancellation()
        switch command {
        case "status":
            let status = try await backend.status()
            if json {
                let value = try JSONDecoder().decode(
                    HostCLIJSON.self, from: JSONEncoder().encode(status))
                return try Self.json(value)
            }
            return try HostCLIOutput.text(
                Self.table(
                    headers: ["FIELD", "VALUE"],
                    rows: [
                        ["state", status.state == "enabled" ? "Enabled" : status.state],
                        ["build", status.build], ["pid", String(status.pid)],
                        ["uptime", Self.duration(Double(status.uptimeSeconds))],
                        [
                            "memory",
                            ByteCountFormatter.string(
                                fromByteCount: Int64(clamping: status.residentBytes),
                                countStyle: .memory),
                        ],
                        ["cpu", String(format: "%.1f%%", status.cpuPercent)],
                        ["subscribers", String(status.subscribers)], ["store", status.store],
                        ["schema", String(status.schemaVersion)],
                    ]))
        case "jobs":
            let jobs = try await backend.jobs()
            if json { return try Self.json(.array(jobs.map(Self.jobJSON))) }
            return try HostCLIOutput.text(
                Self.table(
                    headers: ["ID", "STATE", "TRIGGER", "CADENCE", "SUBS"],
                    rows: jobs.map {
                        [
                            $0.id, $0.phase.title, $0.descriptor.trigger.title,
                            Self.cadence($0), String($0.subscribers),
                        ]
                    }))
        case "restart":
            try await backend.restart()
            return try json
                ? Self.json(.object(["restarted": .bool(true)]))
                : HostCLIOutput.text("background agent restarting")
        case "logs":
            let last = args.options["--last"] ?? "1h"
            _ = try Self.logWindow(last)
            let lines = try await backend.logs(last)
            return try json ? Self.json(.strings(lines)) : Self.lines(lines)
        case "events":
            let events = try await backend.events()
            if json {
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                return try HostCLIOutput.text(
                    String(decoding: encoder.encode(events), as: UTF8.self))
            }
            return try Self.lines(events.map(Self.eventLine))
        case "run", "cancel":
            let job = args.words[0]
            if command == "run" {
                try await backend.run(job)
            } else {
                try await backend.cancel(job)
            }
            return try json
                ? Self.json(.object([command == "run" ? "queued" : "cancelled": .string(job)]))
                : HostCLIOutput.text(
                    command == "run" ? "queued \(job)" : "cancellation requested for \(job)")
        default: throw HostCLIError.usage("Unknown agent command.")
        }
    }

    public static func logWindow(_ value: String) throws -> TimeInterval {
        guard let unit = value.last,
            let scale = ["s": 1.0, "m": 60, "h": 3600, "d": 86400][String(unit)],
            let count = Double(value.dropLast()), count.isFinite, count > 0,
            value.dropLast().allSatisfy({ $0.isNumber }), count * scale <= 31_536_000
        else { throw HostCLIError.usage("--last requires a positive duration such as 10m or 1h.") }
        return count * scale
    }

    static func eventLine(_ event: HostCoreAgentEvent) -> String {
        "\(event.date.ISO8601Format()) [\(event.level.rawValue)] \(event.name): \(event.message)"
    }

    static func json(_ value: HostCLIJSON) throws -> ExtensionCLIReply {
        try HostCLIOutput.text(HostCoreCLIJSONFormatter.string(value))
    }

    static func lines(_ lines: [String]) throws -> ExtensionCLIReply {
        try ExtensionCLIReply(stdout: lines.map { $0 + "\n" }.joined(), stderr: "", exitCode: 0)
    }

    static func jobJSON(_ job: HostCoreJobSnapshot) -> HostCLIJSON {
        .object([
            "id": .string(job.id), "title": .string(job.descriptor.title),
            "trigger": .string(job.descriptor.trigger.rawValue),
            "topic": job.descriptor.topic.map(HostCLIJSON.string) ?? .null,
            "ambientSeconds": job.descriptor.cadence.ambient.map { .integer(Int64($0)) } ?? .null,
            "liveSeconds": job.descriptor.cadence.live.map { .integer(Int64($0)) } ?? .null,
            "power": .string(job.descriptor.power.rawValue), "phase": .string(job.phase.rawValue),
            "subscribers": .integer(Int64(job.subscribers)),
            "runCount": .integer(Int64(job.runCount)),
            "lastError": job.lastError.map(HostCLIJSON.string) ?? .null,
        ])
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        return "\(Int(seconds / 86400))d"
    }

    private static func cadence(_ job: HostCoreJobSnapshot) -> String {
        let ambient = job.descriptor.cadence.ambient.map(duration) ?? "on demand"
        return job.descriptor.cadence.live.map { "\(ambient), live \(duration($0))" } ?? ambient
    }

    static func table(headers: [String], rows: [[String]]) -> String {
        let clean: (String) -> String = { value in
            String(
                String.UnicodeScalarView(
                    value.unicodeScalars.compactMap { scalar in
                        if ["\n", "\r", "\t"].contains(scalar) { return " " }
                        return scalar.value >= 0x20 && scalar.value != 0x7f ? scalar : nil
                    }))
        }
        return HostCLIOutput.table(headers: headers.map(clean), rows: rows.map { $0.map(clean) })
    }
}
