import ArgumentParser
import EdithKit
import Foundation

struct CompanionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "companion",
        abstract: "The companion memory backend.",
        discussion: """
            Run `ed companion hosts` to inspect capable machines, `ed companion deploy`
            to install and remember the stack, and `ed companion stack` to control it.
            Edith creates and maintains the saved port forward for a remote deployment.

            Pass --endpoint or set EDITH_COMPANION_URL to use another backend. The
            default endpoint is http://127.0.0.1:4820.
            """,
        subcommands: [
            CompanionStatusCommand.self, CompanionDoctorCommand.self,
            CompanionSearchCommand.self, CompanionIndexCommand.self,
            CompanionIngestCommand.self, CompanionEpisodesCommand.self,
            CompanionEpisodeCommand.self, CompanionSyncCommand.self,
            CompanionObservationsCommand.self, CompanionReflectCommand.self,
            CompanionBeliefsCommand.self, CompanionAskCommand.self,
            CompanionChatCommand.self, CompanionConversationsCommand.self,
            CompanionForgetCommand.self, CompanionExtractCommand.self,
            CompanionClaimsCommand.self, CompanionCorroborateCommand.self,
            CompanionRunsCommand.self, CompanionNightlyCommand.self,
            CompanionReasonCommand.self, CompanionPersonasCommand.self,
            CompanionCouncilCommand.self, CompanionCoreCommand.self,
            CompanionWhyCommand.self, CompanionHypothesesCommand.self,
            CompanionPredictionsCommand.self, CompanionCommitmentsCommand.self,
            CompanionDiscrepanciesCommand.self, CompanionCalibrationCommand.self,
            CompanionInquireCommand.self, CompanionEntitiesCommand.self,
            CompanionLensesCommand.self, CompanionEvalCommand.self,
            CompanionStandupCommand.self, CompanionMachinesCommand.self,
            CompanionBaselinesCommand.self, CompanionConnectorsCommand.self,
            CompanionFactsCommand.self, CompanionForgetBeliefCommand.self,
            CompanionWeeklyCommand.self, CompanionDbCommand.self,
            CompanionHostsCommand.self, CompanionStackCommand.self,
            CompanionDeployCommand.self, CompanionExportCommand.self,
            CompanionImportCommand.self, CompanionEraseCommand.self,
            CompanionWipeCommand.self,
        ],
        defaultSubcommand: CompanionStatusCommand.self)
}

struct CompanionRunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runs", abstract: "List the background learning runs.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 10

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let runs = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.runs(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        runs.map { run in
                            .object([
                                "id": .string(run.id),
                                "startedAt": .string(run.startedAt),
                                "finishedAt": .optional(run.finishedAt),
                                "ok": .bool(run.ok),
                                "steps": .array(
                                    run.steps.map { step in
                                        .object([
                                            "name": .string(step.name),
                                            "ok": .bool(step.ok),
                                        ])
                                    }),
                            ])
                        }))
                return
            }
            guard !runs.isEmpty else {
                CLIOut.out("no runs yet, the scheduler fires nightly")
                return
            }
            for (index, run) in runs.enumerated() {
                let mark = run.ok ? "ok" : "failed"
                let steps = run.steps.map { "\($0.name)\($0.ok ? "" : "!")" }
                    .joined(separator: ", ")
                CLIOut.out("\(index + 1). \(run.startedAt)  \(mark)  \(steps)")
            }
        }
    }
}

struct CompanionExtractCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "extract", abstract: "Pull typed claims out of recent episodes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.extractClaims()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "episodesConsidered": .int(outcome.episodesConsidered),
                        "claimsExtracted": .int(outcome.claimsExtracted),
                    ]))
                return
            }
            CLIOut.out(
                "considered \(outcome.episodesConsidered) episodes, "
                    + "extracted \(outcome.claimsExtracted) claims")
        }
    }
}

