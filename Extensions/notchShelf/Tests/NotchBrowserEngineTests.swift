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
        let owner = UUID()
        let descriptor = try engine.start("report.txt", owner: owner)
        let first = Data(repeating: 65, count: 65536)
        let second = Data("final synthetic bytes".utf8)
        try engine.write(id: descriptor.id, owner: owner, offset: 0, bytes: first)
        #expect(throws: (any Error).self) {
            try engine.write(id: descriptor.id, owner: owner, offset: 0, bytes: second)
        }
        try engine.write(
            id: descriptor.id, owner: owner, offset: UInt64(first.count), bytes: second)
        let result = try engine.commit(id: descriptor.id, owner: owner)
        #expect(result.name == "report (1).txt")
        #expect(
            try Data(contentsOf: destination.appendingPathComponent(result.name)) == first + second)
        #expect(
            try String(
                contentsOf: destination.appendingPathComponent("report.txt"), encoding: .utf8)
                == "existing fixture")
        #expect(completed == [destination.appendingPathComponent("report (1).txt")])
        let cancelled = try engine.start("cancelled.txt", owner: owner)
        try engine.write(id: cancelled.id, owner: owner, offset: 0, bytes: second)
        try engine.cancel(id: cancelled.id, owner: owner)
        #expect(
            !FileManager.default.fileExists(
                atPath: staging.appendingPathComponent(cancelled.id.uuidString).path))
        #expect(throws: (any Error).self) { try engine.commit(id: cancelled.id, owner: owner) }
        #expect(
            !FileManager.default.fileExists(
                atPath: destination.appendingPathComponent("cancelled.txt").path))
        #expect(throws: (any Error).self) { try engine.start("invalid\u{0}name", owner: owner) }
    }
    @Test func streamedDownloadsRejectOtherScenesAndReleaseOnlyTheirOwnedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "notch-download-scene-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "notch-download-defaults-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 10000)
        let storage = NotchBrowserDownloadEngine(
            destination: { root.appendingPathComponent("Downloads") },
            staging: root.appendingPathComponent("Staging"), now: { now }, completed: { _ in })
        let engine = NotchBrowserEngine(
            installation: .init(
                applicationURL: { nil }, defaultBrowser: { nil },
                userData: .init(root: root.appendingPathComponent("Chrome"))),
            sessionFile: .init(url: root.appendingPathComponent("Session.json")),
            defaults: defaults, keyProvider: { SyntheticChrome.key },
            open: { _, _ in Issue.record("No app may open") }, downloads: storage)
        defer { engine.stop() }
        let owner = UUID()
        let other = UUID()
        let identity = NotchPanelIdentity(ownershipID: UUID(), generation: UUID())
        let remote = NotchBrowserRemoteClient(
            state: try engine.state(),
            request: {
                .init(identity: identity, displayID: 42, presentationID: owner, operation: $0)
            }, invoke: { try await engine.execute($0) })
        defer { remote.stop() }
        let bytes = Data(repeating: 83, count: 180000)
        let source = root.appendingPathComponent("synthetic-download")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try bytes.write(to: source)
        let descriptor = try await remote.beginDownload("download.bin")
        var stolen = NotchBrowserRemoteRequest(
            identity: identity, displayID: 42, presentationID: other, operation: .downloadCommit)
        stolen.downloadID = descriptor.id
        await #expect(throws: (any Error).self) { try await engine.execute(stolen) }
        let name = try await remote.publishDownload(descriptor, file: source)
        #expect(
            try Data(
                contentsOf: root.appendingPathComponent("Downloads").appendingPathComponent(name))
                == bytes)
        let first = try storage.start("one.txt", owner: owner)
        let second = try storage.start("two.txt", owner: other)
        engine.release(owner: owner)
        #expect(throws: (any Error).self) { try storage.commit(id: first.id, owner: owner) }
        try storage.write(id: second.id, owner: other, offset: 0, bytes: Data([2]))
        now = now.addingTimeInterval(1801)
        storage.expire()
        #expect(throws: (any Error).self) { try storage.commit(id: second.id, owner: other) }
        #expect(
            try FileManager.default.contentsOfDirectory(
                atPath: root.appendingPathComponent("Staging").path
            ).isEmpty)
        #expect(throws: (any Error).self) { try storage.start("..", owner: owner) }
    }

}
