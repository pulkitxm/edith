import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
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

@MainActor struct CompanionPersonasCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "personas", abstract: "List the lenses that can answer, and how each thinks.",
        discussion: """
            Lists the lenses that can answer you, and how each one thinks.

            Reads the lenses that can answer. Does not change them.

            ed companion personas
            ed companion personas --json
            """, )

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

@MainActor struct CompanionCouncilCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "council",
        abstract: "Ask several lenses at once and find the crux they disagree on.",
        discussion: """
            Asks several lenses the same question in sequence, then runs a synthesis
            pass whose only job is to locate the crux: the one fact none of them has,
            which would settle the disagreement if it were known.

            Reads several lenses at once and writes one comparison of where they
            disagree.

            ed companion council what did I decide yesterday?
            ed companion council what did I decide yesterday? --json
            """, )

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

@MainActor struct CompanionCoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "core",
        abstract: "Read or edit the standing summary of who you are.",
        discussion: """
            Reads or edits the standing summary of who you are: the small block that
            sits in context on every answer.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion core show
            """,
        subcommands: [CompanionCoreShowCommand.self, CompanionCoreSetCommand.self],
        defaultSubcommand: CompanionCoreShowCommand.self)
}

@MainActor struct CompanionCoreShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Print the standing summary section by section.",
        discussion: """
            Print the standing summary section by section.

            Reads the standing summary section by section. Does not change it.

            ed companion core show
            ed companion core show --json
            """, )

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

@MainActor struct CompanionCoreSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Rewrite one section of the standing summary yourself.",
        discussion: """
            Rewrite one section of the standing summary yourself.

            Changes one section of the standing summary.

            ed companion core set voice "keep it short"
            ed companion core set voice "keep it short" --json
            """, )

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
                try await CompanionMindRuntimeOperationExecution.setCore(
                    section: section, content: content
                ) { section, content in
                    try await client.writeCore(section: section, content: content)
                }
            }
            guard !json else {
                CLIOut.json(.object(["section": .string(section), "ok": .bool(true)]))
                return
            }
            CLIOut.out(CompanionMindRuntimeOperationText.coreSet(section))
        }
    }
}

@MainActor struct CompanionWhyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "why",
        abstract: "Print the whole chain behind a belief, theory or claim.",
        discussion: """
            Prints the whole chain behind anything the companion believes: the evidence
            episodes, what argues against it, the prompt version that produced it, how
            its confidence moved, and how it was checked against the record.

            Reads the chain behind one belief, theory, or claim. Does not change it.

            ed companion why 1
            ed companion why 1 --json
            """, )

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

@MainActor struct CompanionHypothesesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hypotheses",
        abstract: "Show the theories it holds about you, and how they are faring.",
        discussion: """
            The theories the companion holds about you, and how they are faring.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion hypotheses ls
            """,
        subcommands: [CompanionHypothesesListCommand.self, CompanionHypothesesRunCommand.self],
        defaultSubcommand: CompanionHypothesesListCommand.self)
}

@MainActor struct CompanionHypothesesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List the theories it holds about you, and how they are faring.",
        discussion: """
            List the theories it holds about you, and how they are faring.

            Reads the saved records in stored order. Does not change them.

            ed companion hypotheses ls
            ed companion hypotheses ls --json
            """, )

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

@MainActor struct CompanionHypothesesRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Resolve any predictions that are due, then form new theories.",
        discussion: """
            Resolve any predictions that are due, then form new theories.

            Changes stored theories by resolving due predictions and forming new ones.

            ed companion hypotheses run
            ed companion hypotheses run --json
            """, )

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

@MainActor struct CompanionPredictionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "predictions", abstract: "List what it expects to happen, and what did.",
        discussion: """
            What the companion expects to happen, and what actually did.

            Reads stored predictions and what actually happened. Does not change them.

            ed companion predictions
            ed companion predictions --json
            """, )

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

