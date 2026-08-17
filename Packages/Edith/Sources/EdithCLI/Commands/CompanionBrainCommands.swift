import ArgumentParser
import EdithKit
import Foundation

extension CompanionBridge {
    static func askJSON(_ outcome: CompanionAskOutcome) -> JSONValue {
        .object([
            "answer": .string(outcome.answer),
            "persona": .string(outcome.persona),
            "abstained": .bool(outcome.abstained),
            "grounding": .object([
                "score": .double(outcome.grounding.score),
                "scorer": .string(outcome.grounding.scorer),
                "unsupported": .array(outcome.grounding.unsupported.map(JSONValue.string)),
            ]),
            "reframed": .optional(outcome.reframed),
            "opinion": .optional(outcome.opinion),
            "stages": .array(outcome.stages.map(JSONValue.string)),
            "citations": .array(outcome.citations.map(citationJSON)),
            "chunksConsidered": .int(outcome.chunksConsidered),
            "model": .string(outcome.model),
        ])
    }

    static func printAnswer(
        answer: String, citations: [CompanionAskCitation], grounding: CompanionGrounding,
        abstained: Bool, opinion: String?
    ) {
        CLIOut.out(answer)
        for (index, citation) in citations.enumerated() {
            let tag =
                citation.support == "inference" ? "reading between the lines" : citation.support
            CLIOut.out("[\(index + 1)] \(citation.title) (\(citation.occurredAt))  [\(tag)]")
            if !citation.quote.isEmpty, citation.support != "inference" {
                CLIOut.out("    \u{201C}\(citation.quote)\u{201D}")
            }
        }
        if let opinion, !opinion.isEmpty {
            CLIOut.out("")
            CLIOut.out("what it thinks: \(opinion)")
        }
        let score = String(format: "%.2f", grounding.score)
        CLIOut.note(
            abstained
                ? "it declined to answer; grounding \(score) by \(grounding.scorer)"
                : "grounding \(score) by \(grounding.scorer)")
    }
}

struct CompanionPersonasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "personas", abstract: "List the lenses that can answer, and how each thinks.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let personas = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.personas()
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        personas.map { persona in
                            .object([
                                "id": .string(persona.id),
                                "label": .string(persona.label),
                                "pipeline": .array(persona.pipeline.map(JSONValue.string)),
                                "output": .string(persona.output),
                                "abstainBelow": .double(persona.abstainBelow),
                                "maxWords": .int(persona.maxWords),
                                "selfReportWeight": .double(persona.evidence.selfReportWeight),
                                "observationWeight": .double(
                                    persona.evidence.observationWeight),
                                "k": .int(persona.retrieval.k),
                                "windowDays": .optional(
                                    persona.retrieval.windowDays.map(String.init)),
                            ])
                        }))
                return
            }
            for persona in personas {
                CLIOut.out("\(persona.label) (\(persona.id))")
                CLIOut.out(
                    "    reads \(persona.retrieval.k) results, self-report weighted "
                        + "\(persona.evidence.selfReportWeight), observation "
                        + "\(persona.evidence.observationWeight)")
                CLIOut.out("    runs \(persona.pipeline.joined(separator: " -> "))")
                CLIOut.out(
                    "    answers as \(persona.output), at most \(persona.maxWords) words, "
                        + "abstains below \(persona.abstainBelow)")
            }
        }
    }
}

struct CompanionCouncilCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "council",
        abstract: "Ask several lenses at once and find the crux they disagree on.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "Comma separated lenses; the default is analyst, coach, skeptic.")
    var personas: String?

    @Argument(help: "The question worth three opinions.")
    var question: String

    func run() async throws {
        try await execute {
            let wanted =
                personas?.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                } ?? []
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.council(question: question, personas: wanted)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "question": .string(outcome.question),
                        "agreement": .string(outcome.agreement),
                        "divergence": .string(outcome.divergence),
                        "crux": .string(outcome.crux),
                        "cruxQuestion": .string(outcome.cruxQuestion),
                        "model": .string(outcome.model),
                        "answers": .array(
                            outcome.answers.map { answer in
                                .object([
                                    "persona": .string(answer.persona),
                                    "label": .string(answer.label),
                                    "answer": .string(answer.answer),
                                    "abstained": .bool(answer.abstained),
                                    "grounding": .double(answer.grounding.score),
                                    "citations": .array(
                                        answer.citations.map(CompanionBridge.citationJSON)),
                                ])
                            }),
                    ]))
                return
            }
            for answer in outcome.answers {
                CLIOut.out("\(answer.label)")
                CLIOut.out("    \(answer.answer)")
                CLIOut.out("")
            }
            CLIOut.out("where they agree:    \(outcome.agreement)")
            CLIOut.out("where they diverge:  \(outcome.divergence)")
            CLIOut.out("the crux:            \(outcome.crux)")
            if !outcome.cruxQuestion.isEmpty {
                CLIOut.out("worth finding out:   \(outcome.cruxQuestion)")
            }
        }
    }
}

