import Darwin
import Foundation
import Testing
@testable import EdithExtensionSupport

@Suite(.serialized) @MainActor struct ExtensionNativeTaskAuthorizationTests {
    @Test func socketKernelPIDRejectsForgedRegistrationAndWrongParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try ExtensionPeerEndpoint(
            namespace: "native-task-fixture", owner: "fixture", directory: root)
        let server = ExtensionPeerServer(endpoint: endpoint) { _, command, payload in
            #expect(command == "extension.native.authorize")
            #expect(
                (try? JSONSerialization.jsonObject(with: payload) as? [String: Int32])?["pid"]
                    == getpid())
            return Data("authoritative configuration".utf8)
        }
        try server.start()
        defer { server.shutdown() }
        let result = try await Task.detached {
            try ExtensionNativeTaskAuthorization.request(endpoint: endpoint, parent: getpid())
        }.value
        #expect(result == Data("authoritative configuration".utf8))
        await #expect(throws: ExtensionPeerError.self) {
            try await Task.detached {
                try ExtensionNativeTaskAuthorization.request(endpoint: endpoint, parent: getppid())
            }.value
        }
        let original = try Data(contentsOf: endpoint.registrationURL)
        var forged = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var identity = try #require(forged["process"] as? [String: Any])
        let parent = try #require(ExtensionProcessIdentity.read(getppid()))
        identity["pid"] = parent.pid
        identity["generation"] = parent.generation
        forged["process"] = identity
        try JSONSerialization.data(withJSONObject: forged).write(to: endpoint.registrationURL)
        await #expect(throws: ExtensionPeerError.self) {
            try await Task.detached {
                try ExtensionNativeTaskAuthorization.request(endpoint: endpoint, parent: getppid())
            }.value
        }
    }
}
