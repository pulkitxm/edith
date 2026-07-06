import EdithKit
import Foundation

enum StandupGathering {
    static func gitCommits(
        repo: String, author: String, range: StandupDateRange.Range
    ) async -> [String] {
        guard !author.isEmpty else { return [] }
        let args = [
            "-C", repo, "log", "--all", "--no-merges",
            "--since=\(StandupDateRange.gitDateString(range.since))",
            "--until=\(StandupDateRange.gitDateString(range.until))",
            "--author=\(author)", "--pretty=- %s (%h)",
        ]
        let output = await runSync("/usr/bin/git", args)
        return output.split(separator: "\n").map(String.init)
    }

    static func authoredPRs(ghPath: String, dayQuery: String, allowlist: [String]) async -> [String]
    {
        let args = [
            "search", "prs", "--author=@me", "--updated=\(dayQuery)",
            "--json", "title,repository,state,url",
        ]
        let output = await runSync(ghPath, args)
        let prs = GHSearchParsing.parse(Data(output.utf8), allowlist: allowlist)
        return GHSearchParsing.lines(prs)
    }

    static func reviewedPRs(ghPath: String, dayQuery: String, allowlist: [String]) async -> [String]
    {
        let args = [
            "search", "prs", "--reviewed-by=@me", "--updated=\(dayQuery)",
            "--json", "title,repository,url",
        ]
        let output = await runSync(ghPath, args)
        let prs = GHSearchParsing.parse(Data(output.utf8), allowlist: allowlist)
        return GHSearchParsing.lines(prs)
    }

    static func synthesize(claudePath: String, model: String, context: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: claudePath)
            p.arguments = [
                "-p", StandupContext.prompt, "--model", model, "--max-turns", "1",
                "--output-format", "text",
            ]
            p.qualityOfService = .utility
            let input = Pipe()
            let out = Pipe()
            p.standardInput = input
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            input.fileHandleForWriting.write(Data(context.utf8))
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (text?.isEmpty ?? true) ? nil : text
        }.value
    }

    private static func runSync(_ executable: String, _ arguments: [String]) async -> String {
        await Task.detached(priority: .utility) { () -> String in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = arguments
            p.qualityOfService = .utility
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return "" }
            p.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}
