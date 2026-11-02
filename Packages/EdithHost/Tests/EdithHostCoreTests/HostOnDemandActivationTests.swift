import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostOnDemandActivationTests {
    private func state(running: Bool, idle: Bool, pid: Int32? = nil) -> HostCLIProviderState {
        HostCLIProviderState(
            id: "docs", installed: true, compatible: true, enabled: true, running: running,
            idle: idle, version: "1.0.5", disablePending: false, removalPending: false,
            processIdentifier: pid)
    }

    @Test func idleProvidersAreAvailableAndMatchAfterStarting() {
        let idle = state(running: false, idle: true)
        #expect(idle.available)
        #expect(idle.matches(state(running: true, idle: false, pid: 42)))
        #expect(!state(running: false, idle: false).available)
        #expect(
            !state(running: true, idle: false, pid: 1).matches(
                state(running: true, idle: false, pid: 2)))
    }

    @Test func providerStatesDecodeWithoutTheIdleField() throws {
        let json = """
            {"id":"docs","installed":true,"compatible":true,"enabled":true,"running":true,
             "version":"1.0.5","disablePending":false,"removalPending":false}
            """
        let decoded = try JSONDecoder().decode(HostCLIProviderState.self, from: Data(json.utf8))
        #expect(!decoded.idle)
        #expect(decoded.available)
    }

    @Test func surfacesTreatIdleExtensionsAsAvailable() {
        let availability = HostSurfaceAvailability(
            knownIDs: ["docs", "calendar"], installedIDs: ["docs", "calendar"],
            downloadedIDs: ["docs", "calendar"], states: ["docs": .idle, "calendar": .disabled])
        #expect(availability.activeIDs == ["docs"])
    }

    @Test func theBundledIndexMarksOnDemandExtensions() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/EdithHostCore/Resources/index.json")
        let entries = try HostIndex.load(data: Data(contentsOf: url))
        let demand = Set(entries.filter { !$0.background }.map(\.id))
        #expect(
            demand == [
                "homebrew", "jev", "cleaner", "blitztree", "plugins", "docs", "latex", "seoAudit",
                "socialManager", "quinjet", "audioMixer", "calendar", "database", "colorPicker",
                "emoji", "studio", "system", "terminal", "timeLapse", "focusDim", "hinge",
                "keepAwake", "lidAwake", "windowSweaters",
            ])
        #expect(entries.first { $0.id == "notchShelf" }?.background == true)
        #expect(entries.first { $0.id == "colorPicker" }?.commands == ["color", "colour"])
    }

    @Test func launchConditionsReadTheExtensionSuiteAndFallBackToTheirDefault() throws {
        let name = "com.pulkit.edith.tests.launch-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let off = HostLaunchCondition(key: "sampleActive", default: false)
        let on = HostLaunchCondition(key: "sampleActive", default: true)
        #expect(!off.holds(in: defaults))
        #expect(on.holds(in: defaults))
        defaults.set(true, forKey: "sampleActive")
        #expect(off.holds(in: defaults))
        defaults.set(false, forKey: "sampleActive")
        #expect(!on.holds(in: defaults))
    }
}
