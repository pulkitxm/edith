import AppKit
import ArgumentParser
import EdithKit
import Foundation

struct BrowserCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "browser",
        abstract: "Drive the notch browser.",
        discussion: """
            Talks to the menu bar app the same way `ed camera` talks to the virtual camera.
            Listing reads the open tabs and Chrome profiles. Navigation, reload, sync, and
            profile changes update the live browser. Closing a tab and detaching preview
            first. Example: `ed browser ls --json`.
            """,
        subcommands: [
            BrowserListCommand.self, BrowserNavigateCommand.self, BrowserReloadCommand.self,
            BrowserCopyCommand.self, BrowserCloseCommand.self, BrowserCloseOthersCommand.self,
            BrowserCloseRightCommand.self, BrowserReopenCommand.self, BrowserDuplicateCommand.self,
            BrowserSyncCommand.self, BrowserProfileCommand.self, BrowserDetachCommand.self,
            BrowserTabCommand.self,
        ],
        defaultSubcommand: BrowserListCommand.self)
}

enum BrowserCLI {
    static let name = "the notch browser"

    static func request(_ request: NotchBrowserRequest) async throws -> NotchBrowserSnapshot {
        try AppBridge.requireHelper(name)
        let timeout: TimeInterval = 8
        let runtime = NotchBrowserRuntimeRequest(
            request: request, deadline: Date().addingTimeInterval(timeout))
        guard let payload = runtime.payload else {
            throw CLIFailure("The browser request could not be encoded")
        }
        let requestID = runtime.requestID
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.notchBrowserActionResult, timeout: timeout,
                matching: { $0[NotchBrowserIPC.requestIDKey] as? String == requestID },
                trigger: { AppBridge.post(IPC.Name.requestNotchBrowserAction, userInfo: payload) })
        else {
            throw AppBridge.silence(
                name, extensionKey: AppStorageKeys.Notch.browserEnabled)
        }
        guard reply[NotchBrowserIPC.okKey] as? Bool == true else {
            throw CLIFailure(
                reply[NotchBrowserIPC.errorKey] as? String ?? "The browser request failed")
        }
        guard
            let snapshot = NotchBrowserSnapshot.decode(
                reply[NotchBrowserIPC.snapshotKey] as? String)
        else { throw CLIFailure("Edith sent an unreadable browser status") }
        return snapshot
    }

    static func emit(_ snapshot: NotchBrowserSnapshot, json: Bool) {
        if json {
            CLIOut.json(jsonValue(snapshot))
            return
        }
        if let message = snapshot.message { CLIOut.out(message) }
        if let link = snapshot.link { CLIOut.out(link) }
        if let profile = snapshot.profile {
            CLIOut.out("profile\t\(profile.name)")
        } else {
            CLIOut.out("profile\tnone")
        }
        if !snapshot.profiles.isEmpty {
            let names = snapshot.profiles.map(\.name).joined(separator: ", ")
            CLIOut.out("profiles\t\(names)")
        }
        CLIOut.out("sync\t\(snapshot.sync)")
        for tab in snapshot.tabs {
            let mark = tab.selected ? "*" : " "
            let url = tab.url ?? ""
            CLIOut.out("\(tab.index)\(mark)\t\(tab.title)\t\(url)")
        }
    }

    static func jsonValue(_ snapshot: NotchBrowserSnapshot) -> JSONValue {
        .object([
            "attached": .bool(snapshot.attached),
            "canReopen": .bool(snapshot.canReopen),
            "link": snapshot.link.map(JSONValue.string) ?? .null,
            "profile": snapshot.profile.map(profileJSON) ?? .null,
            "profiles": .array(snapshot.profiles.map(profileJSON)),
            "sync": .string(snapshot.sync),
            "tabs": .array(snapshot.tabs.map(tabJSON)),
        ])
    }

    static func profileJSON(_ profile: NotchBrowserProfileState) -> JSONValue {
        .object(["id": .string(profile.id), "name": .string(profile.name)])
    }

    static func tabJSON(_ tab: NotchBrowserTabState) -> JSONValue {
        .object([
            "id": .string(tab.id),
            "index": .int(tab.index),
            "loading": .bool(tab.loading),
            "selected": .bool(tab.selected),
            "title": .string(tab.title),
            "url": tab.url.map(JSONValue.string) ?? .null,
        ])
    }

    static func tab(_ token: String?, in snapshot: NotchBrowserSnapshot) throws
        -> NotchBrowserTabState
    {
        if let token {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let tab = snapshot.tabs.first(where: {
                $0.id.caseInsensitiveCompare(trimmed) == .orderedSame || String($0.index) == trimmed
            }) {
                return tab
            }
            throw CLIFailure.notFound(
                "no tab matches \(trimmed)", hint: "run `ed browser ls` to see open tabs")
        }
        guard let tab = snapshot.tabs.first(where: \.selected) ?? snapshot.tabs.first else {
            throw CLIFailure.notFound(
                "there is no selected tab", hint: "run `ed browser tab` to open one")
        }
        return tab
    }

    static func copy(_ link: String?) throws {
        guard let link, !link.isEmpty else {
            throw CLIFailure("That tab has no address to copy")
        }
        let board = CLIEnvironment.clipboardPasteboard
        board.clearContents()
        guard board.setString(link, forType: .string) else {
            throw CLIFailure("could not copy the address to the clipboard")
        }
    }
}

