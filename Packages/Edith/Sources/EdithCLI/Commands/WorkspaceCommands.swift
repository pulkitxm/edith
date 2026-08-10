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
        guard !store.layouts.isEmpty else {
            throw CLIFailure.unavailable(
                "no workspaces are saved",
                hint: "make one with `ed machines workspace new`")
        }
        let needle = query.lowercased()
        if let exact = store.layouts.first(where: { $0.name.lowercased() == needle }) {
            return exact
        }
        if let byID = store.layouts.first(where: { $0.id.uuidString.lowercased() == needle }) {
            return byID
        }
        let prefixed = store.layouts.filter { $0.name.lowercased().hasPrefix(needle) }
        if prefixed.count == 1, let only = prefixed.first { return only }
        if prefixed.count > 1 {
            throw CLIFailure.notFound(
                "\(query) matches more than one workspace",
                hint: prefixed.map(\.name).joined(separator: ", "))
        }
        throw CLIFailure.notFound(
            "no workspace called \(query)",
            hint: "known: " + store.layouts.map(\.name).joined(separator: ", "))
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
            let store = WorkspaceBridge.store()
            let currentID = store.current?.id
            guard !json else {
                CLIOut.json(
                    .array(
                        store.layouts.map {
                            WorkspaceBridge.json($0, current: $0.id == currentID)
                        }))
                return
            }
            guard !store.layouts.isEmpty else {
                CLIOut.note("no workspaces are saved")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "PANES", "MACHINES", ""],
                    rows: store.layouts.map {
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
            store.currentID = layout.id
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(WorkspaceBridge.json(layout, current: true))
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
            store.upsert(layout)
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(WorkspaceBridge.json(layout, current: true))
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
            var layout = try WorkspaceBridge.layout(workspace, in: store)
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw CLIFailure("a workspace needs a name") }
            let was = layout.name
            layout.name = trimmed
            let currentID = store.currentID
            store.upsert(layout)
            store.currentID = currentID
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(WorkspaceBridge.json(layout, current: layout.id == currentID))
                return
            }
            CLIOut.out("renamed \(was) to \(trimmed)")
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
            store.remove(layout.id)
            try WorkspaceBridge.write(store)
            guard !json else {
                CLIOut.json(
                    .object([
                        "removed": .string(layout.name),
                        "remaining": .int(store.layouts.count),
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
        let panes = layout.root.panes
        guard index >= 1, index <= panes.count else {
            throw CLIFailure.notFound(
                "there is no pane \(index) in \(layout.name)",
                hint: "it has \(panes.count), numbered from 1")
        }
        return panes[index - 1]
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

    static func save(_ store: WorkspaceStore, _ layout: WorkspaceLayout) throws {
        var updated = store
        let currentID = store.currentID
        updated.upsert(layout)
        updated.currentID = currentID ?? layout.id
        try WorkspaceBridge.write(updated)
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
            var found = try PaneBridge.context(workspace)
            let target = try PaneBridge.pane(pane, in: found.layout)
            let wanted = try MachineResolver.machine(machine)
            found.layout.split(
                paneID: target.id, side: try PaneBridge.side(side),
                target: PaneTarget(
                    machineID: wanted.id, screen: try PaneBridge.screen(screen)))
            try PaneBridge.save(found.store, found.layout)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(found.layout, machines: MachineRegistry.machines()))
                return
            }
            CLIOut.out(
                "split pane \(pane) to the \(side); \(found.layout.paneCount) panes now")
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
            var found = try PaneBridge.context(workspace)
            guard found.layout.paneCount > 1 else {
                throw CLIFailure(
                    "\(found.layout.name) has one pane left, and a workspace needs one",
                    hint: "remove the whole thing with `ed machines workspace rm`")
            }
            let target = try PaneBridge.pane(pane, in: found.layout)
            found.layout.closePane(target.id)
            try PaneBridge.save(found.store, found.layout)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(found.layout, machines: MachineRegistry.machines()))
                return
            }
            CLIOut.out("closed pane \(pane); \(found.layout.paneCount) left")
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
            var found = try PaneBridge.context(workspace)
            let target = try PaneBridge.pane(pane, in: found.layout)
            let wanted = try machine.map { try MachineResolver.machine($0) }
            let wantedScreen = try screen.map { try PaneBridge.screen($0) }
            found.layout.root.updatePane(target.id) { node in
                guard let index = node.tabs.firstIndex(where: { $0.id == node.selected })
                else { return }
                if let wanted { node.tabs[index].target.machineID = wanted.id }
                if let wantedScreen { node.tabs[index].target.screen = wantedScreen }
            }
            try PaneBridge.save(found.store, found.layout)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(found.layout, machines: MachineRegistry.machines()))
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
            var found = try PaneBridge.context(workspace)
            found.layout.root.equalize()
            try PaneBridge.save(found.store, found.layout)
            guard !json else {
                CLIOut.json(
                    PaneBridge.describe(found.layout, machines: MachineRegistry.machines()))
                return
            }
            CLIOut.out("evened out \(found.layout.paneCount) panes")
        }
    }
}
