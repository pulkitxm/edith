import ArgumentParser
import EdithKit
import Foundation

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "One-shot actions the Edith app performs.",
        discussion: """
            These are verbs, not settings: things the app does once when asked, rather
            than switches `ed config set` can flip. Each needs the app that owns it, so
            they exit 4 and say which part is missing when it is not running.
            """,
        subcommands: [
            AppActionsCommand.self, AppCleanKeysCommand.self, AppTestNotificationCommand.self,
            AppOpenCommand.self, AppQuitCommand.self, AppCheckUpdatesCommand.self,
            AppUpdatesCommand.self, AppRelaunchCommand.self,
            AppClearUpdateHistoryCommand.self, AppRevealCommand.self, AppSnapshotCommand.self,
        ],
        defaultSubcommand: AppActionsCommand.self)
}

struct AppAction: Sendable {
    let name: String
    let summary: String
    let needsMainApp: Bool
}

enum AppActions {
    static let all: [AppAction] = [
        AppAction(
            name: "clean-keys", summary: "Lock the keyboard so it can be wiped.",
            needsMainApp: false),
        AppAction(
            name: "test-notification", summary: "Send a test notification.",
            needsMainApp: false),
        AppAction(name: "open", summary: "Open the Edith panel.", needsMainApp: false),
        AppAction(name: "quit", summary: "Quit the Edith main window.", needsMainApp: true),
        AppAction(
            name: "check-updates", summary: "Ask Sparkle to check for an update now.",
            needsMainApp: true),
        AppAction(
            name: "reveal", summary: "Show a section of the main window.",
            needsMainApp: true),
        AppAction(
            name: "snapshot", summary: "Capture the open windows as PNG files.",
            needsMainApp: true),
    ]

    static func require(_ action: AppAction) throws {
        guard action.needsMainApp else {
            try AppBridge.requireHelper(action.name)
            return
        }
        try AppBridge.requireMainApp(action.name)
    }

    static func fire(_ action: AppAction, _ name: Notification.Name, json: Bool) async throws {
        try require(action)
        AppBridge.post(name)
        guard !json else {
            CLIOut.json(.object(["action": .string(action.name), "requested": .bool(true)]))
            return
        }
        CLIOut.out("\(action.name) requested")
    }

    static func named(_ name: String) throws -> AppAction {
        guard let found = all.first(where: { $0.name == name }) else {
            throw CLIFailure.notFound(
                "no app action named \(name)",
                hint: "actions: " + all.map(\.name).joined(separator: ", "))
        }
        return found
    }
}

struct AppActionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "actions", abstract: "List the one-shot actions and whether they can run.",
        aliases: ["ls"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let helper = AppBridge.helperIsRunning
            let main = AppBridge.mainAppIsRunning
            guard !json else {
                CLIOut.json(
                    .array(
                        AppActions.all.map { action in
                            .object([
                                "action": .string(action.name),
                                "summary": .string(action.summary),
                                "needs": .string(action.needsMainApp ? "mainApp" : "menuBar"),
                                "available": .bool(action.needsMainApp ? main : helper),
                            ])
                        }))
                return
            }
            let rows = AppActions.all.map { action in
                [
                    action.name, action.needsMainApp ? "main app" : "menu bar",
                    (action.needsMainApp ? main : helper) ? "ready" : "app not running",
                    action.summary,
                ]
            }
            CLIOut.out(
                TextTable.render(headers: ["ACTION", "NEEDS", "STATE", "WHAT"], rows: rows))
        }
    }
}

struct AppCleanKeysCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean-keys",
        abstract: "Lock the keyboard so it can be wiped without typing.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await AppActions.fire(
                AppActions.named("clean-keys"), IPC.Name.requestKeyboardClean, json: json)
        }
    }
}

struct AppTestNotificationCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-notification",
        abstract: "Send the same test notification the settings pane sends.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await AppActions.fire(
                AppActions.named("test-notification"), IPC.Name.requestTestNotification,
                json: json)
        }
    }
}

struct AppOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open Edith's panel.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await AppActions.fire(
                AppActions.named("open"), IPC.Name.openPanel, json: json)
        }
    }
}

struct AppQuitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quit",
        abstract: "Quit the Edith main window, leaving the menu bar running.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try await AppActions.fire(
                AppActions.named("quit"), IPC.Name.quitMainApp, json: json)
        }
    }
}

struct AppCheckUpdatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-updates",
        abstract: "Ask the running app to check for an update now.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Return as soon as the request is sent.")
    var noWait = false

    func run() async throws {
        try await execute {
            let action = try AppActions.named("check-updates")
            try AppActions.require(action)
            let reply = await AppBridge.awaitReply(
                IPC.Name.updateCheckFinished, timeout: noWait ? 0.1 : 60
            ) {
                AppBridge.post(IPC.Name.requestUpdateCheck)
            }
            guard let reply else {
                guard noWait else {
                    throw AppBridge.silence("the update check")
                }
                guard !json else {
                    CLIOut.json(.object(["requested": .bool(true), "finished": .bool(false)]))
                    return
                }
                CLIOut.out("update check requested")
                return
            }
            let outcome = reply["outcome"] as? String ?? "unknown"
            let version = reply["version"] as? String
            guard !json else {
                CLIOut.json(
                    .object([
                        "requested": .bool(true), "finished": .bool(true),
                        "outcome": .string(outcome), "version": .optional(version),
                        "detail": .optional(reply["detail"] as? String),
                    ]))
                return
            }
            CLIOut.out(version.map { "\(outcome) \($0)" } ?? outcome)
        }
    }
}