struct CompanionCoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "core",
        abstract: "Read or edit the standing summary of who you are.",
        subcommands: [CompanionCoreShowCommand.self, CompanionCoreSetCommand.self],
        defaultSubcommand: CompanionCoreShowCommand.self)
}

struct CompanionCoreShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Print the standing summary section by section.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let sections = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.core()
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        sections.map { section in
                            .object([
                                "section": .string(section.section),
                                "content": .string(section.content),
                                "tokens": .int(section.tokens),
                                "updatedAt": .string(section.updatedAt),
                                "updatedBy": .string(section.updatedBy),
                            ])
                        }))
                return
            }
            guard !sections.isEmpty else {
                CLIOut.out("the standing summary is empty; it gets written on the nightly run")
                return
            }
            for section in sections {
                CLIOut.out("\(section.section.replacingOccurrences(of: "_", with: " "))")
                CLIOut.out("    \(section.content)")
                CLIOut.note("    \(section.tokens) tokens, by \(section.updatedBy)")
            }
        }
    }
}

struct CompanionCoreSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Rewrite one section of the standing summary yourself.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(
        help:
            "identity, current_situation, values, open_threads, relationships or communication_style"
    )
    var section: String

    @Argument(help: "What the section should say.")
    var content: String

    func run() async throws {
        try await execute {
            _ = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.writeCore(section: section, content: content)
            }
            guard !json else {
                CLIOut.json(.object(["section": .string(section), "ok": .bool(true)]))
                return
            }
            CLIOut.out("rewrote \(section)")
        }
    }
}

struct CompanionWhyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "why",
        abstract: "Print the whole chain behind a belief, theory or claim.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The id of a belief, hypothesis or claim.")
    var id: String

    func run() async throws {
        try await execute {
            let chain = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.why(id: id)
            }
            guard !json else {
                CLIOut.json(CompanionBrainOutput.chainJSON(chain))
                return
            }
            CLIOut.out("\(chain.kind): \(chain.statement)")
            if let mechanism = chain.mechanism {
                CLIOut.out("because: \(mechanism)")
            }
            if let alternatives = chain.alternatives, !alternatives.isEmpty {
                CLIOut.out("it could also be:")
                for alternative in alternatives {
                    CLIOut.out("    \(alternative)")
                }
            }
            if let confidence = chain.confidence, let stability = chain.stability {
                CLIOut.out(
                    "confidence \(String(format: "%.2f", confidence)), revised "
                        + "\(Int(stability)) times, \(chain.corroboration ?? "unknown") support")
            }
            if let prior = chain.prior, let posterior = chain.posterior {
                CLIOut.out(
                    "started at \(String(format: "%.2f", prior)), now at "
                        + "\(String(format: "%.2f", posterior))")
            }
            CompanionBrainOutput.printEpisodes("it rests on", chain.evidence)
            CompanionBrainOutput.printEpisodes("what argues against it", chain.counterEvidence)
            CompanionBrainOutput.printEpisodes("said in", chain.episode)
            if let revisions = chain.revisions, !revisions.isEmpty {
                CLIOut.out("how it moved:")
                for revision in revisions {
                    CLIOut.out(
                        "    \(revision.at)  \(String(format: "%.2f", revision.posterior))  "
                            + "\(revision.status)  \(revision.note)")
                }
            }
            if let verdicts = chain.verdicts, !verdicts.isEmpty {
                CLIOut.out("checked against the record:")
                for verdict in verdicts {
                    CLIOut.out("    \(verdict.at)  \(verdict.verdict)  \(verdict.note)")
                }
            }
            if let version = chain.promptVersion {
                CLIOut.note("written by prompt \(version)")
            }
        }
    }
}

enum CompanionBrainOutput {
    static func printEpisodes(_ label: String, _ episodes: [MemoryChainEpisode]?) {
        guard let episodes, !episodes.isEmpty else { return }
        CLIOut.out("\(label):")
        for episode in episodes {
            CLIOut.out("    \(episode.occurredAt)  \(episode.kind)  \(episode.episodeId)")
            CLIOut.out("        \(episode.excerpt.prefix(160))")
        }
    }

    static func episodesJSON(_ episodes: [MemoryChainEpisode]?) -> JSONValue {
        .array(
            (episodes ?? []).map { episode in
                .object([
                    "episodeId": .string(episode.episodeId),
                    "occurredAt": .string(episode.occurredAt),
                    "kind": .string(episode.kind),
                    "excerpt": .string(episode.excerpt),
                ])
            })
    }