struct BrowserListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List notch browser tabs and Chrome profiles.",
        discussion: """
            Reads the live browser in the menu bar app. It does not change tabs.
            Example: `ed browser ls --json`.
            """,
        aliases: ["list"])

    @Flag(name: .long, help: "Emit one JSON document on stdout.")
    var json = false

    func run() async throws {
        try await execute { BrowserCLI.emit(try await BrowserCLI.request(.status), json: json) }
    }
}

struct BrowserNavigateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "navigate",
        abstract: "Open an address in a notch browser tab.",
        discussion: """
            Loads the address in the selected tab, or in `--tab`. A value with no
            scheme is searched the way the address bar searches. It writes that
            navigation into the live tab. Example:
            `ed browser navigate https://example.com`.
            """)

    @Flag(name: .long, help: "Emit the browser status as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index or id. Defaults to the selected tab.")
    var tab: String?

    @Argument(help: "Address or search text.")
    var address: String

    func run() async throws {
        try await execute {
            BrowserCLI.emit(
                try await BrowserCLI.request(.navigate(address, tab: tab)), json: json)
        }
    }
}

struct BrowserReloadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reload",
        abstract: "Refresh a notch browser tab.",
        discussion: """
            Reloads the selected tab, or `--tab`. `--hard` reloads from the origin.
            It writes a fresh load of that tab. Example: `ed browser reload --hard`.
            """)

    @Flag(name: .long, help: "Emit the browser status as JSON.")
    var json = false

    @Flag(name: .long, help: "Reload from the origin, ignoring the cache.")
    var hard = false

    @Option(name: .long, help: "Tab index or id. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            BrowserCLI.emit(try await BrowserCLI.request(.reload(hard: hard, tab: tab)), json: json)
        }
    }
}

struct BrowserCopyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "copy",
        abstract: "Copy a tab's address to the clipboard.",
        discussion: """
            Reads the tab address from the live browser and replaces the general pasteboard,
            which is what the copy-link button does. Example: `ed browser copy --json`.
            """)

    @Flag(name: .long, help: "Emit the browser status, including the link, as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index or id. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let snapshot = try await BrowserCLI.request(.copyLink(tab: tab))
            try BrowserCLI.copy(snapshot.link)
            BrowserCLI.emit(snapshot, json: json)
        }
    }
}

struct BrowserCloseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close",
        abstract: "Close a notch browser tab.",
        discussion: """
            Previews the tab, then `--yes` writes the close. The last remaining tab is
            replaced by a new one, matching the browser chrome. Example:
            `ed browser close 2 --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the browser status, as JSON.")
    var json = false

    @Flag(name: .long, help: "Close the tab after printing the plan.")
    var yes = false

    @Option(name: .long, help: "Tab index or id. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await BrowserCLI.request(.status)
            let target = try BrowserCLI.tab(tab, in: current)
            let plan = CLIDestructivePlan(
                action: "close tab \(target.index)", targets: [target.title], confirmed: yes,
                json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await BrowserCLI.request(.close(tab: target.id))
            if json {
                BrowserCLI.emit(snapshot, json: true)
            } else {
                plan.finish(changed: true, plain: "closed \(target.title)")
            }
        }
    }
}

struct BrowserCloseOthersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-others",
        abstract: "Close every notch browser tab except one.",
        discussion: """
            Previews the tab that stays open, then `--yes` writes the close of the others.
            Example: `ed browser close-others --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the browser status, as JSON.")
    var json = false

    @Flag(name: .long, help: "Close the other tabs after printing the plan.")
    var yes = false

    @Option(name: .long, help: "Tab index or id to keep. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await BrowserCLI.request(.status)
            let target = try BrowserCLI.tab(tab, in: current)
            let others = current.tabs.filter { $0.id != target.id }.map(\.title)
            let plan = CLIDestructivePlan(
                action: "close other tabs", targets: others, confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await BrowserCLI.request(.closeOthers(tab: target.id))
            if json {
                BrowserCLI.emit(snapshot, json: true)
            } else {
                plan.finish(changed: !others.isEmpty, plain: "kept \(target.title)")
            }
        }
    }
}

struct BrowserCloseRightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-right",
        abstract: "Close notch browser tabs to the right of one tab.",
        discussion: """
            Previews those tabs, then `--yes` writes the close.
            Example: `ed browser close-right 1 --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the browser status, as JSON.")
    var json = false

    @Flag(name: .long, help: "Close the tabs after printing the plan.")
    var yes = false

    @Option(name: .long, help: "Tab index or id. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await BrowserCLI.request(.status)
            let target = try BrowserCLI.tab(tab, in: current)
            let right = current.tabs.filter { $0.index > target.index }.map(\.title)
            let plan = CLIDestructivePlan(
                action: "close tabs to the right", targets: right, confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await BrowserCLI.request(.closeRight(tab: target.id))
            if json {
                BrowserCLI.emit(snapshot, json: true)
            } else {
                plan.finish(
                    changed: !right.isEmpty, plain: "closed tabs to the right of \(target.title)")
            }
        }
    }
}

