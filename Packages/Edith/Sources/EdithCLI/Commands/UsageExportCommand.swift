import ArgumentParser
import EdithKit
import Foundation

struct UsageExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render branded usage cards as PNG images.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "highlights, activity, daily, busiest or all. Repeatable.")
    var card: [String] = []

    @Option(name: [.short, .long], help: "Output directory, or a PNG path for one card.")
    var output: String?

    @OptionGroup var window: UsageWindow

    func run() async throws {
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
                cards: selected, output: output, workingDirectory: URL(fileURLWithPath: FileManager
                    .default.currentDirectoryPath, isDirectory: true))
            let files = try await UsageShareExport.write(snapshot: snapshot, plan: plan)
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

struct UsageShareExportPlan: Equatable {
    let cards: [UsageShareCard]
    let explicitFile: URL?
    let directory: URL
    let stamp: String
}

enum UsageShareExport {
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
    ) throws -> UsageShareExportPlan {
        let resolved = output.map { NSString(string: $0).expandingTildeInPath }
        let target = resolved.map { path in
            URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
        } ?? workingDirectory
        let explicitFile = target.pathExtension.lowercased() == "png" ? target : nil
        if explicitFile != nil, cards.count != 1 {
            throw CLIFailure.usage(
                "a PNG output path can only be used when exporting one card",
                hint: "pass one --card value or use a directory with --output")
        }
        return UsageShareExportPlan(
            cards: cards, explicitFile: explicitFile,
            directory: explicitFile?.deletingLastPathComponent() ?? target,
            stamp: timestamp(now))
    }

    static func write(snapshot: UsageShareSnapshot, plan: UsageShareExportPlan) async throws
        -> [URL]
    {
        do {
            try FileManager.default.createDirectory(
                at: plan.directory, withIntermediateDirectories: true)
        } catch {
            throw CLIFailure("could not create \(plan.directory.path): \(error.localizedDescription)")
        }
        var files: [URL] = []
        for card in plan.cards {
            let data = try await UsageShareRenderer.pngData(
                snapshot: snapshot, card: card, scale: 2)
            let file = plan.explicitFile
                ?? plan.directory.appendingPathComponent(
                    "\(card.filenameStem)-\(plan.stamp).png")
            do {
                try data.write(to: file, options: .atomic)
            } catch {
                throw CLIFailure("could not write \(file.path): \(error.localizedDescription)")
            }
            files.append(file)
        }
        return files
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
