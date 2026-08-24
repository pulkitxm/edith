import Foundation
import Testing

@testable import Edith
@testable import EdithCore
@testable import EdithKit

@Suite struct WorkspaceOperationTests {
    private let firstMachine = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let secondMachine = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    @Test func descriptorsCoverTheNineWorkspaceCommands() {
        let descriptors = WorkspaceOperation.allCases.map(\.descriptor)
        #expect(
            Set(descriptors.map(\.cli)) == [
                ["machines", "workspace", "ls"],
                ["machines", "workspace", "split"],
                ["machines", "workspace", "close"],
                ["machines", "workspace", "point"],
                ["machines", "workspace", "equalize"],
                ["machines", "workspace", "new"],
                ["machines", "workspace", "use"],
                ["machines", "workspace", "rename"],
                ["machines", "workspace", "rm"],
            ])
        #expect(Set(descriptors.map(\.id)).count == 9)
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(id: $0.id) == $0 })
        #expect(
            Set(UserInterfaceActionCatalog.actions.map(\.operation.id)).isSuperset(
                of: Set(descriptors.map(\.id))))
    }

    @Test func catalogCarriesTheNineExactWorkspaceUIInvocations() {
        let expected: [WorkspaceOperation: (String, String, [String])] = [
            .list: (
                "Workspace view", "list saved layouts", ["machines", "workspace", "ls"]
            ),
            .split: (
                "Workspace pane menu", "split a pane",
                ["machines", "workspace", "split", "1", "box"]
            ),
            .close: (
                "Workspace pane menu", "close a pane",
                ["machines", "workspace", "close", "1"]
            ),
            .point: (
                "Workspace tab strip", "point a pane at another machine",
                ["machines", "workspace", "point", "1", "box"]
            ),
            .equalize: (
                "Workspace toolbar", "even out the panes",
                ["machines", "workspace", "equalize"]
            ),
            .create: (
                "Workspace toolbar", "apply a layout preset",
                ["machines", "workspace", "new", "box", "--screen", "terminal"]
            ),
            .use: (
                "Workspace picker", "switch to another layout",
                ["machines", "workspace", "use", "a"]
            ),
            .rename: (
                "Workspace picker", "rename a layout",
                ["machines", "workspace", "rename", "a", "b"]
            ),
            .remove: (
                "Workspace picker", "delete a layout",
                ["machines", "workspace", "rm", "a"]
            ),
        ]
        #expect(expected.count == WorkspaceOperation.allCases.count)
        for operation in WorkspaceOperation.allCases {
            let action = UserInterfaceActionCatalog.actions.first {
                $0.operation.id == operation.descriptor.id
            }
            let placement = expected[operation]
            #expect(action?.surface == placement?.0)
            #expect(action?.action == placement?.1)
            #expect(action?.cli == placement?.2)
        }
        #expect(WorkspaceOperation.close.descriptor.effect == .destructive)
        #expect(WorkspaceOperation.remove.descriptor.effect == .destructive)
        #expect(!WorkspaceOperation.close.descriptor.requiresPreview)
        #expect(!WorkspaceOperation.remove.descriptor.requiresPreview)
    }

    @Test func wholeWorkspaceOperationsPreserveSavedLayouts() throws {
        let first = WorkspaceLayout.single(machineID: firstMachine)
        var second = WorkspaceLayout.single(machineID: secondMachine)
        second.name = "Remote"
        var store = WorkspaceStore(layouts: [first], currentID: first.id)

        let listed = try WorkspaceOperationExecution.perform(.list, in: &store)
        #expect(listed.layouts == [first])
        #expect(!listed.changed)

        let created = try WorkspaceOperationExecution.perform(.create(second), in: &store)
        #expect(created.layout == second)
        #expect(store.layouts == [first, second])
        #expect(store.currentID == second.id)

        let used = try WorkspaceOperationExecution.perform(
            .use(workspaceID: first.id), in: &store)
        #expect(used.layout == first)
        #expect(store.currentID == first.id)

        let renamed = try WorkspaceOperationExecution.perform(
            .rename(workspaceID: second.id, name: "  Fleet  "), in: &store)
        #expect(renamed.layout?.name == "Fleet")
        #expect(store.currentID == first.id)

        let removed = try WorkspaceOperationExecution.perform(
            .remove(workspaceID: first.id), in: &store)
        #expect(removed.removed?.id == first.id)
        #expect(store.current?.name == "Fleet")
    }

    @Test func paneOperationsUseStablePaneAndTabIDs() throws {
        let firstTab = PaneTab(target: PaneTarget(machineID: firstMachine, screen: .overview))
        let firstPane = PaneNode(tabs: [firstTab], selected: firstTab.id)
        var layout = WorkspaceLayout(
            name: "Fleet", root: .pane(firstPane), focused: firstPane.id)
        var store = WorkspaceStore(layouts: [layout], currentID: layout.id)

        var result = try WorkspaceOperationExecution.perform(
            .split(
                workspaceID: layout.id, paneID: firstPane.id, side: .right,
                target: PaneTarget(machineID: secondMachine, screen: .terminal)),
            in: &store)
        layout = try #require(result.layout)
        #expect(layout.paneCount == 2)

        result = try WorkspaceOperationExecution.perform(
            .point(
                workspaceID: layout.id, paneID: firstPane.id,
                targets: [
                    WorkspaceTabRetarget(
                        tabID: firstTab.id,
                        target: PaneTarget(machineID: secondMachine, screen: .files))
                ]),
            in: &store)
        layout = try #require(result.layout)
        #expect(layout.root.pane(firstPane.id)?.tabs.first?.target.machineID == secondMachine)
        #expect(layout.root.pane(firstPane.id)?.tabs.first?.target.screen == .files)

        result = try WorkspaceOperationExecution.perform(
            .equalize(workspaceID: layout.id), in: &store)
        layout = try #require(result.layout)
        if case let .split(split) = layout.root {
            #expect(split.ratios == [0.5, 0.5])
        } else {
            Issue.record("split operation did not produce a split layout")
        }

        result = try WorkspaceOperationExecution.perform(
            .close(workspaceID: layout.id, paneID: firstPane.id), in: &store)
        #expect(result.layout?.paneCount == 1)
    }

    @Test func resolutionAndValidationRetainCLIErrorCategories() throws {
        var first = WorkspaceLayout.single(machineID: firstMachine)
        first.name = "Fleet"
        var second = WorkspaceLayout.single(machineID: secondMachine)
        second.name = "Flight"
        let store = WorkspaceStore(layouts: [first, second], currentID: first.id)

        #expect(try WorkspaceOperationExecution.workspace(matching: "Fleet", in: store) == first)
        #expect(
            try WorkspaceOperationExecution.workspace(
                matching: second.id.uuidString, in: store) == second)
        do {
            _ = try WorkspaceOperationExecution.workspace(matching: "Fl", in: store)
            Issue.record("ambiguous prefixes must fail")
        } catch let error as WorkspaceOperationError {
            #expect(error.kind == .notFound)
            #expect(error.hint == "Fleet, Flight")
        }

        var empty = WorkspaceStore()
        do {
            _ = try WorkspaceOperationExecution.perform(
                .rename(workspaceID: first.id, name: ""), in: &empty)
            Issue.record("missing workspaces must fail")
        } catch let error as WorkspaceOperationError {
            #expect(error.kind == .notFound)
        }

        var single = WorkspaceStore(layouts: [first], currentID: first.id)
        do {
            _ = try WorkspaceOperationExecution.perform(
                .close(workspaceID: first.id, paneID: first.root.panes[0].id), in: &single)
            Issue.record("the last pane must remain")
        } catch let error as WorkspaceOperationError {
            #expect(error.kind == .invalid)
            #expect(error.hint == "remove the whole thing with `ed machines workspace rm`")
        }
    }
}

