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
        let session = FocusSession(
            profileID: profile.id, profileName: profile.name, origin: .app,
            restorationScene: AutomationScene(name: "Restore", actions: []))
        _ = try client.performInternal(
            AgentFocusStorageOperation.saveSession, payload: AgentPayload.encode(session))
        #expect(
            try AgentPayload.decode(
                FocusSession?.self, from: client.performInternal(AgentFocusStorageOperation.session)
            ) == session)
        let record = FocusHistoryRecord(
            sessionID: session.id, profileName: profile.name, origin: .app,
            startedAt: session.startedAt, outcome: .completed)
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
        let service = AutomationService(
            storage: AutomationStorage(root: root), isEnabled: { false },
            runner: { _ in "restored" })
        let scene = AutomationScene(
            name: "Restore mock state", actions: [AutomationAction(operationID: "app.info")])
        let record = try await service.execute(
            AgentAutomationRunRequest(
                sceneID: scene.id, origin: .app,
                transientScene: scene, restoresFocusState: true))
        #expect(record.succeeded)
        #expect(record.sceneName == scene.name)
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
