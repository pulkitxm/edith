import EdithExtensionSupport
import Foundation
import Testing

@testable import MusicExtension

@MainActor @Suite(.serialized) struct MusicHostNavigationTests {
    @Test func owningBridgePreservesFolderIntentOnlyAfterExactAcknowledgement() async throws {
        let bridge = MusicNavigationFixtureBridge()
        let client = try #require(MusicHostNavigationBridge(bridge: bridge))
        let prior = MusicHostNavigation.navigate
        MusicHostNavigation.reset()
        MusicHostNavigation.navigate = client.navigate
        defer {
            client.invalidate(); MusicHostNavigation.reset(); MusicHostNavigation.navigate = prior
        }
        let id = UUID()
        let task = Task {
            try await MusicHostNavigation.open(
                path: "Mock Collection", presentationID: id, location: "notch")
        }
        for _ in 0..<50 where bridge.requests.isEmpty { await Task.yield() }
        let request = try #require(bridge.requests.first)
        #expect(request["section"] as? String == "music")
        #expect(request["relativePath"] as? String == "Mock Collection")
        #expect(request["presentationID"] as? String == id.uuidString)
        #expect(request["location"] as? String == "notch")
        #expect(MusicHostNavigation.folderIntent == nil)
        bridge.completeFirst(nil)
        try await task.value
        #expect(MusicHostNavigation.folderIntent == .init(revision: 1, path: "Mock Collection"))
        let root = Task { try await MusicHostNavigation.open(path: "") }
        for _ in 0..<50 where bridge.requests.count < 2 { await Task.yield() }
        #expect(bridge.requests.last?["relativePath"] == nil)
        bridge.completeFirst(nil)
        try await root.value
        #expect(MusicHostNavigation.folderIntent == .init(revision: 2, path: ""))
    }

    @Test func cancelDisableAndLateAcknowledgementCannotRestoreFolderIntent() async throws {
        let bridge = MusicNavigationFixtureBridge()
        let client = try #require(MusicHostNavigationBridge(bridge: bridge))
        let prior = MusicHostNavigation.navigate
        MusicHostNavigation.reset(); MusicHostNavigation.navigate = client.navigate
        defer { MusicHostNavigation.reset(); MusicHostNavigation.navigate = prior }
        let task = Task { try await MusicHostNavigation.open(path: "Mock") }
        for _ in 0..<50 where bridge.requests.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(bridge.canceled.count == 1)
        bridge.completeFirst(nil)
        #expect(MusicHostNavigation.folderIntent == nil)
        let disabled = Task { try await MusicHostNavigation.open(path: "Mock Other") }
        for _ in 0..<50 where bridge.requests.count < 2 { await Task.yield() }
        client.invalidate(); MusicHostNavigation.reset()
        await #expect(throws: (any Error).self) { try await disabled.value }
        bridge.completeFirst(nil)
        await client.stopAndWait()
        #expect(bridge.canceled.count == 2)
        #expect(MusicHostNavigation.folderIntent == nil)
    }

    @Test func invalidPathsOriginsAndMissingBridgeFailBeforeDispatch() async throws {
        #expect(MusicHostNavigationBridge(bridge: NSObject()) == nil)
        let bridge = MusicNavigationFixtureBridge()
        let client = try #require(MusicHostNavigationBridge(bridge: bridge))
        for path in [
            "/mock", "../mock", "Mock/../Other", "Mock//Other", "Mock/./Other", "Mock\\Other",
            "Mock\0Other", String(repeating: "x", count: 4097),
        ] {
            await #expect(throws: (any Error).self) {
                try await client.navigate(.init(section: "music", path: path))
            }
        }
        await #expect(throws: (any Error).self) {
            try await client.navigate(.init(section: "music", path: nil, presentationID: UUID()))
        }
        #expect(bridge.requests.isEmpty)
        client.invalidate()
    }
}

@MainActor private final class MusicNavigationFixtureBridge: NSObject {
    var requests: [NSDictionary] = []
    var canceled: [String] = []
    private var completions: [(NSString?) -> Void] = []
    @objc(navigate:completion:) func navigate(
        _ input: NSDictionary, completion: @escaping (NSString?) -> Void
    ) -> NSString? {
        requests.append(input); completions.append(completion)
        return UUID().uuidString as NSString
    }
    @objc(cancelNavigation:) func cancelNavigation(_ token: NSString) {
        canceled.append(token as String)
    }
    func completeFirst(_ message: NSString?) { completions.removeFirst()(message) }
}
