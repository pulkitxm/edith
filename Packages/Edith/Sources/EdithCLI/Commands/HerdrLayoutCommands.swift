import ArgumentParser
import EdithKit
import Foundation

struct HerdrLayoutCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "layout",
        abstract: "Read and change the open Herdr page.",
        discussion: """
            Reads the tabs, saved layouts, and agent terminals in the Edith window.
            Example: `ed herdr layout ls --json`.
            """,
        subcommands: [
            HerdrLayoutListCommand.self, HerdrLayoutSaveCommand.self,
            HerdrLayoutDeleteCommand.self, HerdrLayoutApplyCommand.self,
            HerdrLayoutEvenCommand.self,
        ],
        defaultSubcommand: HerdrLayoutListCommand.self)
}

enum HerdrLayoutCLI {
    static let name = "the Herdr page"
    static let boardID = "board"

    static func request(_ request: HerdrLayoutRequest) async throws -> HerdrLayoutSnapshot {
        try AppBridge.requireMainApp(name)
        let timeout: TimeInterval = 12
        let runtime = HerdrLayoutRuntimeRequest(
            request: request, deadline: Date().addingTimeInterval(timeout))
        guard let payload = runtime.payload else {
            throw CLIFailure("The layout request could not be encoded")
        }
        let requestID = runtime.requestID
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.herdrLayoutActionResult, timeout: timeout,
                matching: { $0[HerdrLayoutIPC.requestIDKey] as? String == requestID },
                trigger: { AppBridge.post(IPC.Name.requestHerdrLayoutAction, userInfo: payload) })
        else { throw AppBridge.silence(name) }
        guard reply[HerdrLayoutIPC.okKey] as? Bool == true else {
            throw CLIFailure(
                reply[HerdrLayoutIPC.errorKey] as? String ?? "The layout request failed")
        }
        guard
            let snapshot = HerdrLayoutSnapshot.decode(reply[HerdrLayoutIPC.snapshotKey] as? String)
        else { throw CLIFailure("Edith sent an unreadable Herdr layout") }
        return snapshot
    }

    static func emit(_ snapshot: HerdrLayoutSnapshot, json: Bool) {
        if json {
            CLIOut.json(jsonValue(snapshot))
            return
        }
        if let message = snapshot.message { CLIOut.out(message) }
        for tab in snapshot.tabs {
            let mark = tab.selected ? "*" : " "
            CLIOut.out("\(tab.index)\(mark)\t\(tab.title)")
        }
        for item in snapshot.arrangements {
            CLIOut.out("layout\t\(item.name)\t\(item.panes)")
        }
        for terminal in snapshot.terminals {
            let mark = terminal.selected ? "*" : " "
            CLIOut.out("terminal\(mark)\t\(terminal.title)")
        }
    }

    static func jsonValue(_ snapshot: HerdrLayoutSnapshot) -> JSONValue {
        .object([
            "agents": .array(snapshot.agents.map(agentJSON)),
            "arrangements": .array(snapshot.arrangements.map(arrangementJSON)),
            "message": snapshot.message.map(JSONValue.string) ?? .null,
            "selected": .string(snapshot.selected),
            "tabs": .array(snapshot.tabs.map(tabJSON)),
            "terminals": .array(snapshot.terminals.map(terminalJSON)),
        ])
    }

    static func agentJSON(_ agent: HerdrLayoutAgentState) -> JSONValue {
        .object([
            "id": .string(agent.id), "pane": .string(agent.pane), "title": .string(agent.title),
        ])
    }

    static func tabJSON(_ tab: HerdrLayoutTabState) -> JSONValue {
        .object([
            "agents": .array(tab.agents.map(agentJSON)),
            "focused": .string(tab.focused),
            "id": .string(tab.id),
            "index": .int(tab.index),
            "selected": .bool(tab.selected),
            "title": .string(tab.title),
        ])
    }

    static func arrangementJSON(_ item: HerdrLayoutArrangementState) -> JSONValue {
        .object([
            "id": .string(item.id), "name": .string(item.name), "panes": .int(item.panes),
        ])
    }

    static func terminalJSON(_ terminal: HerdrLayoutTerminalState) -> JSONValue {
        .object([
            "id": .string(terminal.id),
            "owner": .string(terminal.owner),
            "selected": .bool(terminal.selected),
            "title": .string(terminal.title),
        ])
    }

    static func tab(
        _ token: String?, in snapshot: HerdrLayoutSnapshot, allowingBoard: Bool = false
    ) throws -> HerdrLayoutTabState {
        let resolved: HerdrLayoutTabState
        if let token {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            var exact: HerdrLayoutTabState?
            var matches: [HerdrLayoutTabState] = []
            for tab in snapshot.tabs {
                if tab.id.caseInsensitiveCompare(trimmed) == .orderedSame
                    || String(tab.index) == trimmed
                {
                    exact = tab
                    break
                }
                if tab.title.caseInsensitiveCompare(trimmed) == .orderedSame { matches.append(tab) }
            }
            if let exact {
                resolved = exact
            } else {
                guard matches.count == 1, let tab = matches.first else {
                    throw CLIFailure.notFound(
                        matches.isEmpty
                            ? "no tab matches \(trimmed)" : "more than one tab is named \(trimmed)",
                        hint: "run `ed herdr layout ls` to see open tabs")
                }
                resolved = tab
            }
        } else {
            guard let tab = snapshot.tabs.first(where: \.selected) ?? snapshot.tabs.first else {
                throw CLIFailure.notFound(
                    "there is no selected tab", hint: "run `ed herdr layout ls`")
            }
            resolved = tab
        }
        if !allowingBoard, resolved.id == boardID {
            throw CLIFailure(
                "the board is not a tab of agents",
                hint: "pass --tab with a tab from `ed herdr layout ls`")
        }
        return resolved
    }

    static func agent(_ token: String, in snapshot: HerdrLayoutSnapshot) throws
        -> HerdrLayoutAgentState
    {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var titled: [HerdrLayoutAgentState] = []
        for agent in snapshot.agents {
            if agent.id.caseInsensitiveCompare(trimmed) == .orderedSame
                || agent.pane.caseInsensitiveCompare(trimmed) == .orderedSame
            {
                return agent
            }
            if agent.title.caseInsensitiveCompare(trimmed) == .orderedSame { titled.append(agent) }
        }
        guard titled.count == 1, let agent = titled.first else {
            throw CLIFailure.notFound(
                titled.isEmpty
                    ? "no agent matches \(trimmed)" : "more than one agent is named \(trimmed)",
                hint: "run `ed herdr ls` to see live agents")
        }
        return agent
    }

    static func arrangement(_ token: String, in snapshot: HerdrLayoutSnapshot) throws
        -> HerdrLayoutArrangementState
    {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        var named: [HerdrLayoutArrangementState] = []
        for item in snapshot.arrangements {
            if item.id.caseInsensitiveCompare(trimmed) == .orderedSame { return item }
            if item.name.caseInsensitiveCompare(trimmed) == .orderedSame { named.append(item) }
        }
        guard named.count == 1, let item = named.first else {
            throw CLIFailure.notFound(
                named.isEmpty
                    ? "no saved layout matches \(trimmed)"
                    : "more than one saved layout is named \(trimmed)",
                hint: "run `ed herdr layout ls` to see saved layouts")
        }
        return item
    }

    static func side(_ token: String) throws -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["left", "right", "top", "bottom"].contains(value) else {
            throw CLIFailure(
                "side must be left, right, top, or bottom",
                hint: "example: `ed herdr split w3:p1 --side right`")
        }
        return value
    }

    static func finish(
        _ snapshot: HerdrLayoutSnapshot, plan: CLIDestructivePlan, json: Bool, plain: String
    ) {
        if json {
            emit(snapshot, json: true)
        } else {
            plan.finish(changed: true, plain: plain)
        }
    }
}

