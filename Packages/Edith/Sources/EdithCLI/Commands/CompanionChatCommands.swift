import ArgumentParser
import EdithKit
import Foundation

struct CompanionChatCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "chat", abstract: "Talk with the companion, streamed as it thinks.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "Continue this conversation id instead of starting fresh.")
    var conversation: String?

    @Option(name: .long, help: "Answer through this persona; `ed companion personas` lists them.")
    var persona: String?

    @Argument(help: "What to say.")
    var message: String

    func run() async throws {
        try await execute {
            let resolved = CLIEnvironment.resolveCompanionEndpoint(endpoint)
            let client = CompanionClient(baseURL: resolved)
            if let persona, let known = try? await client.personas(),
                !known.contains(where: { $0.id == persona })
            {
                throw CLIFailure.notFound(
                    "no persona called \(persona)",
                    hint: "personas: " + known.map(\.id).joined(separator: ", "))
            }
            var conversationId = conversation
            var model: String?
            var answer = ""
            var citations: [CompanionAskCitation] = []
            var latencyMs = 0
            var chunksConsidered = 0
            do {
                for try await event in client.chat(
                    message: message, conversationId: conversation, persona: persona)
                {
                    switch event {
                    case let .meta(id, activeModel):
                        conversationId = id
                        model = activeModel
                    case let .delta(delta):
                        answer += delta
                        if !json { CLIOut.raw(delta) }
                    case let .citations(found):
                        citations = found
                    case let .done(_, latency, chunks):
                        latencyMs = latency
                        chunksConsidered = chunks
                    case let .failure(detail):
                        if !json, !answer.isEmpty { CLIOut.raw("\n") }
                        throw CLIFailure.unavailable("the companion could not reply", hint: detail)
                    }
                }
            } catch let error as CompanionClientError {
                throw CompanionBridge.failure(error, endpoint: resolved)
            } catch let error as URLError {
                throw CompanionBridge.failure(
                    .unreachable(error.localizedDescription), endpoint: resolved)
            }
            guard !answer.isEmpty else {
                throw CLIFailure.unavailable(
                    "the companion sent no reply", hint: "check `ed companion doctor`")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "conversationId": .optional(conversationId),
                        "answer": .string(answer.trimmingCharacters(in: .whitespacesAndNewlines)),
                        "citations": .array(citations.map(CompanionBridge.citationJSON)),
                        "model": .optional(model),
                        "latencyMs": .int(latencyMs),
                        "chunksConsidered": .int(chunksConsidered),
                    ]))
                return
            }
            CLIOut.raw("\n")
            for (index, citation) in citations.enumerated() {
                let tag =
                    citation.support == "inference"
                    ? "reading between the lines" : citation.support
                CLIOut.out("[\(index + 1)] \(citation.title) (\(citation.occurredAt))  [\(tag)]")
            }
            if let conversationId {
                CLIOut.note("conversation \(conversationId); continue with --conversation")
            }
        }
    }
}

struct CompanionConversationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "conversations", abstract: "List chats, or replay one by id.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    @Argument(help: "A conversation id to replay in full.")
    var id: String?

    func run() async throws {
        try await execute {
            if let id {
                try await show(id)
                return
            }
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let conversations = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.conversations(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        conversations.map { conversation in
                            .object([
                                "id": .string(conversation.id),
                                "title": .string(conversation.title),
                                "createdAt": .string(conversation.createdAt),
                                "lastActiveAt": .string(conversation.lastActiveAt),
                                "messageCount": .int(conversation.messageCount),
                                "lastMessage": .optional(conversation.lastMessage),
                            ])
                        }))
                return
            }
            guard !conversations.isEmpty else {
                CLIOut.out("no conversations yet, start one with `ed companion chat`")
                return
            }
            let rows = conversations.enumerated().map { offset, conversation in
                [
                    String(offset + 1), conversation.title,
                    String(conversation.messageCount), conversation.lastActiveAt,
                    conversation.id,
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "TITLE", "MSGS", "LAST ACTIVE", "ID"], rows: rows))
        }
    }

    private func show(_ id: String) async throws {
        let detail = try await CompanionBridge.request(endpoint: endpoint) { client in
            try await client.conversation(id: id)
        }
        guard !json else {
            CLIOut.json(
                .object([
                    "id": .string(detail.id),
                    "title": .string(detail.title),
                    "createdAt": .string(detail.createdAt),
                    "messages": .array(
                        detail.messages.map { message in
                            .object([
                                "id": .string(message.id),
                                "role": .string(message.role),
                                "content": .string(message.content),
                                "citations": .array(
                                    (message.citations ?? []).map(CompanionBridge.citationJSON)),
                                "model": .optional(message.model),
                                "createdAt": .string(message.createdAt),
                            ])
                        }),
                ]))
            return
        }
        CLIOut.out("\(detail.title)  (\(detail.createdAt))")
        for message in detail.messages {
            let who = message.role == "user" ? "you" : "companion"
            CLIOut.out("")
            CLIOut.out("\(who): \(message.content)")
        }
    }
}

struct CompanionForgetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget", abstract: "Delete a conversation and its messages.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The conversation id to delete.")
    var id: String

    func run() async throws {
        try await execute {
            let deletion = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.deleteConversation(id: id)
            }
            guard !json else {
                CLIOut.json(.object(["deleted": .string(deletion.deleted)]))
                return
            }
            CLIOut.out("forgot conversation \(deletion.deleted)")
        }
    }
}