struct CompanionClaimsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claims", abstract: "List the claims you have made, with verdicts.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let claims = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.claims(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        claims.map { claim in
                            .object([
                                "id": .string(claim.id),
                                "statement": .string(claim.statement),
                                "claimType": .string(claim.claimType),
                                "testable": .bool(claim.testable),
                                "assertedAt": .string(claim.assertedAt),
                                "verdict": .optional(claim.verdict),
                                "verdictNote": .optional(claim.verdictNote),
                            ])
                        }))
                return
            }
            guard !claims.isEmpty else {
                CLIOut.out("no claims yet, run `ed companion extract`")
                return
            }
            for (index, claim) in claims.enumerated() {
                let verdict = claim.verdict.map { " -> \($0)" } ?? ""
                CLIOut.out("\(index + 1). [\(claim.claimType)]\(verdict) \(claim.statement)")
                if let note = claim.verdictNote {
                    CLIOut.out("   \(note)")
                }
            }
        }
    }
}

struct CompanionCorroborateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "corroborate", abstract: "Check testable claims against the record.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.corroborate()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "claimsChecked": .int(outcome.claimsChecked),
                        "corroborated": .int(outcome.corroborated),
                        "contradicted": .int(outcome.contradicted),
                        "unclear": .int(outcome.unclear),
                    ]))
                return
            }
            CLIOut.out(
                "checked \(outcome.claimsChecked) claims: \(outcome.corroborated) corroborated, "
                    + "\(outcome.contradicted) contradicted, \(outcome.unclear) unclear")
        }
    }
}

struct CompanionAskCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ask", abstract: "Ask a question answered from your own memory.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "Which lens answers: analyst, friend, coach or skeptic.")
    var persona: String?

    @Argument(help: "The question to answer.")
    var question: String

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.askPersona(question: question, persona: persona)
            }
            guard !json else {
                CLIOut.json(CompanionBridge.askJSON(outcome))
                return
            }
            CompanionBridge.printAnswer(
                answer: outcome.answer, citations: outcome.citations,
                grounding: outcome.grounding, abstained: outcome.abstained,
                opinion: outcome.opinion)
        }
    }
}

struct CompanionReflectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reflect", abstract: "Distill fresh beliefs from recent episodes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.reflect()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "episodesConsidered": .int(outcome.episodesConsidered),
                        "beliefsFormed": .int(outcome.beliefsFormed),
                        "model": .string(outcome.model),
                    ]))
                return
            }
            CLIOut.out(
                "considered \(outcome.episodesConsidered) episodes, "
                    + "formed \(outcome.beliefsFormed) beliefs (\(outcome.model))")
        }
    }
}

struct CompanionBeliefsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "beliefs", abstract: "List what the companion believes about you.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let beliefs = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.beliefs(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        beliefs.map { belief in
                            .object([
                                "id": .string(belief.id),
                                "statement": .string(belief.statement),
                                "kind": .string(belief.kind),
                                "confidence": .double(belief.confidence),
                                "firstFormed": .string(belief.firstFormed),
                                "evidenceEpisodeIds": .strings(belief.evidenceEpisodeIds),
                                "status": .string(belief.status),
                            ])
                        }))
                return
            }
            guard !beliefs.isEmpty else {
                CLIOut.out("no beliefs yet, run `ed companion reflect`")
                return
            }
            for (index, belief) in beliefs.enumerated() {
                CLIOut.out(
                    "\(index + 1). [\(belief.kind), \(Int(belief.confidence * 100))%] "
                        + belief.statement)
                CLIOut.out(
                    "   evidence: \(belief.evidenceEpisodeIds.count) episodes, "
                        + "since \(belief.firstFormed)")
            }
        }
    }
}