struct HerdrLayoutListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List Herdr tabs, saved layouts, and agent terminals.",
        discussion: """
            Reads the Edith window. Tabs are numbered from 1. Index 0 is the board.
            Example: `ed herdr layout ls --json`.
            """,
        aliases: ["list"])

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    func run() async throws {
        try await execute {
            HerdrLayoutCLI.emit(try await HerdrLayoutCLI.request(.status), json: json)
        }
    }
}

struct HerdrLayoutSaveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save the current split as a named layout.",
        discussion: """
            Stores the tab's pane geometry under a name, the same way the layout popover
            does. It writes that geometry. The tab needs at least two agents.
            Example: `ed herdr layout save Pair --tab 1`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index, id, or title. Defaults to the selected tab.")
    var tab: String?

    @Argument(help: "Name for the saved layout.")
    var name: String

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current)
            let snapshot = try await HerdrLayoutCLI.request(.save(tab: target.id, name: name))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrLayoutDeleteCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete",
        abstract: "Delete one saved Herdr layout.",
        discussion: """
            Previews the saved layout, then --yes writes the deletion. Built-in arrangements
            stay. Example: `ed herdr layout delete Pair --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the layout, as JSON.")
    var json = false

    @Flag(name: .long, help: "Delete the layout after printing the plan.")
    var yes = false

    @Argument(help: "Saved layout name or id.")
    var name: String

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let item = try HerdrLayoutCLI.arrangement(name, in: current)
            let plan = CLIDestructivePlan(
                action: "delete layout \(item.name)", targets: [item.name], confirmed: yes,
                json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await HerdrLayoutCLI.request(.deleteLayout(item.id))
            HerdrLayoutCLI.finish(snapshot, plan: plan, json: json, plain: "deleted \(item.name)")
        }
    }
}

struct HerdrLayoutApplyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a built-in or saved layout to a tab.",
        discussion: """
            It writes that arrangement onto the tab. Built-in names are columns, rows, grid,
            tallGrid, focusLeft, focusRight, focusTop, focusBottom, focusCenter, twoColumns,
            and twoRows. Titles such as "Side by Side" work too.
            Example: `ed herdr layout apply columns --tab 1`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index, id, or title. Defaults to the selected tab.")
    var tab: String?

    @Argument(help: "Built-in arrangement or saved layout name.")
    var name: String

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current)
            let snapshot = try await HerdrLayoutCLI.request(.apply(tab: target.id, name: name))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrLayoutEvenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "even",
        abstract: "Equalize the panes in one Herdr tab.",
        discussion: """
            It writes equal shares for every pane, matching Even Out in the layout popover.
            Example: `ed herdr layout even --tab 1`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index, id, or title. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current)
            let snapshot = try await HerdrLayoutCLI.request(.even(target.id))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrCloseTabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-tab",
        abstract: "Close one Herdr tab and its agents.",
        discussion: """
            Previews the tab, then --yes writes the close. Running terminals in that tab stop
            without a second prompt, because --yes is the confirmation.
            Example: `ed herdr close-tab --tab 1 --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the layout, as JSON.")
    var json = false

    @Flag(name: .long, help: "Close the tab after printing the plan.")
    var yes = false

    @Option(name: .long, help: "Tab index, id, or title. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current)
            let plan = CLIDestructivePlan(
                action: "close tab \(target.index)", targets: [target.title], confirmed: yes,
                json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await HerdrLayoutCLI.request(.closeTab(target.id))
            HerdrLayoutCLI.finish(
                snapshot, plan: plan, json: json, plain: "closed \(target.title)")
        }
    }
}

