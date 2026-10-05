import AppKit
import ArgumentParser
import EdithKit
import Foundation

struct CodeStatsExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render your code stats as branded PNG cards.",
        discussion: """
            Render aggregate code stats as high resolution PNG cards: commits, lines authored, streaks, languages and rhythm. Repository names are never included.
            Reads the report the last refresh stored. Writes the PNG files, and the clipboard with --clipboard. Does not refresh anything.

            ed code-stats export
            ed code-stats export --range 90d --card highlights --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "highlights, languages, rhythm or all. Repeatable.")
    var card: [String] = []

    @Option(name: .long, help: "Range to export: 30d, 90d, 1y or all.")
    var range = "30d"

    @Option(name: [.short, .long], help: "Output directory, or a PNG path for one card.")
    var output: String?

    @Flag(name: .long, help: "Also copy the first rendered card to the clipboard.")
    var clipboard = false

    func run() async throws {
        try await execute {
            let selected = try CodeStatsExportFiles.cards(card)
            guard let parsed = CodeStatsRange(argument: range),
                CodeStatsRange.presets.contains(parsed)
            else {
                throw CLIFailure.usage(
                    "\(range) is not an export range", hint: "use 30d, 90d, 1y or all")
            }
            let report = try await CodeStatsCLI.call {
                try await CodeStatsCLIEnvironment.client().report(parsed)
            }
            guard let report else {
                throw CLIFailure.notFound(
                    "no code stats report exists yet", hint: "run ed code-stats run --wait")
            }
            let snapshot = CodeStatsExportSnapshot(report: report)
            guard snapshot.hasActivity else {
                throw CLIFailure.unavailable(
                    "there is no code activity to export for this range",
                    hint: "choose a wider range or run `ed code-stats run --wait`")
            }
            let plan = try CodeStatsExportFiles.plan(
                cards: selected, output: output,
                workingDirectory: URL(
                    fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            let files = try await CodeStatsExportFiles.write(snapshot: snapshot, plan: plan)
            if clipboard { try CodeStatsExportFiles.copyToClipboard(files) }
            guard !json else {
                try CodeStatsCLI.print(
                    CodeStatsExportResult(
                        range: parsed.argument, files: files.map(\.path), metrics: snapshot))
                return
            }
            for file in files { CLIOut.out("exported \(file.path)") }
        }
    }
}

struct CodeStatsExportResult: Codable, Equatable {
    let range: String
    let files: [String]
    let metrics: CodeStatsExportSnapshot
}

enum CodeStatsExportFiles {
    static func cards(_ requested: [String]) throws -> [CodeStatsExportCard] {
        guard !requested.isEmpty, !requested.contains("all") else {
            return CodeStatsExportCard.allCases
        }
        var seen = Set<CodeStatsExportCard>()
        var resolved: [CodeStatsExportCard] = []
        for value in requested {
            guard let card = CodeStatsExportCard(rawValue: value.lowercased()) else {
                throw CLIFailure.notFound(
                    "no code stats card named \(value)",
                    hint: "cards: "
                        + (CodeStatsExportCard.allCases.map(\.rawValue) + ["all"])
                        .joined(separator: ", "))
            }
            if seen.insert(card).inserted { resolved.append(card) }
        }
        return resolved
    }

    static func plan(
        cards: [CodeStatsExportCard], output: String?, workingDirectory: URL, now: Date = Date()
    ) throws -> ExportPlan<CodeStatsExportCard> {
        try ExportPlan(cards: cards, output: output, workingDirectory: workingDirectory, now: now)
    }

    static func write(
        snapshot: CodeStatsExportSnapshot, plan: ExportPlan<CodeStatsExportCard>
    ) async throws -> [URL] {
        do {
            try FileManager.default.createDirectory(
                at: plan.directory, withIntermediateDirectories: true)
        } catch {
            throw CLIFailure(
                "could not create \(plan.directory.path): \(error.localizedDescription)")
        }
        var files: [URL] = []
        for card in plan.cards {
            let data = try await CodeStatsExportRenderer.pngData(
                snapshot: snapshot, card: card, scale: 2)
            let file =
                plan.explicitFile
                ?? plan.directory.appendingPathComponent("\(card.filenameStem)-\(plan.stamp).png")
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
        guard let file = files.first else { throw CLIFailure("there is no card to copy") }
        let data = try Data(contentsOf: file)
        do {
            try ExportDelivery.copyPNG(data, to: CLIEnvironment.clipboardPasteboard)
        } catch ExportDeliveryError.copyFailed {
            throw CLIFailure("could not copy the card to the clipboard")
        }
    }
}