    static func chainJSON(_ chain: MemoryChain) -> JSONValue {
        .object([
            "kind": .string(chain.kind),
            "id": .string(chain.id),
            "statement": .string(chain.statement),
            "status": .optional(chain.status),
            "confidence": .optional(chain.confidence.map { String(format: "%.4f", $0) }),
            "stability": .optional(chain.stability.map { String(format: "%.4f", $0) }),
            "corroboration": .optional(chain.corroboration),
            "promptVersion": .optional(chain.promptVersion),
            "mechanism": .optional(chain.mechanism),
            "prior": .optional(chain.prior.map { String(format: "%.4f", $0) }),
            "posterior": .optional(chain.posterior.map { String(format: "%.4f", $0) }),
            "alternatives": .array((chain.alternatives ?? []).map(JSONValue.string)),
            "evidence": episodesJSON(chain.evidence),
            "counterEvidence": episodesJSON(chain.counterEvidence),
            "episode": episodesJSON(chain.episode),
            "revisions": .array(
                (chain.revisions ?? []).map { revision in
                    .object([
                        "at": .string(revision.at),
                        "posterior": .double(revision.posterior),
                        "status": .string(revision.status),
                        "note": .string(revision.note),
                    ])
                }),
            "verdicts": .array(
                (chain.verdicts ?? []).map { verdict in
                    .object([
                        "verdict": .string(verdict.verdict),
                        "note": .string(verdict.note),
                        "at": .string(verdict.at),
                    ])
                }),
        ])
    }
}

struct CompanionHypothesesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hypotheses",
        abstract: "The theories it holds about you, and how they are faring.",
        subcommands: [CompanionHypothesesListCommand.self, CompanionHypothesesRunCommand.self],
        defaultSubcommand: CompanionHypothesesListCommand.self)
}

struct CompanionHypothesesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List the theories it holds about you, and how they are faring.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.hypotheses(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "id": .string(row.id),
                                "statement": .string(row.statement),
                                "mechanism": .string(row.mechanism),
                                "status": .string(row.status),
                                "prior": .double(row.prior),
                                "posterior": .double(row.posterior),
                                "testCount": .int(row.testCount),
                                "alternatives": .array(
                                    row.alternativeExplanations.map(JSONValue.string)),
                                "formedAt": .string(row.formedAt),
                                "generatedBy": .string(row.generatedBy),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("no theories yet; they need a few months of record to be worth having")
                return
            }
            for row in rows {
                CLIOut.out(
                    "\(row.status)  \(String(format: "%.2f", row.posterior))  \(row.statement)")
                CLIOut.out("    because \(row.mechanism)")
                CLIOut.out("    tested \(row.testCount) times, id \(row.id)")
            }
        }
    }
}

struct CompanionHypothesesRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Resolve any predictions that are due, then form new theories.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            _ = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.runHypotheses()
            }
            guard !json else {
                CLIOut.json(.object(["ok": .bool(true)]))
                return
            }
            CLIOut.out("resolved what was due and formed what the record supports")
        }
    }
}

struct CompanionPredictionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "predictions", abstract: "List what it expects to happen, and what did.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.predictions(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "id": .string(row.id),
                                "hypothesisId": .string(row.hypothesisId),
                                "statement": .string(row.statement),
                                "observable": .string(row.observable),
                                "windowStart": .string(row.windowStart),
                                "windowEnd": .string(row.windowEnd),
                                "resolvedAt": .optional(row.resolvedAt),
                                "outcome": .optional(row.outcome),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("nothing predicted yet")
                return
            }
            for row in rows {
                let outcome = row.outcome ?? "open until \(row.windowEnd)"
                CLIOut.out("\(outcome)  \(row.statement)")
                CLIOut.out("    would show as: \(row.observable)")
            }
        }
    }
}

struct CompanionCommitmentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commitments", abstract: "List what you said you would do, and what happened.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.commitments(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "id": .string(row.id),
                                "claim": .string(row.claim),
                                "statedAt": .string(row.statedAt),
                                "dueBy": .string(row.dueBy),
                                "status": .string(row.status),
                                "resolvedAt": .optional(row.resolvedAt),
                                "userOverride": .optional(row.userOverride),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("nothing tracked yet; commitments come out of standups and notes")
                return
            }
            for row in rows {
                CLIOut.out("\(row.status)  due \(row.dueBy)  \(row.claim)")
                if let override = row.userOverride {
                    CLIOut.note("    you said: \(override)")
                }
            }
        }
    }
}

struct CompanionDiscrepanciesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discrepancies",
        abstract: "Where your account and the record parted company.",
        subcommands: [CompanionDiscrepanciesListCommand.self, CompanionOverrideCommand.self],
        defaultSubcommand: CompanionDiscrepanciesListCommand.self)
}

struct CompanionDiscrepanciesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List where your account and the record parted company.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.discrepancies(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "id": .string(row.id),
                                "claim": .string(row.claim),
                                "kind": .string(row.kind),
                                "magnitude": .double(row.magnitude),
                                "detectedAt": .string(row.detectedAt),
                                "dismissed": .bool(row.dismissed),
                                "userResponse": .optional(row.userResponse),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("nothing has diverged from the record")
                return
            }
            for row in rows {
                CLIOut.out("\(row.kind)  \(row.claim)")
                CLIOut.note("    id \(row.id)\(row.dismissed ? ", you set this straight" : "")")
            }
        }
    }
}

