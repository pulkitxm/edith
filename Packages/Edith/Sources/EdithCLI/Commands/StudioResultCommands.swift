import ArgumentParser
import EdithKit
import Foundation

enum StudioResultCLI {
    static func payload(action: String, paths: [String]) -> JSONValue {
        .object([
            "action": .string(action),
            "paths": .array(paths.map { .string($0) }),
        ])
    }

    static func present(_ action: String, urls: [URL], json: Bool, plain: String) {
        let paths = urls.map(\.path)
        guard !json else {
            CLIOut.json(payload(action: action, paths: paths))
            return
        }
        if paths.isEmpty {
            CLIOut.out(plain)
        } else {
            for path in paths { CLIOut.out(path) }
        }
    }
}

struct StudioCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel the Studio run that is in progress.",
        discussion: """
            Stops the run the Studio page started, the same way its Cancel button does.
            Reads whether a run is active in the open window. Changes that run by cancelling it.
            A run started in this terminal still stops with Control-C.

            ed studio cancel
            ed studio cancel --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try AppBridge.requireMainApp("a Studio run")
            let requestID = UUID().uuidString
            guard
                let reply = await AppBridge.awaitReply(
                    IPC.Name.studioJobResult, timeout: 8,
                    matching: { $0["requestID"] as? String == requestID },
                    trigger: {
                        AppBridge.post(
                            IPC.Name.requestStudioCancel, userInfo: ["requestID": requestID])
                    })
            else { throw AppBridge.silence("a Studio run") }
            guard reply["ok"] as? Bool == true else {
                throw CLIFailure(reply["error"] as? String ?? "Studio did not cancel the run")
            }
            let tools = (reply["tools"] as? String ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            let cancelled = Int(reply["cancelled"] as? String ?? "") ?? tools.count
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("cancel"),
                        "cancelled": .int(cancelled),
                        "tools": .array(tools.map { .string($0) }),
                    ]))
                return
            }
            if tools.isEmpty {
                CLIOut.out("no Studio run is in progress")
            } else {
                CLIOut.out("cancelled \(tools.joined(separator: ", "))")
            }
        }
    }
}

struct StudioRevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal",
        abstract: "Reveal Studio result files in Finder.",
        discussion: """
            Shows result files in Finder, the same way Show in Finder does on a Studio result.
            Reads the paths you pass. Changes which files Finder selects. Does not change the files.

            ed studio reveal report.pdf
            ed studio reveal report.pdf --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Result files to select in Finder.")
    var files: [String]

    func run() async throws {
        try await execute {
            guard !files.isEmpty else {
                throw CLIFailure.usage("pass at least one result file")
            }
            let urls = try StudioBridge.files(files)
            await StudioFinderReveal.reveal(urls)
            StudioResultCLI.present("reveal", urls: urls, json: json, plain: "revealed")
        }
    }
}

struct StudioOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Open a Studio result file.",
        discussion: """
            Opens each result in the app macOS uses for that kind of file.
            Reads the paths you pass. Changes nothing on disk. Does not change the files.

            ed studio open report.pdf
            ed studio open report.pdf --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Result files to open.")
    var files: [String]

    func run() async throws {
        try await execute {
            guard !files.isEmpty else {
                throw CLIFailure.usage("pass at least one result file")
            }
            let urls = try StudioBridge.files(files)
            for url in urls { StudioFinderReveal.open(url) }
            StudioResultCLI.present("open", urls: urls, json: json, plain: "opened")
        }
    }
}
