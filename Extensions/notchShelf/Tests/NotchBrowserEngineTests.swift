import EdithExtensionSupport
import Foundation
import Testing
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchBrowserEngineTests {
    @Test func originalChromeCookiesStorageAndSavedSessionCrossCheckedBoundedFacade() async throws {
        let synthetic = try SyntheticChrome(profiles: [
            .init(
                directory: "Default", name: "Mock browser profile", email: "mock@example.invalid",
                cookies: [
                    .init(
                        host: ".example.invalid", name: "session", value: "synthetic-secret",
                        secure: true, httpOnly: true)
                ], localStorage: ["https://example.invalid": ["theme": "dark"]])
        ])
        defer { synthetic.remove() }
        let id = "notch-browser-engine-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: id))
        defer { UserDefaults.standard.removePersistentDomain(forName: id) }
        let file = BrowserSessionFile(
            url: synthetic.root.appendingPathComponent("owned/session.json"))
        file.save(
            .init(
                profile: "Default", profileName: "Mock browser profile",
                tabs: ["https://example.invalid/fixture"], selected: 0, width: 820, height: 460))
        let installation = ChromeInstallation(
            applicationURL: { synthetic.root.appendingPathComponent("Mock Chrome.app") },
            defaultBrowser: { (ChromeInstallation.bundleIdentifier, "Mock Chrome") },
            userData: synthetic.userData)
        let engine = NotchBrowserEngine(
            installation: installation, sessionFile: file, defaults: defaults,
            keyProvider: { SyntheticChrome.key },
            open: { _, _ in Issue.record("No native app operation is allowed") },
            downloads: .init(
                destination: { synthetic.root.appendingPathComponent("Downloads") },
                staging: synthetic.root.appendingPathComponent("Download staging"),
                completed: { _ in }))
        defer { engine.stop() }
        let identity = NotchPanelIdentity(ownershipID: UUID(), generation: UUID())
        let presentation = UUID()
        let remote = NotchBrowserRemoteClient(
            state: try engine.state(),
            request: { operation in
                .init(
                    identity: identity, displayID: 42, presentationID: presentation,
                    operation: operation)
            }, invoke: { try await engine.execute($0) })
        defer { remote.stop() }
        #expect(remote.state.readiness == .ready)
        #expect(remote.state.profiles.first?.pictureURL == nil)
        let (descriptor, imported) = try await remote.importProfile("Default")
        #expect(descriptor.session.tabs == ["https://example.invalid/fixture"])
        #expect(imported.cookies.count == 1)
        #expect(imported.cookies[0].value == "synthetic-secret")
        #expect(imported.cookies[0].isSecure && imported.cookies[0].isHTTPOnly)
        #expect(imported.localStorage["https://example.invalid"]?["theme"] == "dark")
        var session = descriptor.session
        session.tabs = ["https://example.invalid/new-tab"]
        session.width = 900
        remote.save(session)
        await remote.drainActions()
        #expect(file.load() == session)
        remote.held(true)
        await remote.drainActions()
        #expect(engine.held)
        await #expect(throws: (any Error).self) { try await remote.importProfile("../../outside") }
        var invalid = NotchBrowserRemoteRequest(
            identity: identity, displayID: 42, presentationID: presentation, operation: .importRead)
        invalid.importID = descriptor.id
        invalid.offset = 0
        await #expect(throws: (any Error).self) { try await engine.execute(invalid) }
        engine.stop()
        await #expect(throws: (any Error).self) {
            try await engine.execute(
                .init(
                    identity: identity, displayID: 42, presentationID: presentation,
                    operation: .read))
        }
        await engine.stopAndWait()
    }

    @Test func downloadedBytesPreserveOriginalUniqueNamesAndCancelOnlyOwnedStaging() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notch-download-fixture-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("Downloads")
        let staging = root.appendingPathComponent("Staging")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("existing fixture".utf8).write(
            to: destination.appendingPathComponent("report.txt"))
        var completed: [URL] = []
        let engine = NotchBrowserDownloadEngine(
            destination: { destination }, staging: staging, completed: { completed.append($0) })
        defer { engine.stop() }
        let descriptor = try engine.start("report.txt")
        let first = Data(repeating: 65, count: 65536)
        let second = Data("final synthetic bytes".utf8)
        try engine.write(id: descriptor.id, offset: 0, bytes: first)
        #expect(throws: (any Error).self) {
            try engine.write(id: descriptor.id, offset: 0, bytes: second)
        }
        try engine.write(id: descriptor.id, offset: UInt64(first.count), bytes: second)
        let result = try engine.commit(id: descriptor.id)
        #expect(result.name == "report (1).txt")
        #expect(
            try Data(contentsOf: destination.appendingPathComponent(result.name)) == first + second)
        #expect(
            try String(
                contentsOf: destination.appendingPathComponent("report.txt"), encoding: .utf8)
                == "existing fixture")
        #expect(completed == [destination.appendingPathComponent("report (1).txt")])
        let cancelled = try engine.start("cancelled.txt")
        try engine.write(id: cancelled.id, offset: 0, bytes: second)
        engine.cancel(id: cancelled.id)
        #expect(
            !FileManager.default.fileExists(
                atPath: staging.appendingPathComponent(cancelled.id.uuidString).path))
        #expect(throws: (any Error).self) { try engine.commit(id: cancelled.id) }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("cancelled.txt").path))
        #expect(throws: (any Error).self) { try engine.start("invalid\u{0}name") }
    }
}
