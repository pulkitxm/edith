import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentFocusTests {
    @Test func focusStateRoundTripsThroughTheDaemon() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = FocusStorageService(storage: FocusStorage(root: root))
        let runtime = AgentRuntime(build: "fixture", store: nil)
        await service.register(on: runtime)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = listener.client()
        let profile = FocusProfile(name: "Writing")
        let document = FocusDocument(profiles: [profile])
        _ = try client.performInternal(
            AgentFocusStorageOperation.save, payload: AgentPayload.encode(document))
        #expect(
            try AgentPayload.decode(
                FocusDocument.self, from: client.performInternal(AgentFocusStorageOperation.load))
                == document)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let session = FocusSession(
            profileID: profile.id, profileName: profile.name, origin: .app, startedAt: now,
            restorationScene: AutomationScene(name: "Restore", actions: []))
        _ = try client.performInternal(
            AgentFocusStorageOperation.saveSession, payload: AgentPayload.encode(session))
        #expect(
            try AgentPayload.decode(
                FocusSession?.self, from: client.performInternal(AgentFocusStorageOperation.session)
            ) == session)
        let record = FocusHistoryRecord(
            sessionID: session.id, profileName: profile.name, origin: .app,
            startedAt: session.startedAt, endedAt: now, outcome: .completed)
        _ = try client.performInternal(
            AgentFocusStorageOperation.append, payload: AgentPayload.encode(record))
        #expect(
            try AgentPayload.decode(
                [FocusHistoryRecord].self,
                from: client.performInternal(AgentFocusStorageOperation.history)) == [record])
        _ = try client.performInternal(
            AgentFocusStorageOperation.saveSession,
            payload: AgentPayload.encode(Optional<FocusSession>.none))
        #expect(
            try AgentPayload.decode(
                FocusSession?.self, from: client.performInternal(AgentFocusStorageOperation.session)
            ) == nil)
    }

    @Test func daemonRestoresTransientFocusStateAfterAbilityIsDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = FocusExecutionGate()
        let service = AutomationService(
            storage: AutomationStorage(root: root), isEnabled: { false },
            runner: { _ in
                await gate.markStarted()
                try await Task.sleep(for: .milliseconds(50))
                return "restored"
            })
        let scene = AutomationScene(
            name: "Restore mock state", actions: [AutomationAction(operationID: "app.info")])
        let execution = Task {
            try await service.execute(
                AgentAutomationRunRequest(
                    sceneID: scene.id, origin: .app, transientScene: scene, restoresFocusState: true
                ))
        }
        await gate.waitUntilStarted()
        _ = try await service.tick()
        let record = try await execution.value
        #expect(record.succeeded)
        #expect(record.sceneName == scene.name)
    }

    @Test func scheduledFocusCanRunItsComponentSceneWithoutBlocking() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = AutomationStorage(root: root)
        let component = AutomationScene(
            name: "Mock component", actions: [AutomationAction(operationID: "app.info")])
        let scheduled = AutomationScene(
            name: "Mock scheduled focus",
            actions: [
                AutomationAction(
                    operationID: "focus.start", arguments: ["Mock profile"], timeoutSeconds: 5)
            ])
        try storage.save(AutomationDocument(scenes: [component, scheduled]))
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let tasks = try AgentTaskService(directory: nil)
        let listener = AgentRuntimeTestListener(runtime: runtime)
        defer { listener.stop() }
        let client = AgentTaskClient(client: listener.client(), pollInterval: 0.01)
        let service = AutomationService(
            storage: storage, isEnabled: { true },
            runner: { arguments in
                if arguments.first == "focus" {
                    let payload = try await client.run(
                        AgentTaskSubmission(
                            operation: AgentAutomationOperation.focusRun,
                            title: component.name,
                            payload: AgentPayload.encode(
                                AgentAutomationRunRequest(sceneID: component.id, origin: .app))))
                    let result = try AgentPayload.decode(AutomationRunRecord.self, from: payload)
                    #expect(result.succeeded)
                }
                return "ready"
            })
        await service.register(on: runtime, tasks: tasks)
        await AgentTaskOperations.register(on: runtime, service: tasks)
        let payload = try await client.run(
            AgentTaskSubmission(
                operation: AgentAutomationOperation.run,
                title: scheduled.name,
                payload: AgentPayload.encode(
                    AgentAutomationRunRequest(sceneID: scheduled.id, origin: .trigger))))
        let result = try AgentPayload.decode(AutomationRunRecord.self, from: payload)
        #expect(result.succeeded)
        #expect(try storage.history().count == 2)
        await service.shutdown()
    }

    @Test func profilesRequireTheAutomationsAbilityAndDeskSuite() throws {
        let name = "focus-dependencies-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let entry = try #require(ExtensionRegistry.entry("focusProfiles"))
        defaults.set(true, forKey: "focusProfilesEnabled")
        defaults.set(true, forKey: "suiteDeskEnabled")
        defaults.set(false, forKey: "automationsEnabled")
        #expect(!entry.isEnabled(in: defaults))
        defaults.set(true, forKey: "automationsEnabled")
        #expect(entry.isEnabled(in: defaults))
        defaults.set(false, forKey: "suiteDeskEnabled")
        #expect(!entry.isEnabled(in: defaults))
    }
}

private actor FocusExecutionGate {
    private var started = false
    func markStarted() { started = true }
    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }
}