struct CompanionOverrideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "override",
        abstract: "Say the work was real and the record simply did not see it.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "What actually happened.")
    var real: String

    @Argument(help: "The discrepancy id.")
    var id: String

    func run() async throws {
        try await execute {
            _ = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.overrideDiscrepancy(id: id, real: real)
            }
            guard !json else {
                CLIOut.json(.object(["id": .string(id), "ok": .bool(true)]))
                return
            }
            CLIOut.out("noted; it will stop scoring that as absent work")
        }
    }
}

struct CompanionCalibrationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibration",
        abstract: "How your account of yourself compares with the record, in both directions.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.calibration()
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "domain": .string(row.domain),
                                "direction": .string(row.direction),
                                "samples": .int(row.samples),
                                "averageMagnitude": .double(row.averageMagnitude),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("nothing scored yet; this needs claims and records to compare")
                return
            }
            for row in rows {
                CLIOut.out(
                    "\(row.domain)  \(row.direction)  \(row.samples) times, average "
                        + "\(String(format: "%.2f", row.averageMagnitude))")
            }
        }
    }
}

struct CompanionInquireCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inquire",
        abstract: "The questions it wants to ask you, and your answers.",
        subcommands: [
            CompanionInquireNextCommand.self, CompanionInquireAnswerCommand.self,
            CompanionInquireSkipCommand.self, CompanionInquireMuteCommand.self,
            CompanionInquireListCommand.self,
        ],
        defaultSubcommand: CompanionInquireNextCommand.self)
}

struct CompanionInquireNextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next", abstract: "The one question worth asking right now.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Say why it wants to know.")
    var explain = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.nextQuestion()
            }
            guard let question = outcome.question else {
                guard !json else {
                    CLIOut.json(.object(["question": .null]))
                    return
                }
                CLIOut.out("nothing to ask; it keeps to \(outcome.dailyBudget ?? 3) a day")
                return
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "id": .string(question.id),
                        "question": .string(question.question),
                        "motive": .string(question.motive),
                        "topic": .string(question.topic),
                        "expectedGain": .double(question.expectedGain),
                        "sensitivity": .int(question.sensitivity),
                    ]))
                return
            }
            CLIOut.out(question.question)
            if explain {
                CLIOut.out("    it asks because: \(question.motive)")
                CLIOut.note(
                    "    topic \(question.topic), expected gain "
                        + "\(String(format: "%.2f", question.expectedGain))")
            }
            CLIOut.note("answer with: ed companion inquire answer \(question.id) \"...\"")
        }
    }
}

struct CompanionInquireAnswerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "answer", abstract: "Answer a question it asked, and see what it changed.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The question id.")
    var id: String

    @Argument(help: "Your answer.")
    var answer: String

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.answerQuestion(id: id, answer: answer)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "question": .string(outcome.question),
                        "episodeId": .string(outcome.episodeId),
                        "resolution": .string(outcome.resolution),
                        "askedToday": .int(outcome.askedToday),
                    ]))
                return
            }
            CLIOut.out(outcome.resolution)
            CLIOut.note("kept as episode \(outcome.episodeId)")
        }
    }
}

struct CompanionInquireSkipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip", abstract: "Pass on a question; it learns what you skip.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The question id.")
    var id: String

    func run() async throws {
        try await execute {
            _ = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.skipQuestion(id: id)
            }
            guard !json else {
                CLIOut.json(.object(["id": .string(id), "status": .string("skipped")]))
                return
            }
            CLIOut.out("skipped; skip a topic three times and it stops raising it")
        }
    }
}

struct CompanionInquireMuteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute", abstract: "Never be asked about a topic again.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The topic to mute.")
    var topic: String

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.muteTopic(topic)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "topic": .string(outcome.topic),
                        "suppressed": .int(outcome.suppressed),
                    ]))
                return
            }
            CLIOut.out("muted \(outcome.topic), dropping \(outcome.suppressed) queued questions")
        }
    }
}

struct CompanionInquireListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Every question it has queued, asked or been told to drop.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.questions(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "askedToday": .int(outcome.askedToday),
                        "dailyBudget": .int(outcome.dailyBudget),
                        "muted": .array(outcome.muted.map(JSONValue.string)),
                        "questions": .array(
                            outcome.questions.map { question in
                                .object([
                                    "id": .string(question.id),
                                    "question": .string(question.question),
                                    "motive": .string(question.motive),
                                    "topic": .string(question.topic),
                                    "status": .string(question.status),
                                    "expectedGain": .double(question.expectedGain),
                                    "resolution": .optional(question.resolution),
                                ])
                            }),
                    ]))
                return
            }
            for question in outcome.questions {
                CLIOut.out("\(question.status)  \(question.question)")
                CLIOut.note("    \(question.motive)")
            }
            CLIOut.note(
                "\(outcome.askedToday) of \(outcome.dailyBudget) asked today"
                    + (outcome.muted.isEmpty
                        ? "" : "; muted: \(outcome.muted.joined(separator: ", "))"))
        }
    }
}

