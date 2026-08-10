import AppKit
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

enum AppsBridge {
    static func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "")
                    == .orderedAscending
            }
    }

    static func resolve(_ query: String) throws -> NSRunningApplication {
        let all = running()
        let needle = query.lowercased()
        if let exact = all.first(where: { ($0.localizedName ?? "").lowercased() == needle }) {
            return exact
        }
        if let byBundle = all.first(where: { ($0.bundleIdentifier ?? "").lowercased() == needle }) {
            return byBundle
        }
        let prefixed = all.filter { ($0.localizedName ?? "").lowercased().hasPrefix(needle) }
        if prefixed.count == 1, let only = prefixed.first { return only }
        if prefixed.count > 1 {
            throw CLIFailure.notFound(
                "\(query) matches more than one app",
                hint: prefixed.compactMap(\.localizedName).joined(separator: ", "))
        }
        throw CLIFailure.notFound(
            "no running app called \(query)", hint: "run `ed apps ls` to see them")
    }

    static func json(_ app: NSRunningApplication) -> JSONValue {
        .object([
            "name": .string(app.localizedName ?? ""),
            "bundleID": .optional(app.bundleIdentifier),
            "pid": .int(Int(app.processIdentifier)),
            "active": .bool(app.isActive),
        ])
    }
}

struct AppsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the apps with a window open.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let apps = AppsBridge.running()
            guard !json else {
                CLIOut.json(.array(apps.map(AppsBridge.json)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "PID", "BUNDLE"],
                    rows: apps.map {
                        [
                            $0.localizedName ?? "", String($0.processIdentifier),
                            $0.bundleIdentifier ?? "",
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

    @Flag(help: "Actually quit. Required with --all.")
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
            try AppBridge.requireHelper("quitting apps")
            if all {
                let targets = AppsBridge.running().filter {
                    $0.bundleIdentifier != "com.apple.finder"
                        && $0.bundleIdentifier != AppBridge.mainBundleID
                        && $0.bundleIdentifier != AppBridge.helperBundleID
                }
                guard yes else {
                    guard !json else {
                        CLIOut.json(
                            .object(["apps": .int(targets.count), "quit": .bool(false)]))
                        return
                    }
                    CLIOut.out("would quit \(targets.count) app(s)")
                    CLIOut.note("nothing was quit; pass --yes to go ahead")
                    return
                }
                AppBridge.post(
                    IPC.Name.requestQuitApps, userInfo: ["all": true, "force": force])
                guard !json else {
                    CLIOut.json(.object(["apps": .int(targets.count), "quit": .bool(true)]))
                    return
                }
                CLIOut.out("asked Edith to quit \(targets.count) app(s)")
                return
            }
            let target = try AppsBridge.resolve(app ?? "")
            AppBridge.post(
                IPC.Name.requestQuitApps,
                userInfo: ["pid": Int(target.processIdentifier), "force": force])
            guard !json else {
                CLIOut.json(AppsBridge.json(target))
                return
            }
            CLIOut.out("asked Edith to quit \(target.localizedName ?? app ?? "")")
        }
    }
}
