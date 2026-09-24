import ArgumentParser
import EdithKit
import Foundation

struct UsageAttributionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attribution",
        abstract: "How unknown and non-GitHub folders were matched to repositories.",
        subcommands: [UsageAttributionListCommand.self, UsageAttributionResetCommand.self],
        defaultSubcommand: UsageAttributionListCommand.self)

    static func json(key: String, _ decision: UsageAttributionDecision) -> JSONValue {
        .object([
            "key": .string(key),
            "scope": .string(key.hasPrefix("chat|") ? "chat" : "folder"),
            "folder": .string(decision.folder),
            "machine": .optional(decision.machine),
            "title": .optional(decision.title),
            "repositoryID": .optional(decision.repository?.id),
            "repositoryName": .optional(decision.repository?.name),
            "method": .string(decision.method.rawValue),
            "confidence": decision.confidence.map(JSONValue.double) ?? .null,
            "decidedAt": .string(ISO8601DateFormatter().string(from: decision.decidedAt)),
        ])
    }
}

struct UsageAttributionListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: UsageAttributionOperation.list.descriptor.summary)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let decisions = UsageAttributionCache.load().decisions
            let keys = decisions.keys.sorted()
            guard !json else {
                CLIOut.json(
                    .array(
                        keys.compactMap { key in
                            decisions[key].map { UsageAttributionCommand.json(key: key, $0) }
                        }))
                return
            }
            guard !keys.isEmpty else {
                CLIOut.note("no attribution decisions yet; they are made after a usage refresh")
                return
            }
            let rows = keys.compactMap { key -> [String]? in
                guard let decision = decisions[key] else { return nil }
                return [
                    key.hasPrefix("chat|") ? "chat" : "folder", decision.folder,
                    decision.machine ?? "-", decision.title ?? "-",
                    decision.repository?.id ?? "none", decision.method.rawValue,
                    decision.confidence.map { String(format: "%.2f", $0) } ?? "-",
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: [
                        "SCOPE", "FOLDER", "MACHINE", "TITLE", "REPOSITORY", "BY", "CONFIDENCE",
                    ],
                    rows: rows))
        }
    }
}

struct UsageAttributionResetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset", abstract: UsageAttributionOperation.reset.descriptor.summary)

    @Flag(name: .long, help: "Confirm forgetting every decision.")
    var yes = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let count = UsageAttributionCache.load().decisions.count
            if yes { try UsageAttributionCache.reset() }
            guard !json else {
                CLIOut.json(.object(["applied": .bool(yes), "decisions": .int(count)]))
                return
            }
            guard yes else {
                CLIOut.note("would forget \(count) decisions; pass --yes to clear them")
                return
            }
            CLIOut.out("forgot \(count) decisions; the next usage refresh attributes folders again")
        }
    }
}