struct CompanionEntitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entities",
        abstract: "The people, projects and places it knows, with every spelling.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 30

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.entities(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "id": .string(row.id),
                                "kind": .string(row.kind),
                                "canonicalName": .string(row.canonicalName),
                                "aliases": .array(row.aliases.map(JSONValue.string)),
                                "mentionCount": .int(row.mentionCount),
                                "firstSeen": .string(row.firstSeen),
                                "lastSeen": .string(row.lastSeen),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("nothing named yet; entities come out of the nightly run")
                return
            }
            for row in rows {
                let aliases =
                    row.aliases.isEmpty ? "" : "  also: \(row.aliases.joined(separator: ", "))"
                CLIOut.out(
                    "\(row.kind)  \(row.canonicalName)  \(row.mentionCount) episodes\(aliases)")
            }
        }
    }
}

struct CompanionLensesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lenses",
        abstract: "What each lens has learned about being useful to you.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.lenses()
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "persona": .string(row.persona),
                                "content": .string(row.content),
                                "updatedAt": .string(row.updatedAt),
                                "updatedBy": .string(row.updatedBy),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("no lens notes yet; the nightly run writes them, never the lens itself")
                return
            }
            for row in rows {
                CLIOut.out("\(row.persona)")
                CLIOut.out("    \(row.content)")
            }
        }
    }
}

struct CompanionEvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Score the friend layer against the cases it is meant to fail.",
        subcommands: [CompanionEvalRunCommand.self, CompanionEvalHistoryCommand.self],
        defaultSubcommand: CompanionEvalHistoryCommand.self)
}

struct CompanionEvalRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run the suite now and print every case.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "Which lens to score.")
    var persona: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.runEvals(persona: persona)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "suite": .string(outcome.suite),
                        "persona": .string(outcome.persona),
                        "model": .string(outcome.model),
                        "cases": .int(outcome.cases),
                        "passed": .int(outcome.passed),
                        "results": .array(
                            outcome.results.map { result in
                                .object([
                                    "id": .string(result.id),
                                    "kind": .string(result.kind),
                                    "passed": .bool(result.passed),
                                    "reason": .string(result.reason),
                                    "abstained": .bool(result.abstained),
                                    "grounding": .double(result.grounding),
                                    "words": .int(result.words),
                                ])
                            }),
                    ]))
                return
            }
            for result in outcome.results {
                CLIOut.out("\(result.passed ? "pass" : "fail")  \(result.id)  \(result.reason)")
            }
            CLIOut.out("\(outcome.passed) of \(outcome.cases) on \(outcome.persona)")
        }
    }
}

struct CompanionEvalHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Past eval runs, so you can see a prompt change land.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "How many to list.")
    var limit = 10

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.evals(limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "id": .string(row.id),
                                "suite": .string(row.suite),
                                "ranAt": .string(row.ranAt),
                                "model": .string(row.model),
                                "cases": .int(row.cases),
                                "passed": .int(row.passed),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("no runs yet; `ed companion eval run` scores it")
                return
            }
            for row in rows {
                CLIOut.out(
                    "\(row.ranAt)  \(row.passed)/\(row.cases)  \(row.suite)  \(row.model)")
            }
        }
    }
}

struct CompanionStandupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "standup",
        abstract: "Record a standup, and see what your standups have added up to.",
        subcommands: [CompanionStandupRecordCommand.self, CompanionStandupReportCommand.self],
        defaultSubcommand: CompanionStandupRecordCommand.self)
}

struct CompanionStandupRecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a standup, and optionally check it against the record.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Resolve the claims against what the connectors saw.")
    var verify = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "A transcript file, or - to read stdin.", completion: .file())
    var path: String

    func run() async throws {
        try await execute {
            let text: String
            if path == "-" {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                text = String(decoding: data, as: UTF8.self)
            } else {
                let url = URL(fileURLWithPath: path.expandingTilde())
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    throw CLIFailure.usage(
                        "could not read \(url.path)", hint: error.localizedDescription)
                }
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIFailure.usage("the standup is empty", hint: "pass a transcript or text")
            }
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.standup(text: text, verify: verify)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "episodeId": .string(outcome.episodeId),
                        "occurredAt": .string(outcome.occurredAt),
                        "verified": .bool(outcome.verified),
                        "claims": .array(
                            outcome.claims.map { claim in
                                .object([
                                    "id": .string(claim.id),
                                    "statement": .string(claim.statement),
                                    "claimType": .string(claim.claimType),
                                    "testable": .bool(claim.testable),
                                    "verdict": .optional(claim.verdict),
                                    "note": .optional(claim.note),
                                ])
                            }),
                    ]))
                return
            }
            for claim in outcome.claims {
                let verdict = claim.verdict.map { "  \($0)" } ?? ""
                CLIOut.out("\(claim.claimType)\(verdict)  \(claim.statement)")
                if let note = claim.note {
                    CLIOut.note("    \(note)")
                }
            }
            if let aggregate = outcome.aggregate, aggregate.commitmentsResolved > 0 {
                CLIOut.note(
                    "across \(aggregate.standups) standups, "
                        + "\(Int(aggregate.metRate * 100))% of commitments landed")
            }
        }
    }
}

