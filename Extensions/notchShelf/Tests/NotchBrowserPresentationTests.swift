import Foundation
import Testing
import WebKit
@testable import NotchShelfExtension

@MainActor @Suite(.serialized) struct NotchBrowserPresentationTests {
    @Test func exactLeaseOwnerRevisionExpiryAndDisableRejectNativeReuse() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let (descriptor, _) = try await fixture.remote.importProfile("Default")
        let original = descriptor.lease
        #expect(original.presentationID == fixture.owner)
        #expect(original.profileID == "Default")
        var request = fixture.request(.leaseRenew)
        request.lease = original
        let next = try JSONDecoder().decode(
            NotchBrowserLease.self, from: await fixture.engine.execute(request))
        #expect(next.id == original.id && next.revision == 2)
        await #expect(throws: (any Error).self) { try await fixture.engine.execute(request) }
        request.lease = next
        request = NotchBrowserRemoteRequest(
            identity: fixture.identity, displayID: 42, presentationID: UUID(),
            operation: .leaseRenew, lease: next)
        await #expect(throws: (any Error).self) { try await fixture.engine.execute(request) }
        fixture.clock.now = Date().addingTimeInterval(121)
        fixture.engine.expireLeases()
        request = fixture.request(.leaseRenew)
        request.lease = next
        await #expect(throws: (any Error).self) { try await fixture.engine.execute(request) }
        fixture.clock.now = Date()
        _ = try await fixture.remote.importProfile("Default")
        fixture.engine.release(owner: fixture.owner)
        await #expect(throws: (any Error).self) { try await fixture.remote.renewLease() }
        await fixture.remote.stopAndWait()
    }

    @Test func boundedPresentationCapacityAndExactSceneRelease() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        var issued: [NotchBrowserImport] = []
        for _ in 0..<8 {
            var start = fixture.request(.importStart)
            start = NotchBrowserRemoteRequest(
                identity: fixture.identity, displayID: 42, presentationID: UUID(),
                operation: .importStart, profileID: "Default")
            let descriptor = try JSONDecoder().decode(
                NotchBrowserImport.self, from: await fixture.engine.execute(start))
            var end = start
            end = NotchBrowserRemoteRequest(
                identity: fixture.identity, displayID: 42,
                presentationID: start.presentationID, operation: .importEnd,
                importID: descriptor.id)
            _ = try await fixture.engine.execute(end)
            issued.append(descriptor)
        }
        var ninth = fixture.request(.importStart)
        ninth.profileID = "Default"
        await #expect(throws: (any Error).self) { try await fixture.engine.execute(ninth) }
        fixture.engine.release(owner: issued[0].lease.presentationID)
        _ = try await fixture.remote.importProfile("Default")
        var sibling = NotchBrowserRemoteRequest(
            identity: fixture.identity, displayID: 42,
            presentationID: issued[1].lease.presentationID, operation: .leaseRenew)
        sibling.lease = issued[1].lease
        _ = try await fixture.engine.execute(sibling)
        await fixture.remote.stopAndWait()
    }

    private final class Clock { var now = Date() }

    @MainActor private struct Fixture {
        let chrome: SyntheticChrome
        let engine: NotchBrowserEngine
        let remote: NotchBrowserRemoteClient
        let clock = Clock()
        let identity = NotchPanelIdentity(ownershipID: UUID(), generation: UUID())
        let owner = UUID()
        let suite = "notch-browser-lease-" + UUID().uuidString

        init() throws {
            chrome = try SyntheticChrome(profiles: [.init(directory: "Default", name: "Mock")])
            let root = chrome.root
            engine = NotchBrowserEngine(
                installation: .init(
                    applicationURL: { root.appendingPathComponent("Mock Chrome.app") },
                    defaultBrowser: { (ChromeInstallation.bundleIdentifier, "Mock") },
                    userData: chrome.userData),
                sessionFile: .init(url: root.appendingPathComponent("Session.json")),
                defaults: try #require(UserDefaults(suiteName: suite)),
                keyProvider: { SyntheticChrome.key },
                open: { _, _ in Issue.record("No app may open") },
                downloads: .init(
                    destination: { root.appendingPathComponent("Downloads") },
                    staging: root.appendingPathComponent("Staging"), completed: { _ in }),
                openURL: { _ in
                    Issue.record("No URL may open"); return false
                },
                now: { [clock] in clock.now })
            let identity = identity
            let owner = owner
            remote = NotchBrowserRemoteClient(
                state: try engine.state(),
                request: {
                    .init(identity: identity, displayID: 42, presentationID: owner, operation: $0)
                },
                invoke: { [engine] in try await engine.execute($0) })
        }

        func request(_ operation: NotchBrowserRemoteRequest.Operation) -> NotchBrowserRemoteRequest
        {
            .init(identity: identity, displayID: 42, presentationID: owner, operation: operation)
        }

        func clean() {
            remote.stop(); engine.stop(); chrome.remove()
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }
}