@Suite @MainActor struct WorkspaceModelOperationTests {
    private func model() -> (WorkspaceModel, URL) {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-workspace-operation-\(UUID().uuidString).json")
        return (WorkspaceModel(machines: .shared, file: file), file)
    }

    @Test func savedLayoutActionsRetainAndPersistTheCollection() throws {
        let (model, file) = model()
        defer { try? FileManager.default.removeItem(at: file) }
        let original = model.layout
        var created = WorkspaceLayout.single(machineID: UUID(), screen: .terminal)
        created.name = "Terminal Grid"

        model.use(created)
        #expect(model.savedLayouts.map(\.id) == [original.id, created.id])
        #expect(model.layout.id == created.id)

        model.perform(.use(workspaceID: original.id))
        model.perform(.rename(workspaceID: created.id, name: "Remote Grid"))
        #expect(model.layout.id == original.id)
        #expect(model.savedLayouts.last?.name == "Remote Grid")

        let persisted = WorkspaceStore.load(from: file)
        #expect(persisted.layouts == model.store.layouts)
        #expect(persisted.currentID == original.id)
    }

    @Test func paneActionsUseTheSharedExecutorAndSurfaceFailures() throws {
        let (model, file) = model()
        defer { try? FileManager.default.removeItem(at: file) }
        let pane = try #require(model.layout.root.panes.first)
        let secondMachine = UUID()

        model.splitPane(
            pane.id, side: .right,
            target: PaneTarget(machineID: secondMachine, screen: .terminal))
        #expect(model.layout.paneCount == 2)

        let firstTab = try #require(model.layout.root.pane(pane.id)?.tabs.first)
        model.retargetPane(
            pane.id, tabID: firstTab.id,
            to: PaneTarget(machineID: secondMachine, screen: .files))
        #expect(model.layout.root.pane(pane.id)?.tabs.first?.target.screen == .files)

        model.equalize()
        model.closePane(pane.id)
        #expect(model.layout.paneCount == 1)
        model.closePane(model.layout.root.panes[0].id)
        #expect(model.operationError?.contains("one pane left") == true)
    }

