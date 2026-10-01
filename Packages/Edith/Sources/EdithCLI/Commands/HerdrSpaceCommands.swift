import ArgumentParser
import EdithKit
import Foundation

struct HerdrSpaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "space",
        abstract: "List and control open Herdr space windows.",
        discussion: """
            Talks to the space windows that are open in Edith.
            Reads those windows. terminal and split change the selected one. Does not change sessions by itself.

            ed herdr space ls
            """,
        subcommands: [
            HerdrSpaceListCommand.self, HerdrSpaceTerminalCommand.self, HerdrSpaceSplitCommand.self,
        ],
        defaultSubcommand: HerdrSpaceListCommand.self)
}

enum HerdrSpaceCLI {
    static func request(action: String, window: String?, side: String?) async throws -> (
        windows: [[String: Any]], message: String?
    ) {
        try AppBridge.requireMainApp("a Herdr space window")
        let requestID = UUID().uuidString
        var fields: [String: Any] = ["requestID": requestID, "action": action]
        if let window, !window.isEmpty { fields["window"] = window }
        if let side { fields["side"] = side }
        let payload = fields
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.herdrSpaceActionResult, timeout: 8,
                matching: { $0["requestID"] as? String == requestID },
                trigger: { AppBridge.post(IPC.Name.requestHerdrSpaceAction, userInfo: payload) })
        else { throw AppBridge.silence("a Herdr space window") }
        let windows = decode(reply["windows"] as? String)
        guard reply["ok"] as? Bool == true else {
            throw CLIFailure.notFound(
                reply["error"] as? String ?? "no space window matched",
                hint: "run `ed herdr space ls`")
        }
        return (windows, reply["message"] as? String)
    }

    static func decode(_ raw: String?) -> [[String: Any]] {
        guard let raw, let data = raw.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return value
    }

    static func emit(_ windows: [[String: Any]], message: String?, json: Bool) {
        guard !json else {
            CLIOut.json(
                .object([
                    "message": .optional(message),
                    "windows": .array(windows.map(jsonWindow)),
                ]))
            return
        }
        if let message { CLIOut.out(message) }
        for window in windows {
            let id = window["id"] as? String ?? ""
            let title = window["title"] as? String ?? ""
            let tabs = window["tabs"] as? Int ?? 0
            let panes = window["panes"] as? Int ?? 0
            CLIOut.out("\(id)\t\(title)\t\(tabs) tabs\t\(panes) panes")
        }
        if windows.isEmpty, message == nil { CLIOut.out("no space window is open") }
    }

    static func jsonWindow(_ window: [String: Any]) -> JSONValue {
        .object([
            "id": .string(window["id"] as? String ?? ""),
            "panes": .int(window["panes"] as? Int ?? 0),
            "tabs": .int(window["tabs"] as? Int ?? 0),
            "title": .string(window["title"] as? String ?? ""),
        ])
    }

    static func side(_ raw: String) throws -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left": "left"
        case "right": "right"
        case "top", "up": "top"
        case "bottom", "down": "bottom"
        default:
            throw CLIFailure.usage(
                "side must be right, left, down, or up",
                hint: "the space window uses right and down")
        }
    }
}

struct HerdrSpaceListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List the open Herdr space windows.",
        discussion: """
            Reads the space windows Edith has open. Does not change them.

            ed herdr space ls
            ed herdr space ls --json
            """, aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let reply = try await HerdrSpaceCLI.request(action: "list", window: nil, side: nil)
            HerdrSpaceCLI.emit(reply.windows, message: reply.message, json: json)
        }
    }
}

struct HerdrSpaceTerminalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Open a terminal in a Herdr space window.",
        discussion: """
            Adds a shell tab in one open space window, the same way Command-T does there.
            Reads the open windows. Changes the chosen window by adding a terminal.

            ed herdr space terminal
            ed herdr space terminal --window desk --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(
        name: .long, help: "Space id or title. The only open window is used when this is omitted.")
    var window: String?

    func run() async throws {
        try await execute {
            let reply = try await HerdrSpaceCLI.request(
                action: "terminal", window: window, side: nil)
            HerdrSpaceCLI.emit(reply.windows, message: reply.message, json: json)
        }
    }
}

struct HerdrSpaceSplitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Split the focused pane in a Herdr space window.",
        discussion: """
            Splits the focused pane, the same way Split right and Split down do in the space window.
            Reads the open windows. Changes the chosen window by adding a pane. --side is right, left, down, or up.

            ed herdr space split --side right
            ed herdr space split --window desk --side down --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(
        name: .long, help: "Space id or title. The only open window is used when this is omitted.")
    var window: String?

    @Option(name: .long, help: "right, left, down, or up. Defaults to right.")
    var side: String = "right"

    func run() async throws {
        try await execute {
            let reply = try await HerdrSpaceCLI.request(
                action: "split", window: window, side: try HerdrSpaceCLI.side(side))
            HerdrSpaceCLI.emit(reply.windows, message: reply.message, json: json)
        }
    }
}