struct CompanionSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync", abstract: "Pull a connector's activity into observations.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Flag(name: .long, help: "Reconcile every page rather than what changed since last time.")
    var full = false

    @Argument(help: "Connector to sync: github or notion.")
    var connector: String

    func run() async throws {
        try await execute {
            switch connector {
            case "github":
                let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                    try await client.syncGithub()
                }
                guard !json else {
                    CLIOut.json(
                        .object([
                            "eventsFetched": .int(outcome.eventsFetched),
                            "observationsInserted": .int(outcome.observationsInserted),
                        ]))
                    return
                }
                CLIOut.out(
                    "fetched \(outcome.eventsFetched) events, "
                        + "\(outcome.observationsInserted) new observations")
            case "notion":
                let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                    try await client.syncNotion(full: full)
                }
                guard !json else {
                    CLIOut.json(
                        .object([
                            "pagesSeen": .int(outcome.pagesSeen),
                            "pagesWritten": .int(outcome.pagesWritten),
                            "episodesIngested": .int(outcome.episodesIngested),
                            "watermark": .optional(outcome.watermark),
                            "fullScan": .bool(outcome.fullScan),
                        ]))
                    return
                }
                CLIOut.out(
                    "saw \(outcome.pagesSeen) pages, wrote \(outcome.pagesWritten), "
                        + "\(outcome.episodesIngested) new episodes")
            default:
                throw CLIFailure.usage(
                    "unknown connector \(connector)", hint: "the connectors are github and notion")
            }
        }
    }
}

struct CompanionObservationsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "observations", abstract: "List what the connectors saw you do.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    @Option(name: .long, help: "Only this observation kind.")
    var kind: String?

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let observations = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.observations(limit: limit, kind: kind)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        observations.map { observation in
                            .object([
                                "id": .string(observation.id),
                                "source": .string(observation.source),
                                "observedAt": .string(observation.observedAt),
                                "kind": .string(observation.kind),
                                "summary": .string(observation.summary),
                            ])
                        }))
                return
            }
            guard !observations.isEmpty else {
                CLIOut.out("no observations yet")
                return
            }
            let rows = observations.enumerated().map { index, observation in
                [
                    String(index + 1), observation.kind, observation.summary,
                    observation.observedAt,
                ]
            }
            CLIOut.raw(TextTable.render(headers: ["#", "KIND", "SUMMARY", "OBSERVED"], rows: rows))
        }
    }
}

enum CompanionBridge {
    static func request<T>(
        endpoint: String?, operation: (CompanionClient) async throws -> T
    ) async throws -> T {
        let resolved = CLIEnvironment.resolveCompanionEndpoint(endpoint)
        do {
            return try await operation(CompanionClient(baseURL: resolved))
        } catch let error as CompanionClientError {
            throw failure(error, endpoint: resolved)
        }
    }

    static func failure(_ error: CompanionClientError, endpoint: URL) -> CLIFailure {
        switch error {
        case let .unreachable(detail):
            return CLIFailure.unavailable(
                "the companion backend at \(endpoint.absoluteString) is unavailable",
                hint: "\(detail); start the stack on the machine that hosts it, or point at "
                    + "another endpoint with --endpoint or EDITH_COMPANION_URL")
        case let .badResponse(status, detail):
            return CLIFailure(
                "the companion returned HTTP \(status)",
                hint: detail.isEmpty ? nil : detail)
        }
    }

    static func embeddingRequest<T>(
        endpoint: String?, operation: (CompanionClient) async throws -> T
    ) async throws -> T {
        let resolved = CLIEnvironment.resolveCompanionEndpoint(endpoint)
        do {
            return try await operation(CompanionClient(baseURL: resolved))
        } catch let CompanionClientError.badResponse(status, detail) where status == 502 {
            throw CLIFailure.unavailable(
                "the Ollama embedding service is unavailable",
                hint: detail.isEmpty ? "check the Ollama service and embedding model" : detail)
        } catch let error as CompanionClientError {
            throw failure(error, endpoint: resolved)
        }
    }

    static func statusJSON(_ status: CompanionStatus) -> JSONValue {
        .object([
            "sources": .int(status.sources),
            "episodes": .int(status.episodes),
            "claims": .int(status.claims),
            "observations": .int(status.observations),
            "chunks": .int(status.chunks),
            "pendingEpisodes": .int(status.pendingEpisodes),
            "latestIngestedAt": .optional(status.latestIngestedAt),
        ])
    }

    static func searchJSON(_ hit: CompanionSearchHit) -> JSONValue {
        .object([
            "chunkId": .string(hit.chunkId),
            "episodeId": .string(hit.episodeId),
            "ord": .int(hit.ord),
            "title": .string(hit.title),
            "occurredAt": .string(hit.occurredAt),
            "kind": .string(hit.kind),
            "snippet": .string(hit.snippet),
            "score": .double(hit.score),
        ])
    }

