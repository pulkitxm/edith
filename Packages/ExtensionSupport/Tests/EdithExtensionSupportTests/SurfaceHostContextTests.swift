import Foundation
import Testing

@testable import EdithExtensionSupport

@Suite @MainActor struct SurfaceHostContextTests {
    @Test func unavailableOrMalformedHostStateCannotEnableWorkers() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        #expect(fixture.context.activeIDs.isEmpty)
        for raw in ["true", "[1]", "[\"../music\"]", "[\"\"]"] {
            try fixture.host.publish(["surface.activeIDs": raw])
            #expect(fixture.context.activeIDs.isEmpty)
        }
        #expect(fixture.context.visibleLayout(.notch).tiles.isEmpty)
    }

    @Test func liveHostPublishesOnlyReadOnlySurfaceAvailability() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.host.publish(["surface.activeIDs": "[\"calendar\",\"notchShelf\"]"])
        #expect(fixture.context.activeIDs == ["calendar", "notchShelf"])
        #expect(fixture.context.visibleLayout(.notch).tiles.map(\.widget) == [.calendar])
        let saved = fixture.context.layout(.notch)
        try fixture.host.publish(["surface.activeIDs": "[]"])
        #expect(fixture.context.visibleLayout(.notch).tiles.isEmpty)
        #expect(fixture.context.layout(.notch) == saved)
        try fixture.host.clear("host")
        #expect(fixture.context.activeIDs.isEmpty)
    }

    @Test func runtimeLayoutsAndProfilesRemainInTheHostPreferenceDomain() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let store = SurfaceLayoutStore(defaults: fixture.defaults)
        store.update(.home) { $0.tiles = [.init(.ability("futureExtension"))] }
        #expect(store.saveProfile("Future", target: .home))
        #expect(fixture.context.layout(.home).tiles.first?.widget == .ability("futureExtension"))
        #expect(fixture.context.visibleLayout(.home).tiles.isEmpty)
        let restarted = SurfaceLayoutStore(defaults: fixture.defaults)
        #expect(restarted.profiles(.home).first?.layout == store.home)
    }

    @MainActor private struct Fixture {
        let suite: String
        let defaults: UserDefaults
        let root: URL
        let host: ExtensionSharedState
        let context: SurfaceHostContext

        init() throws {
            suite = "com.pulkit.edith.tests.surface-context.\(UUID().uuidString)"
            defaults = try #require(UserDefaults(suiteName: suite))
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            host = ExtensionSharedState(root: root, namespace: suite, owner: "host")
            context = SurfaceHostContext(
                defaults: defaults, sharedState: ExtensionSharedState(root: root, namespace: suite))
        }

        func clean() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