struct CompanionEpisodeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "episode", abstract: "Read one episode in full.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Print only the body text.")
    var body = false

    @Flag(name: .long, help: "Download the original file and open it with the default app.")
    var open = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The episode id.")
    var id: String

    func run() async throws {
        try await execute {
            let episode = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.episodeDetail(id: id)
            }
            if open {
                let (data, contentType) = try await CompanionBridge.request(endpoint: endpoint) {
                    client in
                    try await client.media(episodeId: id)
                }
                let url = try CompanionMedia.temporaryFile(
                    title: episode.title, contentType: contentType, data: data)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = [url.path]
                try process.run()
                guard !json else {
                    CLIOut.json(.object(["opened": .string(url.path)]))
                    return
                }
                CLIOut.out("opened \(url.path)")
                return
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "id": .string(episode.id),
                        "occurredAt": .string(episode.occurredAt),
                        "ingestedAt": .string(episode.ingestedAt),
                        "kind": .string(episode.kind),
                        "title": .string(episode.title),
                        "body": .optional(episode.body),
                        "bodyEn": .optional(episode.bodyEn),
                        "langs": .strings(episode.langs),
                        "durationS": episode.durationS.map { .double($0) } ?? .null,
                        "mediaRef": .optional(episode.mediaRef),
                        "sha256": .string(episode.sha256),
                        "bytes": .int(episode.bytes),
                        "chunks": .int(episode.chunks),
                    ]))
                return
            }
            if body {
                CLIOut.out(episode.body ?? "")
                return
            }
            CLIOut.out("\(episode.title)  [\(episode.kind)]  \(episode.occurredAt)")
            var meta = ["\(episode.chunks) chunks", "\(episode.bytes) bytes"]
            if let duration = episode.durationS, duration > 0 {
                meta.append(String(format: "%.0fs", duration))
            }
            if !episode.langs.isEmpty {
                meta.append(episode.langs.joined(separator: "+"))
            }
            CLIOut.out(meta.joined(separator: ", "))
            if let text = episode.body, !text.isEmpty {
                CLIOut.out("")
                CLIOut.out(text)
            }
        }
    }
}

struct CompanionNightlyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nightly", abstract: "Run the nightly learning pipeline right now.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let started = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.nightlyRun()
            }
            guard !json else {
                CLIOut.json(.object(["runId": .string(started.runId)]))
                return
            }
            CLIOut.out("pipeline finished, run \(started.runId); see `ed companion runs`")
        }
    }
}

struct CompanionReasonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reason", abstract: "Show or change how the companion reasons.",
        subcommands: [
            CompanionReasonShowCommand.self, CompanionReasonSetCommand.self,
            CompanionReasonTestCommand.self,
        ],
        defaultSubcommand: CompanionReasonShowCommand.self)
}

private func reasonSettingsJSON(_ settings: CompanionReasonSettings) -> JSONValue {
    .object([
        "provider": .string(settings.provider),
        "url": .string(settings.url),
        "model": .string(settings.model),
        "hasApiKey": .bool(settings.hasApiKey),
        "apiKeyHint": .string(settings.apiKeyHint),
        "configured": .bool(settings.configured),
        "description": .string(settings.description),
    ])
}

private func printReasonSettings(_ settings: CompanionReasonSettings) {
    CLIOut.out(
        TextTable.render(
            headers: ["FIELD", "VALUE"],
            rows: [
                ["provider", settings.provider],
                ["model", settings.model],
                ["url", settings.url.isEmpty ? "-" : settings.url],
                ["api key", settings.hasApiKey ? "set \(settings.apiKeyHint)" : "not set"],
                ["configured", settings.configured ? "yes" : "no"],
            ]))
}

struct CompanionReasonShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show the active reasoning provider.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let settings = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.reasonSettings()
            }
            guard !json else {
                CLIOut.json(reasonSettingsJSON(settings))
                return
            }
            printReasonSettings(settings)
        }
    }
}

struct CompanionReasonSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Change the reasoning provider, model, URL, or API key.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "anthropic or openai.")
    var provider: String?

    @Option(name: .long, help: "Model name, empty to reset to the default.")
    var model: String?

    @Option(name: .long, help: "OpenAI-compatible base URL.")
    var url: String?

    @Option(name: .long, help: "API key, stored on the companion; empty to clear.")
    var apiKey: String?

    func run() async throws {
        try await execute {
            if let provider, !["anthropic", "openai", ""].contains(provider) {
                throw CLIFailure.usage(
                    "--provider must be anthropic or openai")
            }
            guard provider != nil || model != nil || url != nil || apiKey != nil else {
                throw CLIFailure.usage(
                    "nothing to change",
                    hint: "pass at least one of --provider, --model, --url, --api-key")
            }
            let settings = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.updateReasonSettings(
                    provider: provider, url: url, model: model, apiKey: apiKey)
            }
            guard !json else {
                CLIOut.json(reasonSettingsJSON(settings))
                return
            }
            printReasonSettings(settings)
        }
    }
}

struct CompanionReasonTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test", abstract: "Round-trip one tiny completion through the reasoner.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.testReason()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "ok": .bool(outcome.ok),
                        "model": .string(outcome.model),
                        "latencyMs": .int(outcome.latencyMs),
                    ]))
                return
            }
            CLIOut.out("ok in \(outcome.latencyMs) ms  (\(outcome.model))")
        }
    }
}

extension CompanionBridge {
    static func citationJSON(_ citation: CompanionAskCitation) -> JSONValue {
        .object([
            "episodeId": .string(citation.episodeId),
            "quote": .string(citation.quote),
            "support": .string(citation.support),
            "title": .string(citation.title),
            "occurredAt": .string(citation.occurredAt),
        ])
    }
}
