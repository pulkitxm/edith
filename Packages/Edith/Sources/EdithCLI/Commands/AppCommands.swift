import ArgumentParser
import EdithKit
import Foundation

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "One-shot actions the Edith app performs.",
        discussion: """
            Inspect the Edith installation and ask a running Edith process to perform
            one-shot actions. Commands that need a live process exit 4 and identify the
            missing app when it is not running.
            """,
        subcommands: [
            AppInfoCommand.self, AppDiagnosticsCommand.self, AppPathsCommand.self,
            AppLinksCommand.self, AppOpenPathCommand.self, AppOpenLinkCommand.self,
            AppActionsCommand.self, AppCleanKeysCommand.self, AppTestNotificationCommand.self,
            AppOpenCommand.self, AppQuitCommand.self, AppCheckUpdatesCommand.self,
            AppUpdatesCommand.self, AppRelaunchCommand.self,
            AppClearUpdateHistoryCommand.self, AppRevealCommand.self, AppSnapshotCommand.self,
        ],
        defaultSubcommand: AppActionsCommand.self)
}

extension AppPathID: ExpressibleByArgument {}

enum AppInspectionCLI {
    static var center: AppInspectionCenter { CLIEnvironment.appInspectionCenter() }

    static var contributors: [Contributor] { CLIEnvironment.appContributors() }

    static func info() -> AppInfoSnapshot {
        guard let url = CLIEnvironment.installedAppURL(), let bundle = Bundle(url: url) else {
            return center.info()
        }
        return center.info(bundle: bundle)
    }

    static func infoJSON(_ info: AppInfoSnapshot) -> JSONValue {
        .object([
            "name": .string(info.name), "version": .string(info.version),
            "build": .string(info.build), "bundleID": .optional(info.bundleID),
            "bundlePath": .string(info.bundlePath),
            "repositoryURL": .string(info.repositoryURL.absoluteString),
            "creatorURL": .string(info.creatorURL.absoluteString),
        ])
    }

    static func diagnosticsJSON(_ diagnostics: AppDiagnosticsSnapshot) -> JSONValue {
        .object([
            "info": infoJSON(diagnostics.info), "pid": .int(Int(diagnostics.processID)),
            "uptimeSeconds": .int(diagnostics.uptimeSeconds),
            "uptime": .string(diagnostics.uptimeText),
            "idleWakeups": .int(diagnostics.idleWakeups),
        ])
    }

    static func pathJSON(_ path: AppPathSnapshot) -> JSONValue {
        .object([
            "id": .string(path.id.rawValue), "label": .string(path.label),
            "path": .string(path.url.path), "exists": .bool(path.exists),
        ])
    }

    static func linkJSON(_ link: AppExternalLink) -> JSONValue {
        .object([
            "id": .string(link.id), "label": .string(link.label),
            "url": .string(link.url.absoluteString),
        ])
    }

    static func openJSON(_ result: AppOpenResult) -> JSONValue {
        .object([
            "id": .string(result.id), "url": .string(result.url.absoluteString),
            "mode": .string(result.mode.rawValue), "opened": .bool(result.opened),
        ])
    }

    static func failure(_ error: AppInspectionError) -> CLIFailure {
        switch error {
        case let .unknownLink(id):
            return .notFound(
                "no app link named \(id)",
                hint: "run `ed app links` to list valid link names")
        case let .couldNotPrepare(path):
            return .unavailable("could not prepare \(path) for opening")
        case let .couldNotOpen(target):
            return .unavailable("macOS could not open \(target)")
        }
    }
}

struct AppInfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info", abstract: "Show the installed Edith app identity and version.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let info = AppInspectionCLI.info()
            guard !json else {
                CLIOut.json(AppInspectionCLI.infoJSON(info))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["FIELD", "VALUE"],
                    rows: [
                        ["name", info.name], ["version", info.version], ["build", info.build],
                        ["bundle id", info.bundleID ?? "-"], ["bundle path", info.bundlePath],
                    ]))
        }
    }
}

