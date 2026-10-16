import AppKit
import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

struct UsageExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render branded usage cards as PNG images.",
        discussion: """
            Render Edith's local agent usage as branded, high resolution PNG cards.

            Reads the owning Usage engine history and writes the selected PNG cards.

            ed usage export
            ed usage export --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "highlights, activity, daily, busiest or all. Repeatable.")
    var card: [String] = []

    @Option(name: [.short, .long], help: "Output directory, or a PNG path for one card.")
    var output: String?

    @Flag(name: .long, help: "Also copy the first rendered card to the clipboard.")
    var clipboard = false

    @OptionGroup var window: UsageWindow

    @MainActor func run() async throws {
        try await execute {
            let selected = try UsageShareExport.cards(card)
            let range = try window.resolved()
            let document = try UsageDocument.load()
            let sources = try window.sources(in: document)
            let days = UsageAnalysis.days(document, range: range)
            let snapshot = UsageShareExport.snapshot(
                document: document, days: days, sources: sources)
            guard snapshot.activeDays > 0 else {
                throw CLIFailure.unavailable(
                    "there is no usage to export for this selection",
                    hint: "choose a wider range or run `ed usage refresh`")
            }
            let plan = try UsageShareExport.plan(
                cards: selected, output: output,
                workingDirectory: URL(
                    fileURLWithPath: UsageCLIEnvironment.workingDirectory, isDirectory: true))
            let files = try await UsageShareExport.write(snapshot: snapshot, plan: plan)
            if clipboard { try UsageShareExport.copyToClipboard(files) }
            guard !json else {
                CLIOut.json(
                    .object([
                        "range": .string(range.rawValue),
                        "files": .array(files.map { .string($0.path) }),
                    ]))
                return
            }
            for file in files { CLIOut.out("exported \(file.path)") }
        }
    }
}

@MainActor enum UsageShareExport {
    static func cards(_ requested: [String]) throws -> [UsageShareCard] {
        guard !requested.isEmpty, !requested.contains("all") else {
            return UsageShareCard.allCases
        }
        var seen = Set<UsageShareCard>()
        var resolved: [UsageShareCard] = []
        for value in requested {
            guard let card = UsageShareCard(rawValue: value.lowercased()) else {
                throw CLIFailure.notFound(
                    "no usage card named \(value)",
                    hint: "cards: "
                        + (UsageShareCard.allCases.map(\.rawValue) + ["all"])
                        .joined(separator: ", "))
            }
            if seen.insert(card).inserted { resolved.append(card) }
        }
        return resolved
    }

    static func snapshot(
        document: UsageDocument, days: [UsageDay], sources: Set<String>?
    ) -> UsageShareSnapshot {
        let daily = UsageAnalysis.byDay(days, sources: sources).map { period, totals in
            UsageShareDay(period: period, tokens: totals.tokens, cost: totals.cost)
        }
        let agentIDs = Set(
            days.flatMap { day in
                day.rows(sources: sources).compactMap { entry in
                    entry.row.tokens > 0 || (entry.row.cost ?? 0) > 0 ? entry.source : nil
                }
            })
        let repositories = UsageAnalysis.byProject(days).count
        return UsageShareSnapshot(
            days: daily, agentCount: agentIDs.count, repositoryCount: repositories,
            generatedAt: document.generatedAt)
    }

    static func plan(
        cards: [UsageShareCard], output: String?, workingDirectory: URL,
        now: Date = Date()
    ) throws -> ExportPlan<UsageShareCard> {
        try ExportPlan(cards: cards, output: output, workingDirectory: workingDirectory, now: now)
    }

    static func write(snapshot: UsageShareSnapshot, plan: ExportPlan<UsageShareCard>) async throws
        -> [URL]
    {
        do {
            try FileManager.default.createDirectory(
                at: plan.directory, withIntermediateDirectories: true)
        } catch {
            throw CLIFailure(
                "could not create \(plan.directory.path): \(error.localizedDescription)")
        }
        var files: [URL] = []
        for card in plan.cards {
            let data = try UsageShareRenderer.pngData(
                snapshot: snapshot, card: card, scale: 2)
            let file =
                plan.explicitFile
                ?? plan.directory.appendingPathComponent(
                    "\(card.filenameStem)-\(plan.stamp).png")
            do {
                try ExportDelivery.write(data, to: file)
            } catch {
                throw CLIFailure("could not write \(file.path): \(error.localizedDescription)")
            }
            files.append(file)
        }
        return files
    }

    static func copyToClipboard(_ files: [URL]) throws {
        guard let file = files.first else {
            throw CLIFailure("there is no card to copy")
        }
        let data = try Data(contentsOf: file)
        do {
            try ExportDelivery.copyPNG(data, to: NSPasteboard.general)
        } catch ExportDeliveryError.copyFailed {
            throw CLIFailure("could not copy the card to the clipboard")
        }
    }
}
