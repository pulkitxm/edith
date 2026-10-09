@testable import MachinesExtension
import EdithExtensionSupport
import Foundation
import Testing

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

    @Test func initialStoreLoadsWithoutBlockingInitialization() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-workspace-load-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let saved = WorkspaceLayout.single(machineID: UUID(), screen: .files)
        try WorkspaceStore.save(
            WorkspaceStore(layouts: [saved], currentID: saved.id), to: file)

        let model = WorkspaceModel(machines: .shared, file: file)
        await model.awaitInitialLoad()

        #expect(model.layout.id == saved.id)
        #expect(model.store.currentID == saved.id)
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