    @Test func closingTheOnlyTabInAPaneUsesTheSharedCloseOperation() throws {
        let (model, file) = model()
        defer { try? FileManager.default.removeItem(at: file) }
        let pane = try #require(model.layout.root.panes.first)
        let tab = try #require(pane.tabs.first)
        model.splitPane(
            pane.id, side: .right,
            target: PaneTarget(machineID: UUID(), screen: .terminal))

        model.closeTab(tab.id, in: pane.id)

        #expect(model.layout.paneCount == 1)
        #expect(model.store.current?.paneCount == 1)
        #expect(model.operationError == nil)
    }
}

@Suite struct WorkspaceOperationCLITests {
    @Test func everyWorkspaceCommandUsesTheSharedStoreContract() async {
        await CLIProbe.inWorld { world in
            MachineRegistry.add(Machine(name: "box", host: "box.example"))

            let empty = await CLIProbe.capture(["machines", "workspace", "ls", "--json"])
            #expect(empty.code == 0)
            #expect(empty.array?.isEmpty == true)

            let invocations = [
                ["machines", "workspace", "new", "box", "--name", "Alpha", "--json"],
                [
                    "machines", "workspace", "split", "1", "box", "--side", "right",
                    "--screen", "terminal", "--json",
                ],
                [
                    "machines", "workspace", "point", "1", "box", "--screen", "files",
                    "--json",
                ],
                ["machines", "workspace", "equalize", "--json"],
                ["machines", "workspace", "close", "2", "--json"],
                ["machines", "workspace", "rename", "Alpha", "Beta", "--json"],
                ["machines", "workspace", "new", "box", "--name", "Other", "--json"],
                ["machines", "workspace", "use", "Beta", "--json"],
                ["machines", "workspace", "rm", "Other", "--json"],
            ]
            for invocation in invocations {
                let run = await CLIProbe.capture(invocation)
                #expect(run.code == 0, "\(invocation) failed: \(run.stderr)")
                #expect(run.object != nil, "\(invocation) did not return a JSON object")
            }

            let store = WorkspaceStore.load()
            #expect(store.layouts.map(\.name) == ["Beta"])
            #expect(store.current?.name == "Beta")
            #expect(world.postedNames().count { $0 == IPC.Name.machinesChanged.rawValue } == 9)

            let lastPane = await CLIProbe.capture([
                "machines", "workspace", "close", "1",
            ])
            #expect(lastPane.code == 1)
            #expect(lastPane.stdout.isEmpty)
            #expect(lastPane.stderr.contains("one pane left"))
        }
    }
}
