import EdithExtensionSupport
import Foundation
import Testing
@testable import PluginsExtension

@Suite struct SkillsModelTests {
    private let skill = EdithSkillLibrary.skills[0]
    @MainActor @Test func discoveryRunsOffMainThreadAndResolvesEmptyState() async {
        let model = SkillsModel(detectAgents: {
            #expect(!Thread.isMainThread)
            return []
        })
        #expect(!model.agentsLoaded)
        await model.discoverAgents()
        #expect(model.agentsLoaded)
        #expect(!model.isDiscovering)
        #expect(model.agents.isEmpty)
    }

    @MainActor @Test func overlappingDiscoverySharesWorkAndPublishesLoadedAgents() async {
        let gate = DispatchSemaphore(value: 0)
        let agents = Array(SkillAgentCatalog.agents.prefix(2))
        let model = SkillsModel(detectAgents: {
            #expect(!Thread.isMainThread)
            #expect(gate.wait(timeout: .now() + 5) == .success)
            return agents
        })
        let first = Task { await model.discoverAgents() }
        for _ in 0..<1_000 {
            if model.isDiscovering { break }
            await Task.yield()
        }
        #expect(model.isDiscovering)
        #expect(!model.agentsLoaded)
        var secondStarted = false
        let second = Task {
            secondStarted = true
            await model.discoverAgents()
        }
        for _ in 0..<1_000 {
            if secondStarted { break }
            await Task.yield()
        }
        #expect(secondStarted)
        gate.signal()
        await first.value
        await second.value
        #expect(model.agentsLoaded)
        #expect(!model.isDiscovering)
        #expect(model.agents == agents)
    }

    @MainActor @Test func selectionPersistsAcrossSkillsAndNewModelsIncludingAllOff() async throws {
        let name = "com.pulkit.edith.tests.skills.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let agents = Array(SkillAgentCatalog.agents.prefix(2))
        let model = SkillsModel(defaults: defaults, detectAgents: { agents })
        await model.present(skill)
        #expect(model.selectedAgentIDs == Set(agents.map(\.id)))
        for agent in agents { model.setSelected(agent.id, enabled: false) }
        await model.present(
            EdithSkillLibrary.skills[1])
        #expect(model.selectedAgentIDs.isEmpty)
        let reopened = SkillsModel(defaults: defaults, detectAgents: { agents })
        await reopened.present(skill)
        #expect(reopened.selectedAgentIDs.isEmpty)
        await reopened.present(skill, agentID: agents[0].id)
        #expect(reopened.selectedAgentIDs == [agents[0].id])
        await reopened.present(skill)
        #expect(reopened.selectedAgentIDs.isEmpty)
        reopened.setSelected(agents[1].id, enabled: true)
        await model.present(skill)
        #expect(model.selectedAgentIDs == [agents[1].id])
    }

    @MainActor @Test func newAgentsDefaultOnWithoutReenablingOptedOutAgents() async throws {
        let name = "com.pulkit.edith.tests.skills.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let agents = Array(SkillAgentCatalog.agents.prefix(2))
        let model = SkillsModel(defaults: defaults, detectAgents: { [agents[0]] })
        await model.present(skill)
        model.setSelected(agents[0].id, enabled: false)
        let replacement = SkillsModel(defaults: defaults, detectAgents: { agents })
        await replacement.present(skill)
        #expect(replacement.selectedAgentIDs == [agents[1].id])
    }

    @MainActor @Test func disableWaitsForOwnedDiscoveryAndDiscardsItsLateAgents() async throws {
        let gate = DispatchSemaphore(value: 0)
        let agents = Array(SkillAgentCatalog.agents.prefix(2))
        let model = SkillsModel(detectAgents: {
            _ = gate.wait(timeout: .now() + 5)
            return agents
        })
        let request = Task { await model.discoverAgents() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.isDiscovering, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isDiscovering)
        let stopping = Task { await model.shutdown() }
        while !model.isStopped, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isStopped)
        gate.signal()
        await stopping.value
        await request.value
        #expect(model.agents.isEmpty)
        #expect(!model.agentsLoaded)
        #expect(!model.installerAvailable)
        await model.present(skill)
        #expect(model.presentedSkill == nil)
    }

    @MainActor @Test func disableCancelsInstallationAndCannotPublishLateSuccessOrLogs()
        async throws
    {
        let gate = InstallationGate()
        let installer = SkillInstaller(recordInstalled: { _, _ in
            Issue.record("A stopped installer must not record a document.")
        }) { _, log in
            await gate.pause()
            log("Late synthetic output")
            return CLICommandResult(terminationStatus: 0, output: "synthetic result")
        }
        let agent = try #require(SkillAgentCatalog.agents.first { $0.id == "cursor" })
        let model = SkillsModel(installer: installer, detectAgents: { [agent] })
        await model.present(skill)
        let installation = Task { await model.install() }
        try await gate.waitUntilStarted()
        #expect(model.isInstalling)
        let stopping = Task { await model.shutdown() }
        let deadline = ContinuousClock.now + .seconds(5)
        while !model.isStopped, ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.isStopped)
        await gate.release()
        await stopping.value
        await installation.value
        #expect(!model.isInstalling)
        #expect(!model.installationSucceeded)
        #expect(model.installedAgents.isEmpty)
        #expect(model.installationLog.isEmpty)
        #expect(model.installationError == nil)
    }

    private actor InstallationGate {
        private var started = false
        private var continuation: CheckedContinuation<Void, Never>?

        func pause() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started = true
            }
        }

        func release() {
            let continuation = continuation
            self.continuation = nil
            continuation?.resume()
        }

        func waitUntilStarted() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while !started, ContinuousClock.now < deadline { await Task.yield() }
            guard started else {
                throw SkillsError.message("The synthetic installer did not start.")
            }
        }
    }

}
