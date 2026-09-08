import AppKit
import ArgumentParser
import EdithKit
import Foundation

struct AppsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apps",
        abstract: "The applications running on this Mac.",
        discussion: """
            Listing samples the process table and needs nothing. Quitting asks the Edith
            app to do it, waits for its result, and exits 4 when Edith is closed or silent.
            """,
        subcommands: [AppsListCommand.self, AppsOpenCommand.self, AppsQuitCommand.self],
        defaultSubcommand: AppsListCommand.self)
}

struct AppsOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open an installed app by bundle identifier.")

    @Argument(help: "Application bundle identifier.") var bundleIdentifier: String
    @Flag(name: .long, help: "Emit JSON on stdout.") var json = false

    func run() async throws {
        try await execute {
            guard
                let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleIdentifier)
            else {
                throw CLIFailure.notFound("no installed app has bundle id \(bundleIdentifier)")
            }
            let application = try await NSWorkspace.shared.openApplication(
                at: url, configuration: NSWorkspace.OpenConfiguration())
            if json {
                CLIOut.json(
                    .object([
                        "bundleID": .string(bundleIdentifier), "opened": .bool(true),
                        "pid": .int(Int(application.processIdentifier)),
                    ]))
            } else {
                CLIOut.out("opened \(bundleIdentifier)")
            }
        }
    }
}

enum AppsCLI {
    static var operations: RunningAppOperationCenter {
        RunningAppOperationCenter(
            snapshot: CLIEnvironment.runningApps,
            perform: { _, _ in 0 })
    }

    static func list() async -> [RunningAppSnapshot] {
        let operations = Self.operations
        let apps = operations.list()
        let baseline = operations.resourceBaseline(for: apps)
        try? await Task.sleep(for: .milliseconds(100))
        return operations.measureResources(for: apps, from: baseline).apps
    }

    static func json(_ app: RunningAppSnapshot, resources: Bool = true) -> JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(app.name),
            "bundleID": .optional(app.bundleID),
            "pid": .int(Int(app.pid)),
            "active": .bool(app.active),
        ]
        if resources {
            object["cpuPercent"] = .double(app.cpuPercent)
            object["memoryMB"] = .double(app.memoryMB)
        }
        return .object(object)
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
                    "acknowledged": .bool(outcome.acknowledged),
                    "requested": .int(outcome.plan.targets.count),
                    "changed": .int(outcome.changed),
                    "targets": .array(outcome.plan.targets.map { Self.json($0, resources: false) }),
                ]))
            return
        }
        let targets = outcome.plan.targets
        let names = targets.map(\.name).joined(separator: ", ")
        let label: String
        if targets.isEmpty {
            label = "0 apps"
        } else if targets.count == 1 {
            label = names
        } else {
            label = "\(targets.count) apps: \(names)"
        }
        if !outcome.applied {
            CLIOut.out("would quit \(label); pass --yes to apply")
            return
        }
        CLIOut.out(
            "Edith accepted quit for \(outcome.changed) of \(outcome.plan.targets.count) apps")
    }

    static func apply(_ plan: RunningAppQuitPlan) async throws -> RunningAppQuitOutcome {
        let requestID = UUID().uuidString
        let targets = plan.targets
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.quitAppsResult, timeout: 5,
                matching: { $0[RunningAppIPC.requestIDKey] as? String == requestID },
                trigger: {
                    AppBridge.post(
                        IPC.Name.requestQuitApps,
                        userInfo: [
                            RunningAppIPC.requestIDKey: requestID,
                            RunningAppIPC.pidsKey: targets.map { Int($0.pid) },
                            RunningAppIPC.forceKey: plan.force,
                        ])
                })
        else {
            throw AppBridge.silence("quitting apps")
        }
        guard let changed = reply[RunningAppIPC.changedKey] as? Int else {
            throw CLIFailure("Edith returned an invalid quit result")
        }
        return RunningAppQuitOutcome(
            plan: plan, applied: true, acknowledged: true,
            changed: min(max(0, changed), targets.count))
    }
}

struct AppsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the apps with a window open.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let apps = await AppsCLI.list()
            guard !json else {
                CLIOut.json(.array(apps.map { AppsCLI.json($0) }))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "PID", "CPU", "MEMORY", "BUNDLE"],
                    rows: apps.map {
                        [
                            $0.name, String($0.pid), String(format: "%.1f%%", $0.cpuPercent),
                            String(format: "%.1f MB", $0.memoryMB), $0.bundleID ?? "",
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
            AppsCLI.render(try await AppsCLI.apply(plan), json: json)
        }
    }
}