struct AppDiagnosticsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diagnostics", abstract: "Show live Edith helper process diagnostics.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            try AppBridge.requireHelper("app diagnostics")
            let reply = await AppBridge.awaitReply(IPC.Name.appDiagnostics, timeout: 5) {
                AppBridge.post(IPC.Name.requestAppDiagnostics)
            }
            guard let reply, let diagnostics = AppDiagnosticsPayload.decode(reply) else {
                throw AppBridge.silence("app diagnostics")
            }
            guard !json else {
                CLIOut.json(AppInspectionCLI.diagnosticsJSON(diagnostics))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["FIELD", "VALUE"],
                    rows: [
                        ["name", diagnostics.info.name],
                        ["version", diagnostics.info.version],
                        ["build", diagnostics.info.build],
                        ["pid", String(diagnostics.processID)],
                        ["uptime", diagnostics.uptimeText],
                        ["idle wakeups", String(diagnostics.idleWakeups)],
                        ["bundle path", diagnostics.info.bundlePath],
                    ]))
        }
    }
}

struct AppPathsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "paths", abstract: "List the folders and files Edith exposes.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let paths = AppInspectionCLI.center.paths()
            guard !json else {
                CLIOut.json(.array(paths.map(AppInspectionCLI.pathJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "STATE", "PATH"],
                    rows: paths.map {
                        [$0.id.rawValue, $0.exists ? "exists" : "missing", $0.url.path]
                    }))
        }
    }
}

struct AppLinksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "links", abstract: "List Edith's repository and people links.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let links = AppInspectionCLI.center.links(contributors: AppInspectionCLI.contributors)
            guard !json else {
                CLIOut.json(.array(links.map(AppInspectionCLI.linkJSON)))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["ID", "LABEL", "URL"],
                    rows: links.map { [$0.id, $0.label, $0.url.absoluteString] }))
        }
    }
}

struct AppOpenPathCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-path", abstract: "Open or reveal one Edith folder or file.")

    @Argument(help: "The path name from `ed app paths`.")
    var path: AppPathID

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let result: AppOpenResult
            do {
                result = try AppInspectionCLI.center.openPath(path)
            } catch let error as AppInspectionError {
                throw AppInspectionCLI.failure(error)
            }
            guard !json else {
                CLIOut.json(AppInspectionCLI.openJSON(result))
                return
            }
            CLIOut.out("\(result.mode.rawValue)ed \(result.url.path)")
        }
    }
}

struct AppOpenLinkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open-link", abstract: "Open Edith's repository or a profile link.")

    @Argument(help: "The link name from `ed app links`.")
    var link: String

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let result: AppOpenResult
            do {
                result = try AppInspectionCLI.center.openLink(
                    link, contributors: AppInspectionCLI.contributors)
            } catch let error as AppInspectionError {
                throw AppInspectionCLI.failure(error)
            }
            guard !json else {
                CLIOut.json(AppInspectionCLI.openJSON(result))
                return
            }
            CLIOut.out("opened \(result.url.absoluteString)")
        }
    }
}

struct AppAction: Sendable {
    let operation: AppRuntimeOperation

    var name: String { operation.descriptor.cli.last ?? operation.rawValue }
    var summary: String { operation.descriptor.summary }
    var needsMainApp: Bool { operation.owner == .mainApp }
}

enum AppActions {
    static let all = [
        AppRuntimeOperation.cleanKeys, .testNotification, .open, .quit, .checkUpdates,
        .reveal, .snapshot,
    ].map(AppAction.init)

    static var runtime: AppRuntimeCenter {
        AppRuntimeCenter(post: { AppBridge.post($0, userInfo: $1) })
    }

    static func require(_ action: AppAction) throws {
        guard action.needsMainApp else {
            try AppBridge.requireHelper(action.name)
            return
        }
        try AppBridge.requireMainApp(action.name)
    }

