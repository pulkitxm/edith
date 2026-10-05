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

struct CodeStatsExportPlan: Equatable {
    let cards: [CodeStatsExportCard]
    let explicitFile: URL?
    let directory: URL
    let stamp: String
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
    ) throws -> CodeStatsExportPlan {
        let resolved = output.map { NSString(string: $0).expandingTildeInPath }
        let target =
            resolved.map { path in
                URL(fileURLWithPath: path, relativeTo: workingDirectory).standardizedFileURL
            } ?? workingDirectory
        let explicitFile = target.pathExtension.lowercased() == "png" ? target : nil
        if explicitFile != nil, cards.count != 1 {
            throw CLIFailure.usage(
                "a PNG output path can only be used when exporting one card",
                hint: "pass one --card value or use a directory with --output")
        }
        return CodeStatsExportPlan(
            cards: cards, explicitFile: explicitFile,
            directory: explicitFile?.deletingLastPathComponent() ?? target,
            stamp: timestamp(now))
    }

    static func write(
        snapshot: CodeStatsExportSnapshot, plan: CodeStatsExportPlan
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
                try data.write(to: file, options: .atomic)
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
        let board = CLIEnvironment.clipboardPasteboard
        board.clearContents()
        guard board.setData(data, forType: .png) else {
            throw CLIFailure("could not copy the card to the clipboard")
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
