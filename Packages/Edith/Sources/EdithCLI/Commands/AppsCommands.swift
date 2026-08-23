import ArgumentParser
import EdithKit
import Foundation

struct AppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "The applications running on this Mac.",
        discussion: """
            Listing reads the process table and needs nothing. Quitting asks the Edith app
            to do it, because sending a quit event belongs to the app's Automation grant
            rather than to `ed`, and exits 4 when Edith is closed.
            """,
        subcommands: [AppsListCommand.self, AppsQuitCommand.self],
        defaultSubcommand: AppsListCommand.self)
}

enum AppsCLI {
    static var operations: RunningAppOperationCenter {
        RunningAppOperationCenter(
            snapshot: CLIEnvironment.runningApps,
            perform: { targets, force in
                AppBridge.post(
                    IPC.Name.requestQuitApps,
                    userInfo: ["pids": targets.map { Int($0.pid) }, "force": force])
                return targets.count
            })
    }

    static func json(_ app: RunningAppSnapshot) -> JSONValue {
        .object([
            "name": .string(app.name),
            "bundleID": .optional(app.bundleID),
            "pid": .int(Int(app.pid)),
            "active": .bool(app.active),
        ])
    }

    static func plan(
        _ selection: RunningAppSelection, force: Bool
    ) throws -> RunningAppQuitPlan {
        do {
            return try operations.plan(selection, force: force)
        } catch let error as RunningAppResolutionError {
            switch error {
            case let .notFound(query):
                throw CLIFailure.notFound(
                    "no running app called \(query)", hint: "run `ed apps ls` to see them")
            case let .ambiguous(query, names):
                throw CLIFailure.notFound(
                    "\(query) matches more than one app", hint: names.joined(separator: ", "))
            case let .protected(name):
                throw CLIFailure("\(name) is protected and cannot be quit")
            }
        }
    }

    static func render(_ outcome: RunningAppQuitOutcome, json: Bool) {
        guard !json else {
            CLIOut.json(
                .object([
                    "operation": .string(RunningAppOperation.quit.descriptor.id.rawValue),
                    "force": .bool(outcome.plan.force),
                    "applied": .bool(outcome.applied),
                    "changed": .int(outcome.changed),
                    "targets": .array(outcome.plan.targets.map(Self.json)),
                ]))
            return
        }
        let targets = outcome.plan.targets
        let names = targets.map(\.name).joined(separator: ", ")
        if !outcome.applied {
            let label = targets.count == 1 ? names : "\(targets.count) apps: \(names)"
            CLIOut.out("would quit \(label); pass --yes to apply")
            return
        }
        let label = targets.count == 1 ? names : "\(targets.count) apps: \(names)"
        CLIOut.out("asked Edith to quit \(label)")
    }
}

struct AppsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the apps with a window open.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let apps = AppsCLI.operations.list()
            guard !json else {
                CLIOut.json(.array(apps.map(AppsCLI.json)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "PID", "BUNDLE"],
                    rows: apps.map {
                        [
                            $0.name, String($0.pid), $0.bundleID ?? "",
                        ]
                    }))
        }
    }
}

struct AppsQuitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quit",
        abstract: "Quit one app, or everything except Finder and Edith.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Quit everything except Finder and Edith.")
    var all = false

    @Flag(help: "Force it down rather than asking politely.")
    var force = false

    @Flag(help: "Actually quit. Without this, print the exact plan.")
    var yes = false

    @Argument(help: "App name or bundle id.")
    var app: String?

    func run() async throws {
        try await execute {
            guard all || app != nil else {
                throw CLIFailure("say which app to quit", hint: "pass a name, or --all")
            }
            guard !(all && app != nil) else {
                throw CLIFailure("--all quits everything, so it takes no app name")
            }
            let selection: RunningAppSelection = all ? .all : .query(app ?? "")
            let plan = try AppsCLI.plan(selection, force: force)
            guard yes else {
                AppsCLI.render(AppsCLI.operations.apply(plan, confirmed: false), json: json)
                return
            }
            try AppBridge.requireHelper("quitting apps")
            AppsCLI.render(AppsCLI.operations.apply(plan, confirmed: true), json: json)
        }
    }
}
