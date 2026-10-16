import EdithExtensionSupport
import Foundation
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrSettingsActionTests {
    @Test func stuckThresholdCallbackPersistsAndRestoresOriginalSettings() async throws {
        let environment = ProcessInfo.processInfo.environment
        let home = try #require(environment["EDITH_EXTENSION_FIXTURE_HOME"])
        try #require(environment["HOME"] == home && environment["CFFIXED_USER_HOME"] == home)
        let root = URL(fileURLWithPath: home, isDirectory: true)
        try #require(home.hasPrefix("/") && root.resolvingSymlinksInPath().path == home)
        try #require(environment["TMPDIR"]?.hasPrefix(home + "/") == true)
        try #require(environment["EDITH_EXTENSION_DATA_ROOT"]?.hasPrefix(home + "/") == true)
        let namespace = try #require(environment["EDITH_SHARED_DEFAULTS_SUITE"])
        try #require(namespace.hasPrefix("edith.herdr."))
        let suite = namespace + ".settings." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let persistent = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defer { HerdrWorkOwnership.enable() }
        let baseline = HerdrAttentionSettings(
            blocked: false, finished: false, errors: false, stuck: false,
            openDiff: false, stuckMinutes: 17, monitoring: false)
        baseline.save(in: defaults)
        var providers = AgentActivitySettings.load(in: defaults)
        providers.monitorTerminalAttention = false
        defaults.set(providers.encoded, forKey: AgentActivitySettings.defaultsKey)
        let notifications = HerdrNotificationService(
            defaults: defaults,
            queueURL: root.appendingPathComponent("settings-notifications.json"),
            deliver: { _ in Issue.record("Unexpected notification delivery") },
            remove: { identifiers in #expect(identifiers.isEmpty) },
            open: { _ in Issue.record("Unexpected notification action") })
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }),
            defaults: defaults, notifications: notifications, automaticActions: false)
        var saves = 0
        let model = HerdrSettingsModel { operation, payload in
            #expect(operation == "herdr.settings.read" || operation == "herdr.settings.save")
            if operation == "herdr.settings.save" { saves += 1 }
            return try await worker.execute(operation, payload: payload)
        }
        do {
            await model.read()
            #expect(model.settings == baseline && model.error == nil && !model.loading)
            for (index, minutes) in [18, 17].enumerated() {
                model.update { $0.stuckMinutes = minutes }
                let deadline = ContinuousClock.now + .seconds(10)
                while (saves < index + 1 || model.loading), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(saves == index + 1 && !model.loading && model.error == nil)
                var expected = baseline
                expected.stuckMinutes = minutes
                #expect(model.settings == expected && worker.activity.stuckMinutes == minutes)
                let authoritative = try AgentPayload.decode(
                    HerdrAttentionSettings.self,
                    from: await worker.execute("herdr.settings.read", payload: Data("{}".utf8)))
                #expect(authoritative == expected)
                #expect(HerdrAttentionSettings(defaults: persistent) == expected)
                let domain = try #require(persistent.persistentDomain(forName: suite))
                #expect(domain[HerdrAttentionSettings.Keys.stuckMinutes] as? Int == minutes)
                #expect(domain[HerdrAttentionSettings.Keys.notifyWhenStuck] as? Bool == false)
            }
            #expect(
                model.settings == baseline
                    && HerdrAttentionSettings(defaults: persistent) == baseline)
        } catch {
            await model.stopAndWait()
            await worker.shutdown()
            throw error
        }
        await model.stopAndWait()
        await worker.shutdown()
        #expect(!model.loading && worker.isStopped && saves == 2)
    }
}
