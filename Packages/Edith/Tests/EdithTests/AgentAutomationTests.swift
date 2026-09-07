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

    @Test func sceneRunsThroughTheDaemonTaskTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AutomationStorage(root: root)
        let scene = AutomationScene(
            name: "Mock transport", actions: [AutomationAction(operationID: "app.info")])
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let tasks = try AgentTaskService(directory: nil)
        let service = AutomationService(
            storage: storage, isEnabled: { true }, runner: { _ in "ready" })
        await service.register(on: runtime, tasks: tasks)
        await AgentTaskOperations.register(on: runtime, service: tasks)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = listener.client()
        _ = try client.performInternal(
            AgentAutomationOperation.save,
            payload: AgentPayload.encode(AutomationDocument(scenes: [scene])))
        let document = try AgentPayload.decode(
            AutomationDocument.self,
            from: client.performInternal(AgentAutomationOperation.load))
        #expect(document.scenes == [scene])
        let result = try await AgentTaskClient(client: client, pollInterval: 0.01).run(
            AgentTaskSubmission(
                operation: AgentAutomationOperation.run, title: scene.name,
                payload: AgentPayload.encode(
                    AgentAutomationRunRequest(sceneID: scene.id, origin: .commandLine))))
        let record = try AgentPayload.decode(AutomationRunRecord.self, from: result)
        #expect(record.succeeded)
        let history = try AgentPayload.decode(
            [AutomationRunRecord].self,
            from: client.performInternal(AgentAutomationOperation.history))
        #expect(history.map(\.id) == [record.id])
        await service.shutdown()
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