    static func fire(_ action: AppAction, json: Bool) async throws {
        try require(action)
        runtime.request(action.operation)
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
            let action = try AppActions.named("clean-keys")
            try AppActions.require(action)
            let requestID = UUID().uuidString
            guard
                let reply = await AppBridge.awaitReply(
                    IPC.Name.keyboardCleanResult, timeout: 3,
                    matching: { $0[KeyboardCleaningIPC.requestIDKey] as? String == requestID },
                    trigger: {
                        AppActions.runtime.request(
                            action.operation,
                            userInfo: [KeyboardCleaningIPC.requestIDKey: requestID])
                    }),
                let state = KeyboardCleaningIPC.state(from: reply)
            else {
                throw AppBridge.silence("keyboard cleaning", extensionKey: "tabSystemEnabled")
            }
            guard state.accepted else { throw failure(for: state) }
            if json {
                CLIOut.json(
                    .object([
                        "action": .string(action.name),
                        "requested": .bool(true),
                        "state": .string(state.rawValue),
                    ]))
            } else {
                CLIOut.out(state == .arming ? "keyboard cleaning is arming" : "keyboard is locked")
            }
        }
    }

    private func failure(for state: KeyboardCleaningState) -> CLIFailure {
        switch state {
        case .inputMonitoringRequired:
            CLIFailure.unavailable(
                "keyboard cleaning needs Input Monitoring",
                hint:
                    "run `ed permissions request inputMonitoring`, enable Edith, then relaunch Edith"
            )
        case .accessibilityRequired:
            CLIFailure.unavailable(
                "keyboard cleaning needs Accessibility",
                hint:
                    "run `ed permissions request accessibility`, enable Edith, then relaunch Edith")
        case .unavailable:
            CLIFailure.unavailable(
                "keyboard cleaning is not available",
                hint: "run `ed extensions enable system`, then relaunch Edith")
        case .arming, .cleaning:
            CLIFailure.unavailable("keyboard cleaning did not start")
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
                AppActions.named("test-notification"), json: json)
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
                AppActions.named("open"), json: json)
        }
    }
}

struct AppQuitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quit",
        abstract: "Quit the Edith main window, leaving the menu bar running.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually quit it. Without this nothing is touched.")
    var yes = false

    func run() async throws {
        try await execute {
            let action = try AppActions.named("quit")
            let plan = CLIDestructivePlan(
                action: "quit", targets: [AppBridge.mainBundleID], confirmed: yes, json: json,
                fields: ["requested": .bool(false)])
            guard plan.shouldApply() else { return }
            try AppActions.require(action)
            AppActions.runtime.request(action.operation)
            plan.finish(
                changed: true, plain: "quit requested", fields: ["requested": .bool(true)])
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
                AppActions.runtime.request(.checkUpdates)
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
            let records = AppActions.runtime.updateHistory(limit: limit)
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

    @Flag(help: "Actually relaunch it. Without this nothing is touched.")
    var yes = false

    func run() async throws {
        try await execute {
            let bundle = CLIEnvironment.installedAppURL()
            let plan = CLIDestructivePlan(
                action: "relaunch Edith", targets: [bundle?.path ?? "Edith.app"], confirmed: yes,
                json: json,
                fields: ["path": .optional(bundle?.path), "relaunched": .bool(false)])
            guard plan.shouldApply() else { return }
            guard let bundle else {
                throw CLIFailure.unavailable(
                    "Edith is not installed where ed can find it",
                    hint: "it looks in /Applications and alongside this binary")
            }
            try await AppActions.runtime.perform(.relaunch) {
                let progress = CLIProgress.forCommand(json: json)
                AppActions.runtime.request(.quit)
                progress.begin("waiting for Edith to quit")
                let stopped = await EdithProcesses.quitAll(within: 8)
                progress.end()
                guard stopped else {
                    throw CLIFailure(
                        "Edith did not quit, so it was not relaunched",
                        hint: "quit it from the menu bar, then run `ed app relaunch --yes` again")
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
                plan.finish(
                    changed: true, plain: "relaunched Edith",
                    fields: ["relaunched": .bool(true), "path": .string(bundle.path)])
            }
        }
    }
}

struct AppClearUpdateHistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-updates", abstract: "Forget the record of past update checks.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually clear it. Without this nothing is touched.")
    var yes = false

    func run() async throws {
        try await execute {
            let url = CLIEnvironment.updateHistoryURL()
            let before = AppActions.runtime.updateHistory(url: url).count
            let plan = CLIDestructivePlan(
                action: "clear update history", targets: [url.path], confirmed: yes, json: json,
                fields: ["removed": .int(before)])
            guard plan.shouldApply() else { return }
            let removed = AppActions.runtime.clearUpdateHistory(url: url)
            plan.finish(
                changed: removed > 0, plain: "cleared \(removed) check(s)",
                fields: ["removed": .int(removed)])
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
                "One of home, attention, dashboard, herdr, quinjet, music, calendar, system, "
                + "machines, companion, extensions, settings, about."))
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
                AppActions.runtime.request(.reveal, userInfo: payload)
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
                AppActions.runtime.request(.snapshot, userInfo: payload)
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
