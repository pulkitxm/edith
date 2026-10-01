import ArgumentParser
import EdithKit
import Foundation

enum LiveCancelCLI {
    static func windowCount(
        request: Notification.Name, result: Notification.Name, countKey: String, what: String
    ) async throws -> Int {
        guard AppBridge.mainAppIsRunning else { return 0 }
        let requestID = UUID().uuidString
        guard
            let reply = await AppBridge.awaitReply(
                result, timeout: 8,
                matching: { $0["requestID"] as? String == requestID },
                trigger: { AppBridge.post(request, userInfo: ["requestID": requestID]) })
        else { throw AppBridge.silence(what) }
        guard reply["ok"] as? Bool == true else {
            throw CLIFailure(reply["error"] as? String ?? "Edith did not answer")
        }
        if let flag = reply[countKey] as? String, flag == "true" { return 1 }
        if let flag = reply[countKey] as? String, flag == "false" { return 0 }
        return Int(reply[countKey] as? String ?? "") ?? 0
    }

    static func commandJSON(_ flights: [CLIFlight]) -> JSONValue {
        .array(
            flights.map {
                .object([
                    "action": .string($0.action),
                    "pid": .int(Int($0.pid)),
                    "target": .string($0.target),
                ])
            })
    }
}

struct HomebrewCancelCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cancel",
        abstract: "Cancel an in-flight Homebrew install, upgrade, or uninstall.",
        discussion: """
            Stops a Homebrew change the page or `ed brew` already started.
            Reads the running operation. Changes it by cancelling the process. Does not uninstall anything by itself.

            ed brew cancel
            ed brew cancel --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let window = try await LiveCancelCLI.windowCount(
                request: IPC.Name.requestHomebrewCancel, result: IPC.Name.homebrewCancelResult,
                countKey: "cancelled", what: "Homebrew")
            let commands = CLIFlights.signal(kind: "brew")
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("cancel"),
                        "commands": LiveCancelCLI.commandJSON(commands),
                        "window": .int(window),
                    ]))
                return
            }
            if window == 0, commands.isEmpty {
                CLIOut.out("no Homebrew operation is in progress")
            } else {
                CLIOut.out("cancelled \(window) window operation and \(commands.count) command")
            }
        }
    }
}

struct CompanionStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop companion generation that is in progress.",
        discussion: """
            Stops the reply the chat window is writing, and a chat this terminal already started.
            Reads whether a reply is streaming. Changes that reply by stopping it.

            ed companion stop
            ed companion stop --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let window = try await LiveCancelCLI.windowCount(
                request: IPC.Name.requestCompanionStop, result: IPC.Name.companionStopResult,
                countKey: "stopped", what: "companion chat")
            let commands = CLIFlights.signal(kind: "companion")
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("stop"),
                        "commands": LiveCancelCLI.commandJSON(commands),
                        "window": .int(window),
                    ]))
                return
            }
            if window == 0, commands.isEmpty {
                CLIOut.out("no companion reply is being written")
            } else {
                CLIOut.out("stopped \(window) window reply and \(commands.count) command")
            }
        }
    }
}
