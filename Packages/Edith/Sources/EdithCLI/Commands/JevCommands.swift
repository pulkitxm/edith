import ArgumentParser
import EdithKit
import Foundation

struct JevCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jev",
        abstract: "The TypeSafe Jev decision model behind Edith's smart features.",
        subcommands: [JevStatusCommand.self, JevKeyCommand.self, JevAskCommand.self],
        defaultSubcommand: JevStatusCommand.self)
}

enum JevCLI {
    static func run<Value>(_ body: (AgentJevDecider) async throws -> Value) async throws -> Value {
        do {
            return try await body(AgentJevDecider())
        } catch let error as JevError {
            throw failure(error)
        } catch let error as AgentError {
            throw CLIFailure.unavailable("background agent", hint: error.message)
        }
    }

    static func failure(_ error: JevError) -> CLIFailure {
        switch error {
        case .missingKey, .unauthorized:
            return CLIFailure(
                .unavailable, error.localizedDescription,
                hint: "add the key in Settings > Jev or run `ed jev key set`")
        case .noCredits:
            return CLIFailure(
                .unavailable, error.localizedDescription,
                hint: "add credits at https://console.typesafe.ai/settings/billing")
        case .invalidRequest, .rejected:
            return CLIFailure.usage(error.localizedDescription)
        default:
            return CLIFailure(.unavailable, error.localizedDescription)
        }
    }

    static func statusJSON(_ status: JevStatus) -> JSONValue {
        var fields: [String: JSONValue] = [
            "state": .string(status.state.rawValue),
            "configured": .bool(status.isConfigured),
            "models": .array(status.models.map(JSONValue.string)),
            "decisions": .int(status.decisions),
        ]
        if let hint = status.keyHint { fields["key"] = .string(hint) }
        if let message = status.message { fields["message"] = .string(message) }
        if let median = status.medianMilliseconds { fields["medianMs"] = .int(median) }
        return .object(fields)
    }

    static func answersJSON(_ decision: JevDecision) -> JSONValue {
        .object(
            decision.response.answers.mapValues { answer in
                var fields: [String: JSONValue] = ["type": .string(answer.type)]
                if let noul = answer.noul { fields["noul"] = .double(noul) }
                if let choice = answer.choice { fields["choice"] = .string(choice) }
                if let score = answer.score { fields["score"] = .double(score) }
                if let confidence = answer.confidence { fields["confidence"] = .double(confidence) }
                if let probabilities = answer.probabilities {
                    fields["probabilities"] = .object(probabilities.mapValues(JSONValue.double))
                }
                return .object(fields)
            })
    }
}

struct JevStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract:
            "Show whether a Jev key is set, which models it reaches and whether it has credits.")

    @Flag(name: .long, help: "Send one tiny decision to confirm the key works and has credits.")
    var probe = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = try await JevCLI.run { try await $0.status(probe: probe) }
            guard !json else {
                CLIOut.json(JevCLI.statusJSON(status))
                return
            }
            var rows = [["state", status.summary], ["key", status.keyHint ?? "not set"]]
            if !status.models.isEmpty {
                rows.append(["models", status.models.joined(separator: ", ")])
            }
            rows.append(["decisions", String(status.decisions)])
            if let median = status.medianMilliseconds { rows.append(["median", "\(median) ms"]) }
            if let message = status.message { rows.append(["message", message]) }
            CLIOut.out(TextTable.render(headers: ["FIELD", "VALUE"], rows: rows))
        }
    }
}

struct JevKeyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key", abstract: "Set or remove the TypeSafe API key Edith uses for Jev.",
        subcommands: [JevKeyShowCommand.self, JevKeySetCommand.self, JevKeyClearCommand.self],
        defaultSubcommand: JevKeyShowCommand.self)
}

struct JevKeyShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show whether a key is saved and how it ends, never the key."
    )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let status = try await JevCLI.run { try await $0.status(probe: false) }
            guard !json else {
                var fields: [String: JSONValue] = ["configured": .bool(status.isConfigured)]
                if let hint = status.keyHint { fields["key"] = .string(hint) }
                CLIOut.json(.object(fields))
                return
            }
            CLIOut.out(status.keyHint.map { "saved, \($0)" } ?? "not set")
        }
    }
}

struct JevKeySetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set",
        abstract: "Read a TypeSafe API key from stdin, keep it in the Keychain and check it.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let key = String(
                decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw CLIFailure.usage(
                    "stdin was empty", hint: "printf %s \"$KEY\" | ed jev key set")
            }
            let status = try await JevCLI.run { try await $0.setKey(key) }
            guard !json else {
                CLIOut.json(JevCLI.statusJSON(status))
                return
            }
            CLIOut.out("stored, \(status.keyHint ?? "set"), \(status.summary.lowercased())")
            if let message = status.message { CLIOut.note(message) }
        }
    }
}

struct JevKeyClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Remove the TypeSafe API key, which turns every Jev feature off.")

    @Flag(name: .long, help: "Confirm the removal.")
    var yes = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard yes else {
                guard !json else {
                    CLIOut.json(.object(["applied": .bool(false)]))
                    return
                }
                CLIOut.note("pass --yes to remove the key and turn Jev off")
                return
            }
            let status = try await JevCLI.run { try await $0.setKey(nil) }
            guard !json else {
                CLIOut.json(JevCLI.statusJSON(status))
                return
            }
            CLIOut.out("removed, Jev is off")
        }
    }
}

struct JevAskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask",
        abstract: "Send a raw System One request (state plus questions) through Edith.",
        discussion: """
            Reads a request document from --request or stdin:
            {"state": {...} | "text", "questions": {"name": {"type": "noul"|"choice"|"score", ...}}}
            """)

    @Option(help: "A JSON request file, or - for stdin.")
    var request: String = "-"

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let data =
                request == "-"
                ? FileHandle.standardInput.readDataToEndOfFile()
                : try Data(contentsOf: URL(fileURLWithPath: request))
            let parsed = try Self.parse(data)
            let decision = try await JevCLI.run { try await $0.decide(parsed, purpose: "cli.ask") }
            guard !json else {
                CLIOut.json(
                    .object([
                        "answers": JevCLI.answersJSON(decision),
                        "latencyMs": .int(decision.milliseconds),
                    ]))
                return
            }
            for (name, answer) in decision.response.answers.sorted(by: { $0.key < $1.key }) {
                let value =
                    answer.choice.map { "\($0) (\(Int((answer.chosenProbability ?? 0) * 100))%)" }
                    ?? answer.noul.map { String(format: "%.3f", $0) }
                    ?? answer.score.map { String(format: "%.2f", $0) } ?? "-"
                CLIOut.out("\(name)  \(value)")
            }
            CLIOut.note("\(decision.milliseconds) ms")
        }
    }

    static func parse(_ data: Data) throws -> JevRequest {
        do {
            return try JSONDecoder().decode(JevRequest.self, from: Self.withDefaultModel(data))
                .validated()
        } catch let error as JevError {
            throw CLIFailure.usage(error.localizedDescription)
        } catch {
            throw CLIFailure.usage(
                "the request needs a state and questions of type noul, choice or score")
        }
    }

    static func withDefaultModel(_ data: Data) -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["model"] == nil
        else { return data }
        object["model"] = JevRequest.defaultModel
        return (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
}
