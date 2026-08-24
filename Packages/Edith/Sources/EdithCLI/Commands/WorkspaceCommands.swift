import ArgumentParser
import EdithKit
import Foundation

struct MachinesWorkspaceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspace",
        abstract: "The saved multi-pane layouts the Workspace view shows.",
        discussion: """
            A workspace is a saved arrangement of panes, each pointed at a machine and a
            screen. These read and write the same file the view does, so a layout built
            here shows up there and the other way round.
            """,
        subcommands: [
            WorkspaceListCommand.self, WorkspaceUseCommand.self, WorkspaceNewCommand.self,
            WorkspaceRenameCommand.self, WorkspaceRemoveCommand.self,
            WorkspacePanesCommand.self, WorkspaceSplitCommand.self,
            WorkspaceClosePaneCommand.self, WorkspaceRetargetCommand.self,
            WorkspaceEqualizeCommand.self,
        ],
        defaultSubcommand: WorkspaceListCommand.self,
        aliases: ["workspaces"])
}

enum WorkspaceBridge {
    static func store() -> WorkspaceStore { WorkspaceStore.load() }

    static func layout(_ query: String, in store: WorkspaceStore) throws -> WorkspaceLayout {
        try operation { try WorkspaceOperationExecution.workspace(matching: query, in: store) }
    }

    static func operation<Result>(_ body: () throws -> Result) throws -> Result {
        do {
            return try body()
        } catch let error as WorkspaceOperationError {
            switch error.kind {
            case .invalid:
                throw CLIFailure(error.message, hint: error.hint)
            case .notFound:
                throw CLIFailure.notFound(error.message, hint: error.hint)
            case .unavailable:
                throw CLIFailure.unavailable(error.message, hint: error.hint)
            }
        }
    }

    static func json(_ layout: WorkspaceLayout, current: Bool) -> JSONValue {
        .object([
            "id": .string(layout.id.uuidString),
            "name": .string(layout.name),
            "panes": .int(layout.paneCount),
            "machines": .int(layout.subscribedMachines().count),
            "current": .bool(current),
        ])
    }

    static func announce() {
        AppBridge.post(IPC.Name.machinesChanged)
    }

    static func write(_ store: WorkspaceStore) throws {
        do {
            try WorkspaceStore.save(store)
        } catch {
            throw CLIFailure("could not save the workspaces: \(error.localizedDescription)")
        }
        announce()
    }
}

struct WorkspaceListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List the saved workspaces.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            var store = WorkspaceBridge.store()
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(.list, in: &store)
            }
            let currentID = store.current?.id
            guard !json else {
                CLIOut.json(
                    .array(
                        result.layouts.map {
                            WorkspaceBridge.json($0, current: $0.id == currentID)
                        }))
                return
            }
            guard !result.layouts.isEmpty else {
                CLIOut.note("no workspaces are saved")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "PANES", "MACHINES", ""],
                    rows: result.layouts.map {
                        [
                            $0.name, String($0.paneCount),
                            String($0.subscribedMachines().count),
                            $0.id == currentID ? "current" : "",
                        ]
                    }))
        }
    }
}

struct WorkspaceUseCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use", abstract: "Make one workspace the current one.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Workspace name or id.")
    var workspace: String

    func run() async throws {
        try await execute {
            var store = WorkspaceBridge.store()
            let layout = try WorkspaceBridge.layout(workspace, in: store)
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(
                    .use(workspaceID: layout.id), in: &store)
            }
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(WorkspaceBridge.json(result.layout ?? layout, current: true))
                return
            }
            CLIOut.out("now showing \(layout.name)")
        }
    }
}