struct BrowserReopenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reopen",
        abstract: "Open the most recently closed notch browser tab.",
        discussion: """
            Writes the last closed address back into a tab, the same as the browser's
            reopen action. Example: `ed browser reopen --json`.
            """)

    @Flag(name: .long, help: "Emit the browser status as JSON.")
    var json = false

    func run() async throws {
        try await execute { BrowserCLI.emit(try await BrowserCLI.request(.reopen), json: json) }
    }
}

struct BrowserDuplicateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicate",
        abstract: "Duplicate a notch browser tab.",
        discussion: """
            Writes the tab's address into a new tab beside it. Example:
            `ed browser duplicate`.
            """)

    @Flag(name: .long, help: "Emit the browser status as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index or id. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            BrowserCLI.emit(try await BrowserCLI.request(.duplicate(tab: tab)), json: json)
        }
    }
}

struct BrowserSyncCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync",
        abstract: "Sync the attached Chrome profile into the notch browser.",
        discussion: """
            Writes the attached profile's cookies and storage into the notch browser,
            the same as the sync button. The command returns once that import is running.
            Example: `ed browser sync --json`.
            """)

    @Flag(name: .long, help: "Emit the browser status as JSON.")
    var json = false

    func run() async throws {
        try await execute { BrowserCLI.emit(try await BrowserCLI.request(.sync), json: json) }
    }
}

struct BrowserProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Attach a Chrome profile to the notch browser.",
        discussion: """
            Writes the named Chrome profile onto the live browser and starts importing it.
            Names and profile directories both match. Example: `ed browser profile Work`.
            """)

    @Flag(name: .long, help: "Emit the browser status as JSON.")
    var json = false

    @Argument(help: "Chrome profile name or directory.")
    var name: String

    func run() async throws {
        try await execute {
            BrowserCLI.emit(try await BrowserCLI.request(.profile(name)), json: json)
        }
    }
}

struct BrowserDetachCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detach",
        abstract: "Remove the attached Chrome profile and its browser data.",
        discussion: """
            Previews the attached profile, then `--yes` writes the detach and removes the
            website data for that profile, which is what the setup screen's detach does.
            Example: `ed browser detach --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the browser status, as JSON.")
    var json = false

    @Flag(name: .long, help: "Detach and clear data after printing the plan.")
    var yes = false

    func run() async throws {
        try await execute {
            let current = try await BrowserCLI.request(.status)
            let target = current.profile?.name ?? "none"
            let plan = CLIDestructivePlan(
                action: "detach and clear browser data", targets: [target], confirmed: yes,
                json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await BrowserCLI.request(.detach)
            if json {
                BrowserCLI.emit(snapshot, json: true)
            } else {
                plan.finish(changed: true, plain: "detached \(target)")
            }
        }
    }
}

struct BrowserTabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tab",
        abstract: "Open a new notch browser tab.",
        discussion: """
            Writes a new tab on the attached profile. An address loads there; otherwise the
            tab opens on the search engine home. Example: `ed browser tab https://example.com`.
            """)

    @Flag(name: .long, help: "Emit the browser status as JSON.")
    var json = false

    @Argument(help: "Optional address or search text.")
    var address: String?

    func run() async throws {
        try await execute {
            BrowserCLI.emit(try await BrowserCLI.request(.newTab(address)), json: json)
        }
    }
}