struct HerdrCloseOthersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-others",
        abstract: "Close every Herdr tab except one.",
        discussion: """
            Previews the tabs that would close, then --yes writes those closes. Passing the
            board closes every agent tab. Example: `ed herdr close-others --tab 1 --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the layout, as JSON.")
    var json = false

    @Flag(name: .long, help: "Close the other tabs after printing the plan.")
    var yes = false

    @Option(name: .long, help: "Tab index, id, or title to keep. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current, allowingBoard: true)
            var titles: [String] = []
            for item in current.tabs where item.id != target.id && item.id != HerdrLayoutCLI.boardID
            {
                titles.append(item.title)
            }
            let plan = CLIDestructivePlan(
                action: "close other tabs", targets: titles, confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await HerdrLayoutCLI.request(.closeOthers(target.id))
            HerdrLayoutCLI.finish(snapshot, plan: plan, json: json, plain: "kept \(target.title)")
        }
    }
}

struct HerdrCloseRightCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-right",
        abstract: "Close Herdr tabs to the right of one tab.",
        discussion: """
            Previews those tabs, then --yes writes the close of the tabs to the right.
            Example: `ed herdr close-right --tab 1 --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the layout, as JSON.")
    var json = false

    @Flag(name: .long, help: "Close the tabs after printing the plan.")
    var yes = false

    @Option(name: .long, help: "Tab index, id, or title. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current, allowingBoard: true)
            var titles: [String] = []
            for item in current.tabs where item.index > target.index {
                titles.append(item.title)
            }
            let plan = CLIDestructivePlan(
                action: "close tabs to the right", targets: titles, confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await HerdrLayoutCLI.request(.closeRight(target.id))
            HerdrLayoutCLI.finish(
                snapshot, plan: plan, json: json, plain: "closed tabs after \(target.title)")
        }
    }
}

struct HerdrCloseAllCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close-all",
        abstract: "Close every Herdr agent tab.",
        discussion: """
            Previews the open tabs, then --yes writes the close. The board stays.
            Example: `ed herdr close-all --yes`.
            """)

    @Flag(name: .long, help: "Emit the plan, or the layout, as JSON.")
    var json = false

    @Flag(name: .long, help: "Close the tabs after printing the plan.")
    var yes = false

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            var titles: [String] = []
            for item in current.tabs where item.id != HerdrLayoutCLI.boardID {
                titles.append(item.title)
            }
            let plan = CLIDestructivePlan(
                action: "close every tab", targets: titles, confirmed: yes, json: json)
            guard plan.shouldApply() else { return }
            let snapshot = try await HerdrLayoutCLI.request(.closeAll)
            HerdrLayoutCLI.finish(snapshot, plan: plan, json: json, plain: "closed every tab")
        }
    }
}

struct HerdrGatherCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gather",
        abstract: "Gather every Herdr tab into one.",
        discussion: """
            It writes every open agent into the chosen tab, matching Gather All Tabs.
            Example: `ed herdr gather --tab 1`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index, id, or title that receives the agents.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current)
            let snapshot = try await HerdrLayoutCLI.request(.gather(target.id))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrSeparateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "separate",
        abstract: "Turn one split tab into a tab per agent.",
        discussion: """
            It writes one tab per agent, matching Separate Into Tabs.
            Example: `ed herdr separate --tab 1`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index, id, or title. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.tab(tab, in: current)
            let snapshot = try await HerdrLayoutCLI.request(.separate(target.id))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrSplitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Open an agent beside the focused one.",
        discussion: """
            It writes the agent beside the focused pane, which is Open beside in the layout
            popover. From the board, the agent opens in a new tab.
            Example: `ed herdr split w3:p1 --side right`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "left, right, top, or bottom. Defaults to right.")
    var side: String = "right"

    @Argument(help: "Agent id, pane id, or unique title.")
    var agent: String

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.agent(agent, in: current)
            let direction = try HerdrLayoutCLI.side(side)
            let snapshot = try await HerdrLayoutCLI.request(
                .split(agent: target.id, side: direction))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrMoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "move",
        abstract: "Move an agent into another Herdr tab.",
        discussion: """
            It writes the agent into the destination tab, matching a drag onto that tab.
            Example: `ed herdr move w3:p1 --tab 2`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "Destination tab index, id, or title.")
    var tab: String

    @Argument(help: "Agent id, pane id, or unique title.")
    var agent: String

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let target = try HerdrLayoutCLI.agent(agent, in: current)
            let destination = try HerdrLayoutCLI.tab(tab, in: current)
            let snapshot = try await HerdrLayoutCLI.request(
                .move(agent: target.id, tab: destination.id))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrSwapCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swap",
        abstract: "Swap two agents that share a Herdr tab.",
        discussion: """
            It writes the two panes exchanged. Both agents have to already be in the same tab.
            Example: `ed herdr swap w3:p1 w3:p2`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Argument(help: "First agent id, pane id, or unique title.")
    var first: String

    @Argument(help: "Second agent id, pane id, or unique title.")
    var second: String

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let left = try HerdrLayoutCLI.agent(first, in: current)
            let right = try HerdrLayoutCLI.agent(second, in: current)
            let snapshot = try await HerdrLayoutCLI.request(.swap(left.id, right.id))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}

struct HerdrTerminalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Open a terminal in a Herdr tab.",
        discussion: """
            It writes another terminal for the focused agent in that tab, the same way
            Control-Shift-backtick does. The board opens a terminal on this Mac.
            Example: `ed herdr terminal --tab 1`.
            """)

    @Flag(name: .long, help: "Emit the layout as JSON.")
    var json = false

    @Option(name: .long, help: "Tab index, id, or title. Defaults to the selected tab.")
    var tab: String?

    func run() async throws {
        try await execute {
            let current = try await HerdrLayoutCLI.request(.status)
            let owner = try HerdrLayoutCLI.tab(tab, in: current, allowingBoard: true)
            let snapshot = try await HerdrLayoutCLI.request(.newTerminal(owner.id))
            HerdrLayoutCLI.emit(snapshot, json: json)
        }
    }
}
