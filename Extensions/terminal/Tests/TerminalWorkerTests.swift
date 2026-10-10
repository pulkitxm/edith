import EdithExtensionSupport
import Foundation
import Testing
@testable import TerminalExtension

@Suite(.serialized) @MainActor struct TerminalWorkerTests {
    @Test func remoteModelOwnsOnlyRenderersAndLeavesEngineAliveWhenUIStops() async throws {
        let engine = TerminalTestFixture.engine()
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        let model = TerminalTabsModel(client: remote)
        await remote.open()
        model.synchronize()
        let tab = try #require(model.tabs.first)
        #expect(tab.holder.started && tab.holder.ghosttyView == nil)
        model.stopAll(); model.stopAll()
        #expect(model.tabs.isEmpty && !tab.holder.started && remote.isStopped)
        #expect(try engine.snapshot().sessions.count == 1)
        engine.stop()
        #expect(engine.isStopped)
    }

    @Test func nativeTabsSelectCloseAndRestartThroughOwnedEngine() async throws {
        let engine = TerminalTestFixture.engine()
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        let model = TerminalTabsModel(client: remote)
        defer { model.stopAll() }
        await remote.open(); await remote.open()
        model.synchronize()
        let first = try #require(model.tabs.first)
        model.selectNext(backwards: true)
        try await TerminalTestFixture.wait { model.selected == first.id }
        model.restart(first.id)
        try await TerminalTestFixture.wait {
            model.tabs.first?.holder.generation != first.holder.generation
        }
        #expect(!first.holder.started)
        model.closeTab(first.id, confirm: false)
        try await TerminalTestFixture.wait { model.tabs.count == 1 }
        #expect(try engine.snapshot().sessions.count == 1)
    }

    @Test func checkedBroadcastUsesRealPTYAndRejectsNullInput() async throws {
        let engine = TerminalTestFixture.engine()
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        let model = TerminalTabsModel(client: remote)
        defer { model.stopAll() }
        await remote.open(); await remote.open()
        model.synchronize()
        let plan = try TerminalBroadcastPlan.make(command: " true ").get()
        let delivery = try await model.sendBroadcast(plan)
        #expect(delivery.sent == 2 && delivery.unavailable == 0)
        for session in remote.snapshot.sessions {
            let output = try await remote.read(session, after: 0)
            #expect(String(decoding: output.bytes, as: UTF8.self) == "true\n")
        }
        #expect(TerminalBroadcastPlan.make(command: "bad\u{0}") == .failure(.invalidCommand))
    }

    @Test func preferenceEditTravelsToEngineAndUpdatesOriginalPanes() async throws {
        let suite = "terminal.model.preferences." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = TerminalEngine(
            defaults: defaults,
            launch: {
                TerminalLaunch(
                    executable: "/bin/cat", arguments: [], environment: [],
                    currentDirectory: "/private/tmp", startupCommand: nil)
            })
        defer { engine.stop() }
        let remote = try TerminalTestFixture.remote(engine)
        let model = TerminalTabsModel(client: remote)
        defer { model.stopAll() }
        await remote.open(); model.synchronize()
        let settings = TerminalSettings(
            fontSize: 19, shell: "/bin/sh", loginShell: false, startupCommand: "printf synthetic")
        await model.savePreferences(settings)
        #expect(TerminalSettings.load(defaults) == settings)
        #expect(model.tabs.first?.holder.fontSize == 19)
    }
}