struct CompanionStandupReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report", abstract: "What your standups have added up to.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let report = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.standupAggregate()
            }
            let aggregate = report.aggregate
            guard !json else {
                CLIOut.json(
                    .object([
                        "standups": .int(aggregate.standups),
                        "commitmentsResolved": .int(aggregate.commitmentsResolved),
                        "metRate": .double(aggregate.metRate),
                        "medianSlipDays": .optional(
                            aggregate.medianSlipDays.map { String(format: "%.2f", $0) }),
                        "overstated": .int(aggregate.overstated),
                        "understated": .int(aggregate.understated),
                        "invisibleWork": .int(aggregate.invisibleWork),
                        "dueSoon": .int(report.dueSoon),
                    ]))
                return
            }
            CLIOut.out("\(aggregate.standups) standups recorded")
            guard aggregate.commitmentsResolved > 0 else {
                CLIOut.out("nothing has resolved yet; this needs a few weeks to say anything")
                return
            }
            CLIOut.out(
                "\(Int(aggregate.metRate * 100))% of \(aggregate.commitmentsResolved) "
                    + "commitments landed")
            if let slip = aggregate.medianSlipDays {
                CLIOut.out("median slip \(String(format: "%.1f", slip)) days")
            }
            CLIOut.out(
                "overstated \(aggregate.overstated), understated \(aggregate.understated), "
                    + "invisible work \(aggregate.invisibleWork)")
            if report.dueSoon > 0 {
                CLIOut.note("\(report.dueSoon) commitments come due within a day")
            }
        }
    }
}

struct CompanionMachinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machines",
        abstract: "Where the companion stack runs, and what each machine can do.",
        subcommands: [
            CompanionMachinesListCommand.self, CompanionMachinesAddCommand.self,
            CompanionMachinesProbeCommand.self, CompanionMachinesPlanCommand.self,
            CompanionMachinesProfileCommand.self,
        ],
        defaultSubcommand: CompanionMachinesListCommand.self)
}

struct CompanionMachinesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Every machine registered, and what was found on it.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.machines()
            }
            guard !json else {
                CLIOut.json(.array(rows.map(CompanionBrainOutput.machineJSON)))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("no machines yet; `ed companion machines add this --transport local`")
                return
            }
            for row in rows {
                CLIOut.out("\(row.name)  \(row.effectiveProfile)  \(row.status)")
                CLIOut.out("    \(row.plainEnglish)")
            }
        }
    }
}

extension CompanionBrainOutput {
    static func machineJSON(_ row: CompanionMachine) -> JSONValue {
        .object([
            "id": .string(row.id),
            "name": .string(row.name),
            "transport": .string(row.transport),
            "endpoint": .string(row.endpoint),
            "os": .optional(row.os),
            "arch": .optional(row.arch),
            "gpuVendor": .optional(row.gpuVendor),
            "gpuModel": .optional(row.gpuModel),
            "vramMb": .optional(row.vramMb.map(String.init)),
            "cpuCores": .optional(row.cpuCores.map(String.init)),
            "ramMb": .optional(row.ramMb.map(String.init)),
            "diskFreeMb": .optional(row.diskFreeMb.map(String.init)),
            "profile": .string(row.effectiveProfile),
            "status": .string(row.status),
        ])
    }
}

struct CompanionMachinesAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Register a machine the stack could run on.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "local, ssh or context.")
    var transport = "local"

    @Option(name: .long, help: "user@host for ssh, or the docker context name.")
    var at: String?

    @Argument(help: "What to call it.")
    var name: String

    func run() async throws {
        try await execute {
            _ = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.addMachine(name: name, transport: transport, endpoint: at ?? "")
            }
            guard !json else {
                CLIOut.json(.object(["name": .string(name), "transport": .string(transport)]))
                return
            }
            CLIOut.out("added \(name); `ed companion machines probe \(name)` asks what it is")
        }
    }
}

struct CompanionMachinesProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe", abstract: "Ask a machine what it is rather than assuming.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The machine name.")
    var name: String

    func run() async throws {
        try await execute {
            let machine = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.probeMachine(name: name)
            }
            guard !json else {
                CLIOut.json(CompanionBrainOutput.machineJSON(machine))
                return
            }
            CLIOut.out("\(machine.name): \(machine.plainEnglish)")
            CLIOut.out("tier \(machine.effectiveProfile)")
        }
    }
}