struct AppUpdatesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "updates", abstract: "The update checks Edith has already made.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Show at most this many checks.")
    var limit: Int = 20

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.positive(self.limit, "--limit")
            let records = Array(UpdateCheckLog.load().prefix(limit))
            guard !json else {
                CLIOut.json(
                    .array(
                        records.map { record in
                            .object([
                                "date": .date(record.date),
                                "kind": .string(record.kind.rawValue),
                                "outcome": .string(record.outcome.rawValue),
                                "version": .optional(record.version),
                                "detail": .optional(record.detail),
                            ])
                        }))
                return
            }
            guard !records.isEmpty else {
                CLIOut.note("no update checks recorded yet")
                return
            }
            let rows = records.map { record in
                [
                    JSONSerializer.iso.string(from: record.date), record.kind.rawValue,
                    record.outcome.rawValue, record.summary,
                ]
            }
            CLIOut.out(
                TextTable.render(headers: ["WHEN", "KIND", "OUTCOME", "WHAT"], rows: rows))
        }
    }
}

struct AppRelaunchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "relaunch",
        abstract: "Quit Edith and start it again, which is what a new permission needs.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let bundle = CLIEnvironment.installedAppURL() else {
                throw CLIFailure.unavailable(
                    "Edith is not installed where ed can find it",
                    hint: "it looks in /Applications and alongside this binary")
            }
            let progress = CLIProgress.forCommand(json: json)
            AppBridge.post(IPC.Name.quitMainApp)
            progress.begin("waiting for Edith to quit")
            let stopped = await EdithProcesses.quitAll(within: 8)
            progress.end()
            guard stopped else {
                throw CLIFailure(
                    "Edith did not quit, so it was not relaunched",
                    hint: "quit it from the menu bar, then run `ed app relaunch` again")
            }
            progress.begin("starting Edith")
            do {
                try await EdithProcesses.launch(bundle)
            } catch {
                progress.end()
                throw CLIFailure(
                    "could not start Edith: \(error.localizedDescription)",
                    hint: "open \(bundle.path) from Finder")
            }
            progress.end()
            guard !json else {
                CLIOut.json(.object(["relaunched": .bool(true), "path": .string(bundle.path)]))
                return
            }
            CLIOut.out("relaunched Edith")
        }
    }
}

struct AppClearUpdateHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-updates", abstract: "Forget the record of past update checks.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let before = UpdateCheckLog.load().count
            UpdateCheckLog.clear()
            guard !json else {
                CLIOut.json(.object(["removed": .int(before)]))
                return
            }
            CLIOut.out("cleared \(before) check(s)")
        }
    }
}

struct AppRevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reveal",
        abstract: "Show a section of the main window, and optionally a tab inside it.")

    @Argument(
        help: ArgumentHelp(
            "The section to show; without it the window comes up where it was.",
            discussion:
                "One of home, dashboard, herdr, music, calendar, system, machines, companion, "
                + "extensions, settings, about."))
    var section: String?

    @Option(help: "A tab inside the section; companion and settings have them.")
    var tab: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let action = try AppActions.named("reveal")
            try AppActions.require(action)
            if tab != nil, section == nil {
                throw CLIFailure.usage(
                    "--tab needs a section to go with it",
                    hint: "ed app reveal companion --tab chat")
            }
            let payload: [String: Any]
            switch (section, tab) {
            case let (.some(section), .some(tab)) where !tab.isEmpty:
                payload = ["section": section, "tab": tab]
            case let (.some(section), _):
                payload = ["section": section]
            default:
                payload = [:]
            }
            let reply = await AppBridge.awaitReply(IPC.Name.revealResult, timeout: 10) {
                AppBridge.post(IPC.Name.requestReveal, userInfo: payload)
            }
            guard let reply else {
                throw AppBridge.silence("the reveal")
            }
            let ok = reply["ok"] as? Bool ?? false
            guard ok else {
                throw CLIFailure.notFound(
                    reply["error"] as? String ?? "the app refused the reveal",
                    hint: "run `ed app reveal --help` for the section and tab names")
            }
            let shown = reply["section"] as? String ?? section ?? "the window"
            let shownTab = reply["tab"] as? String
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("reveal"), "section": .string(shown),
                        "tab": .optional(shownTab),
                    ]))
                return
            }
            CLIOut.out(shownTab.map { "showing \(shown) · \($0)" } ?? "showing \(shown)")
        }
    }
}

struct AppSnapshotCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture the app's open windows as PNG files.")

    @Option(help: "Write the images into this directory; /tmp/edith-snapshots without it.")
    var dir: String?

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let action = try AppActions.named("snapshot")
            try AppActions.require(action)
            let payload: [String: Any]
            if let dir, !dir.isEmpty {
                payload = [
                    "dir": URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).path
                ]
            } else {
                payload = [:]
            }
            let reply = await AppBridge.awaitReply(IPC.Name.windowSnapshotResult, timeout: 15) {
                AppBridge.post(IPC.Name.requestWindowSnapshot, userInfo: payload)
            }
            guard let reply else {
                throw AppBridge.silence("the snapshot")
            }
            let ok = reply["ok"] as? Bool ?? false
            guard ok else {
                throw CLIFailure(
                    reply["error"] as? String ?? "the app could not capture its windows",
                    hint: "make sure a window is open; `ed app open` brings one up")
            }
            let files = (reply["files"] as? String ?? "")
                .split(separator: "\n").map(String.init)
            guard !json else {
                CLIOut.json(.object(["files": .array(files.map { .string($0) })]))
                return
            }
            for file in files { CLIOut.out(file) }
        }
    }
}
