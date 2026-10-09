import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostSurfaceNavigationTests {
    @Test func onlyExplicitRequestsFromTheRunningNotchSelectTheEditor() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let token = UUID()
        try fixture.notch.publish([
            "surface.openEditor": "notch", "surface.openEditorToken": token.uuidString,
            "surface.openEditorTileID": "calendar",
        ])
        fixture.navigation.refresh()
        #expect(fixture.navigation.editorRequest == nil)
        try fixture.host.publish(["surface.activeIDs": "[\"notchShelf\"]"])
        fixture.navigation.refresh()
        #expect(fixture.navigation.editorRequest?.token == token)
        #expect(fixture.navigation.editorRequest?.target == .notch)
        #expect(fixture.navigation.editorRequest?.tileID == "calendar")
        try fixture.notch.publish([
            "surface.openEditor": "notch", "surface.openEditorToken": token.uuidString,
            "surface.openEditorTileID": "music",
        ])
        fixture.navigation.refresh()
        #expect(fixture.navigation.editorRequest?.tileID == "calendar")
    }

    @Test func staleAndMalformedNavigationRequestsDoNotChangeSelection() throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.host.publish(["surface.activeIDs": "[\"notchShelf\"]"])
        for values in [
            ["surface.openEditor": "home", "surface.openEditorToken": UUID().uuidString],
            ["surface.openEditor": "notch", "surface.openEditorToken": "invalid"],
            [
                "surface.openEditor": "notch", "surface.openEditorToken": UUID().uuidString,
                "surface.openEditorTileID": String(repeating: "x", count: 257),
            ],
        ] {
            try fixture.notch.publish(values)
            fixture.navigation.refresh()
            #expect(fixture.navigation.editorRequest == nil)
        }
        try fixture.notch.publish([
            "surface.openEditor": "notch", "surface.openEditorToken": UUID().uuidString,
        ])
        let relaunched = HostSurfaceNavigation(context: fixture.context)
        defer { relaunched.shutdown() }
        relaunched.refresh()
        #expect(relaunched.editorRequest == nil)
    }

    @Test func newRequestsAreObservedAndShutdownStopsNavigation() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        try fixture.host.publish(["surface.activeIDs": "[\"notchShelf\"]"])
        let token = UUID()
        try fixture.notch.publish([
            "surface.openEditor": "notch", "surface.openEditorToken": token.uuidString,
        ])
        let deadline = Date().addingTimeInterval(5)
        while fixture.navigation.editorRequest == nil {
            guard Date() < deadline else { throw ExtensionPeerError.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fixture.navigation.editorRequest?.token == token)
        fixture.navigation.shutdown()
        try fixture.notch.publish([
            "surface.openEditor": "notch", "surface.openEditorToken": UUID().uuidString,
        ])
        try await Task.sleep(for: .milliseconds(30))
        #expect(fixture.navigation.editorRequest == nil)
    }

    @MainActor private struct Fixture {
        let root: URL
        let suite: String
        let host: ExtensionSharedState
        let notch: ExtensionSharedState
        let context: SurfaceHostContext
        let navigation: HostSurfaceNavigation
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "edith.tests.navigation." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: suite))
            host = ExtensionSharedState(root: root, namespace: suite, owner: "host")
            notch = ExtensionSharedState(root: root, namespace: suite, owner: "notchShelf")
            context = SurfaceHostContext(defaults: defaults, sharedState: host)
            navigation = HostSurfaceNavigation(context: context)
        }
        func clean() {
            navigation.shutdown()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