struct CompanionMachinesPlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "What would run where, before anything is started.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let plan = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.machinePlan()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "compose": .array(plan.compose.map(JSONValue.string)),
                        "warnings": .array(plan.warnings.map(JSONValue.string)),
                        "placements": .array(
                            plan.placements.map { placement in
                                .object([
                                    "machine": .string(placement.machine),
                                    "service": .string(placement.service),
                                    "role": .string(placement.role),
                                    "enabled": .bool(placement.enabled),
                                    "notes": .string(placement.notes),
                                ])
                            }),
                    ]))
                return
            }
            for placement in plan.placements {
                CLIOut.out("\(placement.machine)  \(placement.role)  \(placement.service)")
            }
            if !plan.compose.isEmpty {
                CLIOut.out("compose files: \(plan.compose.joined(separator: ", "))")
            }
            for warning in plan.warnings {
                CLIOut.note(warning)
            }
        }
    }
}

struct CompanionMachinesProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile", abstract: "Override the tier a machine was given.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "The machine name.")
    var name: String

    @Argument(help: "gpu-large, gpu-small, apple-metal or cpu-only.")
    var profile: String

    func run() async throws {
        try await execute {
            _ = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.setMachineProfile(name: name, profile: profile)
            }
            guard !json else {
                CLIOut.json(.object(["name": .string(name), "profile": .string(profile)]))
                return
            }
            CLIOut.out("\(name) is now treated as \(profile)")
        }
    }
}

struct CompanionBaselinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baselines",
        abstract: "Your own delivery baselines, which every signal is measured against.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.baselines()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "audioSeconds": .double(outcome.audioSeconds),
                        "coldStart": .bool(outcome.coldStart),
                        "baselines": .array(
                            outcome.baselines.map { row in
                                .object([
                                    "kind": .string(row.kind),
                                    "contextBucket": .string(row.contextBucket),
                                    "median": .double(row.median),
                                    "iqr": .double(row.iqr),
                                    "samples": .int(row.samples),
                                ])
                            }),
                    ]))
                return
            }
            let hours = outcome.audioSeconds / 3600
            CLIOut.out("\(String(format: "%.1f", hours)) hours of audio recorded")
            if outcome.coldStart {
                CLIOut.out(
                    "still cold: deviations stay suppressed until about 20 hours, "
                        + "rather than showing you noise")
            }
            for row in outcome.baselines {
                CLIOut.out(
                    "\(row.kind)  \(row.contextBucket)  median "
                        + "\(String(format: "%.2f", row.median))  spread "
                        + "\(String(format: "%.2f", row.iqr))  \(row.samples) samples")
            }
        }
    }
}

struct CompanionConnectorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connectors",
        abstract: "The tokens and exports the behavioural connectors run on.",
        subcommands: [
            CompanionConnectorsShowCommand.self, CompanionConnectorsSetCommand.self,
            CompanionConnectorsImportCommand.self,
        ],
        defaultSubcommand: CompanionConnectorsShowCommand.self)
}

struct CompanionConnectorsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Which connectors have a token, without printing it.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let settings = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.connectorSettings()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "github": .object([
                            "configured": .bool(settings.github.configured),
                            "detail": .string(settings.github.detail),
                        ]),
                        "notion": .object([
                            "configured": .bool(settings.notion.configured),
                            "detail": .string(settings.notion.detail),
                        ]),
                        "importable": .array(settings.importable.map(JSONValue.string)),
                    ]))
                return
            }
            CLIOut.out("github  \(settings.github.detail)")
            CLIOut.out("notion  \(settings.notion.detail)")
            CLIOut.out("import from a file: \(settings.importable.joined(separator: ", "))")
        }
    }
}

struct CompanionConnectorsSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Store a connector token on the companion.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "GitHub token; pass empty to clear it.")
    var github: String?

    @Option(name: .long, help: "Notion token; pass empty to clear it.")
    var notion: String?

    func run() async throws {
        try await execute {
            guard github != nil || notion != nil else {
                throw CLIFailure.usage(
                    "nothing to set", hint: "pass --github or --notion, empty to clear")
            }
            let settings = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.updateConnectorSettings(github: github, notion: notion)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "github": .string(settings.github.detail),
                        "notion": .string(settings.notion.detail),
                    ]))
                return
            }
            CLIOut.out("github  \(settings.github.detail)")
            CLIOut.out("notion  \(settings.notion.detail)")
        }
    }
}

struct CompanionConnectorsImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a calendar, music or YouTube export as observations.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Argument(help: "calendar, music or youtube.")
    var source: String

    @Argument(help: "The exported JSON file.", completion: .file())
    var path: String

    func run() async throws {
        try await execute {
            let url = URL(fileURLWithPath: path.expandingTilde())
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw CLIFailure.usage(
                    "could not read \(url.path)", hint: error.localizedDescription)
            }
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.importConnector(source: source, json: data)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "source": .string(outcome.source),
                        "entriesRead": .int(outcome.entriesRead),
                        "observationsInserted": .int(outcome.observationsInserted),
                        "skipped": .int(outcome.skipped),
                    ]))
                return
            }
            CLIOut.out(
                "read \(outcome.entriesRead) entries, stored "
                    + "\(outcome.observationsInserted) new observations, skipped "
                    + "\(outcome.skipped)")
        }
    }
}

