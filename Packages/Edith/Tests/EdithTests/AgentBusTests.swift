import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentBusTests {
    @Test func aChannelRoundTripsThroughItsTopicName() {
        let topic = AgentBus.topic(for: "com.pulkit.edith.settingsChanged")
        #expect(topic == "bus:com.pulkit.edith.settingsChanged")
        #expect(AgentBus.channel(fromTopic: topic) == "com.pulkit.edith.settingsChanged")
        #expect(AgentBus.channel(fromTopic: "usage") == nil)
    }

    @Test func aMessageCarriesItsUserInfoAcrossTheWire() throws {
        let message = AgentBusMessage(
            channel: "test", userInfo: ["opened": true, "count": 3, "name": "box"])
        let round = try AgentPayload.decode(
            AgentBusMessage.self, from: AgentPayload.encode(message))

        #expect(round.channel == "test")
        #expect(round.userInfo["opened"] as? Bool == true)
        #expect(round.userInfo["count"] as? Int == 3)
        #expect(round.userInfo["name"] as? String == "box")
    }

    @Test func anEmptyBodyDecodesToAnEmptyUserInfo() {
        #expect(AgentBusMessage(channel: "test", body: Data()).userInfo.isEmpty)
    }

    @Test func onlyJSONSafeUserInfoTravels() {
        #expect(AgentBusEncoding.isTransportable(["a": 1, "b": "two", "c": [1, 2]]))
        #expect(!AgentBusEncoding.isTransportable(["date": Date()]))
    }

    @Test func aFailedDeliveryBacksOffBeforeTryingAgain() {
        let now = Date()
        #expect(IPCTransport.shouldTry(lastFailure: nil, now: now))
        #expect(!IPCTransport.shouldTry(lastFailure: now.addingTimeInterval(-5), now: now))
        #expect(IPCTransport.shouldTry(lastFailure: now.addingTimeInterval(-31), now: now))
    }

    @Test func theTransportStaysOffUntilAProcessOptsIn() {
        let state = IPCTransportState()
        #expect(!state.isEnabled)
        #expect(!state.shouldAttempt())

        state.enable()
        #expect(state.shouldAttempt())

        state.recordFailure()
        #expect(!state.shouldAttempt())

        state.disable()
        #expect(!state.isEnabled)
    }

    @Test func everyBusVerbIsServedByTheAgent() {
        for name in [AgentBus.publish, AgentBus.subscribe, AgentBus.unsubscribe] {
            #expect(AgentOperationCatalog.servesInternal(name))
        }
    }

    @Test func aSubscriberReceivesWhatAnotherPeerPublishes() async throws {
        let runtime = AgentRuntime(build: "test", store: nil)
        let listener = RecordingSubscriber()
        let publisher = UUID()
        let subscriber = UUID()

        await runtime.subscribeBus(peer: subscriber, channel: "chan", subscriber: listener)
        await runtime.publishBus(
            AgentBusMessage(channel: "chan", userInfo: ["hello": "there"]), from: publisher)

        #expect(listener.topics == ["bus:chan"])
        #expect(await runtime.busChannelCount == 1)
    }

    @Test func aPublisherDoesNotReceiveItsOwnMessage() async throws {
        let runtime = AgentRuntime(build: "test", store: nil)
        let listener = RecordingSubscriber()
        let peer = UUID()

        await runtime.subscribeBus(peer: peer, channel: "chan", subscriber: listener)
        await runtime.publishBus(AgentBusMessage(channel: "chan", body: Data()), from: peer)

        #expect(listener.topics.isEmpty)
    }

    @Test func unsubscribingStopsDelivery() async throws {
        let runtime = AgentRuntime(build: "test", store: nil)
        let listener = RecordingSubscriber()
        let peer = UUID()

        await runtime.subscribeBus(peer: peer, channel: "chan", subscriber: listener)
        await runtime.unsubscribeBus(peer: peer, channel: "chan")
        await runtime.publishBus(
            AgentBusMessage(channel: "chan", body: Data()), from: UUID())

        #expect(listener.topics.isEmpty)
        #expect(await runtime.busChannelCount == 0)
    }

    @Test func aDroppedPeerLosesItsChannels() async throws {
        let runtime = AgentRuntime(build: "test", store: nil)
        let peer = UUID()

        await runtime.subscribeBus(peer: peer, channel: "chan", subscriber: RecordingSubscriber())
        await runtime.forget(peer: peer)

        #expect(await runtime.busChannelCount == 0)
    }
}

private final class RecordingSubscriber: NSObject, EdithAgentSubscriberXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var topics: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func topicChanged(topic: String, payload: Data) {
        lock.lock()
        recorded.append(topic)
        lock.unlock()
    }
}