@MainActor struct CompanionCommitmentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commitments", abstract: "List what you said you would do, and what happened.",
        discussion: """
            What you said you would do, and what the record says happened.

            Reads what you said you would do. Does not change those records.

            ed companion commitments
            ed companion commitments --json
            """, )

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

@MainActor struct CompanionDiscrepanciesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "discrepancies",
        abstract: "Show where your account and the record parted company.",
        discussion: """
            Where your account of your own work and the record of it parted company, and
            the way to tell the system when the record was simply not looking.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion discrepancies ls
            """,
        subcommands: [CompanionDiscrepanciesListCommand.self, CompanionOverrideCommand.self],
        defaultSubcommand: CompanionDiscrepanciesListCommand.self)
}

@MainActor struct CompanionDiscrepanciesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List where your account and the record parted company.",
        discussion: """
            List where your account and the record parted company.

            Reads the saved records in stored order. Does not change them.

            ed companion discrepancies ls
            ed companion discrepancies ls --json
            """, )

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

@MainActor struct CompanionOverrideCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "override",
        abstract: "Say the work was real and the record simply did not see it.",
        discussion: """
            Say the work was real and the record simply did not see it.

            Changes one discrepancy by recording which side was real.

            ed companion discrepancies override 1 --real true
            ed companion discrepancies override 1 --real true --json
            """, )

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

@MainActor struct CompanionCalibrationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calibration",
        abstract: "Show how your account of yourself compares with the record, in both directions.",
        discussion: """
            How your account of yourself compares with the record, tracked in both
            directions and scored separately per domain, because estimating work,
            judging yourself and reading risk are different skills and you are probably
            not equally miscalibrated across them.

            Reads how your account of yourself compares with the record. Does not change
            it.

            ed companion calibration
            ed companion calibration --json
            """, )

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

@MainActor struct CompanionInquireCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inquire",
        abstract: "Show the questions it wants to ask you, and your answers.",
        discussion: """
            The questions the companion wants to ask you, ranked by the size of the hole
            they would fill rather than picked at random.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion inquire next
            """,
        subcommands: [
            CompanionInquireNextCommand.self, CompanionInquireAnswerCommand.self,
            CompanionInquireSkipCommand.self, CompanionInquireMuteCommand.self,
            CompanionInquireListCommand.self,
        ],
        defaultSubcommand: CompanionInquireNextCommand.self)
}

