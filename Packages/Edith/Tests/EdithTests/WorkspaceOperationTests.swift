import Foundation
import Testing

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