struct CompanionFactsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "facts",
        abstract: "What was true, and what the companion believed at the time.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Option(name: .long, help: "A date to read the world as of.")
    var asOf: String?

    @Option(name: .long, help: "valid for what was true, believed for what it thought.")
    var timeline = "valid"

    @Option(name: .long, help: "How many to list.")
    var limit = 30

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            guard ["valid", "believed"].contains(timeline) else {
                throw CLIFailure.usage(
                    "unknown timeline \(timeline)", hint: "pass valid or believed")
            }
            let rows = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.facts(asOf: asOf, timeline: timeline, limit: limit)
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        rows.map { row in
                            .object([
                                "id": .string(row.id),
                                "subject": .string(row.subject),
                                "predicate": .string(row.predicate),
                                "object": .string(row.object),
                                "validFrom": .optional(row.validFrom),
                                "validTo": .optional(row.validTo),
                                "createdAt": .string(row.createdAt),
                                "expiredAt": .optional(row.expiredAt),
                                "supersededBy": .optional(row.supersededBy),
                            ])
                        }))
                return
            }
            guard !rows.isEmpty else {
                CLIOut.out("no facts recorded yet; the nightly run extracts them")
                return
            }
            for row in rows {
                let window = row.validTo.map { "until \($0.prefix(10))" } ?? "still true"
                CLIOut.out(
                    "\(row.subject) \(row.predicate) \(row.object)  "
                        + "(\(row.validFrom?.prefix(10) ?? "unknown") \(window))")
            }
        }
    }
}

struct CompanionForgetBeliefCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "correct",
        abstract: "Retire a belief that is wrong, or rewrite it in your own words.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Flag(name: .long, help: "Retire it rather than rewriting it.")
    var retire = false

    @Option(name: .long, help: "What it should say instead.")
    var edit: String?

    @Argument(help: "The belief id.")
    var id: String

    func run() async throws {
        try await execute {
            guard retire || edit != nil else {
                throw CLIFailure.usage(
                    "nothing to change", hint: "pass --retire or --edit \"...\"")
            }
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.correctBelief(id: id, retire: retire, statement: edit)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "id": .string(outcome.id),
                        "status": .string(outcome.status),
                        "statement": .string(outcome.statement),
                    ]))
                return
            }
            CLIOut.out("\(outcome.status)  \(outcome.statement)")
        }
    }
}

struct CompanionWeeklyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "weekly",
        abstract: "The wider pass: relate beliefs, reopen contested ones, retire unread ones.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.weekly()
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "beliefsExamined": .int(outcome.beliefsExamined),
                        "linksMade": .int(outcome.linksMade),
                        "contestedReopened": .int(outcome.contestedReopened),
                        "retired": .int(outcome.retired),
                    ]))
                return
            }
            CLIOut.out(
                "examined \(outcome.beliefsExamined), linked \(outcome.linksMade), "
                    + "reopened \(outcome.contestedReopened), retired \(outcome.retired)")
        }
    }
}

struct CompanionDbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Migrate, reindex, or rebuild everything derived from the episodes.",
        subcommands: [
            CompanionDbMigrateCommand.self, CompanionDbReindexCommand.self,
            CompanionDbRebuildCommand.self,
        ],
        defaultSubcommand: CompanionDbMigrateCommand.self)
}

struct CompanionDbMigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate", abstract: "Apply any migrations the backend has not run.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await CompanionDbRunner.run(action: "migrate", endpoint: endpoint, json: json)
    }
}

struct CompanionDbReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex", abstract: "Drop the chunks so every episode is embedded again.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await CompanionDbRunner.run(action: "reindex", endpoint: endpoint, json: json)
    }
}

struct CompanionDbRebuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild-derived",
        abstract: "Throw away everything derived and rebuild it from the episodes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await CompanionDbRunner.run(action: "rebuild-derived", endpoint: endpoint, json: json)
    }
}

enum CompanionDbRunner {
    static func run(action: String, endpoint: String?, json: Bool) async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await client.db(action)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string(action),
                        "chunksDropped": .optional(outcome.chunksDropped.map(String.init)),
                        "beliefsRetired": .optional(outcome.beliefsRetired.map(String.init)),
                        "factsExpired": .optional(outcome.factsExpired.map(String.init)),
                        "episodesKept": .optional(outcome.episodesKept.map(String.init)),
                    ]))
                return
            }
            if let kept = outcome.episodesKept {
                CLIOut.out(
                    "kept \(kept) episodes, dropped \(outcome.chunksDropped ?? 0) chunks, "
                        + "retired \(outcome.beliefsRetired ?? 0) beliefs")
            } else if let dropped = outcome.chunksDropped {
                CLIOut.out("dropped \(dropped) chunks; `ed companion index` rebuilds them")
            } else {
                CLIOut.out("\(action) done")
            }
        }
    }
}