@MainActor struct CompanionInquireNextCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "next", abstract: "Show the one question worth asking right now.",
        discussion: """
            Show the one question worth asking right now.

            Reads the one question worth asking now. Does not change the queue.

            ed companion inquire next
            ed companion inquire next --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Say why it wants to know.")
    var explain = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await execute {
            let outcome = try await CompanionBridge.request(endpoint: endpoint) { client in
                try await CompanionMindRuntimeOperationExecution.nextQuestion {
                    try await client.nextQuestion()
                }
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

@MainActor struct CompanionInquireAnswerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "answer", abstract: "Answer a question it asked, and see what it changed.",
        discussion: """
            Answer a question it asked, and see what it changed.

            Changes an open question by storing your answer.

            ed companion inquire answer 1 we shipped it
            ed companion inquire answer 1 we shipped it --json
            """, )

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

@MainActor struct CompanionInquireSkipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip", abstract: "Pass on a question; it learns what you skip.",
        discussion: """
            Pass on a question; it learns what you skip.

            Changes the question queue by passing on one question.

            ed companion inquire skip 1
            ed companion inquire skip 1 --json
            """, )

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

@MainActor struct CompanionInquireMuteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mute", abstract: "Never be asked about a topic again.",
        discussion: """
            Never be asked about a topic again.

            Changes which topics the companion is allowed to ask about.

            ed companion inquire mute salary
            ed companion inquire mute salary --json
            """, )

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

@MainActor struct CompanionInquireListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "Show every question it has queued, asked or been told to drop.",
        discussion: """
            Show every question it has queued, asked or been told to drop.

            Reads the saved records in stored order. Does not change them.

            ed companion inquire ls
            ed companion inquire ls --json
            """, )

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

@MainActor struct CompanionEntitiesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "entities",
        abstract: "Show the people, projects and places it knows, with every spelling.",
        discussion: """
            The people, projects, places, organisations and other named things the
            companion has resolved, each with every spelling it has seen.

            Reads the people, projects, and places it knows. Does not change them.

            ed companion entities
            ed companion entities --json
            """, )

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

@MainActor struct CompanionLensesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lenses",
        abstract: "Show what each lens has learned about being useful to you.",
        discussion: """
            Prints each lens's short nightly note about how to be useful in its role.

            Reads what each lens has learned. Does not change that record.

            ed companion lenses
            ed companion lenses --json
            """, )

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

@MainActor struct CompanionEvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "Run the friend-layer cases the companion is meant to fail.",
        discussion: """
            Scores the friend layer against the cases it is meant to fail.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion eval run
            """,
        subcommands: [CompanionEvalRunCommand.self, CompanionEvalHistoryCommand.self],
        defaultSubcommand: CompanionEvalHistoryCommand.self)
}

@MainActor struct CompanionEvalRunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run the suite now and print every case.",
        discussion: """
            Run the suite now and print every case.

            Reads every eval case by running the suite now. Writes the run into the eval
            history.

            ed companion eval run
            ed companion eval run --json
            """, )

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

@MainActor struct CompanionEvalHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Past eval runs, so you can see a prompt change land.",
        discussion: """
            Past eval runs, so you can see a prompt change land.

            Reads the saved records in stored order. Does not change them.

            ed companion eval ls
            ed companion eval ls --json
            """, )

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

@MainActor struct CompanionStandupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "standup",
        abstract: "Record a standup, and see what your standups have added up to.",
        discussion: """
            Records a standup and, on request, checks what you said against what the
            record shows.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion standup record /tmp/notes.md
            """,
        subcommands: [CompanionStandupRecordCommand.self, CompanionStandupReportCommand.self],
        defaultSubcommand: CompanionStandupRecordCommand.self)
}

@MainActor struct CompanionStandupRecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record a standup, and optionally check it against the record.",
        discussion: """
            Record a standup, and optionally check it against the record.

            Changes the standup log by storing one standup.

            ed companion standup record /tmp/notes.md
            ed companion standup record /tmp/notes.md --json
            """, )

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
                let data = CompanionCLIEnvironment.input
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

@MainActor struct CompanionStandupReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report", abstract: "Show what your standups have added up to.",
        discussion: """
            Show what your standups have added up to.

            Reads what recorded standups add up to. Does not change them.

            ed companion standup report
            ed companion standup report --json
            """, )

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

@MainActor struct CompanionMachinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machines",
        abstract: "Show where the companion stack runs, and what each machine can do.",
        discussion: """
            The companion backend's own machine inventory and multi-host placement
            planner.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion machines ls
            """,
        subcommands: [
            CompanionMachinesListCommand.self, CompanionMachinesAddCommand.self,
            CompanionMachinesProbeCommand.self, CompanionMachinesPlanCommand.self,
            CompanionMachinesProfileCommand.self,
        ],
        defaultSubcommand: CompanionMachinesListCommand.self)
}

@MainActor struct CompanionMachinesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Every machine registered, and what was found on it.",
        discussion: """
            Every machine registered, and what was found on it.

            Reads the saved records in stored order. Does not change them.

            ed companion machines ls
            ed companion machines ls --json
            """, )

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

@MainActor struct CompanionMachinesAddCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Register a machine the stack could run on.",
        discussion: """
            Register a machine the stack could run on.

            Changes the companion host list by registering one machine.

            ed companion machines add box
            ed companion machines add box --json
            """, )

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

@MainActor struct CompanionMachinesProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe", abstract: "Ask a machine what it is rather than assuming.",
        discussion: """
            Ask a machine what it is rather than assuming.

            Reads a machine by asking it what it is. Does not change the machine.

            ed companion machines probe notes
            ed companion machines probe notes --json
            """, )

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

@MainActor struct CompanionMachinesPlanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "plan", abstract: "What would run where, before anything is started.",
        discussion: """
            What would run where, before anything is started.

            Reads where work would run. Does not change any machine.

            ed companion machines plan
            ed companion machines plan --json
            """, )

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

@MainActor struct CompanionMachinesProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile", abstract: "Override the tier a machine was given.",
        discussion: """
            Override the tier a machine was given.

            Changes the tier stored for one machine.

            ed companion machines profile notes balanced
            ed companion machines profile notes balanced --json
            """, )

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

@MainActor struct CompanionBaselinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baselines",
        abstract: "Show your own delivery baselines, which every signal is measured against.",
        discussion: """
            Your own delivery baselines: the median and spread of stored signals,
            bucketed by recording context and language.

            Reads your delivery baselines. Does not change them.

            ed companion baselines
            ed companion baselines --json
            """, )

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

@MainActor struct CompanionConnectorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connectors",
        abstract: "The tokens and exports the behavioural connectors run on.",
        discussion: """
            Companion connectors bring in two kinds of material.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion connectors show
            """,
        subcommands: [
            CompanionConnectorsShowCommand.self, CompanionConnectorsSetCommand.self,
            CompanionConnectorsImportCommand.self,
        ],
        defaultSubcommand: CompanionConnectorsShowCommand.self)
}

@MainActor struct CompanionConnectorsShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "Show which connectors have a token, without printing it.",
        discussion: """
            Show which connectors have a token, without printing it.

            Reads which connectors have a token. Does not change them, and does not
            print the token.

            ed companion connectors show
            ed companion connectors show --json
            """, )

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

@MainActor struct CompanionConnectorsSetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set", abstract: "Store a connector token on the companion.",
        discussion: """
            Store a connector token on the companion.

            Changes a connector by storing its token on the companion.

            ed companion connectors set
            ed companion connectors set --json
            """, )

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
            let update = try CompanionSettingsOperationBridge.connectorUpdate(
                github: github, notion: notion)
            let settings = try await CompanionSettingsOperationBridge.request(
                endpoint: endpoint
            ) { operations in
                try await operations.updateConnectors(update)
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

@MainActor struct CompanionConnectorsImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a calendar, music or YouTube export as observations.",
        discussion: """
            Import a calendar, music or YouTube export as observations.

            Changes observations by importing a calendar, music, or YouTube export.

            ed companion connectors import calendar /tmp/notes.md
            ed companion connectors import calendar /tmp/notes.md --json
            """, )

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
            let outcome = try await CompanionSettingsOperationBridge.request(
                endpoint: endpoint
            ) { operations in
                try await operations.importConnector(source: source, from: url)
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
            CLIOut.out(CompanionSettingsOperationText.connectorImport(outcome))
        }
    }
}

@MainActor struct CompanionFactsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "facts",
        abstract: "Show what was true, and what the companion believed at the time.",
        discussion: """
            Structured claims with two independent timelines: when something was true in
            the world, and when the system believed it.

            Reads what was true, and what the companion believed then. Does not change
            those records.

            ed companion facts
            ed companion facts --json
            """, )

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

@MainActor struct CompanionForgetBeliefCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "correct",
        abstract: "Retire a belief that is wrong, or rewrite it in your own words.",
        discussion: """
            Retires a belief that is wrong, or rewrites it in your own words.

            Changes one belief by retiring it or rewriting it.

            ed companion correct 1
            ed companion correct 1 --json
            """, )

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

@MainActor struct CompanionWeeklyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "weekly",
        abstract: "The wider pass: relate beliefs, reopen contested ones, retire unread ones.",
        discussion: """
            The wider pass.

            Changes derived beliefs by relating, reopening, and retiring them.

            ed companion weekly
            ed companion weekly --json
            """, )

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

@MainActor struct CompanionDbCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "db",
        abstract: "Migrate, reindex, or rebuild everything derived from the episodes.",
        discussion: """
            The maintenance verbs.

            Reads nothing until a subcommand runs. Does not change anything by itself.

            ed companion db migrate
            """,
        subcommands: [
            CompanionDbMigrateCommand.self, CompanionDbReindexCommand.self,
            CompanionDbRebuildCommand.self,
        ],
        defaultSubcommand: CompanionDbMigrateCommand.self)
}

@MainActor struct CompanionDbMigrateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate", abstract: "Apply any migrations the backend has not run.",
        discussion: """
            Apply any migrations the backend has not run.

            Changes the companion database by applying migrations that have not run.

            ed companion db migrate
            ed companion db migrate --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    func run() async throws {
        try await CompanionDbRunner.run(action: "migrate", endpoint: endpoint, json: json)
    }
}

