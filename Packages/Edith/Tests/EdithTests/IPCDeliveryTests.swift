import Foundation
import Testing

@testable import EdithKit

@Suite struct IPCDeliveryTests {
    @Test func aMessageIsDeliveredOnceEvenWhenBothPathsArrive() {
        let seen = IPCDeduplicator()
        let id = UUID().uuidString

        #expect(seen.accept(id))
        #expect(!seen.accept(id))
    }

    @Test func distinctMessagesAllArrive() {
        let seen = IPCDeduplicator()

        #expect(seen.accept("a"))
        #expect(seen.accept("b"))
        #expect(seen.accept("c"))
    }

    @Test func aMessageWithoutAnIdentifierIsNeverDropped() {
        let seen = IPCDeduplicator()

        #expect(seen.accept(nil))
        #expect(seen.accept(nil))
    }

    @Test func theWindowForgetsTheOldestIdentifiers() {
        let seen = IPCDeduplicator()
        let first = "0"
        #expect(seen.accept(first))
        for index in 1...IPCDeduplicator.capacity {
            #expect(seen.accept(String(index)))
        }

        #expect(seen.accept(first))
    }

    @Test func aPostedMessageCarriesAnIdentifier() {
        var body: [String: Any] = ["command": "play"]
        body[IPCMessage.idKey] = UUID().uuidString

        #expect(body[IPCMessage.idKey] is String)
        #expect(AgentBusEncoding.isTransportable(body))
    }

    @Test func aDiscardedObservationKeepsListening() {
        let before = IPCObservationRegistry.shared.count
        var token: NSObjectProtocol? = IPC.observe(IPC.Name.settingsChanged) {}

        #expect(IPCObservationRegistry.shared.count == before + 1)

        token = nil
        _ = token
        #expect(IPCObservationRegistry.shared.count == before + 1)
    }

    @Test func stoppingAnObservationReleasesIt() {
        let before = IPCObservationRegistry.shared.count
        let token = IPC.observe(IPC.Name.settingsChanged) {}
        #expect(IPCObservationRegistry.shared.count == before + 1)

        IPC.stopObserving(token)

        #expect(IPCObservationRegistry.shared.count == before)
    }

    @Test func theTransportRetriesOnlyAfterItsCooldown() {
        let now = Date()

        #expect(IPCTransport.shouldTry(lastFailure: nil, now: now))
        #expect(!IPCTransport.shouldTry(lastFailure: now.addingTimeInterval(-1), now: now))
        #expect(
            IPCTransport.shouldTry(
                lastFailure: now.addingTimeInterval(-IPCTransport.cooldown - 1), now: now))
    }
}