    static func indexJSON(_ outcome: CompanionIndexOutcome) -> JSONValue {
        .object([
            "episodesIndexed": .int(outcome.episodesIndexed),
            "chunksCreated": .int(outcome.chunksCreated),
        ])
    }

    static func outcomeJSON(_ outcome: CompanionIngestOutcome) -> JSONValue {
        .object([
            "name": .string(outcome.name),
            "status": .string(outcome.status),
            "episodeId": .string(outcome.episodeId),
            "occurredAt": .string(outcome.occurredAt),
        ])
    }

    static func episodeJSON(_ episode: CompanionEpisode) -> JSONValue {
        .object([
            "id": .string(episode.id),
            "occurredAt": .string(episode.occurredAt),
            "kind": .string(episode.kind),
            "title": .string(episode.title),
            "sha256": .string(episode.sha256),
        ])
    }
}

struct CompanionStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Count what the companion remembers.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let status = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.status()
            }
            guard !json else {
                CLIOut.json(CompanionBridge.statusJSON(status))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["RESOURCE", "COUNT"],
                    rows: [
                        ["sources", String(status.sources)],
                        ["episodes", String(status.episodes)],
                        ["claims", String(status.claims)],
                        ["observations", String(status.observations)],
                        ["chunks", String(status.chunks)],
                        ["pending episodes", String(status.pendingEpisodes)],
                    ]))
            if let latest = status.latestIngestedAt { CLIOut.out("latest  \(latest)") }
        }
    }
}

struct CompanionSearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "Search companion memory with hybrid retrieval.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many hits.")
    var limit = 8

    @Argument(help: "What to look for.")
    var query: String

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            guard limit <= 50 else {
                throw CLIFailure.usage("--limit must be 50 or less")
            }
            let hits = try await CompanionBridge.embeddingRequest(endpoint: endpoint) { client in
                try await client.search(query: query, k: limit)
            }
            guard !json else {
                CLIOut.json(.array(hits.map(CompanionBridge.searchJSON)))
                return
            }
            guard !hits.isEmpty else {
                CLIOut.out("no matches")
                return
            }
            let rows = hits.enumerated().map { offset, hit in
                [
                    String(offset + 1), String(format: "%.6f", hit.score), hit.title,
                    hit.occurredAt,
                ]
            }
            CLIOut.out(
                TextTable.render(headers: ["#", "SCORE", "TITLE", "OCCURRED"], rows: rows))
            for (offset, hit) in hits.enumerated() {
                CLIOut.out("  \(offset + 1)  \(TextTable.oneLine(hit.snippet))")
            }
        }
    }
}

struct CompanionIndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index", abstract: "Embed pending companion episodes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.embeddingRequest(endpoint: endpoint) { client in
                try await client.index()
            }
            guard !json else {
                CLIOut.json(CompanionBridge.indexJSON(outcome))
                return
            }
            CLIOut.out(
                "indexed \(outcome.episodesIndexed) episodes into \(outcome.chunksCreated) chunks")
        }
    }
}

struct CompanionDoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check the companion's dependencies.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let health = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.health()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "ok": .bool(health.ok),
                        "degraded": .bool(health.degraded ?? !health.failing.isEmpty),
                        "checks": .array(
                            health.checks.map { check in
                                .object([
                                    "name": .string(check.name),
                                    "ok": .bool(check.ok),
                                    "severity": .string(check.severityKind.rawValue),
                                    "detail": .string(check.detail),
                                ])
                            }),
                    ]))
                return
            }
            for check in health.checks {
                let state = check.ok ? "ok" : check.severityKind == .blocker ? "FAIL" : "off"
                CLIOut.out("\(check.name)  \(state)  \(TextTable.oneLine(check.detail))")
            }
            let blocking = health.blocking
            if !blocking.isEmpty {
                CLIOut.note(
                    "\(blocking.count) blocking: "
                        + blocking.map(\.name).joined(separator: ", "))
            }
        }
    }
}