@MainActor struct CompanionDbReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reindex", abstract: "Drop the chunks so every episode is embedded again.",
        discussion: """
            Drop the chunks so every episode is embedded again.

            Changes the companion index by embedding every episode again.

            ed companion db reindex
            ed companion db reindex --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Flag(name: .long, help: "Apply the previewed maintenance operation.")
    var yes = false

    func run() async throws {
        try await CompanionDbRunner.reindex(endpoint: endpoint, json: json, yes: yes)
    }
}

@MainActor struct CompanionDbRebuildCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rebuild-derived",
        abstract: "Throw away everything derived and rebuild it from the episodes.",
        discussion: """
            Throw away everything derived and rebuild it from the episodes.

            Changes derived memory by throwing it away and rebuilding it from episodes.

            ed companion db rebuild-derived
            ed companion db rebuild-derived --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Companion API base URL.")
    var endpoint: String?

    @Flag(name: .long, help: "Apply the previewed maintenance operation.")
    var yes = false

    func run() async throws {
        try await CompanionDbRunner.rebuildDerived(endpoint: endpoint, json: json, yes: yes)
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

    static func reindex(endpoint: String?, json: Bool, yes: Bool) async throws {
        try await execute {
            let operation = CompanionSettingsOperation.dbReindex
            let plan = CLIDestructivePlan(
                action: operation.descriptor.summary, targets: operation.previewTargets,
                confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let result = try await CompanionSettingsOperationBridge.request(
                endpoint: endpoint
            ) { operations in
                try await operations.reindex()
            }
            plan.finish(
                changed: true, plain: CompanionSettingsOperationText.reindex(result),
                fields: [
                    "chunksDropped": .int(result.maintenance.chunksDropped ?? 0),
                    "episodesIndexed": .int(result.indexing.episodesIndexed),
                    "chunksCreated": .int(result.indexing.chunksCreated),
                ])
        }
    }

    static func rebuildDerived(endpoint: String?, json: Bool, yes: Bool) async throws {
        try await execute {
            let operation = CompanionSettingsOperation.dbRebuildDerived
            let plan = CLIDestructivePlan(
                action: operation.descriptor.summary, targets: operation.previewTargets,
                confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let outcome = try await CompanionSettingsOperationBridge.request(
                endpoint: endpoint
            ) { operations in
                try await operations.rebuildDerived()
            }
            plan.finish(
                changed: true, plain: CompanionSettingsOperationText.rebuildDerived(outcome),
                fields: [
                    "chunksDropped": .int(outcome.chunksDropped ?? 0),
                    "beliefsRetired": .int(outcome.beliefsRetired ?? 0),
                    "factsExpired": .int(outcome.factsExpired ?? 0),
                    "episodesKept": .int(outcome.episodesKept ?? 0),
                ])
        }
    }
}