struct WorkspaceNewCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "new",
        abstract: "Build a workspace with one pane per machine.",
        discussion: """
            This is the Layout menu's presets as a command: name the machines and the
            screen each pane should show. With one machine you get a single pane, with
            several you get them tiled side by side.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "What each pane shows: overview, processes, docker, files or terminal.")
    var screen: String = "overview"

    @Option(help: "What to call it.")
    var name: String?

    @Argument(help: "Machines to give a pane each.")
    var machines: [String]

    func run() async throws {
        try await execute {
            guard !machines.isEmpty else { throw CLIFailure("name at least one machine") }
            guard let wanted = PaneScreen(rawValue: screen) else {
                throw CLIFailure.notFound(
                    "no screen called \(screen)",
                    hint: "screens: "
                        + PaneScreen.allCases.map(\.rawValue).joined(separator: ", "))
            }
            let resolved = try machines.map { try MachineResolver.machine($0) }
            let title = name ?? resolved.map(\.name).joined(separator: " + ")
            guard
                let layout = WorkspaceLayout.tiled(
                    machineIDs: resolved.map(\.id), screen: wanted, name: title)
            else { throw CLIFailure("could not build a layout from those machines") }
            var store = WorkspaceBridge.store()
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(.create(layout), in: &store)
            }
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(WorkspaceBridge.json(result.layout ?? layout, current: true))
                return
            }
            CLIOut.out("made \(layout.name) with \(layout.paneCount) pane(s)")
        }
    }
}

struct WorkspaceRenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rename", abstract: "Rename a workspace.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Workspace name or id.")
    var workspace: String

    @Argument(help: "The new name.")
    var name: String

    func run() async throws {
        try await execute {
            var store = WorkspaceBridge.store()
            let layout = try WorkspaceBridge.layout(workspace, in: store)
            let was = layout.name
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(
                    .rename(workspaceID: layout.id, name: name), in: &store)
            }
            let renamed = result.layout ?? layout
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(
                    WorkspaceBridge.json(renamed, current: renamed.id == store.currentID))
                return
            }
            CLIOut.out("renamed \(was) to \(renamed.name)")
        }
    }
}

struct WorkspaceRemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Forget a workspace.", aliases: ["remove"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Workspace name or id.")
    var workspace: String

    func run() async throws {
        try await execute {
            var store = WorkspaceBridge.store()
            let layout = try WorkspaceBridge.layout(workspace, in: store)
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(
                    .remove(workspaceID: layout.id), in: &store)
            }
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .string(result.removed?.name ?? layout.name),
                        "remaining": .int(result.layouts.count),
                    ]))
                return
            }
            CLIOut.out("removed \(layout.name)")
        }
    }
}

enum PaneBridge {
    static func context(_ workspace: String?) throws -> (
        store: WorkspaceStore, layout: WorkspaceLayout
    ) {
        let store = WorkspaceBridge.store()
        guard let name = workspace else {
            guard let current = store.current else {
                throw CLIFailure.unavailable(
                    "no workspaces are saved",
                    hint: "make one with `ed machines workspace new`")
            }
            return (store, current)
        }
        return (store, try WorkspaceBridge.layout(name, in: store))
    }

    static func pane(_ index: Int, in layout: WorkspaceLayout) throws -> PaneNode {
        try WorkspaceBridge.operation {
            try WorkspaceOperationExecution.pane(at: index, in: layout)
        }
    }

    static func screen(_ raw: String) throws -> PaneScreen {
        guard let value = PaneScreen(rawValue: raw) else {
            throw CLIFailure.notFound(
                "no screen called \(raw)",
                hint: "screens: " + PaneScreen.allCases.map(\.rawValue).joined(separator: ", "))
        }
        return value
    }

    static func side(_ raw: String) throws -> InsertSide {
        guard let value = InsertSide(rawValue: raw) else {
            throw CLIFailure.notFound(
                "no side called \(raw)", hint: "sides: left, right, top, bottom")
        }
        return value
    }

    static func describe(_ layout: WorkspaceLayout, machines: [Machine]) -> JSONValue {
        let names = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.name) })
        return .object([
            "workspace": .string(layout.name),
            "panes": .array(
                layout.root.panes.enumerated().map { offset, pane in
                    .object([
                        "index": .int(offset + 1),
                        "focused": .bool(pane.id == layout.focused),
                        "tabs": .array(
                            pane.tabs.map { tab in
                                .object([
                                    "machine": .string(
                                        names[tab.target.machineID] ?? "removed machine"),
                                    "screen": .string(tab.target.screen.rawValue),
                                    "selected": .bool(tab.id == pane.selected),
                                ])
                            }),
                    ])
                }),
        ])
    }
}

struct WorkspacePanesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "panes", abstract: "The panes in a workspace and what they show.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Which workspace. Defaults to the current one.")
    var workspace: String?

    func run() async throws {
        try await execute {
            let found = try PaneBridge.context(workspace)
            let machines = MachineRegistry.machines()
            let names = Dictionary(uniqueKeysWithValues: machines.map { ($0.id, $0.name) })
            guard !json else {
                CLIOut.json(PaneBridge.describe(found.layout, machines: machines))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["#", "", "MACHINE", "SHOWING"],
                    rows: found.layout.root.panes.enumerated().map { offset, pane in
                        let tab = pane.tabs.first { $0.id == pane.selected } ?? pane.tabs[0]
                        return [
                            String(offset + 1),
                            pane.id == found.layout.focused ? "focused" : "",
                            names[tab.target.machineID] ?? "removed machine",
                            tab.target.screen.rawValue,
                        ]
                    }))
        }
    }
}

struct WorkspaceSplitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split", abstract: "Split a pane and point the new one somewhere.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Which workspace. Defaults to the current one.")
    var workspace: String?

    @Option(help: "Which side the new pane goes: left, right, top or bottom.")
    var side: String = "right"

    @Option(help: "What the new pane shows.")
    var screen: String = "overview"

    @Argument(help: "The pane number to split, counting from 1.")
    var pane: Int

    @Argument(help: "Machine the new pane points at.")
    var machine: String

    func run() async throws {
        try await execute {
            let found = try PaneBridge.context(workspace)
            let target = try PaneBridge.pane(pane, in: found.layout)
            let wanted = try MachineResolver.machine(machine)
            var store = found.store
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(
                    .split(
                        workspaceID: found.layout.id, paneID: target.id,
                        side: try PaneBridge.side(side),
                        target: PaneTarget(
                            machineID: wanted.id, screen: try PaneBridge.screen(screen))),
                    in: &store)
            }
            let layout = result.layout ?? found.layout
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(layout, machines: MachineRegistry.machines()))
                return
            }
            CLIOut.out(
                "split pane \(pane) to the \(side); \(layout.paneCount) panes now")
        }
    }
}

struct WorkspaceClosePaneCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "close", abstract: "Close a pane.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Which workspace. Defaults to the current one.")
    var workspace: String?

    @Argument(help: "The pane number, counting from 1.")
    var pane: Int

    func run() async throws {
        try await execute {
            let found = try PaneBridge.context(workspace)
            let target = try PaneBridge.pane(pane, in: found.layout)
            var store = found.store
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(
                    .close(workspaceID: found.layout.id, paneID: target.id), in: &store)
            }
            let layout = result.layout ?? found.layout
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(layout, machines: MachineRegistry.machines()))
                return
            }
            CLIOut.out("closed pane \(pane); \(layout.paneCount) left")
        }
    }
}

struct WorkspaceRetargetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "point",
        abstract: "Point a pane at a different machine or screen.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Which workspace. Defaults to the current one.")
    var workspace: String?

    @Option(help: "What the pane should show.")
    var screen: String?

    @Argument(help: "The pane number, counting from 1.")
    var pane: Int

    @Argument(help: "Machine the pane should point at. Leave out to only change the screen.")
    var machine: String?

    func run() async throws {
        try await execute {
            guard machine != nil || screen != nil else {
                throw CLIFailure("say a machine, a --screen, or both")
            }
            let found = try PaneBridge.context(workspace)
            let target = try PaneBridge.pane(pane, in: found.layout)
            let wanted = try machine.map { try MachineResolver.machine($0) }
            let wantedScreen = try screen.map { try PaneBridge.screen($0) }
            let tab = target.tabs.first { $0.id == target.selected } ?? target.tabs[0]
            let next = PaneTarget(
                machineID: wanted?.id ?? tab.target.machineID,
                screen: wantedScreen ?? tab.target.screen,
                argument: tab.target.argument)
            var store = found.store
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(
                    .point(
                        workspaceID: found.layout.id, paneID: target.id,
                        targets: [WorkspaceTabRetarget(tabID: tab.id, target: next)]),
                    in: &store)
            }
            let layout = result.layout ?? found.layout
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(layout, machines: MachineRegistry.machines()))
                return
            }
            CLIOut.out(
                "pane \(pane) now shows \(wantedScreen?.rawValue ?? "")"
                    + (wanted.map { " on \($0.name)" } ?? ""))
        }
    }
}

struct WorkspaceEqualizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "equalize", abstract: "Even out every split.", aliases: ["even"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Which workspace. Defaults to the current one.")
    var workspace: String?

    func run() async throws {
        try await execute {
            let found = try PaneBridge.context(workspace)
            var store = found.store
            let result = try WorkspaceBridge.operation {
                try WorkspaceOperationExecution.perform(
                    .equalize(workspaceID: found.layout.id), in: &store)
            }
            let layout = result.layout ?? found.layout
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(layout, machines: MachineRegistry.machines()))
                return
            }
            CLIOut.out("evened out \(layout.paneCount) panes")
        }
    }
}