struct CompanionIngestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ingest",
        abstract: "Ingest notes, recordings, photos, video and PDFs as episodes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(
        help: "A note, recording, photo, video or PDF, or a folder of them.",
        completion: .file())
    var path: String

    func run() async throws {
        try await execute {
            let url = URL(fileURLWithPath: path.expandingTilde())
            let scan: CompanionScanResult
            let audioScan: CompanionAudioScanResult
            let pdfScan: CompanionAudioScanResult
            let imageScan: CompanionAudioScanResult
            let videoScan: CompanionAudioScanResult
            do {
                scan = try CompanionScan.markdownFiles(at: url)
                audioScan = try CompanionScan.audioFiles(at: url)
                pdfScan = try CompanionScan.pdfFiles(at: url)
                imageScan = try CompanionScan.imageFiles(at: url)
                videoScan = try CompanionScan.videoFiles(at: url)
            } catch {
                throw CLIFailure.usage(
                    "could not scan \(url.path)", hint: error.localizedDescription)
            }
            for name in scan.skipped {
                CLIOut.note("skipped \(name): larger than 2MB")
            }
            for name in audioScan.skipped + pdfScan.skipped + imageScan.skipped {
                CLIOut.note("skipped \(name): larger than 48MB")
            }
            for name in videoScan.skipped {
                CLIOut.note("skipped \(name): larger than 768MB")
            }
            let binaryCount =
                audioScan.files.count + pdfScan.files.count + imageScan.files.count
                + videoScan.files.count
            guard !scan.files.isEmpty || binaryCount > 0 else {
                throw CLIFailure.usage(
                    "nothing ingestable found at \(url.path)",
                    hint: "pass a note, recording, photo, video or PDF, or a folder of them")
            }
            var outcomes: [CompanionIngestOutcome] = []
            for start in stride(from: 0, to: scan.files.count, by: 200) {
                let end = min(start + 200, scan.files.count)
                let batch = Array(scan.files[start..<end])
                let added = try await CompanionBridge.request(endpoint: endpoint) { client in
                    try await client.ingest(files: batch)
                }
                outcomes.append(contentsOf: added)
            }
            for file in audioScan.files {
                let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                    try await client.ingestAudio(
                        name: file.name, data: file.data, mtime: file.mtime)
                }
                outcomes.append(outcome)
            }
            for file in pdfScan.files {
                let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                    try await client.ingestPdf(
                        name: file.name, data: file.data, mtime: file.mtime)
                }
                outcomes.append(outcome)
            }
            for file in imageScan.files {
                let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                    try await client.ingestImage(
                        name: file.name, data: file.data, mtime: file.mtime)
                }
                outcomes.append(outcome)
            }
            for file in videoScan.files {
                let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                    try await client.ingestVideo(
                        name: file.name, data: file.data, mtime: file.mtime)
                }
                outcomes.append(outcome)
            }
            let skippedCount =
                scan.skipped.count + audioScan.skipped.count + pdfScan.skipped.count
                + imageScan.skipped.count + videoScan.skipped.count
            let ingested = outcomes.filter { $0.status == "ingested" }.count
            let duplicates = outcomes.filter { $0.status == "duplicate" }.count
            guard !json else {
                CLIOut.json(
                    .object([
                        "ingested": .int(ingested),
                        "duplicates": .int(duplicates),
                        "skipped": .int(skippedCount),
                        "results": .array(outcomes.map(CompanionBridge.outcomeJSON)),
                    ]))
                return
            }
            for outcome in outcomes {
                CLIOut.out("\(outcome.status)  \(outcome.name)")
            }
            CLIOut.out(
                "\(ingested) ingested, \(duplicates) duplicates, \(skippedCount) skipped")
        }
    }
}

struct CompanionEpisodesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "episodes", abstract: "List recent companion episodes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let episodes = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.episodes(limit: limit)
            }
            guard !json else {
                CLIOut.json(.array(episodes.map(CompanionBridge.episodeJSON)))
                return
            }
            let rows = episodes.enumerated().map { offset, episode in
                [String(offset + 1), episode.title, episode.kind, episode.occurredAt]
            }
            CLIOut.out(
                TextTable.render(headers: ["#", "TITLE", "KIND", "OCCURRED"], rows: rows))
        }
    }
}
