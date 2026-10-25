import Foundation
import Testing

@testable import CompanionExtension

@MainActor
struct CompanionTransportOwnershipTests {
    @Test func closingEitherWindowPreservesTheOtherRemoteConnection() async throws {
        let transport = CompanionTransport()
        let firstID = UUID(), secondID = UUID()
        let first = CompanionUIBridge(invoke: { _, _ in Data("first".utf8) })
        let second = CompanionUIBridge(invoke: { _, _ in Data("second".utf8) })
        transport.configureRemote(first, owner: firstID)
        transport.configureRemote(second, owner: secondID)
        transport.releaseRemote(secondID)
        #expect(try await transport.remoteBridge?.invoke("fixture", Data()) == Data("first".utf8))
        transport.configureRemote(second, owner: secondID)
        transport.releaseRemote(firstID)
        #expect(try await transport.remoteBridge?.invoke("fixture", Data()) == Data("second".utf8))
        transport.releaseRemote(secondID)
        #expect(transport.remoteBridge == nil)
    }
}
