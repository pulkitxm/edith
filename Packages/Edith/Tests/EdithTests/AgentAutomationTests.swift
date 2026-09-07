import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentAutomationTests {
    @Test func agentExecutesScenesAndOwnsHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AutomationStorage(root: root)
        let scene = AutomationScene(
            name: "Mock status", actions: [AutomationAction(operationID: "app.info")])
        try storage.save(AutomationDocument(scenes: [scene]))
        let service = AutomationService(
            storage: storage, isEnabled: { true },
            runner: { arguments in
                #expect(arguments == ["app", "info"])
                return "mock status ready"
            })
        let record = try await service.execute(
            AgentAutomationRunRequest(sceneID: scene.id, origin: .commandLine))
        #expect(record.succeeded)
        #expect(try storage.history().map(\.id) == [record.id])
    }

    @Test func disabledAbilityRefusesExecutionBeforeLaunchingAProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AutomationStorage(root: root)
        let scene = AutomationScene(
            name: "Mock status", actions: [AutomationAction(operationID: "app.info")])
        try storage.save(AutomationDocument(scenes: [scene]))
        let service = AutomationService(
            storage: storage, isEnabled: { false },
            runner: { _ in
                Issue.record("Disabled automation launched a process")
                return ""
            })
        await #expect(throws: AutomationExecutionError.disabled) {
            try await service.execute(
                AgentAutomationRunRequest(sceneID: scene.id, origin: .trigger))
        }
        #expect(try storage.history().isEmpty)
    }

    @Test func agentOwnsBackgroundTriggersAndHelperOwnsSessionTriggers() {
        let descriptor = AgentJobPlan.descriptors.first { $0.id == "automations.triggers" }
        #expect(descriptor?.abilityID == "automations")
        #expect(descriptor?.cadence.ambient == 30)
        #expect(AgentOperationCatalog.servesInternal(AgentAutomationOperation.load))
        #expect(AgentOperationCatalog.servesInternal(AgentAutomationOperation.save))
        #expect(AgentOperationCatalog.servesInternal(AgentAutomationOperation.history))
    }
}
